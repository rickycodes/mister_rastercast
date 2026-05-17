#!/usr/bin/env bash
# shellcheck disable=SC2154

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'error: required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

is_http_url() {
  [[ "$1" =~ ^https?:// ]]
}

is_ytdlp_url() {
  [[ "$1" =~ ^https?://([^/?#]+\.)?(youtube\.com|youtu\.be)([/?#]|$) ]]
}

is_enabled() {
  case "$1" in
    1 | yes | true)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

validate_bool() {
  local name=$1
  local value=$2

  case "$value" in
    1 | yes | true | 0 | no | false)
      ;;
    *)
      printf 'error: %s must be 1 or 0\n' "$name" >&2
      exit 1
      ;;
  esac
}

show_ffmpeg_log() {
  if [[ -f "${ffmpeg_log}" ]]; then
    printf '%s\n' '---- ffmpeg log ----' >&2
    sed -n '1,200p' "${ffmpeg_log}" >&2
    printf '%s\n' '--------------------' >&2
  fi
}

show_server_log() {
  if [[ -f "${server_log}" ]]; then
    printf '%s\n' '---- server log ----' >&2
    sed -n '1,80p' "${server_log}" >&2
    printf '%s\n' '--------------------' >&2
  fi
}

concat_escape() {
  local value=${1//\'/\'\\\'\'}
  printf "file '%s'\n" "$value"
}

shell_quote() {
  local value=${1//\'/\'\\\'\'}
  printf "'%s'" "$value"
}
