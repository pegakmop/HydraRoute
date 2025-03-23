#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
echo "$(date "+%Y-%m-%d %H:%M:%S") Удаление" >> "$LOG"
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
	/opt/etc/init.d/S99adguardhome kill
	/opt/etc/init.d/S99hpanel kill
	/opt/etc/init.d/S99hrpanel kill
	opkg remove adguardhome-go ipset iptables jq node-npm node tar
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
		[ -f "$FILE" ] && chmod +x "$FILE"
		[ -f "$FILE" ] && rm -f "$FILE"
	done

	[ -d /opt/etc/HydraRoute ] && rm -rf /opt/etc/HydraRoute
	[ -d /opt/etc/AdGuardHome ] && rm -rf /opt/etc/AdGuardHome
}

# удаление политик
policy_uninstall() {
	ndmc -c 'no ip policy HydraRoute1st'
	ndmc -c 'no ip policy HydraRoute2nd'
	ndmc -c 'no ip policy HydraRoute3rd'
	ndmc -c 'system configuration save'
}

# проверка версии прошивки
firmware_check() {
	if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
		dns_on >>"$LOG" 2>&1 &
	else
		dns_on_sh
	fi
}

# включение системного DNS
dns_on() {
	ndmc -c 'opkg no dns-override'
	ndmc -c 'system configuration save'
	sleep 2
}

# включение системного DNS через "nohup"
dns_on_sh() {
	opkg install coreutils-nohup >>"$LOG" 2>&1
	echo "Удаление завершено (╥_╥)"
	echo "Включение системного DNS..."
	echo "Перезагрузка..."
	/opt/bin/nohup sh -c "ndmc -c 'opkg no dns-override' && ndmc -c 'system configuration save' && sleep 2 && reboot" >>"$LOG" 2>&1
}

opkg_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление opkg пакетов"

( files_uninstall >>"$LOG" 2>&1; exit 0 ) &
animation $! "Удаление файлов, созданных HydraRoute"

policy_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление политик HydraRoute"

firmware_check
animation $! "Включение системного DNS"

echo "Удаление завершено (╥_╥)"
echo "Перезагрузка..."
reboot
