#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
printf "\n%s Удаление\n" "$(date "+%Y-%m-%d %H:%M:%S")" >>"$LOG" 2>&1
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
REQUIRED_VERSION="4.2.3"
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

  echo -e "\b✔ Готово!"
}

# удаление пакетов
opkg_uninstall() {
	/opt/etc/init.d/S99adguardhome stop
	/opt/etc/init.d/S99hpanel stop
	/opt/etc/init.d/S99hrpanel stop
	opkg remove adguardhome-go ipset iptables jq node-npm node
}

# удаление файлов
files_uninstall() {
	FILES="
	/opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
	/opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
	/opt/etc/ndm/netfilter.d/010-bypass.sh
	/opt/etc/ndm/netfilter.d/011-bypass6.sh
	/opt/etc/ndm/netfilter.d/010-hydra.sh
	/opt/etc/init.d/S52ipset
	/opt/etc/init.d/S52hydra
	/opt/etc/init.d/S99hpanel
	/opt/etc/init.d/S99hrpanel
	/opt/var/log/AdGuardHome.log
	/opt/bin/agh
	/opt/bin/hr
	/opt/bin/hrpanel
	"

	for FILE in $FILES; do
		[ -f "$FILE" ] && { chmod 777 "$FILE" || true; rm -f "$FILE"; }
	done

	[ -d /opt/etc/HydraRoute ] && { chmod -R 777 /opt/etc/HydraRoute || true; rm -rf /opt/etc/HydraRoute; }
	[ -d /opt/etc/AdGuardHome ] && { chmod -R 777 /opt/etc/AdGuardHome || true; rm -rf /opt/etc/AdGuardHome; }
}

# удаление политик
policy_uninstall() {
	for suffix in 1st 2nd 3rd; do
		ndmc -c "no ip policy HydraRoute$suffix"
	done
	ndmc -c 'system configuration save'
	sleep 2
}

# проверка версии прошивки
firmware_check() {
	if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
		dns_on >>"$LOG" 2>&1 &
	else
		dns_on_sh
	fi
}

# включение IPv6 и DNS провайдера
enable_ipv6_and_dns() {
  interfaces=$(curl -kfsS "http://localhost:79/rci/show/interface/" | jq -r '
    to_entries[] | 
    select(.value.defaultgw == true or .value.via != null) | 
    if .value.via then "\(.value.id) \(.value.via)" else "\(.value.id)" end
  ')

  for line in $interfaces; do
    set -- $line
    iface=$1
    via=$2

    ndmc -c "interface $iface ipv6 address auto"
    ndmc -c "interface $iface ip name-servers"

    if [ -n "$via" ]; then
      ndmc -c "interface $via ipv6 address auto"
      ndmc -c "interface $via ip name-servers"
    fi
  done

  ndmc -c 'system configuration save'
  sleep 2
}

# включение системного DNS сервера
dns_on() {
	ndmc -c 'opkg no dns-override'
	ndmc -c 'system configuration save'
	sleep 2
}

# включение системного DNS сервера через "nohup"
dns_on_sh() {
	opkg install coreutils-nohup >>"$LOG" 2>&1
	echo "Удаление завершено (╥_╥)"
	echo "Включение системного DNS..."
	echo "Перезагрузка..."
	/opt/bin/nohup sh -c "ndmc -c 'opkg no dns-override' && ndmc -c 'system configuration save' && sleep 2 && reboot" >>"$LOG" 2>&1
}

#main
enable_ipv6_and_dns >>"$LOG" 2>&1 &
animation $! "Включение IPv6 и DNS провайдера"

opkg_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление opkg пакетов"

( files_uninstall >>"$LOG" 2>&1; exit 0 ) &
animation $! "Удаление файлов, созданных HydraRoute"

policy_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление политик HydraRoute"

firmware_check
animation $! "Включение системного DNS сервера"

echo "Удаление завершено (╥_╥)"
echo "Перезагрузка..."
[ -f "$0" ] && rm "$0"
reboot
