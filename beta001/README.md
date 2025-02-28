**v.0.0.1b(202501300900)**

# HydraRoute

**Основная цель** — перенаправление трафика к **отдельным доменам** через VPN. Все, что не указано в списке, будет открываться напрямую.

## Установка:
1. Подключитесь к роутеру по SSH (к Entware).
2. Выполните команду:
```
curl -L -s "https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/refs/heads/main/beta001/hydraroute.sh" > /opt/tmp/hydraroute.sh && chmod +x /opt/tmp/hydraroute.sh && /opt/tmp/hydraroute.sh
```
3. Выберите VPN из списка.

## Дополнительная информация:
### Как добавить домены в ipset

1. Через web-панель.
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
