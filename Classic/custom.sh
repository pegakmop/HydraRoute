#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
echo "$(date "+%Y-%m-%d %H:%M:%S") Запуск установки КОСТЫЛЯ" >> "$LOG"

## анимация
animation() {
	local pid=$1
	local message=$2
	local spin='-\|/'

	echo -n "$message... "

	while kill -0 $pid 2>/dev/null; do
		for i in $(seq 0 3); do
			echo -ne "\b${spin:$i:1}"
			usleep 100000  # 0.1 сек
		done
	done

	wait $pid
	if [ $? -eq 0 ]; then
		echo -e "\b✔ Готово!"
	else
		echo -e "\b✖ Ошибка!"
	fi
}

# Получение списка и выбор интерфейса
get_interfaces() {
    ## выводим список интерфейсов для выбора
    echo "Доступные интерфейсы:"
    i=1
    interfaces=$(ip a | sed -n 's/.*: \(.*\): <.*UP.*/\1/p')
    interface_list=""
    for iface in $interfaces; do
        ## проверяем, существует ли интерфейс, игнорируя ошибки 'ip: can't find device'
        if ip a show "$iface" &>/dev/null; then
            ip_address=$(ip a show "$iface" | grep -oP 'inet \K[\d.]+')

            if [ -n "$ip_address" ]; then
                echo "$i. $iface: $ip_address"
                interface_list="$interface_list $iface"
                i=$((i+1))
            fi
        fi
    done

    ## запрашиваем у пользователя имя интерфейса с проверкой ввода
    while true; do
        read -p "Введите ИМЯ интерфейса, через которое будет перенаправляться трафик: " net_interface

        if echo "$interface_list" | grep -qw "$net_interface"; then
            echo "Выбран интерфейс: $net_interface"
			break
		else
			echo "Неверный выбор, необходимо ввести ИМЯ интерфейса из списка."
		fi
	done
}

# Установка пакетов
opkg_install() {
	opkg update
	opkg install ip-full
}

# Формирование файлов
files_create() {
## ipset
	cat << EOF > /opt/etc/init.d/S52ipset
#!/bin/sh

PATH=/opt/sbin:/opt/bin:/opt/usr/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "\$1" = "start" ]; then
    ipset create bypass hash:ip
    ip rule add fwmark 1001 table 1001
fi
EOF
	
## скрипты маршрутизации
	cat << EOF > /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
#!/bin/sh

[ "\$system_name" == "$net_interface" ] || exit 0
[ ! -z "\$(ipset --quiet list bypass)" ] || exit 0
[ "\${connected}-\${link}-\${up}" == "yes-up-up" ] || exit 0

if [ -z "\$(ip route list table 1001)" ]; then
    ip route add default dev \$system_name table 1001
fi
EOF
	

## cкрипты маркировки трафика
	cat << EOF > /opt/etc/ndm/netfilter.d/010-bypass.sh
#!/bin/sh

[ "\$type" == "ip6tables" ] && exit
[ "\$table" != "mangle" ] && exit
[ -z "\$(ip link list | grep $net_interface)" ] && exit
[ -z "\$(ipset --quiet list bypass)" ] && exit

iptables -w -t mangle -C PREROUTING ! -i $net_interface -m conntrack --ctstate NEW -m set --match-set bypass dst -j CONNMARK --set-mark 1001 2>/dev/null || \
iptables -w -t mangle -A PREROUTING ! -i $net_interface -m conntrack --ctstate NEW -m set --match-set bypass dst -j CONNMARK --set-mark 1001

iptables -w -t mangle -C PREROUTING ! -i $net_interface -m set --match-set bypass dst -j CONNMARK --restore-mark 2>/dev/null || \
iptables -w -t mangle -A PREROUTING ! -i $net_interface -m set --match-set bypass dst -j CONNMARK --restore-mark
EOF

# Базовый список доменов для костыля с 3D защитой на всякий случай... ))
domain_add() {
	config_file="/opt/etc/AdGuardHome/ipset.conf"
	pattern="googlevideo.com\|ggpht.com\|googleapis.com\|googleusercontent.com\|gstatic.com\|nhacmp3youtube.com\|youtu.be\|youtube.com\|ytimg.com"
	sed -i "/$pattern/d" "$config_file"
	cat << EOF >> "$config_file"
googlevideo.com,ggpht.com,googleapis.com,googleusercontent.com,gstatic.com,nhacmp3youtube.com,youtu.be,youtube.com,ytimg.com/bypass
EOF
}

# Установка прав на скрипты
chmod_set() {
	chmod +x /opt/etc/init.d/S52ipset
	chmod +x /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
	chmod +x /opt/etc/ndm/netfilter.d/010-bypass.sh
}

# Отключение ipv6 на провайдере
disable_ipv6() {
	curl -kfsS "localhost:79/rci/show/interface/" | jq -r '
	  to_entries[] | 
	  select(.value.defaultgw == true or .value.via != null) | 
	  if .value.via then "\(.value.id) \(.value.via)" else "\(.value.id)" end
	' | while read -r iface via; do
	  ndmc -c "no interface $iface ipv6 address"
	  if [ -n "$via" ]; then
		ndmc -c "no interface $via ipv6 address"
	  fi
	done
	ndmc -c 'system configuration save'
}

# Сообщение установка ОK
complete_info() {
	echo "Установка КОСТЫЛЯ завершена"
	echo "Нажми Enter для перезагрузки (обязательно)."
}

# === main ===
# Запрос интерфейса у пользователя
get_interfaces

# Установка пакетов
opkg_install >>"$LOG" 2>&1 &
animation $! "Установка необходимых пакетов"

# Формирование скриптов 
files_create >>"$LOG" 2>&1 &
animation $! "Формируем скрипты"

# Добавление YOUTUBE в ipset
domain_add >>"$LOG" 2>&1 &
animation $! "Добавление в ipset YOUTUBE через костыль"

# Установка прав на выполнение скриптов
chmod_set >>"$LOG" 2>&1 &
animation $! "Установка прав на выполнение скриптов"

# Отключение ipv6
disable_ipv6 >>"$LOG" 2>&1 &
animation $! "Отключение ipv6"

# Завершение
echo ""
complete_info
rm -- "$0"

# Ждем Enter и ребутимся
read -r
reboot
