#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154,SC2029

run_mister_ssh() {
  mister_ssh_used=1
  ssh "${ssh_opts[@]}" "${mister_user}@${mister_host}" "$@"
}

run_mister_playback() {
  case "$mister_tty" in
    1 | yes | true)
      mister_ssh_used=1
      ssh "${ssh_opts[@]}" -t "${mister_user}@${mister_host}" "$@"
      ;;
    0 | no | false)
      run_mister_ssh "$@"
      ;;
    *)
      printf 'error: RASTERCAST_MISTER_TTY must be 1 or 0\n' >&2
      exit 1
      ;;
  esac
}

run_mister_scp() {
  mister_ssh_used=1
  scp "${ssh_opts[@]}" "$@"
}

copy_mister_script() {
  local local_script="${repo_dir}/mister/rastercast.sh"

  if [[ ! -f "$local_script" ]]; then
    printf 'error: local MiSTer script not found: %s\n' "$local_script" >&2
    exit 1
  fi

  printf 'rastercast: deploying MiSTer script to %s@%s:%s\n' "$mister_user" "$mister_host" "$mister_script" >&2
  run_mister_scp "$local_script" "${mister_user}@${mister_host}:${mister_script}"
}

launch_mister() {
  local playback_cmd
  local remote_env=()
  local var
  local value

  case "$mister_auto" in
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

  if [[ "$mister_script" == *"'"* ]]; then
    printf "error: RASTERCAST_MISTER_SCRIPT cannot contain a single quote\n" >&2
    exit 1
  fi

  require_command ssh
  require_command scp

  case "$mister_deploy" in
    always)
      copy_mister_script
      ;;
    auto)
      if ! run_mister_ssh "test -x '$mister_script'"; then
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

  printf 'rastercast: launching MiSTer playback on %s@%s\n' "$mister_user" "$mister_host" >&2
  for var in \
    RASTERCAST_CACHE_KB \
    RASTERCAST_CACHE_MIN \
    RASTERCAST_MPLAYER_VO \
    RASTERCAST_MPLAYER_AUTOSYNC \
    RASTERCAST_MPLAYER_FRAMEDROP; do
    value=${!var-}
    if [[ -n "$value" ]]; then
      remote_env+=("${var}=$(shell_quote "$value")")
    fi
  done

  playback_cmd="chmod +x $(shell_quote "$mister_script") &&"
  if [[ ${#remote_env[@]} -gt 0 ]]; then
    playback_cmd+=" ${remote_env[*]}"
  fi
  playback_cmd+=" exec $(shell_quote "$mister_script") $(shell_quote "$stream_url")"
  if is_enabled "$mister_detach"; then
    run_mister_ssh "nohup sh -c $(shell_quote "$playback_cmd") >/tmp/rastercast.log 2>&1 </dev/null &"
  else
    run_mister_playback "$playback_cmd"
  fi
}
