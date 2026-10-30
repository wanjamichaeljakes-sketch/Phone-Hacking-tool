#!/usr/bin/env bash
# =====================================================================
#  PHONE TOOLKIT for Parrot OS
#  Sets up adb, scrcpy, Tailscale, fzf and helpers, connects your phone
#  (saved IP, USB or Tailscale) and gives you menus for ADB, scrcpy,
#  backups, notifications, camera, network tools and automation.
#
#  Run as your normal user (not root):   bash parrot-setup.sh
#  After the first run use the shortcut:  phone   (see "phone help")
#  Force the update/upgrade/install step: bash parrot-setup.sh --full
#  Hands-free Tailscale login:  TS_AUTHKEY=tskey-xxxx bash parrot-setup.sh
#
#  Created by Michael Mbua Murigi
# =====================================================================
set -e

if [ "$EUID" -eq 0 ]; then
  echo "Run as your normal user, not root (scrcpy needs your desktop session)."
  exit 1
fi

# ---------------- Startup password ----------------
# Basic local gate only: this stops a casual launch, not a determined local
# attacker who has file access anyway. The password itself isn't stored in
# the script - only its SHA-256 hash is, so reading this file doesn't hand
# someone the password directly (it could still be brute-forced or found
# in your shell history if you ever typed it on a command line, so don't
# rely on this for anything that really matters).
PHONE_TOOLS_PASSWORD_HASH="bc2be00c40f8ba9f28b55625e250ba152475af5608cfffb2301c4dceaca300bd"

if [ -t 0 ]; then
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "sha256sum not found (part of coreutils); can't check the password."
    exit 1
  fi
  for _attempt in 1 2 3; do
    read -rsp "Password: " _entered
    echo
    _entered_hash=$(printf '%s' "$_entered" | sha256sum | awk '{print $1}')
    unset _entered
    if [ "$_entered_hash" = "$PHONE_TOOLS_PASSWORD_HASH" ]; then
      unset _entered_hash
      break
    fi
    unset _entered_hash
    if [ "$_attempt" -eq 3 ]; then
      echo "Too many wrong attempts."
      exit 1
    fi
    echo "Wrong password, try again."
  done
fi

export DEBIAN_FRONTEND=noninteractive

SELF="$(readlink -f "$0")"
SHORTCUT="$HOME/.local/bin/phone"
SAVED_IP_FILE="$HOME/.phone_tools_ip"
SCHED_IP_FILE="$HOME/.phone_tools_backup_ip"
NAMES_FILE="$HOME/.phone_tools_names"
PRESET_FILE="$HOME/.phone_tools_presets"
LOG_FILE="$HOME/.phone_tools.log"
CHECK_FILE="$HOME/.phone_tools_update_check"
BACKUP_NAME="phone_backup"
BACKUP_DIR="$HOME/$BACKUP_NAME"
# Optional: raw link to the newest version of this script for self-update
SELF_UPDATE_URL=""

# ---------------- Arguments ----------------
FULL=0
if [ "$1" = "--full" ]; then FULL=1; shift; fi
CMD="${1:-menu}"
if [ $# -gt 0 ]; then shift; fi
ARGS=("$@")
NONINT=0
[ "$CMD" = "cron-backup" ] && NONINT=1

# ---------------- Colors and UI ----------------
if [ -t 1 ]; then
  RED=$'\e[1;31m'; GRN=$'\e[1;32m'; YLW=$'\e[1;33m'
  BLU=$'\e[1;34m'; CYN=$'\e[1;36m'; DIM=$'\e[2m'; RST=$'\e[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; CYN=""; DIM=""; RST=""
fi

ok()      { echo "${GRN}✔${RST} $*"; }
warn()    { echo "${YLW}!${RST} $*"; }
err()     { echo "${RED}✘${RST} $*"; }
info()    { echo "${CYN}➜${RST} $*"; }
title()   { echo "${BLU}========== $* ==========${RST}"; }
section() { echo "${YLW}--- $* ---${RST}"; }

banner() {
  echo "$CYN"
  cat << 'BANNER'
 ____  _   _  ___  _   _ _____
|  _ \| | | |/ _ \| \ | | ____|
| |_) | |_| | | | |  \| |  _|
|  __/|  _  | |_| | |\  | |___
|_|   |_| |_|\___/|_| \_|_____|   T O O L K I T
BANNER
  echo "$RST"
  echo "${DIM}Created by Michael Mbua Murigi${RST}"
}

usage() {
  cat << 'U'
Phone Toolkit
  phone                 open the menu
  phone mirror          mirror and control the phone
  phone cam | front     live back / front camera with mic audio
  phone shot            screenshot the phone and open it
  phone backup          full backup (call log, SMS, contacts, pictures, files, WhatsApp, zip)
  phone notif           show phone notifications as laptop popups
  phone preset NAME     run a saved scrcpy preset
  phone status          connection, battery and Tailscale status
  phone update          update adb, scrcpy, Tailscale and this script
  phone install         install the 'phone' shortcut
  phone --full          force the update/upgrade/install step
U
}

case "$CMD" in help|-h|--help) usage; exit 0 ;; esac

# ---------------- Basic helpers ----------------
is_connected() {
  adb devices | awk -v d="$1" '$1==d && $2=="device" {f=1} END{exit !f}'
}

pause() { read -rp "Press Enter to continue..." _; }

# tailscale without needing a password prompt every time
ts() { tailscale "$@" 2>/dev/null || sudo -n tailscale "$@" 2>/dev/null; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 && return 0
  warn "$1 not found. Installing $2..."
  sudo apt install -y "$2" >/dev/null 2>&1
  command -v "$1" >/dev/null 2>&1
}

# Safely single-quote text for the phone's shell
shq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# ---------------- Device names ----------------
# Names are stored as "id|name" lines, one per device id (serial or ip:port).
device_name() {
  local id="$1" line
  [ -f "$NAMES_FILE" ] || { echo "$id"; return; }
  line=$(grep -F -- "$id|" "$NAMES_FILE" | head -n1)
  if [ -n "$line" ]; then echo "${line#*|}"; else echo "$id"; fi
}

name_device() {
  local id="$1" new
  read -rp "Name for $id (blank to clear): " new
  touch "$NAMES_FILE"
  grep -vF -- "$id|" "$NAMES_FILE" > "$NAMES_FILE.tmp" 2>/dev/null || true
  mv "$NAMES_FILE.tmp" "$NAMES_FILE"
  if [ -n "$new" ]; then
    echo "$id|$new" >> "$NAMES_FILE"
    ok "$id is now called '$new'."
  else
    ok "Name cleared for $id."
  fi
}

# Lists device ids currently reporting state "device" (authorized and ready).
list_connected_ids() {
  adb devices | awk '$2=="device" {print $1}'
}

# Prints "N) name (id)" for every connected device, 1-indexed.
list_devices_named() {
  local id i=0
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    i=$((i+1))
    printf '%d) %s %s(%s)%s\n' "$i" "$(device_name "$id")" "$DIM" "$id" "$RST"
  done < <(list_connected_ids)
}

# Returns the chosen device id on stdout.
# - 0 connected -> error, nothing printed.
# - 1 connected -> that one, no prompt.
# - 2+ connected -> numbered picker by name, with an option to (re)name any of them.
pick_connected_device() {
  local -a ids=()
  local id n choice name_target
  while IFS= read -r id; do [ -n "$id" ] && ids+=("$id"); done < <(list_connected_ids)

  if [ "${#ids[@]}" -eq 0 ]; then
    echo "No authorized devices connected." >&2
    return 1
  fi
  if [ "${#ids[@]}" -eq 1 ]; then
    echo "${ids[0]}"
    return 0
  fi

  while true; do
    echo "Several devices are connected:" >&2
    for i in "${!ids[@]}"; do
      printf '%d) %s  %s(%s)%s\n' "$((i+1))" "$(device_name "${ids[$i]}")" "$DIM" "${ids[$i]}" "$RST" >&2
    done
    echo "n) Name one of these devices" >&2
    read -rp "Choose a device (or n to name one): " choice >&2
    if [ "$choice" = "n" ]; then
      read -rp "Which number to name? " n >&2
      if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#ids[@]}" ]; then
        name_device "${ids[$((n-1))]}" >&2
      fi
      continue
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#ids[@]}" ]; then
      echo "${ids[$((choice-1))]}"
      return 0
    fi
    echo "Invalid choice." >&2
  done
}

# ---------------- Setup ----------------
setup_tools() {
  if [ "$FULL" = 1 ] || ! command -v adb >/dev/null || ! command -v scrcpy >/dev/null || ! command -v tailscale >/dev/null; then
    info "[1/6] Updating package lists..."
    sudo apt update
    info "[2/6] Upgrading packages..."
    sudo apt full-upgrade -y
    info "[3/6] Installing adb, scrcpy, fzf and helpers..."
    sudo apt install -y adb scrcpy curl zip fzf xclip libnotify-bin
    info "[4/6] Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  else
    ok "[1-4/6] adb, scrcpy and Tailscale already installed (use --full to force the update)."
  fi
}

setup_tailscale() {
  info "[5/6] Tailscale..."
  if ts status >/dev/null 2>&1; then
    ok "Tailscale is already connected."
  elif [ -n "$TS_AUTHKEY" ]; then
    sudo tailscale up --authkey "$TS_AUTHKEY"
    ts status
  else
    echo "Open the login link below in your browser..."
    sudo tailscale up
    ts status
  fi
}

connect_phone() {
  info "[6/6] Connecting the phone..."
  adb start-server >/dev/null 2>&1
  DEV=""
  local target=""

  if [ "$NONINT" = 1 ] && [ -f "$SCHED_IP_FILE" ]; then
    target=$(cat "$SCHED_IP_FILE")
  elif [ -f "$SAVED_IP_FILE" ]; then
    target=$(cat "$SAVED_IP_FILE")
  fi

  if [ -n "$target" ]; then
    info "Trying saved phone: $target ..."
    timeout 8 adb connect "$target" >/dev/null 2>&1 || true
    if is_connected "$target"; then
      DEV="$target"
      ok "Reconnected to $DEV without USB."
    else
      warn "Saved phone not reachable."
    fi
  fi

  if [ -z "$DEV" ] && [ "$NONINT" = 1 ]; then
    err "Phone unreachable, nightly backup skipped."
    exit 1
  fi

  if [ -z "$DEV" ]; then
    echo "Plug in your phone via USB (USB debugging on) and accept the prompt."
    adb kill-server
    adb start-server
    adb -d wait-for-device

    local ip
    ip=$(adb -d shell ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | tr -d '\r')
    if [ -z "$ip" ]; then
      err "Could not detect the phone IP. Make sure the phone is on Wi-Fi."
      exit 1
    fi
    ok "Phone IP address: $ip"

    info "Opening port 5555 on the phone..."
    adb -d tcpip 5555
    sleep 3

    info "Connecting to $ip:5555..."
    adb connect "$ip:5555"
    if ! is_connected "$ip:5555"; then
      err "Wireless connection failed. Check that the laptop and phone are on the same Wi-Fi."
      exit 1
    fi
    DEV="$ip:5555"
    echo "$DEV" > "$SAVED_IP_FILE"
    ok "Connected wirelessly. You can unplug the USB cable."
  fi
}

# ---------------- Auto-reconnect watcher ----------------
WATCH_PID=""

reconnect_loop() {
  local was_connected=1
  while true; do
    if ! is_connected "$1"; then
      if [ "$was_connected" = 1 ]; then
        echo "$(date '+%F %T') lost $1, reconnecting" >> "$LOG_FILE"
        command -v notify-send >/dev/null 2>&1 && notify-send -a "Phone" "Phone disconnected" "$1" 2>/dev/null
        was_connected=0
      fi
      if timeout 10 adb connect "$1" >/dev/null 2>&1 && is_connected "$1"; then
        was_connected=1
        echo "$(date '+%F %T') reconnected $1" >> "$LOG_FILE"
        command -v notify-send >/dev/null 2>&1 && notify-send -a "Phone" "Phone reconnected" "$1" 2>/dev/null
      fi
    else
      was_connected=1
    fi
    sleep 10
  done
}

stop_watcher() {
  if [ -n "$WATCH_PID" ]; then
    kill "$WATCH_PID" 2>/dev/null
    WATCH_PID=""
  fi
}

start_watcher() {
  stop_watcher
  reconnect_loop "$DEV" >/dev/null 2>&1 &
  WATCH_PID=$!
}

watcher_state() {
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then echo "${GRN}on${RST}"; else echo "${DIM}off${RST}"; fi
}

set_target() {
  DEV="$1"
  A="adb -s $DEV"
  echo "$DEV" > "$SAVED_IP_FILE"
  ok "Active target: $(device_name "$DEV") ($DEV, saved for next time)"
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Phone" "Phone connected" "$DEV" 2>/dev/null
  case "$DEV" in *:*) start_watcher ;; esac
}

# ---------------- Visual helpers (bars, dots) ----------------
# Draws a 10-segment bar for a 0-100 value, colored by thresholds.
bar() {
  local val="$1" width=10 filled empty i color out
  if ! [[ "$val" =~ ^[0-9]+$ ]]; then printf '%s' "${DIM}[??????????]${RST}"; return; fi
  filled=$(( val * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))
  if   [ "$val" -ge 50 ]; then color="$GRN"
  elif [ "$val" -ge 20 ]; then color="$YLW"
  else color="$RED"
  fi
  out="["
  for ((i=0; i<filled; i++)); do out+="█"; done
  for ((i=0; i<empty; i++)); do out+="░"; done
  out+="]"
  printf '%s%s%s' "$color" "$out" "$RST"
}

# Maps a Wi-Fi RSSI (negative dBm) to a rough 0-100 scale for the bar helper.
rssi_to_pct() {
  local r="$1" pct
  if ! [[ "$r" =~ ^-?[0-9]+$ ]]; then echo ""; return; fi
  pct=$(( (r + 100) * 100 / 50 ))
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  echo "$pct"
}

# ---------------- Box-drawing menu header ----------------
box_title() {
  local text=" $* " len width i top bot mid
  len=${#text}
  width=$(( len > 46 ? len : 46 ))
  top="┌"; bot="└"
  for ((i=0; i<width; i++)); do top+="─"; bot+="─"; done
  top+="┐"; bot+="┘"
  mid="│${text}"
  for ((i=len; i<width; i++)); do mid+=" "; done
  mid+="│"
  echo "${BLU}${top}${RST}"
  echo "${BLU}│${RST}${CYN}${text}$(printf '%*s' $((width-len)) '')${BLU}│${RST}"
  echo "${BLU}${bot}${RST}"
}

# ---------------- Status ----------------
status_line() {
  local conn bat batpct tsst rssi rssipct
  if is_connected "$DEV"; then conn="${GRN}●${RST} connected"; else conn="${RED}●${RST} offline"; fi
  bat=$(timeout 5 $A shell dumpsys battery < /dev/null 2>/dev/null | tr -d '\r' | awk -F': ' '/^ *level:/ {print $2; exit}')
  if ts status >/dev/null 2>&1; then
    tsst="${GRN}up${RST} ($(ts ip -4 2>/dev/null | head -n1))"
  else
    tsst="${RED}down${RST}"
  fi
  rssi=$(timeout 5 $A shell dumpsys wifi < /dev/null 2>/dev/null | tr -d '\r' | grep -m1 -oP 'RSSI: \K-?[0-9]+')
  rssipct=$(rssi_to_pct "$rssi")
  echo "$conn ${DIM}|${RST} $(device_name "$DEV") ${DIM}($DEV)${RST}"
  if [ -n "$bat" ]; then
    echo "  battery  $(bar "$bat") ${bat}%"
  else
    echo "  battery  ${DIM}[??????????] ?%${RST}"
  fi
  if [ -n "$rssipct" ]; then
    echo "  wifi     $(bar "$rssipct") ${rssi} dBm"
  fi
  echo "  tailscale $tsst ${DIM}|${RST} auto-reconnect $(watcher_state)"
}

# ---------------- Session stats ----------------
SESSION_START=$(date +%s)
SESSION_BACKUPS=0
SESSION_SHOTS=0

session_summary() {
  local end dur mins secs
  end=$(date +%s)
  dur=$(( end - SESSION_START ))
  mins=$(( dur / 60 )); secs=$(( dur % 60 ))
  echo
  echo "${CYN}Session summary:${RST} connected ${mins}m ${secs}s | backups run: $SESSION_BACKUPS | screenshots: $SESSION_SHOTS"
}

# ---------------- Package picker (fzf or numbered) ----------------
get_packages() {
  local out=""
  case "$1" in
    launcher)
      out=$($A shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER < /dev/null 2>/dev/null \
        | tr -d '\r' | grep '/' | cut -d/ -f1 | sort -u)
      if [ -z "$out" ]; then
        out=$($A shell pm list packages < /dev/null | tr -d '\r' | sed 's/^package://' | sort -u)
      fi
      ;;
    user) out=$($A shell pm list packages -3 < /dev/null | tr -d '\r' | sed 's/^package://' | sort -u) ;;
    *)    out=$($A shell pm list packages < /dev/null | tr -d '\r' | sed 's/^package://' | sort -u) ;;
  esac
  printf '%s\n' "$out"
}

# Prints the chosen package on stdout. $1 = launcher | user | all
pick_package() {
  local list choice pkg matches i
  local -a apps
  list=$(get_packages "${1:-launcher}")
  if [ -z "$list" ]; then echo "Could not read the app list." >&2; return 1; fi

  if command -v fzf >/dev/null 2>&1; then
    printf '%s\n' "$list" | fzf --height=70% --reverse --prompt="App> "
    return
  fi

  mapfile -t apps <<< "$list"
  while true; do
    echo "Apps found: ${#apps[@]}" >&2
    { for i in "${!apps[@]}"; do printf '%3d) %s\n' $((i+1)) "${apps[$i]}"; done; } | less -FX >&2
    read -rp "Number, package name, or search word (Enter to cancel): " choice
    [ -z "$choice" ] && return 1

    pkg=""
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#apps[@]}" ]; then
      pkg="${apps[$((choice-1))]}"
    else
      matches=$(printf '%s\n' "${apps[@]}" | grep -i -- "$choice")
      if [ -z "$matches" ]; then echo "No match for '$choice'." >&2; continue; fi
      if [ "$(printf '%s\n' "$matches" | wc -l)" -eq 1 ]; then
        pkg="$matches"
      else
        mapfile -t apps <<< "$matches"
        continue
      fi
    fi
    echo "$pkg"
    return 0
  done
}

launch_app() {
  local pkg
  pkg=$(pick_package launcher) || return
  [ -z "$pkg" ] && return
  info "Launching $pkg ..."
  $A shell monkey -p "$pkg" -c android.intent.category.LAUNCHER 1 < /dev/null
}

# ---------------- Backup helpers ----------------
# Pull a phone folder, skipping files that already exist locally
pull_new() {
  local src="$1" dst="$2" total=0 got=0 skipped=0 f rel out
  if ! $A shell "[ -d '$src' ]" < /dev/null; then
    echo "Not found on phone: $src"
    return
  fi
  mkdir -p "$dst"
  while IFS= read -r f; do
    f=${f%$'\r'}
    [ -z "$f" ] && continue
    rel=${f#"$src"/}
    out="$dst/$rel"
    total=$((total+1))
    if [ -e "$out" ]; then
      skipped=$((skipped+1))
      continue
    fi
    mkdir -p "$(dirname "$out")"
    if $A pull "$f" "$out" < /dev/null > /dev/null 2>&1; then
      got=$((got+1))
      echo "  + $rel"
    fi
  done < <($A shell "find '$src' -type f" < /dev/null 2>/dev/null)
  ok "$src -> $got new, $skipped already saved, $total total"
}

backup_calllog() {
  local f; mkdir -p "$BACKUP_DIR"
  f="$BACKUP_DIR/call_log_$(date +%Y%m%d_%H%M%S).txt"
  $A shell content query --uri content://call_log/calls < /dev/null > "$f"
  ok "Saved $f ($(wc -l < "$f") lines)"
}

backup_sms() {
  local f; mkdir -p "$BACKUP_DIR"
  f="$BACKUP_DIR/sms_$(date +%Y%m%d_%H%M%S).txt"
  $A shell content query --uri content://sms < /dev/null > "$f"
  ok "Saved $f ($(wc -l < "$f") lines)"
  echo "If the file is empty, your Android version blocks SMS access over adb."
}

backup_contacts() {
  local f; mkdir -p "$BACKUP_DIR"
  f="$BACKUP_DIR/contacts_$(date +%Y%m%d_%H%M%S).txt"
  $A shell content query --uri content://com.android.contacts/data/phones --projection display_name:data1 < /dev/null > "$f"
  ok "Saved $f ($(wc -l < "$f") lines)"
}

backup_pictures() {
  pull_new /sdcard/DCIM "$BACKUP_DIR/DCIM"
  pull_new /sdcard/Pictures "$BACKUP_DIR/Pictures"
}

backup_files() {
  pull_new /sdcard/Download "$BACKUP_DIR/Download"
  pull_new /sdcard/Documents "$BACKUP_DIR/Documents"
  pull_new /sdcard/Music "$BACKUP_DIR/Music"
}

backup_whatsapp() {
  pull_new /sdcard/Android/media/com.whatsapp/WhatsApp/Media "$BACKUP_DIR/WhatsApp/Media"
  pull_new /sdcard/WhatsApp/Media "$BACKUP_DIR/WhatsApp/Media_old"
  pull_new "/sdcard/Android/media/com.whatsapp.w4b/WhatsApp Business/Media" "$BACKUP_DIR/WhatsApp_Business/Media"
}

zip_backup() {
  if [ ! -d "$BACKUP_DIR" ]; then echo "Nothing to zip yet."; return; fi
  need_cmd zip zip || { err "zip is not available."; return; }
  local z="phone_backup_$(date +%Y%m%d_%H%M%S).zip"
  (cd "$HOME" && zip -rq "$z" "$BACKUP_NAME") && ok "Created $HOME/$z"
}

full_backup() {
  backup_calllog; backup_sms; backup_contacts
  backup_pictures; backup_files; backup_whatsapp
  zip_backup
  SESSION_BACKUPS=$((SESSION_BACKUPS+1))
  command -v notify-send >/dev/null 2>&1 && notify-send -a "Phone" "Backup complete" "Saved to $BACKUP_DIR" 2>/dev/null
}

extract_apk() {
  local p paths line n=0
  p=$(pick_package user) || return
  [ -z "$p" ] && return
  paths=$($A shell pm path "$p" < /dev/null | tr -d '\r' | sed 's/^package://')
  if [ -z "$paths" ]; then err "Package not found."; return; fi
  mkdir -p "$BACKUP_DIR/apks/$p"
  while IFS= read -r line; do
    $A pull "$line" "$BACKUP_DIR/apks/$p/" < /dev/null && n=$((n+1))
  done <<< "$paths"
  ok "Pulled $n file(s) to $BACKUP_DIR/apks/$p/"
}

# ---------------- Screenshots, photos, installs ----------------
take_shot() {
  local f; mkdir -p "$BACKUP_DIR/screenshots"
  f="$BACKUP_DIR/screenshots/screenshot_$(date +%Y%m%d_%H%M%S).png"
  $A exec-out screencap -p > "$f" || return 1
  echo "$f"
}

shot_open() {
  local f
  f=$(take_shot) || { err "Screenshot failed."; return 1; }
  ok "Saved $f"
  SESSION_SHOTS=$((SESSION_SHOTS+1))
  if need_cmd xclip xclip; then
    xclip -selection clipboard -t image/png -i "$f" 2>/dev/null && ok "Copied to the laptop clipboard"
  fi
  xdg-open "$f" >/dev/null 2>&1 &
}

photo_browser() {
  local dir list sel tmp f i n
  local -a items
  read -rp "Phone folder [/sdcard/DCIM/Camera]: " dir
  dir=${dir:-/sdcard/DCIM/Camera}
  list=$($A shell "ls -t '$dir' 2>/dev/null | head -n 80" < /dev/null | tr -d '\r')
  if [ -z "$list" ]; then err "No files found in $dir"; return; fi

  if command -v fzf >/dev/null 2>&1; then
    sel=$(printf '%s\n' "$list" | fzf -m --height=70% --reverse --prompt="Photos (Tab = select several)> ")
  else
    mapfile -t items <<< "$list"
    for i in "${!items[@]}"; do printf '%3d) %s\n' $((i+1)) "${items[$i]}"; done
    read -rp "Numbers to open (space separated): " n
    sel=""
    for i in $n; do sel+="${items[$((i-1))]}"$'\n'; done
  fi
  [ -z "$sel" ] && return

  tmp=$(mktemp -d)
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    $A pull "$dir/$f" "$tmp/" < /dev/null > /dev/null 2>&1
    xdg-open "$tmp/$f" >/dev/null 2>&1 &
  done <<< "$sel"
  ok "Opened. Temporary copies are in $tmp"
}

install_apks() {
  local dir f n=0 fail=0
  read -rp "Folder with APK files [$PWD]: " dir
  dir=${dir:-$PWD}
  dir=${dir/#\~/$HOME}
  shopt -s nullglob
  for f in "$dir"/*.apk; do
    info "Installing $(basename "$f") ..."
    if $A install -r "$f" < /dev/null; then n=$((n+1)); else fail=$((fail+1)); fi
  done
  shopt -u nullglob
  ok "$n installed, $fail failed."
}

# ---------------- Typing, clipboard, calls ----------------
type_text() {
  local t="$1" esc
  t=${t//$'\n'/ }
  esc=$(printf '%s' "$t" | sed 's/[^a-zA-Z0-9 ._-]/\\&/g; s/ /%s/g')
  $A shell input text "$esc"
}

get_laptop_clip() {
  if command -v xclip >/dev/null 2>&1; then xclip -o -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then xsel -ob
  elif command -v wl-paste >/dev/null 2>&1; then wl-paste
  else return 1
  fi
}

clip_menu() {
  local c t
  while true; do
    clear
    box_title "CLIPBOARD AND TYPING"
    echo "1) Type the laptop clipboard on the phone (click a text field first)"
    echo "2) Type text from here on the phone"
    echo "3) Mirror with two-way clipboard sync (scrcpy)"
    echo "0) Back"
    echo "${DIM}Note: only plain ASCII text can be typed over adb. scrcpy syncs the clipboard"
    echo "both ways automatically while mirroring (Ctrl+V pastes the laptop clipboard).${RST}"
    read -rp "Choose: " c
    case "$c" in
      1) need_cmd xclip xclip
         t=$(get_laptop_clip)
         if [ -z "$t" ]; then err "Laptop clipboard is empty."; else type_text "$t"; ok "Typed."; fi
         pause ;;
      2) read -rp "Text: " t; type_text "$t"; pause ;;
      3) scrcpy -s "$DEV" ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

calls_menu() {
  local c n b
  while true; do
    clear
    box_title "CALLS AND SMS"
    echo "1) Call a number"
    echo "2) Open the dialer with a number"
    echo "3) Answer incoming call"
    echo "4) End call"
    echo "5) Write an SMS (opens Messages with the text ready, tap Send)"
    echo "0) Back"
    read -rp "Choose: " c
    case "$c" in
      1) read -rp "Number (e.g. +254712345678): " n
         n=${n//+/%2B}; n=${n//#/%23}
         $A shell am start -a android.intent.action.CALL -d "$(shq "tel:$n")"
         pause ;;
      2) read -rp "Number: " n
         n=${n//+/%2B}; n=${n//#/%23}
         $A shell am start -a android.intent.action.DIAL -d "$(shq "tel:$n")"
         pause ;;
      3) $A shell input keyevent KEYCODE_CALL ;;
      4) $A shell input keyevent KEYCODE_ENDCALL ;;
      5) read -rp "To (number): " n
         read -rp "Message: " b
         $A shell am start -a android.intent.action.SENDTO -d "$(shq "sms:$n")" \
           --es sms_body "$(shq "$b")" --ez exit_on_sent true
         echo "Tap Send on the phone (or in scrcpy) to finish."
         pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------------- Notifications ----------------
notif_dump() {
  $A shell dumpsys notification --noredact < /dev/null 2>/dev/null | tr -d '\r' | awk '
    function flush() { if (pkg != "" && (title != "" || text != "")) print pkg "|" title "|" text; pkg=""; title=""; text="" }
    /NotificationRecord\(/ { flush(); if (match($0, /pkg=[^ ]+/)) pkg=substr($0, RSTART+4, RLENGTH-4) }
    /android\.title=/ { t=$0; sub(/.*android\.title=/, "", t); sub(/^String \(/, "", t); sub(/\)$/, "", t); title=t }
    /android\.text=/  { t=$0; sub(/.*android\.text=/, "", t);  sub(/^String \(/, "", t); sub(/\)$/, "", t); text=t }
    END { flush() }
  ' | sort -u
}

notif_show() {
  local pkg title text
  notif_dump | while IFS='|' read -r pkg title text; do
    echo "${CYN}$pkg${RST}: ${YLW}$title${RST} - $text"
  done
}

notif_watch() {
  need_cmd notify-send libnotify-bin || warn "notify-send missing, showing notifications in the terminal only."
  declare -A seen=()
  local l k pkg title text
  STOP=0
  trap 'STOP=1' INT
  info "Watching phone notifications (Ctrl+C to stop)..."
  while IFS= read -r l; do
    k=$(printf '%s' "$l" | md5sum | cut -d' ' -f1); seen[$k]=1
  done < <(notif_dump)
  while [ "$STOP" -eq 0 ]; do
    while IFS= read -r l; do
      [ -n "$l" ] || continue
      k=$(printf '%s' "$l" | md5sum | cut -d' ' -f1)
      [ -n "${seen[$k]}" ] && continue
      seen[$k]=1
      IFS='|' read -r pkg title text <<< "$l"
      echo "${DIM}$(date +%H:%M:%S)${RST} ${CYN}$pkg${RST}: ${YLW}$title${RST} - $text"
      if command -v notify-send >/dev/null 2>&1; then
        notify-send -a "Phone" "$title" "$text ($pkg)" 2>/dev/null
      fi
    done < <(notif_dump)
    [ "$STOP" -eq 0 ] && sleep 5
  done
  trap ':' INT
  ok "Stopped."
}

# ---------------- Phone info ----------------
phone_info() {
  section "Device"
  echo "Model:    $($A shell getprop ro.product.model < /dev/null | tr -d '\r')"
  echo "Android:  $($A shell getprop ro.build.version.release < /dev/null | tr -d '\r')"
  echo "Wi-Fi:    $($A shell dumpsys wifi < /dev/null | grep -m1 -oP 'SSID: \K[^,]+' | tr -d '\r')"
  echo "IP:       $($A shell ip route get 1.1.1.1 < /dev/null | grep -oP 'src \K\S+' | tr -d '\r')"
  section "Battery"
  $A shell dumpsys battery < /dev/null | grep -E 'level|status|temperature|powered' | tr -d '\r'
  section "Storage (/sdcard)"
  $A shell df -h /sdcard < /dev/null | tr -d '\r'
  section "RAM"
  $A shell grep -E 'MemTotal|MemAvailable' /proc/meminfo < /dev/null | tr -d '\r'
  section "Running apps (top 40)"
  $A shell ps -A -o NAME < /dev/null | tr -d '\r' | grep -E '^[a-z][a-z0-9_]*\.[a-z]' | sort -u | head -n 40
}

# ---------------- Network tools ----------------
speed_test() {
  local f=/tmp/phone_speedtest.bin b=/tmp/phone_speedtest_back.bin t0 t1
  info "Creating a 30 MB test file..."
  head -c 30000000 /dev/urandom > "$f"
  t0=$(date +%s.%N)
  $A push "$f" /data/local/tmp/speedtest.bin > /dev/null
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "Laptop -> phone: %.1f MB/s (%.0f Mbit/s)\n", 30/(b-a), 240/(b-a)}'
  t0=$(date +%s.%N)
  $A pull /data/local/tmp/speedtest.bin "$b" > /dev/null
  t1=$(date +%s.%N)
  awk -v a="$t0" -v b="$t1" 'BEGIN{printf "Phone -> laptop: %.1f MB/s (%.0f Mbit/s)\n", 30/(b-a), 240/(b-a)}'
  $A shell rm -f /data/local/tmp/speedtest.bin < /dev/null
  rm -f "$f" "$b"
}

signal_info() {
  $A shell dumpsys wifi < /dev/null | tr -d '\r' | grep -m1 'mWifiInfo' \
    | grep -oP 'SSID: [^,]+|RSSI: -?[0-9]+|Link speed: [^,]+|Frequency: [^,]+'
  echo "${DIM}RSSI guide: above -60 great, -60 to -75 okay, below -75 weak.${RST}"
  section "Mobile signal"
  $A shell dumpsys telephony.registry < /dev/null | tr -d '\r' | grep -m1 -i 'mSignalStrength' | cut -c1-220
}

wifi_scan() {
  local out
  info "Scanning for nearby Wi-Fi networks (takes a few seconds)..."
  $A shell cmd wifi start-scan < /dev/null >/dev/null 2>&1
  sleep 4
  out=$($A shell cmd wifi list-scan-results < /dev/null 2>/dev/null | tr -d '\r')
  if [ -z "$out" ] || printf '%s' "$out" | grep -qi "unknown command"; then
    # Older Android: fall back to parsing dumpsys wifi's scan result block.
    out=$($A shell dumpsys wifi < /dev/null 2>/dev/null | tr -d '\r' \
      | awk '/ScanResults:/{flag=1; next} /^ *$/{flag=0} flag')
  fi
  if [ -z "$out" ]; then
    warn "No scan results."
    echo "On the phone: Settings > Location > Wi-Fi scanning must be on, and Location"
    echo "itself generally needs to be on too - Android ties Wi-Fi scan results to the"
    echo "location permission system on most versions."
  else
    printf '%s\n' "$out"
  fi
}

net_menu() {
  local c
  while true; do
    clear
    box_title "NETWORK TOOLS"
    echo "1) Speed test (laptop <-> phone)"
    echo "2) Wi-Fi signal strength (current network)"
    echo "3) Devices on this Wi-Fi (laptop and phone neighbours)"
    echo "4) Ping test from the phone"
    echo "5) Tailscale peers and ping to the phone"
    echo "6) Scan nearby Wi-Fi networks (SSID, signal, channel)"
    echo "0) Back"
    read -rp "Choose: " c
    case "$c" in
      1) speed_test; pause ;;
      2) signal_info; pause ;;
      3) section "Seen by the laptop"; ip neigh show | grep -v FAILED
         section "Seen by the phone"; $A shell ip neigh show < /dev/null | tr -d '\r' | grep -v FAILED
         pause ;;
      4) $A shell ping -c 4 8.8.8.8; pause ;;
      5) ts status
         echo
         ts ping -c 3 "${DEV%%:*}"
         pause ;;
      6) wifi_scan; pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------------- scrcpy helpers ----------------
install_latest_scrcpy() {
  if [ "$(uname -m)" != "x86_64" ]; then
    echo "Auto-install only supports x86_64. Use snap or build scrcpy from source."
    return
  fi
  local tag url tmp
  tag=$(curl -fsSL https://api.github.com/repos/Genymobile/scrcpy/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+')
  if [ -z "$tag" ]; then err "Could not reach GitHub."; return; fi
  url="https://github.com/Genymobile/scrcpy/releases/download/$tag/scrcpy-linux-x86_64-$tag.tar.gz"
  tmp=$(mktemp -d)
  info "Downloading scrcpy $tag ..."
  if ! curl -fL "$url" -o "$tmp/scrcpy.tar.gz"; then
    err "Download failed: $url"
    rm -rf "$tmp"
    return
  fi
  sudo rm -rf /opt/scrcpy
  sudo mkdir -p /opt/scrcpy
  sudo tar -xzf "$tmp/scrcpy.tar.gz" -C /opt/scrcpy --strip-components=1
  sudo ln -sf /opt/scrcpy/scrcpy /usr/local/bin/scrcpy
  rm -rf "$tmp"
  hash -r
  ok "Installed: $(scrcpy --version | head -n1)"
}

# Offer to install the latest scrcpy if the current one is older than $1
need_scrcpy() {
  local ver y
  ver=$(scrcpy --version | head -n1 | grep -oP '\d+\.\d+' | head -n1)
  if [ "$(printf '%s\n%s\n' "$ver" "$1" | sort -V | head -n1)" != "$1" ]; then
    warn "$2 needs scrcpy $1+ (you have $ver)."
    read -rp "Install the latest scrcpy now? (y/n): " y
    [ "$y" = "y" ] && install_latest_scrcpy
  fi
}

cam_run() {
  need_scrcpy 2.2 "Camera mirroring"
  scrcpy -s "$DEV" --video-source=camera --camera-facing="$1" --audio-source=mic --window-title="$1 camera"
}

seed_presets() {
  if [ ! -f "$PRESET_FILE" ]; then
    cat > "$PRESET_FILE" << 'PRESETS'
weak-network+sound|-m 640 -b 500K --max-fps 15 --audio-dup
hd-smooth|-m 1920 -b 16M --max-fps 60
battery-saver|--turn-screen-off --stay-awake -m 800 -b 2M
PRESETS
  fi
}

run_preset() {
  local name="$1" line args
  line=$(grep -m1 "^$name|" "$PRESET_FILE")
  if [ -z "$line" ]; then err "No preset called '$name'."; return 1; fi
  args=${line#*|}
  info "scrcpy $args"
  scrcpy -s "$DEV" $args
}

presets_menu() {
  local c n name flags line
  while true; do
    clear
    box_title "SCRCPY PRESETS"
    if [ -s "$PRESET_FILE" ]; then
      nl -w2 -s') ' "$PRESET_FILE" | sed 's/|/   ->   /'
    else
      echo "(no presets yet)"
    fi
    echo
    echo "r) Run a preset    s) Save a new preset    d) Delete a preset    0) Back"
    read -rp "Choose: " c
    case "$c" in
      r) read -rp "Preset number: " n
         line=$(sed -n "${n}p" "$PRESET_FILE")
         if [ -n "$line" ]; then run_preset "${line%%|*}"; else echo "Invalid number"; fi
         pause ;;
      s) read -rp "Preset name (no spaces or |): " name
         echo "Examples: -m 800 -b 2M --max-fps 30 | --audio-dup | --turn-screen-off --stay-awake"
         read -rp "scrcpy options: " flags
         if [ -n "$name" ] && [ -n "$flags" ]; then
           echo "${DIM}Will run as:${RST} scrcpy -s $DEV $flags"
           read -rp "Save this preset? (y/n): " y
           if [ "$y" = "y" ]; then
             echo "$name|$flags" >> "$PRESET_FILE"; ok "Saved '$name'."
           fi
         fi
         pause ;;
      d) read -rp "Preset number to delete: " n
         if [ -n "$n" ]; then sed -i "${n}d" "$PRESET_FILE"; ok "Deleted."; fi
         pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

game_menu() {
  local c base
  base=(--max-fps=60 -b 12M -m 1280 --stay-awake --window-title="Gaming mode")
  while true; do
    clear
    box_title "GAMING MODE"
    echo "1) Low latency: 60 fps, 12 Mbit/s"
    echo "2) + laptop keyboard and mouse as real input devices (scrcpy 3.0+)"
    echo "3) + physical gamepad forwarded (scrcpy 3.0+)"
    echo "0) Back"
    echo "${DIM}With keyboard/mouse mode the pointer is captured. Press Left Alt to release it.${RST}"
    read -rp "Choose: " c
    case "$c" in
      1) scrcpy -s "$DEV" "${base[@]}" ;;
      2) need_scrcpy 3.0 "Keyboard and mouse mode"
         scrcpy -s "$DEV" "${base[@]}" --keyboard=uhid --mouse=uhid ;;
      3) need_scrcpy 3.0 "Gamepad mode"
         scrcpy -s "$DEV" "${base[@]}" --keyboard=uhid --mouse=uhid --gamepad=uhid ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------------- Log viewer ----------------
log_menu() {
  local c p pid w f
  while true; do
    clear
    box_title "LOG VIEWER (Ctrl+C stops a live log)"
    echo "1) Whole phone, colored"
    echo "2) One app only (pick from a list)"
    echo "3) Errors only"
    echo "4) Search for a word"
    echo "5) Save the current log to a file"
    echo "6) Clear the log"
    echo "0) Back"
    read -rp "Choose: " c
    case "$c" in
      1) $A logcat -v color ;;
      2) p=$(pick_package user) || continue
         [ -z "$p" ] && continue
         pid=$($A shell pidof "$p" < /dev/null | tr -d '\r' | awk '{print $1}')
         if [ -z "$pid" ]; then warn "$p is not running. Launch it first."; pause
         else $A logcat -v color --pid="$pid"; fi ;;
      3) $A logcat -v color '*:E' ;;
      4) read -rp "Word to search for: " w
         $A logcat -v color | grep --line-buffered -i -- "$w" ;;
      5) mkdir -p "$BACKUP_DIR"
         f="$BACKUP_DIR/logcat_$(date +%Y%m%d_%H%M%S).txt"
         $A logcat -d > "$f"; ok "Saved $f"; pause ;;
      6) $A logcat -c; ok "Log cleared."; pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------------- Shortcut, schedule, updates ----------------
install_shortcut() {
  mkdir -p "$HOME/.local/bin"
  if [ "$SELF" != "$SHORTCUT" ]; then cp "$SELF" "$SHORTCUT"; fi
  chmod +x "$SHORTCUT"
  local rc
  case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)
      for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        if [ -f "$rc" ] && ! grep -q '\.local/bin' "$rc"; then
          echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
        fi
      done
      warn "Open a new terminal (or run: export PATH=\"\$HOME/.local/bin:\$PATH\") so 'phone' works."
      ;;
  esac
  ok "Shortcut installed: type 'phone' anywhere. Try 'phone help'."
}

schedule_backup() {
  local t ip guess h m
  install_shortcut > /dev/null
  need_cmd crontab cron || { err "cron is not available."; return; }
  sudo systemctl enable --now cron >/dev/null 2>&1

  read -rp "Time for the nightly backup (HH:MM, 24h) [02:00]: " t
  t=${t:-02:00}
  if ! [[ "$t" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then err "Invalid time."; return; fi
  h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}

  guess=$(ts status | awk '/android/ {print $1; exit}')
  guess=${guess:-${DEV%%:*}}
  echo "Use the phone's Tailscale IP to back up from any network (needs the Tailscale app on the phone)."
  read -rp "Phone IP to back up over [$guess]: " ip
  ip=${ip:-$guess}
  case "$ip" in *:*) ;; *) ip="$ip:5555" ;; esac
  echo "$ip" > "$SCHED_IP_FILE"

  ( crontab -l 2>/dev/null | grep -v '# phone-tools'
    echo "$m $h * * * $SHORTCUT cron-backup >> $LOG_FILE 2>&1 # phone-tools" ) | crontab -
  ok "Nightly backup scheduled at $(printf '%02d:%02d' "$h" "$m") for $ip. Log: $LOG_FILE"
  echo "The phone must be reachable then (port 5555 open, same network or Tailscale)."
}

unschedule_backup() {
  crontab -l 2>/dev/null | grep -v '# phone-tools' | crontab -
  rm -f "$SCHED_IP_FILE"
  ok "Nightly backup removed."
}

self_update() {
  local tmp y
  if [ -z "$SELF_UPDATE_URL" ]; then
    echo "Script self-update is off. Set SELF_UPDATE_URL at the top of the script to a raw link to the newest version."
    return
  fi
  tmp=$(mktemp)
  if ! timeout 15 curl -fsSL "$SELF_UPDATE_URL" -o "$tmp" || ! bash -n "$tmp"; then
    err "Could not fetch a valid update."; rm -f "$tmp"; return
  fi
  if cmp -s "$tmp" "$SELF"; then ok "Script is up to date."; rm -f "$tmp"; return; fi
  read -rp "A newer script version was found. Install it? (y/n): " y
  if [ "$y" = "y" ]; then
    cp "$tmp" "$SELF"
    [ -f "$SHORTCUT" ] && cp "$tmp" "$SHORTCUT"
    ok "Updated. Run the script again."
  fi
  rm -f "$tmp"
}

update_all() {
  local y
  info "Updating adb, scrcpy and Tailscale from apt..."
  sudo apt update && sudo apt install --only-upgrade -y adb scrcpy tailscale
  read -rp "Also install the newest scrcpy from GitHub? (y/n): " y
  [ "$y" = "y" ] && install_latest_scrcpy
  self_update
  rm -f "$CHECK_FILE.msg"
}

# Once a day: look for newer scrcpy / script and leave a note for the menu
check_updates() {
  local today last cur latest tmp msg=""
  today=$(date +%F)
  last=""; [ -f "$CHECK_FILE" ] && last=$(cat "$CHECK_FILE")
  [ "$last" = "$today" ] && return
  echo "$today" > "$CHECK_FILE"

  cur=$(scrcpy --version 2>/dev/null | head -n1 | grep -oP '\d+(\.\d+)+' | head -n1)
  latest=$(timeout 4 curl -fsSL https://api.github.com/repos/Genymobile/scrcpy/releases/latest 2>/dev/null | grep -oP '"tag_name":\s*"v\K[^"]+')
  if [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" != "$latest" ] \
     && [ "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | head -n1)" = "$cur" ]; then
    msg="A newer scrcpy is available: $latest (you have $cur). Install it: scrcpy menu -> 9"
  fi

  if [ -n "$SELF_UPDATE_URL" ]; then
    tmp=$(mktemp)
    if timeout 6 curl -fsSL "$SELF_UPDATE_URL" -o "$tmp" 2>/dev/null && bash -n "$tmp" && ! cmp -s "$tmp" "$SELF"; then
      msg="$msg${msg:+  |  }A newer version of this script is available: run 'phone update'"
    fi
    rm -f "$tmp"
  fi

  if [ -n "$msg" ]; then echo "$msg" > "$CHECK_FILE.msg"; else rm -f "$CHECK_FILE.msg"; fi
}

# ---------------- Menus ----------------
controls_menu() {
  local c b u t
  while true; do
    clear
    box_title "PHONE CONTROLS"
    echo " 1) Wake screen         7) Open a URL"
    echo " 2) Lock screen         8) Launch an app (pick from all apps)"
    echo " 3) Volume up           9) Type text on the phone"
    echo " 4) Volume down        10) Home button"
    echo " 5) Mute               11) Back button"
    echo " 6) Set brightness     12) Recent apps"
    echo "                       13) Power button"
    echo " 0) Back"
    read -rp "Choose: " c
    case "$c" in
      1) $A shell input keyevent KEYCODE_WAKEUP ;;
      2) $A shell input keyevent KEYCODE_SLEEP ;;
      3) $A shell input keyevent KEYCODE_VOLUME_UP ;;
      4) $A shell input keyevent KEYCODE_VOLUME_DOWN ;;
      5) $A shell input keyevent KEYCODE_VOLUME_MUTE ;;
      6) read -rp "Brightness (0-255): " b
         $A shell settings put system screen_brightness_mode 0
         $A shell settings put system screen_brightness "$b" ;;
      7) read -rp "URL: " u
         $A shell am start -a android.intent.action.VIEW -d "$(shq "$u")" ;;
      8) launch_app; pause ;;
      9) read -rp "Text: " t; type_text "$t" ;;
      10) $A shell input keyevent KEYCODE_HOME ;;
      11) $A shell input keyevent KEYCODE_BACK ;;
      12) $A shell input keyevent KEYCODE_APP_SWITCH ;;
      13) $A shell input keyevent KEYCODE_POWER ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

adb_menu() {
  local c f p s d y cmd
  while true; do
    clear
    box_title "ADB COMMANDS"
    section "Basics"
    echo " 1)  List connected devices"
    echo " 2)  Open phone shell"
    echo " 3)  Install an APK"
    echo " 4)  Uninstall an app (pick from a list)"
    echo " 5)  List installed apps"
    echo " 6)  Push file to phone"
    echo " 7)  Pull file from phone"
    echo " 8)  Take screenshot (saved in $BACKUP_NAME/screenshots)"
    echo " 9)  Record screen (Ctrl+C to stop)"
    echo "10)  Battery info"
    echo "11)  Phone model and Android version"
    echo "12)  Show phone IP address"
    echo "13)  Log viewer (colored, per app, search)"
    echo "14)  Reboot phone"
    echo "15)  Restart adb server"
    echo "16)  Disconnect wireless adb"
    echo "17)  Run a custom adb command"
    section "Backup and data (saved in ~/$BACKUP_NAME)"
    echo "18)  Pull call log"
    echo "19)  Pull text messages (SMS)"
    echo "20)  Pull pictures (skips ones already saved)"
    echo "21)  Pull contacts"
    echo "22)  Pull Downloads, Documents and Music"
    echo "23)  Pull WhatsApp media"
    echo "24)  FULL BACKUP (all of the above, then zip)"
    echo "25)  Zip the backup folder"
    echo "26)  Android app backup (adb backup)"
    echo "27)  Extract an installed app's APK"
    section "Phone"
    echo "28)  Phone controls"
    echo "29)  Phone info dashboard"
    echo "30)  Install every APK in a folder"
    echo "31)  Screenshot now and open it"
    echo "32)  Photo browser (latest photos, open on laptop)"
    echo "33)  Calls and SMS"
    echo "34)  Clipboard and typing"
    echo "35)  Live phone notifications as laptop popups"
    echo "36)  Show current phone notifications"
    echo " 0)  Back"
    read -rp "Choose: " c
    case "$c" in
      1) list_devices_named
         [ "$(list_connected_ids | wc -l)" -eq 0 ] && echo "(none connected)"
         pause ;;
      2) $A shell ;;
      3) read -rp "Path to APK: " f; $A install -r "$f"; pause ;;
      4) p=$(pick_package user)
         if [ -n "$p" ]; then
           read -rp "Uninstall $p? (y/n): " y
           [ "$y" = "y" ] && $A uninstall "$p"
         fi
         pause ;;
      5) $A shell pm list packages -3 | sed 's/package://'; pause ;;
      6) read -rp "Local file: " s; read -rp "Phone destination (e.g. /sdcard/Download/): " d; $A push "$s" "$d"; pause ;;
      7) read -rp "Phone file path: " s; read -rp "Local destination (e.g. .): " d; $A pull "$s" "$d"; pause ;;
      8) f=$(take_shot) && ok "Saved $f"; pause ;;
      9) f="/sdcard/record_$(date +%Y%m%d_%H%M%S).mp4"
         $A shell -t screenrecord "$f"
         sleep 1
         mkdir -p "$BACKUP_DIR/recordings"
         $A pull "$f" "$BACKUP_DIR/recordings/" && ok "Saved in $BACKUP_DIR/recordings"; pause ;;
      10) $A shell dumpsys battery; pause ;;
      11) $A shell getprop ro.product.model
          $A shell getprop ro.build.version.release; pause ;;
      12) $A shell ip route get 1.1.1.1; pause ;;
      13) log_menu ;;
      14) read -rp "Reboot the phone? (y/n): " y
          [ "$y" = "y" ] && $A reboot; pause ;;
      15) adb kill-server; adb start-server; adb connect "$DEV"; pause ;;
      16) adb disconnect "$DEV"; pause ;;
      17) read -rp "adb command (without the word adb): " cmd; $A $cmd; pause ;;
      18) backup_calllog; pause ;;
      19) backup_sms; pause ;;
      20) backup_pictures; pause ;;
      21) backup_contacts; pause ;;
      22) backup_files; pause ;;
      23) backup_whatsapp; pause ;;
      24) full_backup; pause ;;
      25) zip_backup; pause ;;
      26) mkdir -p "$BACKUP_DIR"
          read -rp "Package name, or 'all': " p
          f="$BACKUP_DIR/android_backup_$(date +%Y%m%d_%H%M%S).ab"
          warn "Unlock the phone and confirm the backup prompt. Many apps and newer Android versions block this."
          if [ "$p" = "all" ]; then $A backup -apk -shared -all -f "$f"; else $A backup -apk "$p" -f "$f"; fi
          pause ;;
      27) extract_apk; pause ;;
      28) controls_menu ;;
      29) phone_info; pause ;;
      30) install_apks; pause ;;
      31) shot_open; pause ;;
      32) photo_browser; pause ;;
      33) calls_menu ;;
      34) clip_menu ;;
      35) notif_watch; pause ;;
      36) notif_show; pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

scrcpy_menu() {
  local c ver y
  while true; do
    clear
    box_title "SCRCPY"
    echo "1)  Mirror and control phone"
    echo "2)  Mirror with screen off on the phone"
    echo "3)  Mirror, lower quality (faster)"
    echo "4)  Record the screen to a file"
    echo "5)  View only (no control)"
    echo "6)  Fullscreen"
    echo "7)  Weak network mode (low res, low bitrate, 15 fps)"
    echo "8)  Mirror with sound on both devices"
    echo "9)  Install or update to the latest scrcpy"
    section "Live camera (Android 12+, scrcpy 2.2+)"
    echo "10) Back camera + microphone audio"
    echo "11) Front camera + microphone audio"
    echo "12) Both cameras at once (two windows)"
    echo "13) List the phone's cameras"
    section "More"
    echo "14) Presets (save and run your favorite settings)"
    echo "15) Gaming mode (low latency, keyboard, mouse, gamepad)"
    echo "0)  Back"
    read -rp "Choose: " c
    case "$c" in
      1) scrcpy -s "$DEV" ;;
      2) scrcpy -s "$DEV" --turn-screen-off --stay-awake ;;
      3) scrcpy -s "$DEV" -m 800 -b 2M ;;
      4) mkdir -p "$BACKUP_DIR/recordings"
         scrcpy -s "$DEV" --record "$BACKUP_DIR/recordings/scrcpy_$(date +%Y%m%d_%H%M%S).mp4" ;;
      5) scrcpy -s "$DEV" --no-control ;;
      6) scrcpy -s "$DEV" --fullscreen ;;
      7) scrcpy -s "$DEV" -m 640 -b 500K --max-fps 15 ;;
      8) need_scrcpy 2.7 "Sound on both devices"
         echo "Needs Android 13+ on the phone."
         scrcpy -s "$DEV" --audio-dup
         pause ;;
      9) install_latest_scrcpy; pause ;;
      10) cam_run back; pause ;;
      11) cam_run front; pause ;;
      12) need_scrcpy 2.2 "Camera mirroring"
          echo "Both cameras at once isn't supported on every phone. Close a window to stop it."
          echo "Audio comes from the phone's microphone (one stream, on the back camera window)."
          scrcpy -s "$DEV" --video-source=camera --camera-facing=back --audio-source=mic --window-title="Back camera" &
          sleep 3
          scrcpy -s "$DEV" --video-source=camera --camera-facing=front --no-audio --window-title="Front camera"
          wait
          pause ;;
      13) need_scrcpy 2.2 "Listing cameras"
          scrcpy -s "$DEV" --list-cameras
          pause ;;
      14) presets_menu ;;
      15) game_menu ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

conn_menu() {
  local c s ip guess pp code cp y picked
  while true; do
    clear
    box_title "CONNECTION AND AUTOMATION"
    echo "Current target: $(device_name "$DEV") ($DEV)   Auto-reconnect: $(watcher_state)"
    section "Connect"
    echo " 1) Reconnect to saved IP"
    echo " 2) Connect over Tailscale (works from any network)"
    echo " 3) Wireless pairing (Android 11+, no USB)"
    echo " 4) Re-enable port 5555 over USB and reconnect"
    echo " 5) Forget saved IP"
    echo "12) Switch device (when more than one is connected)"
    echo "13) Name the current device"
    section "Automation"
    echo " 6) Auto-reconnect watcher: turn on/off"
    echo " 7) Network tools (speed test, signal, devices, ping)"
    echo " 8) Schedule a nightly backup"
    echo " 9) Remove the nightly backup"
    echo "10) Install the 'phone' shortcut command"
    echo "11) Update adb, scrcpy, Tailscale and this script"
    echo " 0) Back"
    read -rp "Choose: " c
    case "$c" in
      1) if [ -f "$SAVED_IP_FILE" ]; then
           s=$(cat "$SAVED_IP_FILE")
           timeout 10 adb connect "$s"
           if is_connected "$s"; then set_target "$s"; else err "Could not reach $s"; fi
         else
           echo "No saved IP yet."
         fi
         pause ;;
      2) ts status
         guess=$(ts status | awk '/android/ {print $1; exit}')
         read -rp "Phone Tailscale IP [$guess]: " ip
         ip=${ip:-$guess}
         if [ -z "$ip" ]; then
           echo "No IP given. The phone needs the Tailscale app, logged in to the same account."
         else
           echo "Port 5555 must already be open on the phone (use option 4 once over USB)."
           timeout 15 adb connect "$ip:5555"
           if is_connected "$ip:5555"; then set_target "$ip:5555"; else err "Could not connect to $ip:5555"; fi
         fi
         pause ;;
      3) read -rp "Pairing IP:PORT (from 'Pair device with pairing code'): " pp
         read -rp "Pairing code: " code
         adb pair "$pp" "$code"
         read -rp "Connect IP:PORT (shown on the Wireless debugging screen): " cp
         timeout 15 adb connect "$cp"
         if is_connected "$cp"; then set_target "$cp"; else err "Could not connect to $cp"; fi
         pause ;;
      4) echo "Plug the phone in via USB..."
         adb -d wait-for-device
         ip=$(adb -d shell ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | tr -d '\r')
         if [ -z "$ip" ]; then
           err "Could not detect the phone IP. Is it on Wi-Fi?"
         else
           adb -d tcpip 5555
           sleep 3
           adb connect "$ip:5555"
           if is_connected "$ip:5555"; then set_target "$ip:5555"; else err "Connection failed."; fi
         fi
         pause ;;
      5) rm -f "$SAVED_IP_FILE"; ok "Saved IP removed."; pause ;;
      6) if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then
           stop_watcher; ok "Auto-reconnect turned off."
         else
           start_watcher; ok "Auto-reconnect turned on (checks every 10 seconds)."
         fi
         pause ;;
      7) net_menu ;;
      8) schedule_backup; pause ;;
      9) unschedule_backup; pause ;;
      10) install_shortcut; pause ;;
      11) update_all; pause ;;
      12) picked=$(pick_connected_device)
          if [ -n "$picked" ]; then set_target "$picked"; else err "Nothing to switch to."; fi
          pause ;;
      13) name_device "$DEV"; pause ;;
      0) return ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

main_menu() {
  local m
  while true; do
    clear
    banner
    status_line
    [ -f "$CHECK_FILE.msg" ] && warn "$(cat "$CHECK_FILE.msg")"
    echo
    echo "${GRN}1)${RST} ADB"
    echo "${GRN}2)${RST} scrcpy"
    echo "${GRN}3)${RST} Connection and automation"
    echo "${GRN}0)${RST} Exit"
    read -rp "Choose: " m
    case "$m" in
      1) adb_menu ;;
      2) scrcpy_menu ;;
      3) conn_menu ;;
      0) session_summary; echo "Bye."; exit 0 ;;
      *) echo "Invalid choice"; sleep 1 ;;
    esac
  done
}

# ---------------- Command line shortcuts ----------------
dispatch() {
  case "$CMD" in
    menu) return ;;
    mirror) scrcpy -s "$DEV" ;;
    cam|back) cam_run back ;;
    front) cam_run front ;;
    shot) shot_open; wait ;;
    backup) full_backup ;;
    cron-backup)
      echo "=== $(date '+%F %T') nightly backup from $DEV ==="
      backup_calllog; backup_sms; backup_contacts
      backup_pictures; backup_files; backup_whatsapp
      echo "=== done ===" ;;
    notif) notif_watch ;;
    status) status_line; ts status | head -n 8 ;;
    update) update_all ;;
    install) install_shortcut ;;
    preset) run_preset "${ARGS[0]}" ;;
    *) err "Unknown command: $CMD"; usage; exit 1 ;;
  esac
  exit 0
}

# ---------------- Main ----------------
if [ "$NONINT" = 0 ]; then
  setup_tools
  setup_tailscale
fi
connect_phone

set +e
A="adb -s $DEV"
trap 'stop_watcher' EXIT
trap ':' INT
seed_presets

if [ "$NONINT" = 0 ]; then
  # keep the shortcut in sync with the newest script you ran
  if [ -f "$SHORTCUT" ] && [ "$SELF" != "$SHORTCUT" ] && ! cmp -s "$SELF" "$SHORTCUT"; then
    cp "$SELF" "$SHORTCUT"
  fi
  case "$DEV" in *:*) start_watcher ;; esac
  [ "$CMD" = "menu" ] && check_updates
fi

dispatch
main_menu
