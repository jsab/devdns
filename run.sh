#!/bin/bash
[[ -n "$DEBUG" ]] && set -x
domain="${DNS_DOMAIN:-test}"
fallbackdns="${FALLBACK_DNS:-8.8.8.8}"
network="${NETWORK:-bridge}"
naming="${NAMING:-default}"
read -r -a extrahosts <<< "$EXTRA_HOSTS"

dnsmasq_pid=""
dnsmasq_path="/etc/dnsmasq.d/"

RESET="\e[0;0m"
RED="\e[0;31;49m"
GREEN="\e[0;32;49m"
YELLOW="\e[0;33;49m"

trap shutdown SIGINT SIGTERM

start_dnsmasq(){
  dnsmasq --keep-in-foreground &
  dnsmasq_pid=$!
}
reload_dnsmasq(){
  kill $dnsmasq_pid
  start_dnsmasq
}
shutdown(){
  echo "Shutting down..."
  kill $dnsmasq_pid
  exit 0
}
get_name(){
  local cid="$1"
  docker inspect -f '{{ .Name }}' "$cid" | sed "s,^/,,"
}
get_safe_name(){
  local name="$1"
  case "$naming" in
    full)
      # Replace _ with -, useful when using default Docker naming
      name="${name//_/-}"
      ;;

    *)
      # Docker allows _ in names, but other than that same as RFC 1123
      # We remove everything from "_" and use the result as record.
      if [[ ! "$name" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        name="${name%%_*}"
      fi
      ;;
  esac

  echo "$name"
}
set_record(){
  local record="$1" ip="$2" fpath infomsg
  fpath="${dnsmasq_path}${record}.conf"

  [[ -z "$ip" ]] && return 1
  [[ "$ip" == "<no value>" ]] && return 1

  infomsg="${GREEN}+ Added ${record} → ${ip}${RESET}"
  if [[ -f "$fpath" ]]; then
    infomsg="${YELLOW}+ Replaced ${record} → ${ip}${RESET}"
  fi

  echo "address=/.${record}/${ip}" > "$fpath"
  echo -e "$infomsg"
}
del_container_record(){
  local name="$1" record file
  record="${name}.${domain}"
  file="${dnsmasq_path}${record}.conf"

  [[ -f "$file" ]] && rm "$file"
  echo -e "${RED}- Removed record for ${record}${RESET}"
}
set_container_record(){
  local cid="$1" ip name safename record cnetwork
  cnetwork="$network"

  # set the network to the first detected network, if any
  if [[ "$network" == "auto" ]]; then
    cnetwork=$(docker inspect -f '{{ range $k, $v := .NetworkSettings.Networks }}{{ $k }}{{ end }}' "$cid" | head -n1)
    # abort if the container has no network interfaces, e.g.
    # if it inherited its network from another container
    [[ -z "$cnetwork" ]] && return 1
  fi
  ip=$(docker inspect -f "{{with index .NetworkSettings.Networks \"${cnetwork}\"}}{{.IPAddress}}{{end}}" "$cid" | head -n1)
  name=$(get_name "$cid")
  safename=$(get_safe_name "$name")
  if [[ -z "$ip" ]]; then
    echo -e "${YELLOW}- Could not get IP for container $name, probably not on network $network, skipping..."
  else
    record="${safename}.${domain}"
    set_record "$record" "$ip"
  fi
}
set_extra_records(){
  local host ip
  for record in "${extrahosts[@]}"; do
    host=${record%=*}
    ip=${record#*=}
    set_record "$host" "$ip"
  done
}
find_and_set_prev_record(){
  local name="$1" prevcid
  prevcid=$(docker ps -q -f "name=${name}.*" | head -n1)
  [[ -z "$prevcid" ]] && return 0

  echo -e "${YELLOW}+ Found other active container with matching name: ${name}"
  set_container_record "$prevcid"
}
setup_listener(){
  local name
  while read -r _ _ event container meta; do
    case "$event" in
      start|rename)
        set_container_record "$container"
        reload_dnsmasq
        ;;
      die)
        name=$(echo "$meta" | grep -Eow "name=[a-zA-Z0-9.-_]+" | cut -d= -f2)
        [[ -z "$name" ]] && continue
        safename=$(get_safe_name "$name")

        del_container_record "$safename"
        sleep 1
        find_and_set_prev_record "$safename"
        reload_dnsmasq
        ;;
    esac
  done < <(docker events -f event=start -f event=die -f event=rename)
}
add_running_containers(){
  local ids
  ids=$(docker ps -q)
  for id in $ids; do
    set_container_record "$id"
  done
}
set_fallback_dns(){
  sed -i "s/{{FALLBACK_DNS}}/${fallbackdns}/" "/etc/dnsmasq.conf"
  echo "Fallback DNS set to ${fallbackdns}"
}
print_startup_msg(){
  echo -e "${YELLOW}"
  cat << "EOF"
 (                      (          )   (
 )\ )                   )\ )    ( /(   )\ )
(()/(    (     (   (   (()/(    )\()) (()/(
 /(_))   )\    )\  )\   /(_))  ((_)\   /(_))
(_))_   ((_)  ((_)((_) (_))_    _((_) (_))
EOF
  echo -en "${RESET}"
  cat << "EOF"
 |   \  | __| \ \ / /   |   \  | \| | / __|
 | |) | | _|   \ V /    | |) | | .` | \__ \
 |___/  |___|   \_/     |___/  |_|\_| |___/
EOF
 echo ""
}

set -Eeo pipefail
print_startup_msg
set_fallback_dns
add_running_containers
set_extra_records
start_dnsmasq
set +Eeo pipefail

setup_listener
