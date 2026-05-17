#!/usr/bin/env bash

build_mister_ssh_opts() {
  local -a out=()

  out+=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o ControlMaster=auto
    -o ControlPersist=60
    -o "ControlPath=${cfg[ssh_control_path]}"
  )

  printf '%s\0' "${out[@]}"
}

run_mister_scp() {
  local -a ssh_opts=()

  IFS= read -r -d '' -a ssh_opts < <(build_mister_ssh_opts)
  cfg+=( [mister_ssh_used]=1 )
  scp "${ssh_opts[@]}" "$@"
}

remote_test_mister_script() {
  local -a ssh_opts=()

  IFS= read -r -d '' -a ssh_opts < <(build_mister_ssh_opts)
  cfg+=( [mister_ssh_used]=1 )
  ssh "${ssh_opts[@]}" "${cfg[mister_user]}@${cfg[mister_host]}" sh -s -- "${cfg[mister_script]}" <<'SCRIPT'
script_path=$1
test -x "$script_path"
SCRIPT
}

copy_mister_script() {
  local local_script="${cfg[repo_dir]}/mister/rastercast.sh"

  if [[ ! -f "$local_script" ]]; then
    printf 'error: local MiSTer script not found: %s\n' "$local_script" >&2
    exit 1
  fi

  printf 'rastercast: deploying MiSTer script to %s@%s:%s\n' "${cfg[mister_user]}" "${cfg[mister_host]}" "${cfg[mister_script]}" >&2
  run_mister_scp "$local_script" "${cfg[mister_user]}@${cfg[mister_host]}:${cfg[mister_script]}"
}

close_mister_connection() {
  local -a ssh_opts=()

  if [[ -z ${cfg[mister_ssh_used]:-} ]] || ! command -v ssh >/dev/null 2>&1; then
    return
  fi

  IFS= read -r -d '' -a ssh_opts < <(build_mister_ssh_opts)
  ssh "${ssh_opts[@]}" -O exit "${cfg[mister_user]}@${cfg[mister_host]}" >/dev/null 2>&1 || true
}

run_remote_mister_script() {
  local use_tty=$1
  shift
  local -a ssh_opts=()
  local -a ssh_cmd=(ssh)

  IFS= read -r -d '' -a ssh_opts < <(build_mister_ssh_opts)
  ssh_cmd+=( "${ssh_opts[@]}" )
  if is_enabled "$use_tty"; then
    ssh_cmd+=( -t )
  fi

  cfg+=( [mister_ssh_used]=1 )
  "${ssh_cmd[@]}" "${cfg[mister_user]}@${cfg[mister_host]}" sh -s -- "${cfg[mister_script]}" "${cfg[stream_url]}" "$@" <<'SCRIPT'
script_path=$1
stream_url=$2
shift 2
for pair in "$@"; do
  export "$pair"
done
chmod +x "$script_path"
if [[ ${RASTERCAST_MISTER_DETACH:-0} == 1 ]]; then
  nohup "$script_path" "$stream_url" >/tmp/rastercast.log 2>&1 </dev/null &
else
  exec "$script_path" "$stream_url"
fi
SCRIPT
}

launch_mister() {
  local -a remote_env=()
  local var
  local value

  case "${cfg[mister_auto]}" in
    1 | yes | true)
      ;;
    0 | no | false)
      return
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_AUTO must be 1 or 0\n' >&2
      exit 1
      ;;
  esac

  if [[ "${cfg[mister_script]}" == *"'"* ]]; then
    printf 'error: RASTERCAST_MISTER_SCRIPT cannot contain a single quote\n' >&2
    exit 1
  fi

  require_command ssh
  require_command scp

  case "${cfg[mister_deploy]}" in
    always)
      copy_mister_script
      ;;
    auto)
      if ! remote_test_mister_script; then
        copy_mister_script
      fi
      ;;
    never)
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_DEPLOY must be auto, always, or never\n' >&2
      exit 1
      ;;
  esac

  printf 'rastercast: launching MiSTer playback on %s@%s\n' "${cfg[mister_user]}" "${cfg[mister_host]}" >&2
  remote_env+=( "RASTERCAST_MISTER_DETACH=${cfg[mister_detach]}" )
  for var in \
    RASTERCAST_CACHE_KB \
    RASTERCAST_CACHE_MIN \
    RASTERCAST_MPLAYER_VO \
    RASTERCAST_MPLAYER_AUTOSYNC \
    RASTERCAST_MPLAYER_FRAMEDROP; do
    value=${!var-}
    if [[ -n "$value" ]]; then
      remote_env+=( "${var}=${value}" )
    fi
  done

  run_remote_mister_script "${cfg[mister_tty]}" "${remote_env[@]}"
}
