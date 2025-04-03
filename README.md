# HydraRoute

**HydraRoute** — инструмент для раздельной маршрутизации трафика по доменам с использованием VPN на роутерах **Keenetic**.

💡 Трафик к указанным доменам отправляется через VPN, а всё остальное — напрямую.  
Управление политиками — через Web-интерфейс роутера или конфигурационные файлы.

---

## 🚀 Возможности

- Перенаправление трафика отдельных доменов через VPN.
- Поддержка нескольких политики и маршрутизации в разные туннели.
- Поддержка IPv6 и ip6tables (в Neo).
- Настройка через Web-интерфейс или вручную.
- Поддержка мульти-WAN и агрегации каналов.
- Защищенные DNS через TLS.
- Возможность суммирования пропускной способности каналов.
- Перенаправление отдельных доменов через разные VPN.
- Совместимость с WARP.
- Фильтрация рекламы (в Classic).

---

## 🧬 Версии HydraRoute

### 🔹 Classic

- Простота установки и управления.
- Управление подключениями через Web-интерфейс Keenetic.
- Редактирование списков доменов в Web-интерфейсе RydraRoute.
- Поддержка до 3х предустановленных политик.
- Интеграция IPset с AdGuard Home.
- Подходит для большинства пользователей.

[Подробнее →](https://github.com/Ground-Zerro/HydraRoute/tree/main/Classic)

---

### 🔸 Neo

- Для продвинутых пользователей.
- Не требует отключения системного DNS.
- Пользователь сам задаёт названия и количество политик.
- Полная поддержка IPv6.

[Подробнее →](https://github.com/Ground-Zerro/HydraRoute/tree/main/Neo)

⚠️ *Neo — это концепт и подтверждение жизнеспособности подхода. Поддержка ограничена.*

---

## 📋 Требования

- Роутер с KeenOS
- Entware (установлен и настроен)
- Настроенное VPN-подключение (WireGuard, OpenVPN, etc.)
- Установленный `curl`

---

## 🧭 Планы на будущее

- Поддержка vless
- Интеграция с [zapret](https://github.com/bol-van/zapret)
- Обновления из WebUI

---

## ☕ Поддержка

Если проект оказался Вам полезен — можно поддержать автора:

- [Поддержать на Boosty](https://boosty.to/ground_zerro)
