#!/bin/sh

# Служебные функции и переменные
LOG="/opt/var/log/HydraRoute.log"
printf "\n%s Запуск установки\n" "$(date "+%Y-%m-%d %H:%M:%S")" >>"$LOG" 2>&1
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

# Очистка от прошлых версий и мусора
garbage_clear() {
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
}

# Установка пакетов
opkg_install() {
	opkg update
	opkg install adguardhome-go ipset iptables jq
}

# Скрипты
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
	chmod +x /opt/etc/init.d/S52hydra

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
	chmod +x /opt/etc/ndm/netfilter.d/010-hydra.sh
}

# Конфиг AdGuard Home
agh_setup() {
	##системный лог - off
	sed -i 's/ *\$LOG//g' /opt/etc/AdGuardHome/adguardhome.conf
	##кастомная конфигурация
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

# Домены
domain_add() {
	##Сохраняем пользовательский набор доменов, если он есть
	if [ -f /opt/etc/AdGuardHome/domain.conf ]; then
	  dt=$(date +%Y%m%d-%H%M%S)
	  mv /opt/etc/AdGuardHome/domain.conf "/opt/etc/AdGuardHome/backup_${dt}_domain.conf"
	fi
	##Базовый
	cat << 'EOF' > /opt/etc/AdGuardHome/domain.conf
##Youtube
googlevideo.com,ggpht.com,googleapis.com,googleusercontent.com,gstatic.com,nhacmp3youtube.com,youtu.be,youtube.com,ytimg.com/hr1
##OpenAI
chatgpt.com,openai.com,oaistatic.com,files.oaiusercontent.com,gpt3-openai.com,openai.fund,openai.org/hr1
##Instagram
cdninstagram.com,instagram.com,bookstagram.com,carstagram.com,chickstagram.com,ig.me,igcdn.com,igsonar.com,igtv.com,imstagram.com,imtagram.com,instaadder.com,instachecker.com,instafallow.com,instafollower.com,instagainer.com,instagda.com,instagify.com,instagmania.com,instagor.com,instagram.fkiv7-1.fna.fbcdn.net,instagram-brand.com,instagram-engineering.com,instagramhashtags.net,instagram-help.com,instagramhilecim.com,instagramhilesi.org,instagramium.com,instagramizlenme.com,instagramkusu.com,instagramlogin.com,instagrampartners.com,instagramphoto.com,instagram-press.com,instagram-press.net,instagramq.com,instagramsepeti.com,instagramtips.com,instagramtr.com,instagy.com,instamgram.com,instanttelegram.com,instaplayer.net,instastyle.tv,instgram.com,oninstagram.com,onlineinstagram.com,online-instagram.com,web-instagram.net,wwwinstagram.com/hr1
##ITDog Inside
10minutemail.com,1337x.to,24.kg,4freerussia.org,4pda.to,4pna.com,5sim.net,7dniv.rv.ua,7tv.app,7tv.io,co.il,abercrombie.com,abook-club.ru,academy.terrasoft.ua,activatica.org,adguard.com,adidas.com,adminforge.de,adobe.com,ads-twitter.com,adultmult.tv,agents.media,ahrefs.com,ai-chat.bsg.brave.com,ai.com,allegro.pl,alphacoders.com,alza.hu,amazfitwatchfaces.com,amdm.ru,amedia.site,amnezia.org,amx.com,analog.com,anidub.com,anilibria.tv,anilibria.uno,animaunt.org,anime-portal.su,animebest.org,animedia.tv,animego.org,animespirit.ru,anistar.org,anistars.ru,annas-archive.org,anthropic.com,aol.com,api.service-kp.com,api.theins.info,themoviedb.org,arbat.media,archive.ph,archiveofourown.org,as6723.net,assets.heroku.com,atn.ua,att.com,attachments.f95zone.to,autodesk.com,avira.com,azathabar.com,azattyq.org,babook.org,baginya.org,baikal-journal.ru,bato.to,co.uk,bbc.com,bcbits.com,bell-sw.com,bellingcat.com,bestbuy.com,bestchange.ru,bihus.info,bitdefender.com,blackseanews.net,blinkshot.io,bluehost.com,booktracker.org,botnadzor.org,brawlstarsgame.com,broadcom.com,broncosportforum.com,btdig.com,btod.com,buanzo.org,buf.build,parsec.app,buymeacoffee.com,byteoversea.com,canva.com,canva.dev,capcut.com,carnegieendowment.org,carrefouruae.com,cats.com,cbilling.eu,cbilling.vip,cdn-telegram.org,cdn.web-platform.io,cdnbunny.org,cdromance.org,cdw.com,censortracker.org,chaos.com,chat.com,cloudflare.net,chaturbate.com,cherta.media,chess.com,cisco.com,clashofclans.com,clashroyaleapp.com,claude.ai,clickup.com,cms-twdigitalassets.com,cnd2exp.online,cock.li,codeium.com,coingate.com,coinpayments.net,coinsbee.com,coldfilm.xyz,colta.ru,comments.app,sophos.com,contabo.com,contest.com,coomer.su,microsoft.com,corsair.com,coursera.org,cpu-monkey.com,credly.com,crunchyroll.com,in.ua,cub.red,currenttime.tv,cvedetails.com,cyberghostvpn.com,cyxymu.info,daemon-tools.cc,danbooru.donmai.us,data-cdn.mbamupdates.com,decrypt.day,deepstatemap.live,delfi.lt,delfi.lv,dell.com,dellcdn.com,depositphotos.com,designify.com,nvidia.com,deviantart.com,digikey.com,digitalcontent.sky,digitalocean.com,dis.gd,discord-activities.com,discord.co,discord.com,discord.design,discord.dev,discord.gg,discord.gift,discord.gifts,discord.media,discord.new,discord.store,discord.tools,discordactivities.com,discordapp.com,discordapp.net,discordmerch.com,discordpartygames.com,discordsays.com,discours.io,disctech.com,docs.liquibase.com,dorama.live,doramalive.ru,doramy.club,dovod.online,omnissa.com,doxa.team,dpidetector.org,dreamhost.com,ducati.com,dw.com,e621.net,echofm.online,edu-cisco.org,ef.com,ef.edu,eggertspiele.de,ej.ru,ekhokavkaza.com,element14.com,elevenlabs.io,epidemz.net.co,euronews.com,euroradio.fm,eutrp.eu,everand.com,exler.ru,expres.online,extremetech.com,f1.com,f95-zone.to,facebook.com,facebook.net,fast-torrent.club,fast.com,fb.com,fbsbx.com,ficbook.net,filmitorrent.net,filmix.ac,filmix.biz,filmix.day,filmix.fm,filmix.la,flibusta.is,flibusta.net,flipboard.com,flir.com,flir.eu,flourish.studio,fls.guru,fluke.com,flukenetworks.com,fn-volga.ru,fonge.org,footballapi.pulselive.com,force-user-content.com,force.com,forklog.com,formula1.com,fortanga.org,forum.netgate.com,forum.ru-board.com,foxnews.com,fragment.com,framer.com,freedomletters.org,freeimages.com,freemedia.io,gagadget.com,gamedistribution.com,gamesrepack.com,gaming.amazon.com,gdb.rferl.org,geforcenow.com,gelbooru.com,google.com,geolocation.onetrust.com,germania.one,getoutline.com,getoutline.org,gfn.am,ghostrc.game.idtech.services,global.fncstatic.com,glpals.com,godaddy.com,gofile.io,gofundme.com,golosameriki.com,gonitro.com,goodreads.com,gpsonextra.net,gr-assets.com,grafana.com,grani.ru,graph.org,graty.me,graylog.org,grok.com,groq.com,groupon.com,guilded.gg,gulagu.net,habr.com,hackernoon.com,hackmd.io,halooglasi.com,hashicorp.com,hdkinoteatr.com,hdrezka.ac,hdrezka.ag,hdrezka.me,healthline.com,hentai-foundry.com,herokucdn.com,hetzner.com,hollisterco.com,holod.media,home-connect.com,hostgator.com,hostinger.com,hotels.com,hqporner.com,hromadske.ua,hs.fi,htmhell.dev,i.sakh.com,ibm.com,ibytedtos.com,idelreal.org,iedb.org,ign.com,iherb.com,iichan.hk,ilook.tv,tmdb.org,important-stories.com,indiehackers.com,infineon.com,intel.com,intel.de,intel.nl,com.ua,internalfb.com,intuit.com,intuitibits.com,ionos.com,iptv.online,is.fi,istories.media,itninja.com,itsmycity.ru,jamf.com,jetbrains.com,jetbrains.space,jut-su.net,jut.su,kaktus.media,kamatera.com,kara.su,kasparov.ru,kavkaz-uzel.eu,kavkazr.com,kemono.su,keysight.com,kino.pub,kinogo.ec,kinogo.la,kinogo.uk,kinovod.net,kinozal.guru,kinozal.tv,kmail-lists.com,knews.kg,knowyourmeme.com,kolsar.org,korrespondent.net,kovcheg.live,krymr.com,kupujemprodajem.com,lambdalabs.com,lamcdn.net,ldoceonline.com,leafletjs.com,libgen.li,licdn.com,lidarr.audio,lifehacker.com,lightning.ai,linear.app,linkedin.com,linktr.ee,livetv.sx,liveuamap.com,locals.md,lolz.guru,lostfilm.tv,lostfilmtv2.site,lucid.app,proton.me,mailfence.com,mailo.com,malwarebytes.com,mangadex.org,mangahub.ru,mangapark.net,mashable.com,mattermost.com,mbk-news.appspot.com,mediazona.ca,medicalnewstoday.com,medium.com,meduza.io,megapeer.vip,merezha.co,meta.com,metacritic.com,metal-archives.com,metla.press,middlewareinventory.com,mignews.com,mixcloud.com,mongodb.com,monoprice.com,more.fm,mouser.fi,mullvad.net,multporn.net,muscdn.com,musical.ly,mydoramy.club,myjetbrains.com,navalny.com,nba.com,neo4j.com,netflix.ca,netflix.com,netflix.net,netflixinvestor.com,netflixtechblog.com,netlify.com,networksolutions.com,newark.com,newsroom.porsche.com,newsru.com,newtimes.ru,nfl.com,nflxext.com,nflximg.com,nflximg.net,nflxsearch.net,nflxso.net,nflxvideo.net,ngrok.com,nhentai.com,nhl.com,nih.gov,nike.com,nippon.com,nitropdf.com,nnmclub.to,nnmstatic.win,nordvpn.com,notepad-plus-plus.org,notion-static.com,notion.com,notion.new,notion.site,notion.so,novaline.fm,novaya.no,novayagazeta.eu,novayagazeta.ru,ntc.party,ntp.msn.com,nxp.com,ocstore.com,oculus.com,ohmyswift.ru,oi.legal,okx.com,olx.ua,omv-extras.org,onfastspring.com,onlinesim.io,onshape.com,openmedia.io,opensea.io,opposition-news.com,oracle.com,ovd.info,ovd.legal,ovd.news,ovdinfo.org,ozodi.org,pages.dev,pap.pl,paperpaper.io,paperpaper.ru,patreon.com,patriot.dp.ua,pcgamesn.com,pcmag.com,periscope.tv,pexels.com,phncdn.com,phncdn.com.sds.rncdn7.com,pimpletv.ru,pingdom.com,piratbit.top,pkgs.tailscale.com,platform.activestate.com,playboy.com,plugshare.com,polit.ru,politico.eu,politiken.dk,polymarket.com,pornhub.com,pornhub.org,pornolab.net,portal.lviv.ua,posle.media,postimees.ee,pravda.com,premierleague.com,primevideo.com,privatekeys.pw,prnt.sc,proekt.media,prosleduetmedia.com,prostovpn.org,protonvpn.com,provereno.media,prowlarr.com,pscp.tv,psiphon.ca,qt.io,quickconnect.to,quiz.directory,quora.com,r4.err.ee,radiosakharov.org,radiosvoboda.org,rbc.ua,reactflow.dev,realist.online,recraft.ai,reddxxx.com,redgifs.com,redis.io,redshieldvpn.com,remna.st,remove.bg,render-state.to,rentry.co,rentry.org,republic.ru,research.net,returnyoutubedislikeapi.com,rezka.ag,rezka.my,rezkify.com,rezonans.media,rf.dobrochan.net,riperam.org,roar-review.com,root-nation.com,rublacklist.net,rule34.art,rus.delfi.ee,rus.jauns.lv,rutor.info,rutor.is,rutor.org,rutracker.cc,rutracker.net,rutracker.org,rutracker.wiki,sakhalin.info,sakharovfoundation.org,salesforce-experience.com,salesforce-hub.com,salesforce-scrt.com,salesforce-setup.com,salesforce-sites.com,salesforce.com,salesforceiq.com,salesforceliveagent.com,sap.com,saverudata.net,sdxcentral.com,seasonvar.ru,selezen.org,semnasem.org,sentry.io,sephora.com,servarr.com,severreal.org,sfdcopens.com,shikimori.me,shiza-project.com,shop.gameloft.com,showip.net,sibreal.org,signal.org,simplex.chat,simplex.im,simplix.info,singlekey-id.com,site.com,skat.media,sketchup.com,skiff.com,skladchik.com,sklatchiki.ru,sky.com,skycdp.com,slashlib.me,slavicsac.com,smartbear.co,smartbear.com,smartdeploy.com,snort.org,snyk.io,sobesednik.com,solarwinds.com,sora.com,soundcloud.com,sovetromantica.com,spacelift.io,spektr.press,spitfireaudio.com,spotify.com,spreadthesign.com,sputnikipogrom.com,squadbustersgame.com,squareup.com,squietpc.com,static.lostfilm.top,statology.org,steamstat.info,strana.news,strana.today,strava.com,supercell.com,support.xerox.com,surfshark.com,surveymonkey.com,suspilne.media,svoboda.org,svoi.kr.ua,svtv.org,swagger.io,swissinfo.ch,synoforum.com,t.co,t.me,tableau.com,talosintelligence.com,tayga.info,tdesktop.com,te-st.org,teamviewer.com,telega.one,telegra.ph,telegraf.by,telegraf.news,telegram-cdn.org,telegram.dog,telegram.me,telegram.org,telegram.space,telemetr.io,telesco.pe,tellapart.com,tempmail.plus,temu.com,terraform.io,tg.dev,the-village.ru,theaudiodb.com,thebarentsobserver.com,thebell.io,theins.press,theins.ru,thetruestory.news,threads.net,threema.ch,ti.com,tidal.com,tik-tokapi.com,tiktok.com,tiktokcdn-eu.com,tiktokcdn-us.com,tiktokcdn.com,tiktokd.net,tiktokd.org,tiktokv.com,tiktokv.us,tiktokw.us,timberland.de,tmdb-image-prod.b-cdn.net,tmdb.com,torrenteditor.com,torrentgalaxy.to,trailblazer.me,trailhead.com,trellix.com,trueblackmetalradio.com,tsmc.com,ttwstatic.com,turbobit.net,tuta.com,tuta.io,tutanota.com,tvfreedom.io,tvrain.ru,tvrain.tv,tweetdeck.com,twimg.com,twirpx.com,twitpic.com,twitter.biz,twitter.com,twitter.jp,twittercommunity.com,twitterflightschool.com,twitterinc.com,twitteroauth.com,twitterstat.us,twtrdns.net,twttr.com,twttr.net,twvid.com,tx.me,typing.com,uaudio.com,ukr.net,ukr.radio,ukrtelcdn.net,unian.ua,unscreen.com,upwork.com,usa.one,usercontent.dev,vagrantcloud.com,veeam.com,verstka.media,vesma.one,vesma.today,vice.com,vine.co,vipergirls.to,visualcapitalist.com,vmware.com,vndb.org,voanews.com,voidboost.cc,volkswagen-classic-parts.com,vot-tak.tv,vpngate.net,vpngen.org,vpnlove.me,vpnpay.io,w.atwiki.jp,walmart.com,watermarkremover.io,weather.com,webnames.ca,webtoons.com,weebly.com,welt.de,widgetapp.stream,wiki.fextralife.com,wikidot.com,wilsoncenter.org,windows10spotlight.com,wonderzine.com,wpengine.com,x.ai,x.com,xhamster.com,xhamsterlive.com,xsts.auth.xboxlive.com,xtracloud.net,xv-ru.com,xvideos.com,yle.fi,youtube-nocookie.com,youtubekids.com,yummyani.me,zahav.ru,zapier.com,zbigz.com,zedge.net,zendesk.com,zerkalo.io,zona.media/hr1
##Antifilter community edition
protonmail.com,aftermarket.schaeffler.com,aftermarket.zf.com,agentura.ru,alberta.ca,animestars.org,api.app.prod.grazie.aws.intellij.net,api.github.com,githubcopilot.com,api.protonmail.ch,api.radarr.video,aplawrence.com,app.amplitude.com,app.m3u.in,app.paraswap.io,app.zerossl.com,appstorrent.ru,aqicn.org,elastic.co,atlassian.com,grazie.ai,bitbucket.org,bitcoin.org,bitru.org,boosteroid.com,bosch-home.com,bradyid.com,t-ru.org,certifytheweb.com,buckaroo.nl,citrix.com,clamav.net,cloudflare-dns.com,copilot-proxy.githubusercontent.com,czx.to,d.docs.live.net,deezer.com,devops.com,discordapp.io,discordapp.org,discordstatus.com,torproject.org,redis.com,documentation.meraki.com,lenovo.com,wetransfer.com,doxajournal.ru,dual-a-0001.a-msedge.net,bing.com,ehorussia.com,envato.com,etsy.com,event.on24.com,fex.net,firefly-ps.adobe.io,flashscore.com,fork.pet,forum.voynaplemyon.com,ubnt.com,gallery.zetalliance.org,geni.us,genius.com,gitlab.io,gnome-look.org,googletagmanager.com,gordonua.com,grammarly.com,hd.zetfix.online,holod.global.ssl.fastly.net,honeywell.com,hyperhost.ua,island-of-pleasure.site,kemono.party,kinobase.org,kinokopilka.pro,kinozal.me,kpapp.link,lib.rus.ec,libgen.rs,linuxiac.com,localbitcoins.com,login.amd.com,lostfilm.run,lostfilm.win,macpaw.com,macvendors.com,mdza.io,mediazona.online,megapeer.ru,memohrc.org,meteo.paraplan.net,monster.ie,mouser.com,mrakopedia.net,myworld-portal.leica-geosystems.com,nasvsehtoshnit.ru,netapp.com,newstudio.tv,nyaa.si,nyaa.tracker.wf,oasis.app,onlineradiobox.com,onlinesim.ru,openwrt.wk.cz,orbit-games.com,os.mbed.com,packages.gitlab.com,pandasecurity.com,paypal.com,pb.wtf,pcbway.com,pcbway.ru,php.su,piccy.info,pixiv.net,plab.site,portal.bgpmon.net,redtube.com,refactoring.guru,refinitiv.com,repo.mongodb.org,resp.app,rus-media.org,rustorka.com,rutracker.ru,s3-1.amazonaws.com,saverudata.info,searchfloor.org,sebeanus.online,seedoff.zannn.top,serpstat.com,siemens-home.bsh-group.com,skyscanner.com,slideshare.net,snapmagic.com,soapui.org,sobesednik.ru,static-ss.xvideos-cdn.com,stulchik.net,support.cambiumnetworks.com,support.huawei.com,support.ruckuswireless.com,sysdig.com,thepiratebay.org,timberland.com,tjournal.ru,torrent.by,tracker.opentrackr.org,ufile.io,underver.se,unfiltered.adguard-dns.com,unian.net,uniongang.tv,vectorworks.net,velocidrone.com,veritas.com,zetflix.online,viber.com,vipdrive.net,vrv.co,vyos.io,watchguard.com,wheather.com,windguru.cz,wixmp.com,wunderground.com,www.hrw.org,www.jabra.com,www.lostfilmtv5.site,www.microchip.com,www.moscowtimes.ru,www.postfix.org,www.qualcomm.com,www.smashwords.com,www.stalker2.com,www.wikiart.org,xnxx.com,yeggi.com,znanija.com,zohomail.com/hr1
EOF
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
	ARCH=$(opkg print-architecture | awk '
	/^arch/ && $2 !~ /_kn$/ && $2 ~ /-[0-9]+\.[0-9]+$/ {
	  print $2; exit
	}'
	)

	if [ -z "$ARCH" ]; then
	echo "Не удалось определить архитектуру."
	exit 1
	fi

	case "$ARCH" in
	aarch64-3.10)
	  URL="https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/main/repo/aarch64-k3.10/hrpanel_0.0.2-1_aarch64-3.10.bin.gz"
	  ;;
	mipsel-3.4)
	  URL="https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/main/repo/mipselsf-k3.4/hrpanel_0.0.2-1_mipsel-3.4.bin.gz"
	  ;;
	mips-3.4)
	  URL="https://raw.githubusercontent.com/Ground-Zerro/HydraRoute/main/repo/mipssf-k3.4/hrpanel_0.0.2-1_mips-3.4.bin.gz"
	  ;;
	*)
	  echo "Неизвестная архитектура: $ARCH"
	  exit 1
	  ;;
	esac

	TMP_DEST="/opt/tmp/hrpanel.bin.gz"
	FINAL_DEST="/opt/bin/hrpanel"

	curl -Ls --retry 5 --retry-delay 5 --connect-timeout 5 --retry-all-errors -o "$TMP_DEST" "$URL"
	if [ $? -ne 0 ]; then
	echo "Ошибка загрузки: $URL"
	exit 1
	fi

	gunzip -c "$TMP_DEST" > "$FINAL_DEST"
	rm -f "$TMP_DEST"
	chmod +x "$FINAL_DEST"
	ln -sf /opt/etc/init.d/S99hrpanel /opt/bin/hr
	mkdir -p /opt/etc/HydraRoute
	
	cat << 'EOF' >/opt/etc/HydraRoute/login.scrt
a2VlbmV0aWM=
EOF
	
	cat << 'EOF' >/opt/etc/init.d/S99hrpanel
#!/bin/sh

ENABLED=yes
PROCS=hrpanel
ARGS=""
PREARGS=""
DESC=$PROCS
PATH=/opt/sbin:/opt/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

. /opt/etc/init.d/rc.func
EOF
	chmod +x /opt/etc/init.d/S99hrpanel
}

# Отключение ipv6 и DNS провайдера
disable_ipv6_and_dns() {
	interfaces=$(curl -kfsS "http://localhost:79/rci/show/interface/" | jq -r '
	  to_entries[] | 
	  select(.value.defaultgw == true or .value.via != null) | 
	  if .value.via then "\(.value.id) \(.value.via)" else "\(.value.id)" end
	')

	for line in $interfaces; do
	  set -- $line
	  iface=$1
	  via=$2

	  ndmc -c "no interface $iface ipv6 address" 2>/dev/null
	  ndmc -c "interface $iface no ip name-servers" 2>/dev/null

	  if [ -n "$via" ]; then
		ndmc -c "no interface $via ipv6 address" 2>/dev/null
		ndmc -c "interface $via no ip name-servers" 2>/dev/null
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
	echo " - пароль: keenetic"
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
# Выход если места меньше 40Мб
if [ "$AVAILABLE_SPACE" -lt 40960 ]; then
	echo "Не достаточно места для установки" >>"$LOG" 2>&1
	[ -f "$0" ] && rm "$0"
	exit 1
fi

# Очитска от мусора
( garbage_clear >>"$LOG" 2>&1; exit 0 ) &
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

# Установка web-панели
install_panel >>"$LOG" 2>&1 &
PID=$!
animation $PID "Установка web-панели"

wait $PID
[ $? -eq 0 ] && PANEL="1" || PANEL="0"

# Символическая ссылка AGH
ln -sf /opt/etc/init.d/S99adguardhome /opt/bin/agh

# Создаем политики доступа
policy_set >>"$LOG" 2>&1 &
animation $! "Создаем политики доступа"

# Отключение ipv6 и DNS провайдера
disable_ipv6_and_dns >>"$LOG" 2>&1 &
animation $! "Отключение ipv6 и DNS провайдера"

# Отключение системного DNS сервера и сохранение
firmware_check
animation $! "Отключение системного DNS сервера"

# Завершение
echo ""
if [ "$PANEL" = "1" ]; then
	complete_info
else
	complete_info_no_panel
fi

# Пауза 5 сек и ребут
sleep 5
[ -f "$0" ] && rm "$0"
reboot
