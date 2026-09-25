#!/bin/bash

#######################
## Generating script variables and basics
script_name=$(basename "$0" | cut -d'.' -f1)
script_name_cap=${script_name^^}
script_name_full=$(basename "$0")
script_bin="$0"
script_conf=`echo $HOME"/.config/"$script_name"/"$script_name".conf"`
script_remote="https://raw.githubusercontent.com/Z0uZOU/$script_name/main/$script_name_full"
url_conf_remote="https://raw.githubusercontent.com/Z0uZOU/$script_name/main/url.conf"
script_folder="$HOME/.config/$script_name"
mkdir -p "$script_folder/logs"


#######################
## Check if this script is running
lock_file="$script_folder/$script_name.lock"
exec 200>"$lock_file"

if ! flock -n 200; then
    echo "Script already running..."
    exit 1
fi

#######################
## Advanced command arguments
die() { echo "$*" >&2; exit 2; }  # complain to STDERR and exit with error
needs_arg() { if [ -z "$OPTARG" ]; then die "No arg for --$OPT option"; fi; }
needs_long_arg() {
  if [[ -z "$OPTARG" ]] && (( OPTIND <= $# )); then
    OPTARG="${!OPTIND}"
    ((OPTIND++))
  fi
  needs_arg
}


SERVERS="EU-PVE-Astraeos5989|EU-PVE-GenOne6465|EU-PVE-LostColony6324"
SERVER_LIST_URL="https://cdn2.arkdedicated.com/servers/asa/officialserverlist.json"
STATE_DIR="${ARK_MONITOR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ark_servers_monitor}"
QUERY_TIMEOUT=10
QUERY_ATTEMPTS=2

for command in curl jq gamedig timeout; do
  if ! command -v "$command" >/dev/null 2>&1; then
    printf 'Erreur: commande requise introuvable: %s\n' "$command" >&2
    exit 1
  fi
done

if ! mkdir -p "$STATE_DIR"; then
  printf "Erreur: impossible de créer le répertoire d'état: %s\n" "$STATE_DIR" >&2
  exit 1
fi

server_list=$(mktemp) || exit 1
trap 'rm -f "$server_list"' EXIT

if ! curl -fsSL --retry 2 --connect-timeout 5 --max-time 30 "$SERVER_LIST_URL" -o "$server_list"; then
  printf 'Erreur: impossible de récupérer la liste officielle des serveurs.\n' >&2
  exit 1
fi

if ! jq -e 'type == "array"' "$server_list" >/dev/null 2>&1; then
  printf 'Erreur: la liste officielle reçue est invalide.\n' >&2
  exit 1
fi

format_duration() {
  local seconds=$1
  local days hours minutes
  (( seconds < 0 )) && seconds=0
  days=$((seconds / 86400))
  hours=$((seconds % 86400 / 3600))
  minutes=$((seconds % 3600 / 60))
  if (( days > 0 )); then
    printf '%dj %dh' "$days" "$hours"
  elif (( hours > 0 )); then
    printf '%dh %02dmin' "$hours" "$minutes"
  else
    printf '%dmin' "$minutes"
  fi
}

show_offline() {
  local name=$1
  local state_file=$2
  local now offline_since duration
  now=$(date +%s)
  if [[ -r "$state_file" ]]; then
    read -r offline_since < "$state_file"
  else
    offline_since=$now
  fi
  if [[ ! "$offline_since" =~ ^[0-9]+$ ]]; then
    offline_since=$now
  fi
  printf '%s\n' "$offline_since" > "$state_file"
  duration=$(format_duration "$((now - offline_since))")
  printf '%s | Offline depuis %s\n' "$name" "$duration"
}

IFS='|' read -r -a server_names <<< "$SERVERS"
for name in "${server_names[@]}"; do
  [[ -z "$name" ]] && continue
  state_name=${name//[^[:alnum:]_.-]/_}
  state_file="$STATE_DIR/$state_name.offline"
  server_data=$(jq -r --arg name "$name" 'first(.[] | select(.Name == $name)) as $server | [$server.IP, ($server.Port | tostring)] | @tsv' "$server_list")
  if [[ -z "$server_data" ]]; then
    show_offline "$name" "$state_file"
    continue
  fi
  IFS=$'\t' read -r ip port <<< "$server_data"
  result=''
  for ((attempt = 1; attempt <= QUERY_ATTEMPTS; attempt++)); do
    if result=$(timeout "${QUERY_TIMEOUT}s" gamedig --type asa "$ip:$port" 2>/dev/null) && jq -e '.numplayers >= 0 and .maxplayers > 0' <<< "$result" >/dev/null 2>&1; then
      break
    fi
    result=''
  done
  if [[ -n "$result" ]]; then
    players=$(jq -r '.numplayers' <<< "$result")
    max_players=$(jq -r '.maxplayers' <<< "$result")
    rm -f "$state_file"
    printf '%s | %s/%s\n' "$name" "$players" "$max_players"
  else
    show_offline "$name" "$state_file"
  fi
done
