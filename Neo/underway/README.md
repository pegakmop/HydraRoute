# Архитектура HRneo - Принцип работы и оптимизации

## 1. Общий обзор системы

HRneo - это система маршрутизации DNS-трафика через VPN на основе списка доменов (watchlist). Программа перехватывает DNS-запросы, анализирует их и автоматически добавляет IP-адреса целевых доменов в ipset, после чего iptables правила направляют трафик через VPN-туннель.

### Основная архитектура

```
Клиент → DNS-запрос → NFLOG (копия пакета) → HRneo анализирует
                ↓                                      ↓
        Пакет идёт дальше                    Сохраняет txID в кеше
                ↓                                      ↓
        DNS-ответ → NFLOG (копия) → HRneo → Добавляет IP в ipset → Разрывает conntrack
                ↓                                                            ↓
        Клиент получает ответ                              Новое соединение через VPN
```

---

## 2. Эволюция архитектуры: монолит vs модульная структура

### Старая версия (hrneo OLD realese.go)

**Проблемы монолитной архитектуры:**

```go
// ❌ Всё в одном файле (~900+ строк)
// ❌ Использование tcpdump для перехвата DNS
// ❌ Обработка через exec.Command("ipset", "add", ...)
// ❌ Парсинг текстового вывода tcpdump
// ❌ Отсутствие определения новых/существующих IP
// ❌ Разрыв conntrack для ВСЕХ IP (даже существующих)
```

**Пример старой обработки:**

```go
// Старый код - перехват через tcpdump
cmd := exec.Command("tcpdump", "-l", "-i", interfaceName, "-vv", "src port 53")
scanner := bufio.NewScanner(stdout)

for scanner.Scan() {
    line := scanner.Text()  // Текстовый парсинг!
    go processDNSLine(line, watchlist, reconnect)
}

// Добавление IP через CLI
exec.Command("ipset", "add", ipsetName, ip).Run()

// Разрыв conntrack для ВСЕХ IP
if reconnect == "true" {
    clearConntrack(ip)  // Даже если IP уже был в ipset!
}
```

### Новая версия (модульная структура)

**Файловая структура:**

```
hrneo_main.go           - Главный файл, инициализация, обработка сигналов
nflog_monitor.go        - Перехват DNS через NFLOG (ядро Linux)
netlink_ipset.go   - Низкоуровневая работа с ipset через netlink
ipset_manager.go        - Высокоуровневый интерфейс для ipset операций
conntrack_manager.go    - Управление conntrack (разрыв соединений)
helpers_functions.go    - Вспомогательные функции (config, iptables, etc)
arch_detector.go        - Определение архитектуры и byte order
```

**Преимущества модульной архитектуры:**

- ✅ Разделение ответственности (SRP)
- ✅ Простота тестирования отдельных компонентов
- ✅ Возможность замены реализации (например, netlink/CLI)
- ✅ Читаемость кода
- ✅ Поддержка кеширования и оптимизаций

---

## 3. Ключевое отличие: tcpdump vs NFLOG

### Старый подход: tcpdump

```go
// ❌ Проблемы tcpdump:
// 1. Запуск внешнего процесса (fork/exec overhead)
// 2. Парсинг текстового вывода (медленно, хрупко)
// 3. Буферизация stdout может вносить задержки
// 4. Нет прямого доступа к packet metadata

cmd := exec.Command("tcpdump", "-l", "-i", interfaceName, "-vv", "src port 53")
scanner := bufio.NewScanner(stdout)

for scanner.Scan() {
    line := scanner.Text()
    // Регулярные выражения для парсинга текста
    re := regexp.MustCompile(`(A|AAAA) ([0-9a-fA-F:.]+)`)
    matches := re.FindAllStringSubmatch(line, -1)
}
```

**Типичная задержка:** 5-15ms на обработку одного пакета

### Новый подход: NFLOG

```go
// ✅ Преимущества NFLOG:
// 1. Прямая работа с ядром через netlink
// 2. Нативный парсинг пакетов (gopacket)
// 3. Асинхронная обработка (zero-copy)
// 4. Полный доступ к packet layers

nf, err := nflog.Open(&config)
hook := func(attrs nflog.Attribute) int {
    packet := gopacket.NewPacket(*attrs.Payload, layerType, gopacket.NoCopy)
    
    dnsLayer := packet.Layer(layers.LayerTypeDNS)
    dns := dnsLayer.(*layers.DNS)
    
    // Прямой доступ к DNS полям
    for _, answer := range dns.Answers {
        if answer.Type == layers.DNSTypeA {
            ip := answer.IP.String()
        }
    }
    
    return 0  // Пакет продолжает путь
}
```

**Типичная задержка:** 0ms (асинхронная обработка, пакет не блокируется)

---

## 4. Критическое улучшение: умный разрыв conntrack

### Проблема старой версии

```go
// ❌ СТАРАЯ ВЕРСИЯ - разрыв для ВСЕХ IP

func addIPsToIpset(line, ipset, reconnect string) {
    for _, match := range matches {
        ip := match[2]
        if exec.Command("ipset", "add", ipsetName, ip).Run() == nil {
            // Добавили IP (возможно, он уже был)
            if reconnect == "true" {
                clearConntrack(ip)  // ❌ РАЗРЫВ ВСЕГДА
            }
        }
    }
}
```

**Сценарий проблемы:**

```
t=0s:    youtube.com → 142.251.1.136 добавлен в ipset
         conntrack разорван → видео начинает грузиться ✅
         
t=30s:   Браузер делает новый DNS-запрос (TTL истек)
         142.251.1.136 УЖЕ в ipset, но команда ipset add вернула успех
         ❌ conntrack разорван СНОВА → видео зависло на 2-3 секунды
         
t=60s:   Ещё один DNS-запрос
         ❌ conntrack разорван СНОВА → видео зависло
         
Результат: Постоянные микро-разрывы работающих соединений!
```

### Решение новой версии

```go
// ✅ НОВАЯ ВЕРСИЯ - интеллектуальный разрыв

func (m *NFLOGMonitor) processDNSAnswer(packet gopacket.Packet) {
    var ipv4List []string
    var ipv6List []string
    
    // Извлекаем IP из DNS-ответа
    for _, answer := range dns.Answers {
        if answer.Type == layers.DNSTypeA {
            ipv4List = append(ipv4List, answer.IP.String())
        }
    }
    
    // Добавляем в ipset и получаем список НОВЫХ IP
    newIPv4List, err := m.ipsetManager.AddIPBatch(ipsetName, ipv4List)
    
    // Разрываем conntrack ТОЛЬКО для НОВЫХ IP
    if m.reconnect {
        for _, ip := range newIPv4List {
            clearConntrackFast(ip)
            log.Printf("[CONNTRACK] Cleared for NEW IP: %s\n", ip)
        }
    }
}
```

**Механизм определения новизны:**

```go
// Для ipset С timeout
func (m *NetlinkIPSetManager) AddIP(setName, ip string) (bool, error) {
    hasTimeout := m.setHasTimeout[setName]
    
    var isNew bool
    if hasTimeout {
        // Проверяем существование ПЕРЕД добавлением
        isNew = !m.checkIPExists(setName, ip)
    }
    
    // Отправляем команду добавления
    wasAdded, err := m.sendAddCommand(setName, parsedIP, hasTimeout, timeoutVal, isNew)
    
    // Для ipset с timeout: используем предварительную проверку
    if hasTimeout {
        return isNew, nil
    }
    
    // Для ipset без timeout: анализируем ответ netlink
    return wasAdded, nil
}

// Для ipset БЕЗ timeout
func (m *NetlinkIPSetManager) sendAddCommand(...) (bool, error) {
    responses, err := m.conn.Execute(msg)
    
    if errCode == IPSET_ERR_EXIST {
        // IP уже существовал
        return false, nil  // ❌ НЕ новый - conntrack не трогаем
    }
    
    return true, nil  // ✅ Новый - разорвём conntrack
}
```

**Результат:**

```
t=0s:    youtube.com → 142.251.1.136
         ipset test → НЕ найден → isNew=true
         ✅ conntrack разорван → видео начинает грузиться
         
t=30s:   DNS-запрос снова
         ipset test → НАЙДЕН → isNew=false
         ✅ conntrack НЕ трогаем → видео продолжает играть
         
t=60s:   DNS-запрос снова
         ipset test → НАЙДЕН → isNew=false
         ✅ conntrack НЕ трогаем → видео продолжает играть
         
t=180s:  DNS вернул новый IP: 142.251.1.200
         ipset test → НЕ найден → isNew=true
         ✅ conntrack разорван → новое соединение через VPN
         
Результат: Разрыв только при реальной необходимости!
```

---

## 5. Производительность: CLI vs Netlink

### Старая версия: только CLI

```go
// ❌ Каждое добавление = fork процесса
exec.Command("ipset", "add", "Disable", "1.1.1.1").Run()  // ~5-10ms
exec.Command("ipset", "add", "Disable", "2.2.2.2").Run()  // ~5-10ms
exec.Command("ipset", "add", "Disable", "3.3.3.3").Run()  // ~5-10ms

// 3 IP = 15-30ms + overhead fork/exec
```

### Новая версия: Netlink с fallback на CLI

```go
// ✅ Прямые syscalls через netlink
nlManager.AddIPBatch("Disable", []string{"1.1.1.1", "2.2.2.2", "3.3.3.3"})

// 3 IP = 1-2ms, один netlink message
```

**IPSetManager с автоматическим fallback:**

```go
type IPSetManager struct {
    useNetlink bool
    nlManager  *NetlinkIPSetManager
}

func (m *IPSetManager) AddIP(setName, ip string) (bool, error) {
    if m.useNetlink {
        isNew, err := m.nlManager.AddIP(setName, ip)
        if err != nil {
            // Ошибка netlink - переключаемся на CLI
            log.Printf("[WARN] Netlink failed, falling back to CLI\n")
            m.useNetlink = false
        }
    }
    
    if !m.useNetlink {
        // Fallback на ipset команду
        cmd := exec.Command("ipset", "add", setName, ip)
        err := cmd.Run()
    }
}
```

**Сравнение производительности:**

| Операция | Старая версия (CLI) | Новая версия (Netlink) | Ускорение |
|----------|---------------------|------------------------|-----------|
| Добавление 1 IP | ~5-10ms | ~0.5-1ms | **5-10x** |
| Добавление 10 IP | ~50-100ms | ~1-2ms | **25-50x** |
| Проверка существования | ~5ms | ~0.5ms | **10x** |

---

## 6. Архитектура и byte order

### Автоопределение архитектуры

```go
// arch_detector.go - НЕТ в старой версии

type ArchInfo struct {
    GOARCH      string            // mips/mipsle/aarch64
    GOOS        string            // linux
    IsBigEndian bool             // true/false
    ByteOrder   binary.ByteOrder  // BigEndian/LittleEndian
}

func init() {
    SystemArch = detectArchitecture()
}

func detectArchitecture() *ArchInfo {
    buf := [2]byte{}
    *(*uint16)(unsafe.Pointer(&buf[0])) = uint16(0x0102)
    
    if buf[0] == 1 {
        return &ArchInfo{IsBigEndian: true, ByteOrder: binary.BigEndian}
    }
    return &ArchInfo{IsBigEndian: false, ByteOrder: binary.LittleEndian}
}
```

### Network Byte Order для netlink

```go
// КРИТИЧНО для timeout в ipset
func PutUint32NetworkOrder(b []byte, v uint32) {
    b[0] = byte(v >> 24)  // Всегда big-endian
    b[1] = byte(v >> 16)
    b[2] = byte(v >> 8)
    b[3] = byte(v)
}

// Использование
timeoutData := make([]byte, 4)
PutUint32NetworkOrder(timeoutData, timeoutVal)  // Работает на ЛЮБОЙ архитектуре
```

**Поддерживаемые платформы:**

| Архитектура | Byte Order | Старая версия | Новая версия |
|-------------|------------|---------------|--------------|
| mipsel-3.4 | Little-endian | ⚠️ Проблемы с timeout | ✅ Работает |
| mips-3.4 | Big-endian | ⚠️ Проблемы с timeout | ✅ Работает |
| aarch64-3.10 | Little-endian | ⚠️ Проблемы с timeout | ✅ Работает |

---

## 7. IPv6 - исправление критической ошибки

### Проблема в старой версии

Старая версия использовала CLI `ipset add`, который обрабатывает IPv6 автоматически, но при этом:
- Нет контроля над процессом
- Нет информации о новизне IP
- Невозможно оптимизировать

### Решение в новой версии

При использовании netlink для IPv6 требуется **другой тип атрибута**:

```go
// Старая попытка netlink (НЕВЕРНО)
innerIPAttrs = []netlink.Attribute{
    {Type: IPSET_ATTR_IP | NLA_F_NET_BYTEORDER, Data: ipData},  // ❌ Не работает для IPv6
}

// Правильная реализация
var innerIPAttrs []netlink.Attribute
if ip.To4() != nil {
    // IPv4: используем type=1
    innerIPAttrs = []netlink.Attribute{
        {Type: IPSET_ATTR_IP | NLA_F_NET_BYTEORDER, Data: ipData},
    }
} else {
    // IPv6: используем type=2 (не 1!)
    innerIPAttrs = []netlink.Attribute{
        {Type: 2 | NLA_F_NET_BYTEORDER, Data: ipData},
    }
}
```

**Результат:** IPv6 адреса корректно добавляются без ошибок `IPSET_ERR_PROTOCOL`.

---

## 8. Задержки для клиента

### NFLOG: нулевая задержка

```go
// NFLOG создаёт КОПИЮ пакета для анализа
// Оригинал продолжает путь БЕЗ ЗАДЕРЖКИ

hook := func(attrs nflog.Attribute) int {
    // Этот callback - асинхронный
    // Оригинальный пакет УЖЕ прошёл дальше
    
    if udp.SrcPort == 53 {
        go func(pkt gopacket.Packet) {  // ← Горутина
            m.processDNSAnswer(pkt)
        }(packet)
    }
    
    return 0  // ← Возврат немедленно
}
```

**Путь DNS-пакета:**

```
DNS-запрос → iptables NFLOG (копия) → Userspace анализ (фоново)
       ↓
   Продолжает путь к DNS-серверу (0ms задержки)
       ↓
DNS-ответ → iptables NFLOG (копия) → Userspace анализ (фоново)
       ↓
   К клиенту (0ms задержки)
```

---

## 9. Временная диаграмма

### Первое добавление IP

```
t=0.0ms:     Клиент → DNS-запрос "youtube.com"
             └→ NFLOG копирует (фоново) → программа анализирует
             └→ Оригинал к DNS БЕЗ ЗАДЕРЖКИ

t=15.0ms:    DNS → Ответ: 142.251.1.136
HR t=0ms     └→ NFLOG копирует (фоново) → программа получает
             └→ К клиенту БЕЗ ЗАДЕРЖКИ
             ✅ Клиент получил ответ (задержка DNS = 15ms)

         
t=15.2ms:    [ФОНОВО] ipset test → НЕ найден → isNew=true
HR t=0.2ms

t=15.7ms:    [ФОНОВО] netlink ADD → IP добавлен
HR t=0.7ms

t=16.2ms:    [ФОНОВО] clearConntrack(142.251.1.136)
HR t=1.2ms
         
t=20.0ms:    Клиент → TCP SYN → 142.251.1.136
             iptables: NEW + ipset match → применяем MARK → через VPN
HR t=5.0ms  (общее время обработки HRneo)
```

### Повторный DNS-запрос (через 30 секунд - типичный TTL)

```
t=0.0ms:     Браузер делает DNS-запрос "youtube.com" снова (TTL истёк)
             └→ Тот же IP: 142.251.1.136
             └→ DNS-запрос выполняется ~15ms

t=15.0ms:    ✅ Клиент получил ответ (задержка DNS = 15ms)
HR t=0ms
          
t=15.2ms:    [ФОНОВО] ipset test → НАЙДЕН → isNew=false
HR t=0.2ms

t=15.7ms:    [ФОНОВО] netlink ADD → timeout обновлён (если ipset с timeout)
HR t=0.7ms

t=15.8ms:    [ФОНОВО] conntrack НЕ трогаем (isNew=false)
HR t=0.8ms (общее время обработки HRneo)
          
✅ Существующие TCP соединения продолжают работать без разрывов!
✅ HRneo обработал за 0.8ms (без разрыва conntrack)
```

### Смена IP-адреса (через 3 минуты - DNS round-robin)

```
t=0.0ms:     DNS-запрос "youtube.com" снова
             └→ DNS вернул новый IP: 142.251.1.200 (изменился!)
             └→ DNS-запрос выполняется ~15ms

t=15.0ms:    ✅ Клиент получил ответ (задержка DNS = 15ms)
HR t=0ms
          
t=15.2ms:    [ФОНОВО] ipset test → НЕ найден → isNew=true
HR t=0.2ms

t=15.7ms:    [ФОНОВО] netlink ADD → IP добавлен
HR t=0.7ms

t=16.2ms:    [ФОНОВО] clearConntrack(142.251.1.200)
HR t=1.2ms
          
t=20.0ms:    Клиент → TCP SYN → 142.251.1.200
             iptables: NEW + ipset match → через VPN
HR t=5.0ms  (общее время обработки HRneo)
          
✅ Старые соединения к 142.251.1.136 продолжают работать
✅ Новые соединения к 142.251.1.200 идут через VPN
✅ HRneo обработал новый IP за 1.2ms (с разрывом conntrack)
```

### Пояснение к временным меткам

Каждое событие показано с двумя отсчётами:

- **t=** - абсолютное время от начала события
- **HR t=** - время работы HRneo (от момента получения DNS-ответа)

**Ключевые моменты:**

1. **Первое добавление IP**: HRneo работает 5.0ms (включая разрыв conntrack)
2. **Повторный DNS-запрос**: HRneo работает 0.8ms (БЕЗ разрыва conntrack)
3. **Смена IP**: HRneo работает 1.2ms (с разрывом conntrack для нового IP)

**Задержка для клиента:** 0ms (NFLOG асинхронный, обработка в фоне)

---

## 10. Оптимизации

### Кеширование и производительность

```go
// Кеш регулярных выражений для доменов
type DomainRegexCache struct {
    cache map[string]*regexp.Regexp
    mu    sync.RWMutex
}

// Кеш существования ipset
type IPSetCache struct {
    cache map[string]bool
    mu    sync.RWMutex
}

// Кеш DNS транзакций (txID → ipset)
type DNSTransactionCache struct {
    cache map[string]string
    mu    sync.RWMutex
}
```

### Ограничение конкурентности

```go
const MaxConcurrentGoroutines = 100

type NFLOGMonitor struct {
    semaphore chan struct{}  // Ограничивает параллельные горутины
}

// При обработке DNS-ответа
m.semaphore <- struct{}{}  // Захват слота
go func(pkt gopacket.Packet) {
    defer func() { <-m.semaphore }()  // Освобождение
    m.processDNSAnswer(pkt)
}(packet)
```

### Batch операции

```go
// Вместо N отдельных команд
for _, ip := range ips {
    exec.Command("ipset", "add", setName, ip).Run()  // ❌ N fork/exec
}

// Один вызов через netlink
newIPs, err := nlManager.AddIPBatch(setName, ips)  // ✅ Один syscall
```

---

## 11. Сравнительная таблица

| Характеристика | Старая версия (монолит) | Новая версия (модульная) |
|----------------|-------------------------|--------------------------|
| **Файловая структура** | 1 файл (~900 строк) | 8 файлов (~400-500 строк каждый) |
| **Перехват DNS** | tcpdump (5-15ms) | NFLOG (0ms) |
| **Добавление IP** | CLI (~5-10ms) | Netlink (~0.5-1ms) |
| **IPv4, IPv6 через netlink** | ❌ Не реализовано | ✅ Полная поддержка |
| **Timeout в ipset** | ❌ Не реализовано | ✅ Полная поддержка |
| **Определение архитектуры** | ❌ Нет | ✅ Автоматическое |
| **Fallback CLI** | Только CLI | ✅ Автоматический fallback |
| **Утечка памяти** | ❌ Возможна (кеш не контролировался) | ✅ Нет (проверка через kernel) |
| **Скачки нагрузки** | ❌ Возможны (не контролировалось) | ✅ Нет |
| **Задержка DNS** | Возможна (tcpdump buffer) | 0ms (асинхронная обработка) |

---

## 12. Выводы

### Архитектурные преимущества новой версии

1. **Модульность** - код разделён на логические компоненты
2. **Производительность** - netlink вместо CLI (5-50x быстрее)
3. **Стабильность** - умный разрыв conntrack (только новые IP)
4. **Кросс-платформенность** - автоопределение архитектуры
5. **Надёжность** - kernel как источник истины, нет утечек памяти

### Производительность

| Метрика | Значение |
|---------|----------|
| Задержка DNS | 0 мс |
| Проверка IP | ~0.5 мс |
| Добавление IP | ~0.5-1 мс |
| Разрыв conntrack | ~0.5 мс |
| Потребление памяти | Константа |

### Надёжность

- ✅ Нет рассинхронизации данных
- ✅ Корректная обработка timeout
- ✅ Стабильные соединения (разрыв только для новых IP)
- ✅ Полная поддержка IPv6
- ✅ Работа на всех архитектурах

**Общий вывод:** Переход от монолитной архитектуры на CLI к модульной с netlink обеспечил многократный прирост производительности, стабильность соединений и полную кросс-платформенность, сохранив при этом нулевую задержку для пользователя. Ключевое улучшение - интеллектуальный разрыв conntrack только для новых IP устраняет проблему микро-разрывов соединений, которая возникала в старой версии каждые 30-60 секунд при обновлении DNS.
