#!/usr/bin/env bash
set -euo pipefail

config_file=${RASTERCAST_CONFIG_FILE:-/media/fat/MiSTer.ini}

ideal_video_mode='320,240,60'
ideal_vga_scaler='1'

default_video_mode=${RASTERCAST_DEFAULT_VIDEO_MODE:-0}
default_vga_scaler=${RASTERCAST_DEFAULT_VGA_SCALER:-0}

usage_error() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

read_setting() {
  local key=$1
  awk -F= -v key="$key" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      sub(/\r$/, "", value)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      print value
      exit
    }
  ' "$config_file" 2>/dev/null || true
}

ensure_config() {
  [[ -f $config_file ]] || usage_error "config not found: $config_file"
}

replace_or_append() {
  local key=$1
  local value=$2

  if grep -q "^${key}=" "$config_file"; then
    sed -i -E "s|^${key}=.*|${key}=${value}|" "$config_file"
  else
    printf '%s=%s\n' "$key" "$value" >> "$config_file"
  fi
}

set_stream_profile() {
  replace_or_append video_mode "$ideal_video_mode"
  replace_or_append vga_scaler "$ideal_vga_scaler"
}

set_default_profile() {
  replace_or_append video_mode "$default_video_mode"
  replace_or_append vga_scaler "$default_vga_scaler"
}

is_stream_profile() {
  [[ $(read_setting video_mode) == "$ideal_video_mode" ]]
}

is_default_profile() {
  [[ $(read_setting video_mode) == "$default_video_mode" ]]
}

reload_menu() {
  if [[ -w /dev/MiSTer_cmd ]]; then
    printf '%s\n' 'load_core /media/fat/menu.rbf' > /dev/MiSTer_cmd
    printf 'reloaded menu core\n' >&2
  else
    printf 'note: reboot or reload the menu core for the new video settings to take effect\n' >&2
  fi
}

print_profile_state() {
  local label=$1
  printf '%s: video_mode=%s vga_scaler=%s\n' \
    "$label" \
    "$(read_setting video_mode)" \
    "$(read_setting vga_scaler)" >&2
}

main() {
  ensure_config

  print_profile_state before

  if is_stream_profile; then
    set_default_profile
    printf 'set default profile\n' >&2
  else
    set_stream_profile
    printf 'set streaming profile\n' >&2
  fi

  sync
  print_profile_state after
  reload_menu
}

main "$@"
