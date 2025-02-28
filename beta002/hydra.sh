#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
echo "$(date "+%Y-%m-%d %H:%M:%S") Запуск установки" >>"$LOG" 2>&1
REQUIRED_VERSION="4.2.3"
IP_ADDRESS=$(ip addr show br0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
VERSION=$(ndmc -c show version | grep "title" | awk -F": " '{print $2}')
AVAILABLE_SPACE=$(df /opt | awk 'NR==2 {print $4}')
## переменные для конфига AGH
PASSWORD=\$2y\$10\$fpdPsJjQMGNUkhXgalKGluJ1WFGBO6DKBJupOtBxIzckpJufHYpk.
rule1='||*^$dnstype=HTTPS,dnsrewrite=NOERROR'
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

# Очистка от мусора
garbage_clear() {
	/opt/etc/init.d/S99hpanel stop
	chmod -R 777 /opt/etc/HydraRoute/
	chmod 777 /opt/etc/init.d/S99hpanel
	chmod 777 /opt/etc/init.d/S52ipset
	chmod 777 /opt/etc/init.d/S52hydra
	chmod 777 /opt/etc/ndm/netfilter.d/010-hydra.sh
	chmod 777 /opt/var/log/AdGuardHome.log
	rm -rf /opt/etc/HydraRoute/
	rm -f /opt/etc/ndm/ifstatechanged.d/010-bypass-table.sh
	rm -f /opt/etc/ndm/ifstatechanged.d/011-bypass6-table.sh
	rm -f /opt/etc/ndm/netfilter.d/010-bypass.sh
	rm -f /opt/etc/ndm/netfilter.d/011-bypass6.sh
	rm -f /opt/etc/ndm/netfilter.d/010-hydra.sh
	rm -f /opt/etc/init.d/S52ipset
	rm -f /opt/etc/init.d/S52hydra
	rm -f /opt/etc/init.d/S99hpanel
	rm -f /opt/var/log/AdGuardHome.log
}

# Установка пакетов
opkg_install() {
	opkg update
	opkg install adguardhome-go ipset iptables ip-full jq
}

# Создаем скрипты
files_create() {
## ipset для hr1,2,3
	cat << 'EOF' > /opt/etc/init.d/S52hydra
#!/bin/sh

ipset create hr1 hash:ip
ipset create hr2 hash:ip
ipset create hr3 hash:ip
ipset create hr1v6 hash:ip family inet6
ipset create hr2v6 hash:ip family inet6
ipset create hr3v6 hash:ip family inet6

ndmc -c 'ip policy HydraRoute1st' >/dev/null 2>&1
ndmc -c 'ip policy HydraRoute2nd' >/dev/null 2>&1
ndmc -c 'ip policy HydraRoute3rd' >/dev/null 2>&1
EOF
	
## cкрипт iptables
	cat << 'EOF' > /opt/etc/ndm/netfilter.d/010-hydra.sh
#!/bin/sh

policies="HydraRoute1st HydraRoute2nd HydraRoute3rd"
bypasses="hr1 hr2 hr3"
bypassesv6="hr1v6 hr2v6 hr3v6"

if [ "$type" != "iptables" ]; then
    if [ "$type" != "ip6tables" ]; then
        exit
    fi
fi

if [ "$table" != "mangle" ]; then
    exit
fi

# policy markID
policy_data=$(curl -kfsS localhost:79/rci/show/ip/policy/)

i=0
for policy in $policies; do
    mark_id=$(echo "$policy_data" | jq -r ".$policy.mark")
    if [ "$mark_id" = "null" ]; then
		i=$((i+1))
        continue
    fi

    eval "mark_ids_$i=$mark_id"
    i=$((i+1))
done

# ipv4
iptables_mangle_save=$(iptables-save -t mangle)
i=0
for policy in $policies; do
    bypass=$(echo $bypasses | cut -d' ' -f$((i+1)))
    mark_id=$(eval echo \$mark_ids_$i)

    ! ipset list "$bypass" >/dev/null 2>&1 && i=$((i+1)) && continue

    if echo "$iptables_mangle_save" | grep -qE -- "--match-set $bypass dst -j CONNMARK --restore-mark"; then
        i=$((i+1))
        continue
    fi

    iptables -w -t mangle -A PREROUTING -m conntrack --ctstate NEW -m set --match-set "$bypass" dst -j CONNMARK --set-mark 0x"$mark_id"
    iptables -w -t mangle -A PREROUTING -m set --match-set "$bypass" dst -j CONNMARK --restore-mark
    i=$((i+1))
done

# ipv6
ip6tables_mangle_save=$(ip6tables-save -t mangle)
i=0
for policy in $policies; do
    bypassv6=$(echo $bypassesv6 | cut -d' ' -f$((i+1)))
    mark_id=$(eval echo \$mark_ids_$i)

    ! ipset list "$bypassv6" >/dev/null 2>&1 && i=$((i+1)) && continue

    if echo "$ip6tables_mangle_save" | grep -qE -- "--match-set $bypassv6 dst -j CONNMARK --restore-mark"; then
        i=$((i+1))
        continue
    fi

    ip6tables -w -t mangle -A PREROUTING -m conntrack --ctstate NEW -m set --match-set "$bypassv6" dst -j CONNMARK --set-mark 0x"$mark_id"
    ip6tables -w -t mangle -A PREROUTING -m set --match-set "$bypassv6" dst -j CONNMARK --restore-mark
    i=$((i+1))
done

# nginx proxy
NGINX_CONF="/tmp/nginx/nginx.conf"
if grep -q "hr.net" "$NGINX_CONF"; then
    exit
fi

IP_ADDRESS=$(ip addr show br0 | grep 'inet ' | awk '{print $2}' | cut -d/ -f1)
sed -i '$ s/}$//' "$NGINX_CONF"
cat <<EOT >> "$NGINX_CONF"
  server {
    listen $IP_ADDRESS:80;
    server_name hr.net hr.local;
      location / {
        proxy_pass http://$IP_ADDRESS:2000;
      }
    }
}
EOT

nginx -s reload
EOF
}

# Настройки AGH
agh_setup() {
	## конфиг AdGuard Home
	cat << EOF > /opt/etc/AdGuardHome/AdGuardHome.yaml
http:
  pprof:
    port: 6060
    enabled: false
  address: $IP_ADDRESS:3000
  session_ttl: 720h
users:
  - name: admin
    password: $PASSWORD
auth_attempts: 5
block_auth_min: 15
http_proxy: ""
language: ""
theme: auto
dns:
  bind_hosts:
    - 0.0.0.0
  port: 53
  anonymize_client_ip: false
  ratelimit: 20
  ratelimit_subnet_len_ipv4: 24
  ratelimit_subnet_len_ipv6: 56
  ratelimit_whitelist: []
  refuse_any: true
  upstream_dns:
    - tls://dns.google
    - tls://one.one.one.one
    - tls://p0.freedns.controld.com
    - tls://dot.sb
    - tls://dns.nextdns.io
    - tls://dns.quad9.net
  upstream_dns_file: ""
  bootstrap_dns:
    - 9.9.9.9
    - 1.1.1.1
    - 8.8.8.8
    - 149.112.112.10
    - 94.140.14.14
  fallback_dns: []
  upstream_mode: load_balance
  fastest_timeout: 1s
  allowed_clients: []
  disallowed_clients: []
  blocked_hosts:
    - version.bind
    - id.server
    - hostname.bind
  trusted_proxies:
    - 127.0.0.0/8
    - ::1/128
  cache_size: 4194304
  cache_ttl_min: 0
  cache_ttl_max: 0
  cache_optimistic: false
  bogus_nxdomain: []
  aaaa_disabled: false
  enable_dnssec: false
  edns_client_subnet:
    custom_ip: ""
    enabled: false
    use_custom: false
  max_goroutines: 300
  handle_ddr: true
  ipset: []
  ipset_file: /opt/etc/AdGuardHome/domain.conf
  bootstrap_prefer_ipv6: false
  upstream_timeout: 10s
  private_networks: []
  use_private_ptr_resolvers: true
  local_ptr_upstreams: []
  use_dns64: false
  dns64_prefixes: []
  serve_http3: false
  use_http3_upstreams: false
  serve_plain_dns: true
  hostsfile_enabled: true
tls:
  enabled: false
  server_name: ""
  force_https: false
  port_https: 443
  port_dns_over_tls: 853
  port_dns_over_quic: 853
  port_dnscrypt: 0
  dnscrypt_config_file: ""
  allow_unencrypted_doh: false
  certificate_chain: ""
  private_key: ""
  certificate_path: ""
  private_key_path: ""
  strict_sni_check: false
querylog:
  dir_path: ""
  ignored: []
  interval: 24h
  size_memory: 1000
  enabled: false
  file_enabled: true
statistics:
  dir_path: ""
  ignored: []
  interval: 24h
  enabled: false
filters:
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt
    name: AdGuard DNS filter
    id: 1
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_2.txt
    name: AdAway Default Blocklist
    id: 2
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt
    name: AdGuard DNS Popup Hosts filter
    id: 1737211801
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt
    name: Phishing URL Blocklist (PhishTank and OpenPhish)
    id: 1737211802
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_42.txt
    name: ShadowWhisperer's Malware List
    id: 1737211803
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_9.txt
    name: The Big List of Hacked Malware Web Sites
    id: 1737211804
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt
    name: HaGeZi's Windows/Office Tracker Blocklist
    id: 1737211805
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_7.txt
    name: Perflyst and Dandelion Sprout's Smart-TV Blocklist
    id: 1737211806
  - enabled: true
    url: https://adguardteam.github.io/HostlistsRegistry/assets/filter_12.txt
    name: Dandelion Sprout's Anti-Malware List
    id: 1737211807
whitelist_filters: []
user_rules:
  - '$rule1'
dhcp:
  enabled: false
  interface_name: ""
  local_domain_name: lan
  dhcpv4:
    gateway_ip: ""
    subnet_mask: ""
    range_start: ""
    range_end: ""
    lease_duration: 86400
    icmp_timeout_msec: 1000
    options: []
  dhcpv6:
    range_start: ""
    lease_duration: 86400
    ra_slaac_only: false
    ra_allow_slaac: false
filtering:
  blocking_ipv4: ""
  blocking_ipv6: ""
  blocked_services:
    schedule:
      time_zone: Local
    ids: []
  protection_disabled_until: null
  safe_search:
    enabled: false
    bing: true
    duckduckgo: true
    ecosia: true
    google: true
    pixabay: true
    yandex: true
    youtube: true
  blocking_mode: default
  parental_block_host: family-block.dns.adguard.com
  safebrowsing_block_host: standard-block.dns.adguard.com
  rewrites:
    - domain: my.keenetic.net
      answer: $IP_ADDRESS
    - domain: hr.net
      answer: $IP_ADDRESS
    - domain: hr.local
      answer: $IP_ADDRESS
  safe_fs_patterns:
    - /opt/etc/AdGuardHome/userfilters/*
  safebrowsing_cache_size: 1048576
  safesearch_cache_size: 1048576
  parental_cache_size: 1048576
  cache_time: 30
  filters_update_interval: 24
  blocked_response_ttl: 10
  filtering_enabled: true
  parental_enabled: false
  safebrowsing_enabled: false
  protection_enabled: true
clients:
  runtime_sources:
    whois: true
    arp: true
    rdns: true
    dhcp: true
    hosts: true
  persistent: []
log:
  enabled: true
  file: ""
  max_backups: 0
  max_size: 100
  max_age: 3
  compress: false
  local_time: false
  verbose: false
os:
  group: ""
  user: ""
  rlimit_nofile: 0
schema_version: 29
EOF
}

# Базовый список доменов
domain_add() {
	cat << 'EOF' > /opt/etc/AdGuardHome/domain.conf
##Tunnel check
2ip.ru,2ipcore.com/hr1
##Youtube
googlevideo.com,ggpht.com,googleapis.com,googleusercontent.com,gstatic.com,nhacmp3youtube.com,youtu.be,youtube.com,ytimg.com/hr1
##Instagram
cdninstagram.com,instagram.com,bookstagram.com,carstagram.com,chickstagram.com,ig.me,igcdn.com,igsonar.com,igtv.com,imstagram.com,imtagram.com,instaadder.com,instachecker.com,instafallow.com,instafollower.com,instagainer.com,instagda.com,instagify.com,instagmania.com,instagor.com,instagram.fkiv7-1.fna.fbcdn.net,instagram-brand.com,instagram-engineering.com,instagramhashtags.net,instagram-help.com,instagramhilecim.com,instagramhilesi.org,instagramium.com,instagramizlenme.com,instagramkusu.com,instagramlogin.com,instagrampartners.com,instagramphoto.com,instagram-press.com,instagram-press.net,instagramq.com,instagramsepeti.com,instagramtips.com,instagramtr.com,instagy.com,instamgram.com,instanttelegram.com,instaplayer.net,instastyle.tv,instgram.com,oninstagram.com,onlineinstagram.com,online-instagram.com,web-instagram.net,wwwinstagram.com/hr1
##Torrent tracker
1337x.to,262203.game4you.top,eztv.re,eztvx.to,fitgirl-repacks.site,new.megashara.net,nnmclub.to,nnm-club.to,nnm-club.me,rarbg.to,rustorka.com,rutor.info,rutor.org,rutracker.cc,rutracker.org,tapochek.net,thelastgame.ru,thepiratebay.org,thepirate-bay.org,torrentgalaxy.to,torrent-games.best,torrentz2eu.org,limetorrents.info,pirateproxy-bay.com,torlock.com,torrentdownloads.me/hr1
##OpenAI
chatgpt.com,openai.com,oaistatic.com,files.oaiusercontent.com,gpt3-openai.com,openai.fund,openai.org/hr1
EOF
}

# Установка прав на скрипты
chmod_set() {
	chmod +x /opt/etc/init.d/S52hydra
	chmod +x /opt/etc/ndm/netfilter.d/010-hydra.sh
}

# Добавление политик доступа
policy_set() {
	ndmc -c 'ip policy HydraRoute1st'
	ndmc -c 'ip policy HydraRoute2nd'
	ndmc -c 'ip policy HydraRoute3rd'
	# Пробуем включить WG в HR1 если он есть
	ndmc -c 'ip policy HydraRoute1st permit global Wireguard0'
	ndmc -c 'system configuration save'
	sleep 2
}

# Установка web-панели
install_panel() {
	opkg install node tar
	rm -f /opt/tmp/hpanel.tar
	mkdir -p /opt/tmp
	curl -Ls --retry 6 --retry-delay 5 --max-time 5 -o /opt/tmp/hpanel.tar "https://github.com/Ground-Zerro/HydraRoute/raw/refs/heads/main/beta/webpanel/hpanel.tar"
	if [ $? -ne 0 ]; then
		exit 1
	fi

	mkdir -p /opt/etc/HydraRoute
	tar -xf /opt/tmp/hpanel.tar -C /opt/etc/HydraRoute/
	rm /opt/tmp/hpanel.tar
	chmod -R +x /opt/etc/HydraRoute/
	cat << 'EOF' >/opt/etc/init.d/S99hpanel
#!/bin/sh

ENABLED=yes
PROCS=node
ARGS="/opt/etc/HydraRoute/hpanel.js"
PREARGS=""
DESC="HydraRoute Panel"
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
	chmod +x /opt/etc/init.d/S99hpanel
}

# Отключение ipv6
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
	sleep 2
}

# Проверка версии прошивки
firmware_check() {
	if [ "$(printf '%s\n' "$VERSION" "$REQUIRED_VERSION" | sort -V | tail -n1)" = "$VERSION" ]; then
		dns_off >>"$LOG" 2>&1 &
	else
		dns_off_sh
	fi
}

# Отклчюение системного DNS
dns_off() {
	ndmc -c 'opkg dns-override'
	ndmc -c 'system configuration save'
	sleep 2
}

# Отключение системного DNS через "nohup"
dns_off_sh() {
	opkg install coreutils-nohup >>"$LOG" 2>&1
	echo "Отключение системного DNS..."
	echo ""
	if [ "$PANEL" = "1" ]; then
		complete_info
	else
		complete_info_no_panel
	fi
	rm -- "$0"
	read -r
	/opt/bin/nohup sh -c "ndmc -c 'opkg dns-override' && ndmc -c 'system configuration save' && sleep 2 && reboot" >>"$LOG" 2>&1
}

# Сообщение установка ОK
complete_info() {
	echo "Установка HydraRoute завершена"
	echo " - панель управления доступна по адресу: hr.net"
	echo ""
	echo "После перезагрузки включите нужный VPN в политике HydraRoute1st"
	echo " - Веб-конфигуратор роутера -> Приоритеты подключений -> Политики доступа в интернет"
	echo ""
	echo "Перезагрузка через 5 секунд..."
}

# Сообщение установка без панели
complete_info_no_panel() {
	echo "HydraRoute установлен без web-панели"
	echo " - редактирование domain возможно только вручную (инструкция на GitHub)."
	echo ""
	echo "AdGuard Home доступен по адресу: http://$IP_ADDRESS:3000/"
	echo "Login: admin"
	echo "Password: keenetic"
	echo ""
	echo "После перезагрузки включите нужный VPN в политике HydraRoute1st"
	echo " - Веб-конфигуратор роутера -> Приоритеты подключений -> Политики доступа в интернет"
	echo ""
	echo "Перезагрузка через 5 секунд..."
}

# === main ===
# Выход если места меньше 80Мб
if [ "$AVAILABLE_SPACE" -lt 81920 ]; then
	echo "Не достаточно места для установки" >>"$LOG" 2>&1
	rm -- "$0"
	exit 1
fi

# Очитска от мусора
garbage_clear >>"$LOG" 2>&1 &
animation $! "Очистка"

# Установка пакетов
opkg_install >>"$LOG" 2>&1 &
PID=$!
animation $PID "Установка необходимых пакетов"
wait $PID
if [ $? -ne 0 ]; then
	echo "Установка прервана..."
    exit 1
fi

# Формирование скриптов 
files_create >>"$LOG" 2>&1 &
animation $! "Формируем скрипты"

# Настройка AdGuard Home
agh_setup >>"$LOG" 2>&1 &
animation $! "Настройка AdGuard Home"

# Добавление доменов
domain_add >>"$LOG" 2>&1 &
animation $! "Базовый список доменов"

# Установка прав на выполнение скриптов
chmod_set >>"$LOG" 2>&1 &
animation $! "Установка прав на выполнение скриптов"

# установка web-панели если места больше 80Мб
if [ "$AVAILABLE_SPACE" -gt 81920 ]; then
    PANEL="1"
    install_panel >>"$LOG" 2>&1 &
    PID=$!
    animation $PID "Установка web-панели"

    wait $PID
    if [ $? -ne 0 ]; then
        PANEL="0"
    fi
fi

# Символические ссылки
ln -sf /opt/etc/init.d/S99adguardhome /opt/bin/agh
ln -sf /opt/etc/init.d/S99hpanel /opt/bin/hr

# Создаем политики доступа
policy_set >>"$LOG" 2>&1 &
animation $! "Создаем политики доступа"

# Отключение ipv6
disable_ipv6 >>"$LOG" 2>&1 &
animation $! "Отключение ipv6"

# Отключение системного DNS и сохранение
firmware_check
animation $! "Отключение системного DNS"

# Завершение
echo ""
if [ "$PANEL" = "1" ]; then
	complete_info
else
	complete_info_no_panel
fi

# Пауза 5 сек и ребут
sleep 5
reboot
