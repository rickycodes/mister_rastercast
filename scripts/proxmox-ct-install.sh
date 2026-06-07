#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: proxmox-ct-install.sh <hostname> [source-dir]

Provision a Proxmox LXC container with rastercast runtime dependencies,
deploy the repository into the container, and install a systemd service
that keeps rastercast running.

Environment:
  RASTERCAST_REPO_URL      Git URL used when no local source-dir is provided
  RASTERCAST_INSTALL_DIR   Install path inside the container (default: /opt/rastercast)
  RASTERCAST_LAUNCH_MODE   Launch mode used by the service (default: detached-loop)
  RASTERCAST_ENABLE_SERVICE Enable and start the playback service: 1 or 0 (default: 0)
  RASTERCAST_ENABLE_PLAYBACK_SERVICE  Alias for RASTERCAST_ENABLE_SERVICE
  RASTERCAST_ENABLE_CONTROL_SERVICE   Enable and start the control server: 1 or 0 (default: 1)
  RASTERCAST_CT_TEMPLATE   Proxmox template path used when creating a CT; otherwise prompt from /var/lib/vz/template/cache
  RASTERCAST_CT_STORAGE    Rootfs storage for a created CT; otherwise prompt from available storages
  RASTERCAST_CT_DISK_SIZE  Rootfs size for a created CT (default: 8)
  RASTERCAST_CTID          Optional numeric VMID used when creating a CT
  RASTERCAST_CT_BRIDGE     Network bridge for a created CT (default: vmbr0)
  RASTERCAST_CT_MEMORY     Memory in MiB for a created CT (default: 1024)
  RASTERCAST_CT_CORES      CPU cores for a created CT (default: 1)
  RASTERCAST_CT_PASSWORD   Root password for a created CT
  RASTERCAST_CT_SSH_PUBLIC_KEY_FILE  SSH public key file for a created CT
  RASTERCAST_CONTROL_BIND_ADDR  Bind address for the control server (default: 0.0.0.0)
  RASTERCAST_CONTROL_PORT       Port for the control server (default: 8092)
  RASTERCAST_CONTROL_DJ_MODE    Run the control server in DJ mode: 1 or 0 (default: 0)
EOF
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required command not found on Proxmox host: %s\n' "$1" >&2
    exit 1
  fi
}

is_enabled() {
  case ${1:-0} in
    1 | yes | true)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

next_ctid() {
  pvesh get /cluster/nextid
}

list_local_templates() {
  find /var/lib/vz/template/cache -maxdepth 1 -type f \
    \( -name '*.tar.zst' -o -name '*.tar.xz' -o -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.tar.lzo' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1 { print $2 }'
}

list_all_templates() {
  find /var/lib/vz/template/cache -maxdepth 1 -type f \
    \( -name '*.tar.zst' -o -name '*.tar.xz' -o -name '*.tar.gz' -o -name '*.tar.bz2' -o -name '*.tar.lzo' \) \
    -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk '{ $1=""; sub(/^ /, ""); print }'
}

choose_template_interactively() {
  local -a templates=("$@")
  local -a labels=()
  local template_path index

  for template_path in "${templates[@]}"; do
    labels+=( "$(template_display_label "$template_path")" )
  done

  index=$(choose_from_list_interactively "Select a Proxmox template:" "${labels[@]}")
  printf '%s\n' "${templates[$((index - 1))]}"
}

choose_storage_interactively() {
  local -a storages=("$@")
  local index

  index=$(choose_from_list_interactively "Select a Proxmox storage:" "${storages[@]}")
  printf '%s\n' "${storages[$((index - 1))]}"
}

choose_from_list_interactively() {
  local prompt=$1
  shift
  local -a choices=("$@")
  local count=${#choices[@]}
  local index choice
  local tty=/dev/tty

  if [[ ! -r $tty || ! -w $tty ]]; then
    printf 'error: interactive selection requires a tty; set the matching env var explicitly\n' >&2
    exit 1
  fi

  printf '%s\n' "$prompt" >"$tty"
  for index in "${!choices[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${choices[$index]}" >"$tty"
  done

  while :; do
    printf 'Choice [1-%d]: ' "$count" >"$tty"
    read -r choice <"$tty"
    choice=${choice:-1}
    if [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      printf '%s\n' "$choice"
      return 0
    fi
    printf 'error: choose a number between 1 and %d\n' "$count" >"$tty"
  done
}

template_display_label() {
  local template_path=$1
  local template_name=${template_path##*/}
  local template_stem=${template_name%.tar.*}

  printf '%s\n' "$template_stem"
}

list_storages() {
  pvesh get /storage | awk -F'│' '
    $0 ~ /^│/ {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($2 != "" && $2 != "storage") {
        print $2
      }
    }
  '
}

resolve_storage() {
  local storage=${RASTERCAST_CT_STORAGE:-auto}

  if [[ -n $storage && $storage != auto ]]; then
    printf '%s\n' "$storage"
    return 0
  fi

  local -a storages=()
  local storage_name
  while IFS= read -r storage_name; do
    [[ -n $storage_name ]] && storages+=( "$storage_name" )
  done < <(list_storages)

  if [[ ${#storages[@]} -eq 0 ]]; then
    printf 'error: no Proxmox storages found; set RASTERCAST_CT_STORAGE explicitly\n' >&2
    exit 1
  fi

  if [[ ${#storages[@]} -eq 1 ]]; then
    printf '%s\n' "${storages[0]}"
    return 0
  fi

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    choose_storage_interactively "${storages[@]}"
    return 0
  fi

  printf 'error: multiple Proxmox storages are available but no interactive prompt is possible; set RASTERCAST_CT_STORAGE explicitly\n' >&2
  printf 'available storages:\n' >&2
  printf '  %s\n' "${storages[@]}" >&2
  exit 1
}

resolve_template() {
  local template=${RASTERCAST_CT_TEMPLATE:-auto}

  if [[ -n $template && $template != auto ]]; then
    if [[ ! -f $template ]]; then
      printf 'error: RASTERCAST_CT_TEMPLATE not found: %s\n' "$template" >&2
      exit 1
    fi
    printf '%s\n' "$template"
    return 0
  fi

  local -a templates=()
  local template_path
  while IFS= read -r template_path; do
    [[ -n $template_path ]] && templates+=( "$template_path" )
  done < <(list_all_templates)

  if [[ ${#templates[@]} -eq 0 ]]; then
    printf 'error: no local CT template found in /var/lib/vz/template/cache; set RASTERCAST_CT_TEMPLATE explicitly\n' >&2
    exit 1
  fi

  if [[ ${#templates[@]} -eq 1 ]]; then
    printf '%s\n' "${templates[0]}"
    return 0
  fi

  if [[ -r /dev/tty && -w /dev/tty ]]; then
    choose_template_interactively "${templates[@]}"
    return 0
  fi

  printf 'error: multiple Proxmox templates are available but no interactive prompt is possible; set RASTERCAST_CT_TEMPLATE explicitly\n' >&2
  printf 'available templates:\n' >&2
  for template_path in "${templates[@]}"; do
    printf '  %s\n' "$(template_display_label "$template_path")" >&2
  done
  exit 1
}

create_ct() {
  local ctid=$1
  local hostname=$2
  local template
  template=$(resolve_template)
  local storage
  storage=$(resolve_storage)
  local disk_size=${RASTERCAST_CT_DISK_SIZE:-8}
  disk_size=${disk_size%G}
  disk_size=${disk_size%g}
  local bridge=${RASTERCAST_CT_BRIDGE:-vmbr0}
  local memory=${RASTERCAST_CT_MEMORY:-1024}
  local cores=${RASTERCAST_CT_CORES:-1}
  local password=${RASTERCAST_CT_PASSWORD:-}
  local ssh_public_key_file=${RASTERCAST_CT_SSH_PUBLIC_KEY_FILE:-}
  local nameserver=${RASTERCAST_CT_NAMESERVER:-1.1.1.1}
  local searchdomain=${RASTERCAST_CT_SEARCHDOMAIN:-}
  local -a create_args=(
    create
    "$ctid"
    "$template"
    --hostname "$hostname"
    --rootfs "${storage}:${disk_size}"
    --cores "$cores"
    --memory "$memory"
    --net0 "name=eth0,bridge=${bridge},ip=dhcp"
    --ostype debian
    --unprivileged 1
    --features nesting=1
    --onboot 1
    --nameserver "$nameserver"
  )

  if [[ -n $searchdomain ]]; then
    create_args+=( --searchdomain "$searchdomain" )
  fi
  if [[ -n $password ]]; then
    create_args+=( --password "$password" )
  fi

  if pct config "$ctid" >/dev/null 2>&1; then
    printf 'error: CT ID %s already exists; choose a different RASTERCAST_CTID or omit it\n' "$ctid" >&2
    exit 1
  fi

  printf 'provision: creating CT %s (%s) from %s\n' "$ctid" "$hostname" "$template" >&2
  pct "${create_args[@]}"

  if [[ -n $ssh_public_key_file ]]; then
    if [[ ! -f $ssh_public_key_file ]]; then
      printf 'error: RASTERCAST_CT_SSH_PUBLIC_KEY_FILE not found: %s\n' "$ssh_public_key_file" >&2
      exit 1
    fi
    pct set "$ctid" --ssh-public-keys "$ssh_public_key_file"
  fi
}

wait_for_ct() {
  local ctid=$1
  local attempts=30

  while (( attempts > 0 )); do
    if pct exec "$ctid" -- true >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempts=$((attempts - 1))
  done

  printf 'error: timed out waiting for CT %s to become available\n' "$ctid" >&2
  exit 1
}

sync_repo_into_ct() {
  local ctid=$1
  local source_dir=$2
  local install_dir=$3

  printf 'provision: syncing %s into CT %s:%s\n' "$source_dir" "$ctid" "$install_dir" >&2
  pct exec "$ctid" -- bash -lc "rm -rf '$install_dir' && mkdir -p '$install_dir'"
  tar -C "$source_dir" --exclude=.git -cf - . | pct exec "$ctid" -- tar -C "$install_dir" -xf -
}

clone_repo_into_ct() {
  local ctid=$1
  local repo_url=$2
  local install_dir=$3

  printf 'provision: cloning %s into CT %s:%s\n' "$repo_url" "$ctid" "$install_dir" >&2
  pct exec "$ctid" -- env DEBIAN_FRONTEND=noninteractive bash -lc \
    "rm -rf '$install_dir' && git clone '$repo_url' '$install_dir'"
}

install_packages_into_ct() {
  local ctid=$1

  printf 'provision: installing runtime packages in CT %s\n' "$ctid" >&2
  pct exec "$ctid" -- env DEBIAN_FRONTEND=noninteractive bash -lc \
    "apt-get update && apt-get install -y ca-certificates curl ffmpeg git openssh-client python3 rsync systemd yt-dlp"
}

install_playback_service_into_ct() {
  local ctid=$1
  local install_dir=$2
  local launch_mode=$3

  printf 'provision: installing systemd service in CT %s\n' "$ctid" >&2
  pct exec "$ctid" -- bash -lc "cat > /etc/systemd/system/rastercast.service" <<EOF
[Unit]
Description=Rastercast
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
Environment=RASTERCAST_REPO_DIR=${install_dir}
Environment=RASTERCAST_LAUNCH_MODE=${launch_mode}
ExecStart=${install_dir}/scripts/rastercast-service.sh
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  pct exec "$ctid" -- bash -lc "systemctl daemon-reload && systemctl enable rastercast.service"
}

start_playback_service_into_ct() {
  local ctid=$1

  printf 'provision: starting rastercast.service in CT %s\n' "$ctid" >&2
  pct exec "$ctid" -- systemctl start rastercast.service
}

install_control_service_into_ct() {
  local ctid=$1
  local install_dir=$2
  local bind_addr=$3
  local port=$4
  local dj_mode=$5

  printf 'provision: installing control server service in CT %s\n' "$ctid" >&2
  pct exec "$ctid" -- bash -lc "cat > /etc/systemd/system/rastercast-control.service" <<EOF
[Unit]
Description=Rastercast Control Server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
WorkingDirectory=${install_dir}
Environment=RASTERCAST_DJ_MODE=${dj_mode}
ExecStart=/usr/bin/python3 ${install_dir}/bin/rastercast-control-server.py ${bind_addr} ${port} ${install_dir}
Restart=on-failure
RestartSec=5
KillMode=control-group
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
  pct exec "$ctid" -- bash -lc "systemctl daemon-reload && systemctl enable rastercast-control.service"
}

start_control_service_into_ct() {
  local ctid=$1

  printf 'provision: starting rastercast-control.service in CT %s\n' "$ctid" >&2
  pct exec "$ctid" -- systemctl start rastercast-control.service
}

report_service_state() {
  local ctid=$1
  local service=$2
  local state

  if state=$(pct exec "$ctid" -- systemctl is-active "$service" 2>/dev/null); then
    printf 'provision: %s is %s in CT %s\n' "$service" "$state" "$ctid" >&2
  else
    printf 'warning: %s is not active in CT %s\n' "$service" "$ctid" >&2
    pct exec "$ctid" -- systemctl status "$service" --no-pager -l >&2 || true
  fi
}

get_ct_ip() {
  local ctid=$1

  pct exec "$ctid" -- sh -lc "hostname -I 2>/dev/null | awk '{print \$1}'"
}

print_summary() {
  local ctid=$1
  local hostname=$2
  local ip
  local control_state
  local playback_state

  ip=$(get_ct_ip "$ctid" | tr -d '\r' || true)
  control_state=$(pct exec "$ctid" -- systemctl is-active rastercast-control.service 2>/dev/null || true)
  playback_state=$(pct exec "$ctid" -- systemctl is-active rastercast.service 2>/dev/null || true)

  printf 'provision: summary\n' >&2
  printf '  VMID: %s\n' "$ctid" >&2
  printf '  hostname: %s\n' "$hostname" >&2
  printf '  ip: %s\n' "${ip:-unknown}" >&2
  printf '  rastercast-control.service: %s\n' "${control_state:-inactive}" >&2
  printf '  rastercast.service: %s\n' "${playback_state:-inactive}" >&2
}

main() {
  if [[ ${1:-} == "" || ${1:-} == "-h" || ${1:-} == "--help" ]]; then
    usage
    exit 0
  fi

  require_command pct
  require_command pvesh
  require_command tar

  local hostname=$1
  local ctid
  local source_dir=${2:-}
  local install_dir=${RASTERCAST_INSTALL_DIR:-/opt/rastercast}
  local launch_mode=${RASTERCAST_LAUNCH_MODE:-detached-loop}
  local enable_playback_service=${RASTERCAST_ENABLE_PLAYBACK_SERVICE:-${RASTERCAST_ENABLE_SERVICE:-0}}
  local enable_control_service=${RASTERCAST_ENABLE_CONTROL_SERVICE:-1}
  local repo_url=${RASTERCAST_REPO_URL:-https://github.com/rickycodes/mister_rastercast.git}
  local control_bind_addr=${RASTERCAST_CONTROL_BIND_ADDR:-0.0.0.0}
  local control_port=${RASTERCAST_CONTROL_PORT:-8092}
  local control_dj_mode=${RASTERCAST_CONTROL_DJ_MODE:-0}
  local repo_root=

  if [[ -z $source_dir ]]; then
    if repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd) && [[ -d $repo_root/.git ]]; then
      source_dir=$repo_root
    fi
  fi

  if [[ -n ${RASTERCAST_CTID:-} ]]; then
    if [[ ! ${RASTERCAST_CTID} =~ ^[0-9]+$ ]]; then
      printf 'error: RASTERCAST_CTID must be numeric when set\n' >&2
      exit 1
    fi
    ctid=$RASTERCAST_CTID
  else
    ctid=$(next_ctid)
  fi

  if [[ ! $ctid =~ ^[0-9]+$ ]]; then
    printf 'error: could not determine a numeric VMID for CT creation\n' >&2
    exit 1
  fi

  create_ct "$ctid" "$hostname"

  if ! pct status "$ctid" 2>/dev/null | grep -q 'status: running'; then
    pct start "$ctid" >/dev/null 2>&1 || true
  fi

  wait_for_ct "$ctid"
  install_packages_into_ct "$ctid"

  if [[ -n $source_dir ]]; then
    if [[ ! -d $source_dir ]]; then
      printf 'error: source dir not found: %s\n' "$source_dir" >&2
      exit 1
    fi
    sync_repo_into_ct "$ctid" "$source_dir" "$install_dir"
  else
    clone_repo_into_ct "$ctid" "$repo_url" "$install_dir"
  fi

  pct exec "$ctid" -- bash -lc "chmod +x '$install_dir/scripts/rastercast-service.sh' '$install_dir/launch.sh'"

  if is_enabled "$enable_playback_service"; then
    install_playback_service_into_ct "$ctid" "$install_dir" "$launch_mode"
    start_playback_service_into_ct "$ctid"
    report_service_state "$ctid" rastercast.service
  fi

  if is_enabled "$enable_control_service"; then
    install_control_service_into_ct "$ctid" "$install_dir" "$control_bind_addr" "$control_port" "$control_dj_mode"
    start_control_service_into_ct "$ctid"
    report_service_state "$ctid" rastercast-control.service
  fi

  print_summary "$ctid" "$hostname"
  printf 'provision: rastercast setup complete in CT %s at %s\n' "$ctid" "$install_dir" >&2
}

main "$@"
