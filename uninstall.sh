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
	opkg remove adguardhome-go ipset iptables jq node-npm node tar
}

# удаление файлов
files_uninstall() {
	chmod -R 777 /opt/etc/AdGuardHome/
	chmod 777 /opt/etc/init.d/S52ipset
	chmod 777 /opt/var/log/AdGuardHome.log
	chmod 777 /opt/etc/init.d/S52hydra
	chmod 777 /opt/etc/ndm/netfilter.d/010-hydra.sh
	rm -f /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
	rm -f /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
	rm -f /opt/etc/ndm/netfilter.d/010-bypass.sh
	rm -f /opt/etc/ndm/netfilter.d/011-bypass6.sh
	rm -f /opt/etc/init.d/S52ipset
	rm -rf /opt/etc/AdGuardHome/
	rm -f /opt/var/log/AdGuardHome.log
	rm -f /opt/etc/init.d/S52hydra
	rm -f /opt/etc/ndm/netfilter.d/010-hydra.sh
	rm -f /opt/bin/agh
}

# удаление политик
policy_uninstall() {
	ndmc -c 'no ip policy HydraRoute1st'
	ndmc -c 'no ip policy HydraRoute2nd'
	ndmc -c 'no ip policy HydraRoute3rd'
	ndmc -c 'system configuration save'
}

# удаление веб-панели
files_hpanel_uninstall() {
	chmod -R 777 /opt/etc/HydraRoute/
	chmod 777 /opt/etc/init.d/S99hpanel
	rm -rf /opt/etc/HydraRoute/
	rm -f /opt/etc/init.d/S99hpanel
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
	sleep 3
}

# включение системного DNS через "nohup"
dns_on_sh() {
	opkg install coreutils-nohup >>"$LOG" 2>&1
	echo "Удаление завершено (╥_╥)"
	echo "Включение системного DNS..."
	echo "Перезагрузка..."
	/opt/bin/nohup sh -c "ndmc -c 'opkg no dns-override' && ndmc -c 'system configuration save' && sleep 3 && reboot" >>"$LOG" 2>&1
}

opkg_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление opkg пакетов"

files_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление файлов HydraRoute"

files_hpanel_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление веб-панели"

policy_uninstall >>"$LOG" 2>&1 &
animation $! "Удаление политик HydraRoute"

firmware_check
animation $! "Включение системного DNS"

echo "Удаление завершено (╥_╥)"
echo "Перезагрузка..."
reboot
