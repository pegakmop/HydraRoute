**v.0.0.1b(202501300900)**

# HydraRoute

**Основная цель** — перенаправление запросов к **отдельным доменам** через VPN. Все, что не указано в списке, будет открываться напрямую.

Скрипт облегчает настройку раздельной маршрутизации трафика к доменам на роутерах **Keenetic**.
- Установка **"одной кнопкой"**.
- Никаких сложных настроек.
- Требуется всего 1 действие: указать VPN.

## Функции и возможности:
- Установка необходимых пакетов.
- Настройка и интеграция IPSet с AdGuard Home для управления маршрутизацией.
- Создание скриптов для динамической маршрутизации и маркировки трафика.
- Обход блокировки ECH Cloudflare.
- Установка DNS, защищенных шифрованием.
- Фильтрация рекламы.
    * Включены базовые фильтры рекламы, малваре и телеметрии Microsoft.
- Список доменов можно редактировать и расширять. После установки в него уже включены:
  - Youtube
  - Instagram
  - OpenAI (ChatGPT)
  - Некоторые T-трекеры

## Требования:
- KeenOS версия 4.х (Работа на 3.х возможна, но не тестировалась).
- Развёрнутая среда [Entware](https://help.keenetic.com/hc/ru/articles/360021214160-Установка-системы-пакетов-репозитория-Entware-на-USB-накопитель).
- Настроенное VPN подключение.

## Установка:
1. Подключитесь к роутеру по SSH (к Entware).
2. Выполните команду:
    ```
    curl -L -s "https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/refs/heads/main/beta001/hydraroute.sh" > /opt/tmp/hydraroute.sh && chmod +x /opt/tmp/hydraroute.sh && /opt/tmp/hydraroute.sh
    ```
3. Выберите VPN из списка.

## Дополнительная информация:
### Как добавить домены в ipset

1. Через [web-панель](https://github.com/Ground-Zerro/HydraRoute/tree/main/beta001/webpanel).
   - web-панель доступна по адресу: [http://192.168.1.1:2000/](http://192.168.1.1:2000/)
     * (где `192.168.1.1` - это IP-адрес роутера)

2. Вручную, правкой файла `ipset.conf`.

    <details>
    <summary>нажать, чтобы прочесть подробней</summary>
    
    1. Чтобы добавить домены для перенаправления, отредактируйте файл: `/opt/etc/AdGuardHome/ipset.conf`.
        ```
        nano /opt/etc/AdGuardHome/ipset.conf
        ```

        <details>
        <summary>Синтаксис файла ipset.conf (нажать, чтобы прочесть подробней)</summary>
    
        ```
        instagram.com,cdninstagram.com/bypass,bypass6
        openai.com,chatgpt.com/bypass,bypass6
        ```
        - В левой части через запятую указаны домены, требующие обхода.
        - Справа после слэша — ipset, в который AGH складывает результаты разрешения DNS-имён. В примере указаны созданные скриптом `ipset` для IPv4 и IPv6: `/bypass,bypass6`.
        - Можно указать всё в одну строчку, можно разделить логически на несколько строк, как в примере.
        - Домены третьего уровня и выше включаются сами, т.е. указание `intel.com` включает также `www.intel.com`, `download.intel.com` и прочее.
        </details>
    2. После добавления доменов необходимо перезапустить **AdGuard Home** командой:
        ```
        /opt/etc/init.d/S99adguardhome restart
        ```
    </details>

## Удаление:
```
curl -Ls "https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/refs/heads/main/uninstall.sh" | sh
```

## Планы на будущее
### To do
- ~~починить работу на роутерах с ARM~~
- ~~[Web панель в паблик релиз](https://github.com/Ground-Zerro/HydraRoute/tree/main/webpanel)~~ 30/01/2025
- ~~добавить дизайна~~ 22/02/2025 [в 0.0.2b](https://github.com/Ground-Zerro/HydraRoute/tree/main/beta)
- авторизация в web панели (нужна вообще она?)
- написать wiki или FAQ
- загрузка сторонних списокв из сети
- ~~[переписать установщик](https://github.com/Ground-Zerro/HydraRoute/blob/main/hydraroute.sh)~~ 01/02/2025

### Пожелания от пользоваталей
- ~~[boosty](https://boosty.to/ground_zerro)~~ 25/01/2025
- ~~опция: блокировать трафик если туннель не доступен (нет связи, отключен и т.п.)~~ 22/02/2025 [в 0.0.2b](https://github.com/Ground-Zerro/HydraRoute/tree/main/beta)
- ~~раздельная маршрутизация в два туннеля. Или в три?? ;)~~ 22/02/2025 [в 0.0.2b](https://github.com/Ground-Zerro/HydraRoute/tree/main/beta)
- расширение списка black листов
- опция: автоматическое обновление списокв по расписанию
- поддержка vless
- ~~[анигилятор](https://github.com/Ground-Zerro/HydraRoute/blob/main/uninstall.sh)~~ 28/01/2025
