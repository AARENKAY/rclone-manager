#!/usr/bin/env bash
# =============================================================================
#  Rclone Commander  -  rclone.sh   (simple / numbered-menu edition)
#  Interactive file manager + transfer manager for rclone, built for Termux.
#
#  Requirements : bash >= 4.4, rclone, jq, coreutils, findutils
#  Optional     : ncurses-utils, less, termux-api (clipboard), ffprobe/mediainfo
#  Safety       : no eval, no root, arrays for every command, NUL-safe listings
# =============================================================================

APP_NAME="Rclone Commander"
APP_VERSION="1.1.0"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
  echo "Bash >= 4.4 is required (found $BASH_VERSION)." >&2
  exit 1
fi

umask 077
set -u
set -o pipefail
shopt -s nullglob

###############################################################################
# 1. CONFIGURABLE SETTINGS (defaults; persisted in settings.conf)
###############################################################################
APP_DIR="${RCLONE_MANAGER_HOME:-$HOME/.rclone-manager}"
SETTINGS_FILE="$APP_DIR/settings.conf"
JOBS_DIR="$APP_DIR/jobs"          # active job state (queued/running/paused)
HIST_DIR="$APP_DIR/history"       # finished jobs (done/failed/cancelled/interrupted)
LOG_DIR="$APP_DIR/logs"
EXPORT_DIR="$APP_DIR/exports"
APP_LOG="$LOG_DIR/app.log"
HISTORY_TSV="$APP_DIR/history.tsv"
TMP_DIR=""

TRANSFERS=4            # rclone --transfers
CHECKERS=8             # rclone --checkers
BWLIMIT=""             # rclone --bwlimit (empty = unlimited)
RETRIES=3              # rclone --retries
EXISTING=skip          # skip | overwrite | newer   (skip is the safe default)
CHECKSUM=0             # 1 = --checksum
SHOW_HIDDEN=0
SORT_KEY=name          # name | size | time
SORT_REV=0
QUEUE_MODE=sequential  # sequential | concurrent
LOG_MAX_BYTES=1048576
EMPTY_DIRS=0           # 1 = --create-empty-src-dirs
DRYRUN_FIRST=1         # offer a dry run before move / sync
AUTO_RETRIES=3         # extra whole-job attempts when rclone reports a corrupted/size-mismatched transfer
MON_REFRESH=1          # job monitor redraw interval in seconds (rclone writes stats once per STATS_EVERY)
STATS_EVERY=1s         # rclone --stats interval
NOTIFY=1               # 1 = Android notifications via termux-api (job finished / failed / interrupted / queue done)
NOTIFY_LIVE=1          # 1 = also alert once when a RUNNING job first reports errors
SETTING_KEYS=(TRANSFERS CHECKERS BWLIMIT RETRIES EXISTING CHECKSUM SHOW_HIDDEN
              SORT_KEY SORT_REV QUEUE_MODE LOG_MAX_BYTES EMPTY_DIRS DRYRUN_FIRST AUTO_RETRIES NOTIFY NOTIFY_LIVE)

# Runtime state
ROWS=24; COLS=80
KEY=""; ANS=""; CHOICE=0; MENU_START=0
REMOTES=(); P_REMOTE=("" ""); P_PATH=("" ""); ACT=0
E_TYPE=(); E_SIZE=(); E_TIME=(); E_NAME=(); CUR=0; TOP=0
declare -A SELIDX=()
LIST_ERR=""; LIST_FAILED=0; LAST_ERR=""; JOB_ID=""; WAKE_HELD=0
declare -A FLAG_CACHE=()
LIST_FLAGS=(--contimeout 20s --timeout 60s --retries 1)
C_RST=""; C_B=""; C_DIM=""; C_REV=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_MAG=""; C_CYN=""
C_BG_BLU=""; C_BG_GRN=""; C_BG_RED=""; C_BG_YEL=""; C_BG_CYN=""; C_BG_MAG=""

###############################################################################
# 2. SETTINGS
###############################################################################
setting_valid() { # key value -> 0 if valid
  local k=$1 v=$2
  case $k in
    TRANSFERS|CHECKERS|RETRIES) [[ $v =~ ^[0-9]+$ ]] && (( 10#$v >= 1 && 10#$v <= 64 )) ;;
    LOG_MAX_BYTES) [[ $v =~ ^[0-9]+$ ]] && (( 10#$v >= 65536 )) ;;
    AUTO_RETRIES) [[ $v =~ ^[0-9]+$ ]] && (( 10#$v <= 10 )) ;;
    BWLIMIT) [[ -z $v || $v =~ ^[0-9]+(\.[0-9]+)?[bBkKMGP]?$ ]] ;;
    EXISTING) [[ $v == skip || $v == overwrite || $v == newer ]] ;;
    CHECKSUM|SHOW_HIDDEN|SORT_REV|EMPTY_DIRS|DRYRUN_FIRST|NOTIFY|NOTIFY_LIVE) [[ $v == 0 || $v == 1 ]] ;;
    SORT_KEY) [[ $v == name || $v == size || $v == time ]] ;;
    QUEUE_MODE) [[ $v == sequential || $v == concurrent ]] ;;
    *) return 1 ;;
  esac
}

load_settings() { # parse key=value lines; only whitelisted + validated keys are applied
  [[ -f $SETTINGS_FILE ]] || return 0
  local line k v key ok
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line == *=* ]] || continue
    k=${line%%=*}; v=${line#*=}
    ok=0; for key in "${SETTING_KEYS[@]}"; do [[ $key == "$k" ]] && ok=1; done
    (( ok )) || continue
    setting_valid "$k" "$v" && printf -v "$k" '%s' "$v"
  done <"$SETTINGS_FILE"
  return 0
}

save_settings() {
  local t="$SETTINGS_FILE.tmp.$$" k
  if { for k in "${SETTING_KEYS[@]}"; do printf '%s=%s\n' "$k" "${!k}"; done; } 2>/dev/null >"$t" &&
     mv -f "$t" "$SETTINGS_FILE"; then
    chmod 600 "$SETTINGS_FILE" 2>/dev/null
    return 0
  fi
  rm -f -- "$t"; log_msg ERROR "could not save settings to $SETTINGS_FILE"; return 1
}

###############################################################################
# 3. LOGGING, TEMP FILES, CLEANUP
###############################################################################
rotate_logs() {
  local sz
  sz=$(stat -c %s "$APP_LOG" 2>/dev/null || echo 0)
  if (( sz > LOG_MAX_BYTES )); then mv -f "$APP_LOG" "$APP_LOG.1"; fi
  if [[ -f $HISTORY_TSV ]] && (( $(wc -l <"$HISTORY_TSV") > 1000 )); then
    tail -n 800 "$HISTORY_TSV" >"$HISTORY_TSV.tmp" && mv -f "$HISTORY_TSV.tmp" "$HISTORY_TSV"
  fi
}

log_msg() { # level message...   (never pass secrets here)
  local lvl=$1; shift
  rotate_logs
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$lvl" "$*" >>"$APP_LOG" 2>/dev/null
}

init_dirs() {
  mkdir -p -- "$APP_DIR" "$JOBS_DIR" "$HIST_DIR" "$LOG_DIR" "$EXPORT_DIR" 2>/dev/null || {
    echo "Cannot create application directory: $APP_DIR" >&2; exit 1; }
  chmod 700 "$APP_DIR" "$JOBS_DIR" "$HIST_DIR" "$LOG_DIR" "$EXPORT_DIR" 2>/dev/null
  TMP_DIR=$(mktemp -d 2>/dev/null) || TMP_DIR=$(mktemp -d "$APP_DIR/tmp.XXXXXX") || {
    echo "Cannot create a temporary directory." >&2; exit 1; }
}

cleanup() {
  if (( WAKE_HELD )) && (( $(count_running) == 0 )) && command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock 2>/dev/null
  fi
  [[ -n $TMP_DIR && -d $TMP_DIR ]] && rm -rf -- "$TMP_DIR"
}

###############################################################################
# 4. GENERIC HELPERS
###############################################################################
sanitize() { LC_ALL=C tr -d '\000-\010\013-\037\177'; }   # strip control chars / escapes

hsize() { # bytes -> human readable
  local b=${1:-} i=0 frac=0 u=(B K M G T)
  [[ $b =~ ^[0-9]+$ ]] || { printf '?'; return; }
  while (( b >= 1024 && i < 4 )); do frac=$(( (b % 1024) * 10 / 1024 )); b=$(( b / 1024 )); i=$((i+1)); done
  if (( i == 0 )); then printf '%dB' "$b"; else printf '%d.%d%s' "$b" "$frac" "${u[i]}"; fi
}

fmt_dur() { local s=${1:-0}; s=${s%.*}; [[ $s =~ ^[0-9]+$ ]] || s=0
  printf '%02d:%02d:%02d' $((s/3600)) $((s%3600/60)) $((s%60)); }

pad() { local s=$1 w=$2; s=${s:0:w}; printf '%s%*s' "$s" $((w - ${#s})) ''; }

# midfit text width : shorten in the MIDDLE so the file extension stays visible (a.very.long…name.gif)
midfit() {
  local s=$1 w=$2 t
  if (( ${#s} <= w )); then printf '%s' "$s"; return; fi
  t=$(( w/2 > 12 ? 12 : w/2 ))
  printf '%s…%s' "${s:0:w-1-t}" "${s: -t}"
}

tail_trunc() { local s=$1 w=$2
  if (( ${#s} > w && w > 2 )); then printf '…%s' "${s: -$((w-1))}"; else printf '%s' "${s:0:w}"; fi; }

yn() { if [[ ${1:-0} == 1 ]]; then printf 'yes'; else printf 'no'; fi; }

join_path() { # base name
  if [[ -z $1 ]]; then printf '%s' "$2"
  elif [[ $1 == */ ]]; then printf '%s%s' "$1" "$2"
  else printf '%s/%s' "$1" "$2"; fi
}

fq() { # remote path -> rclone spec ("" remote = local path)
  if [[ -z $1 ]]; then printf '%s' "$2"; else printf '%s:%s' "$1" "$2"; fi
}

parent_of() { # remote path
  local r=$1 p=$2
  if [[ -z $r ]]; then
    [[ $p == / ]] && { printf '/'; return; }
    p=${p%/}; p=${p%/*}; [[ -z $p ]] && p=/
    printf '%s' "$p"
  else
    [[ $p == / ]] && { printf '/'; return; }
    p=${p%/}
    if [[ $p == */* ]]; then p=${p%/*}; [[ -z $p ]] && p=/; printf '%s' "$p"; else printf ''; fi
  fi
}

# path_inside r1 p1 r2 p2 : 0 if p1 is p2 or lies below p2 on the same remote (copying
# a folder into itself would recurse forever, so such transfers are refused)
path_inside() {
  [[ $1 == "$3" ]] || return 1
  local a=${2%/} b=${4%/}
  [[ -z $b || $a == "$b" || $a == "$b"/* ]]
}

loc_fmt() { # remote path -> display string
  local r=$1 p=$2
  if [[ -z $r ]]; then printf 'local:%s' "$p"
  elif [[ $p == /* ]]; then printf '%s:%s' "$r" "$p"
  else printf '%s:/%s' "$r" "$p"; fi
}

loc_str() { loc_fmt "${P_REMOTE[$1]}" "${P_PATH[$1]}"; }   # panel index

has_flag() { # has_flag <subcommand|-> <--flag>   (cached; avoids unsupported flags)
  local sub=$1 flag=$2 key="$1|$2"
  if [[ -z ${FLAG_CACHE[$key]:-} ]]; then
    local out
    if [[ $sub == - ]]; then out=$(rclone help flags 2>/dev/null); else out=$(rclone "$sub" --help 2>/dev/null); fi
    if [[ $out == *"$flag"* ]]; then FLAG_CACHE[$key]=1; else FLAG_CACHE[$key]=0; fi
  fi
  [[ ${FLAG_CACHE[$key]} == 1 ]]
}

rc_quiet() { # run rclone capturing stderr into LAST_ERR; stdout -> $TMP_DIR/out
  local rc
  trap ':' INT
  rclone "$@" >"$TMP_DIR/out" 2>"$TMP_DIR/err"
  rc=$?
  trap 'exit 130' INT
  LAST_ERR=$(sanitize <"$TMP_DIR/err" | tail -n 6)
  return $rc
}

run_fg() { # run a foreground command; Ctrl-C stops the child, not the manager
  local rc
  trap ':' INT
  "$@"
  rc=$?
  trap 'exit 130' INT
  return $rc
}

rev_lines() { # reverse stdin line order without requiring tac
  if command -v tac >/dev/null 2>&1; then tac; else awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}'; fi
}

path_exists() { rc_quiet lsjson --stat "$1" ; }

###############################################################################
# 5. TERMINAL UI PRIMITIVES
###############################################################################
init_ui() {   # colours only; this edition never uses the alternate screen
  if [[ -t 1 && ${TERM:-dumb} != dumb && -z ${NO_COLOR:-} ]]; then
    C_RST=$'\e[0m'; C_B=$'\e[1m'; C_DIM=$'\e[2m'; C_REV=$'\e[7m'
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_MAG=$'\e[35m'; C_CYN=$'\e[36m'
    C_BG_BLU=$'\e[1;97;44m'; C_BG_GRN=$'\e[1;30;42m'; C_BG_RED=$'\e[1;97;41m'
    C_BG_YEL=$'\e[1;30;43m'; C_BG_CYN=$'\e[1;30;46m'; C_BG_MAG=$'\e[1;97;45m'
  fi
}

term_size() {
  local s
  if { s=$(stty size 2>/dev/null) || s=$(stty size </dev/tty 2>/dev/null); } && [[ $s =~ ^([0-9]+)\ ([0-9]+)$ ]]; then
    ROWS=${BASH_REMATCH[1]}; COLS=${BASH_REMATCH[2]}
  else ROWS=${LINES:-24}; COLS=${COLUMNS:-80}; fi
  (( ROWS < 12 )) && ROWS=12
  (( COLS < 30 )) && COLS=30
  return 0
}

# Simple (numbered-menu) mode: wipe the visible screen AND scrollback so each menu replaces the previous one
# instead of piling up. Messages raised since the last menu are kept in SIMPLE_NOTE and re-shown under the title.
SIMPLE_NOTE=""
sclear() { if [[ -t 1 ]]; then printf '\e[H\e[2J\e[3J'; fi; return 0; }

# ---- simple-mode drawing helpers (boxes, badges, banner) ----
S_W=60
sbox_init() { term_size; S_W=$((COLS-2)); (( S_W > 90 )) && S_W=90; (( S_W < 28 )) && S_W=28; return 0; }
srule() { local s; printf -v s '%*s' "$1" ''; printf '%s' "${s// /${2:-─}}"; }   # srule width [char]

sbanner() {
  sbox_init
  local inner=$((S_W-2))
  printf '%s╭%s╮%s\n' "$C_MAG" "$(srule "$inner")" "$C_RST"
  printf '%s│%s%s%s%s│%s\n' "$C_MAG" "$C_B$C_CYN" "$(pad " ◆ $APP_NAME  ·  v$APP_VERSION" "$inner")" "$C_RST" "$C_MAG" "$C_RST"
  printf '%s╰%s╯%s\n' "$C_MAG" "$(srule "$inner")" "$C_RST"
}

stitle() { local l; while IFS= read -r l; do printf '%s%s%s\n' "$C_BG_BLU" "$(pad "  $l" "$S_W")" "$C_RST"; done < <(printf '%s\n' "$1" | sanitize | fold -s -w $((S_W-2))); }

sbadge_color() { # item text -> bold foreground colour for its number
  case $1 in
    Back*|Exit*|Quit*|Cancel*) printf '%s' "$C_B$C_RED" ;;
    Delete*|Clear*|Reset*|Remove*) printf '%s' "$C_B$C_YEL" ;;
    *) printf '%s' "$C_B$C_GRN" ;;
  esac
}

shint() { # text : dim, wrapped key-hint line(s) printed just above a prompt
  local l
  while IFS= read -r l; do printf '%s  %s%s\n' "$C_DIM" "$l" "$C_RST"; done < <(printf '%s\n' "$1" | fold -s -w $((S_W-2)))
}
H_LIST="Keys: N=open folder (instant) · N⏎=open file · ←/→ page · .⏎=show/hide hidden files · q=back · ⏎=Enter"
H_LIST2="c/m/d use the ✔ selected items or typed numbers: m 1 11 21⏎ · c 5-9⏎ · c all⏎ · c files⏎ · all keys: ?"
H_JOBS="Keys: N=open job N · s 1⏎ start job 1 · c 2⏎ cancel job 2 · t 3⏎ retry job 3 · S=start all · q=back"
H_RESULTS="Keys: s 3⏎ or s 1 4 7-9⏎ select (⏎=Enter) · c/m/d/r/x act on ✔ selected · ←/→=page · q=back"
H_DEST="Keys: N=open folder · ←/→=page · s=USE THIS FOLDER · n=new folder · ..=go up · .⏎=show/hide hidden folders · q=back to menu · ⌫ erase"
H_MONITOR="Keys (instant, no Enter): c cancel job · p pause · r resume · l view log · q back"

snotes() { # print and clear pending notes in coloured boxes
  [[ -n $SIMPLE_NOTE ]] || return 0
  local inner=$((S_W-2)) note col line first
  while IFS= read -r note; do
    [[ -n $note ]] || continue
    case ${note,,} in *invalid*|*fail*|*error*|*cannot*|*"not "*|*missing*|*bad*) col=$C_RED ;; *) col=$C_GRN ;; esac
    printf '%s╭%s╮%s\n' "$col" "$(srule "$inner")" "$C_RST"
    first=1
    while IFS= read -r line; do
      printf '%s│%s %s%s%s %s│%s\n' "$col" "$C_RST" "$col$C_B" "$(pad "$( ((first)) && printf '● ' || printf '  ')$line" $((inner-2)))" "$C_RST" "$col" "$C_RST"
      first=0
    done < <(printf '%s\n' "$note" | sanitize | fold -s -w $((inner-6)))
    printf '%s╰%s╯%s\n' "$col" "$(srule "$inner")" "$C_RST"
  done <<<"$SIMPLE_NOTE"
  SIMPLE_NOTE=""
}

sfit() { local t=$1 w=$2; (( ${#t} > w )) && t="${t:0:w-1}…"; printf '%s' "$t"; }   # truncate with an ellipsis
sbox_top() { printf '%s╭%s╮%s\n' "$1" "$(srule $((S_W-2)))" "$C_RST"; }
sbox_bot() { printf '%s╰%s╯%s\n' "$1" "$(srule $((S_W-2)))" "$C_RST"; }
sline() { # border_colour coloured_text visible_length
  printf '%s│%s %s%*s %s│%s\n' "$1" "$C_RST" "$2" $((S_W-4-$3)) '' "$1" "$C_RST"
}

# sfm_box start end : boxed entry list of the current panel (E_* arrays), used by the simple file manager and picker
sfm_box() {
  local start=$1 end=$2 n=${#E_NAME[@]} i name mark ic nc sz nw=$((S_W-2-19))
  sbox_top "$C_CYN"
  if (( LIST_FAILED )); then
    name=$(sfit "✖ Listing failed: $(printf '%s' "$LIST_ERR" | sanitize | tr '\n' ' ')" $((S_W-4)))
    sline "$C_CYN" "${C_RED}${name}${C_RST}" "${#name}"
  elif (( n == 0 )); then sline "$C_CYN" "${C_DIM}(empty folder)${C_RST}" 14; fi
  for ((i=start; i<end; i++)); do
    name=$(printf '%s' "${E_NAME[i]}" | sanitize)
    if [[ ${E_TYPE[i]} == d ]]; then ic="▸"; nc="$C_B$C_BLU"; name+="/"; sz="DIR"
    else ic="·"; nc=""; sz=$(hsize "${E_SIZE[i]}"); fi
    name=$(midfit "$name" "$nw")
    if [[ -n ${SELIDX[$i]:-} ]]; then mark="${C_B}${C_YEL}✔${C_RST}"; else mark=" "; fi
    printf '%s│%s %s%3d%s %s %s%s%s %s%8s%s %s│%s\n' "$C_CYN" "$C_RST" "$C_B$C_GRN" $((i+1)) "$C_RST" "$mark" \
      "$nc" "$ic $(pad "$name" "$nw")" "$C_RST" "$C_DIM" "$sz" "$C_RST" "$C_CYN" "$C_RST"
  done
  sbox_bot "$C_CYN"
}

read_key() { # [timeout_seconds]  ->  KEY
  local t=${1:-} k rest rc _
  KEY=""
  if [[ -n $t ]]; then
    IFS= read -rsn1 -t "$t" k; rc=$?
    if (( rc > 128 )); then KEY=TIMEOUT; return 0; fi
    if (( rc != 0 )); then exit 0; fi
  else
    IFS= read -rsn1 k || exit 0
  fi
  case $k in
    $'\e')
      if IFS= read -rsn2 -t 0.05 rest; then
        case $rest in
          '[A'|'OA') KEY=UP ;;   '[B'|'OB') KEY=DOWN ;;
          '[C'|'OC') KEY=RIGHT ;; '[D'|'OD') KEY=LEFT ;;
          '[H'|'OH') KEY=HOME ;;  '[F'|'OF') KEY=END ;;
          '[5') IFS= read -rsn1 -t 0.05 _; KEY=PGUP ;;
          '[6') IFS= read -rsn1 -t 0.05 _; KEY=PGDN ;;
          '[1'|'[7') IFS= read -rsn1 -t 0.05 _; KEY=HOME ;;
          '[4'|'[8') IFS= read -rsn1 -t 0.05 _; KEY=END ;;
          *) KEY=OTHER ;;
        esac
      else KEY=ESC; fi ;;
    '') KEY=ENTER ;;
    $'\x7f'|$'\b') KEY=BACKSPACE ;;
    $'\t') KEY=TAB ;;
    ' ') KEY=SPACE ;;
    *) KEY=$k ;;
  esac
  return 0
}

notify() { # message [kind: info|ok|err]
  printf '%s\n' "$1"; SIMPLE_NOTE+="$(printf '%s' "$1" | tr '\n' ' ')"$'\n'
  return 0
}

busy() { # immediate progress note (long operations; not queued like notify)
  printf '%s ⏳ %s %s%s%s\n' "$C_BG_CYN" "$C_RST" "$C_CYN" "$1" "$C_RST"
}

ask() { # label [default] -> ANS ; returns read status
  local label=$1 def=${2:-} rc plabel
  plabel=$'\001'"${C_B}${C_CYN}"$'\002'" ❯ "$'\001'"$C_RST"$'\002'"$label"
  shint "Keys: type the answer, then ⏎ to accept · ←/→ ⌫ edit · Ctrl-U clear"
  IFS= read -e -r -p "$plabel" -i "$def" ANS; rc=$?
  return $rc
}

confirm() { # message [default Y|N]  -> 0 = yes
  local def=${2:-N} hint='[y/N]'
  [[ $def == Y ]] && hint='[Y/n]'
  if [[ $def == Y ]]; then shint "Keys: press y=yes or n=no (no Enter needed) · ⏎ alone = yes (default)"
  else shint "Keys: press y=yes or n=no (no Enter needed) · ⏎ alone = no (default)"; fi
  printf '%s ? %s ' "$C_BG_YEL" "$C_RST"
  printf '%s%s %s %s' "$C_YEL" "$1" "$hint" "$C_RST"
  read_key
  printf '\n'
  case $KEY in
    y|Y) return 0 ;;
    ENTER) [[ $def == Y ]] ;;
    *) return 1 ;;
  esac
}

confirm_typed() { # message word -> 0 only if the exact word is typed
  ask "$1 (type $2 to confirm): " || return 1
  [[ $ANS == "$2" ]]
}

pause_key() {
  printf '\n%s ⏎ %s %sPress any key to continue...%s' "$C_BG_CYN" "$C_RST" "$C_DIM" "$C_RST"
  read_key
  printf '\n'
}

page_file() { # show a text file as a page (sanitised copy)
  local f=$1 s="$TMP_DIR/page.txt"
  sanitize <"$f" >"$s"
  sclear; sbanner; fold -s -w "$S_W" "$s"; pause_key
}

show_text() { # print text args as a page
  printf '%s\n' "$@" >"$TMP_DIR/show.txt"
  page_file "$TMP_DIR/show.txt"
}

# ---- auth-error recovery -----------------------------------------------------
is_auth_error() { # text -> 0 if it looks like an expired/revoked OAuth token
  [[ $1 == *invalid_grant* || $1 == *"config reconnect"* || $1 == *"token expired"* \
     || $1 == *"couldn't fetch token"* || $1 == *"Token has been expired or revoked"* ]]
}

spec_remote() { # rclone spec -> prints the configured remote it points to (fails for local paths)
  [[ $1 == *:* ]] || return 1
  local r=${1%%:*} x; load_remotes
  for x in "${REMOTES[@]}"; do [[ $x == "$r" ]] && { printf '%s' "$r"; return 0; }; done
  return 1
}

hint_text() { # error text -> one-line suggestion for non-token failures (empty if unknown)
  local e=${1,,}
  case $e in
    *"no such host"*|*"network is unreachable"*|*"dial tcp"*|*"i/o timeout"*|*"connection refused"*|*"tls handshake timeout"*|*"connection reset"*|*"context deadline exceeded"*|*"temporary failure in name resolution"*)
      printf 'Network problem: check Wi-Fi/mobile data, VPN or DNS, then retry.' ;;
    *ratelimitexceeded*|*"too many requests"*|*"error 429"*|*"status code 429"*|*"rate limit"*)
      printf 'Provider rate limit: wait a few minutes, then retry; lower Transfers/Checkers or set a bandwidth limit in Settings.' ;;
    *storagequotaexceeded*|*"quota exceeded"*|*"insufficient storage"*|*"no space left"*|*"disk quota"*)
      printf 'Storage full or upload quota reached (Google Drive caps uploads at ~750 GB/day): free space or wait, then retry.' ;;
    *"didn't find section in config file"*|*"didn't find section"*)
      printf 'That remote is not in the rclone config: see Remote Manager > List remotes (it may have been renamed or deleted).' ;;
    *invalid_client*|*"unauthorized_client"*)
      printf 'The OAuth client ID/secret was rejected: edit the remote (Remote Manager > Edit) and re-enter or clear them.' ;;
    *insufficientpermissions*|*"access denied"*|*"error 403"*|*"status code 403"*|*"forbidden"*)
      printf 'Access refused by the provider: check you are signed in to the right account and that it may access this item; reconnecting can refresh scopes.' ;;
    *"directory not found"*|*"object not found"*|*"error 404"*|*"status code 404"*)
      printf 'Folder or file not found: check the path and spelling (names are case-sensitive).' ;;
  esac
}

offer_reconnect() { # remote-name error-text -> 0 if "rclone config reconnect" was run
  local r=$1 h
  if ! is_auth_error "$2"; then h=$(hint_text "$2"); [[ -n $h ]] && notify "Hint: $h" info; return 1; fi
  [[ -n $r ]] || return 1
  confirm "Token looks expired/revoked. Run: rclone config reconnect \"$r:\" now?" Y || return 1
  run_screen rclone config reconnect "$r:"
  return 0
}

auth_recover() { # rclone-spec error-text : for one-shot actions; user repeats the action afterwards
  local r; r=$(spec_remote "$1") || return 1
  offer_reconnect "$r" "$2" && { notify "Reconnect finished - repeat the action." ok; return 0; }
  return 1
}

read_cmd() { # prompt [list-size [is-folder-fn [paging]]] -> ANS_LINE   (small single-line editor with instant keys)
  # - a lone q/Q acts at once (no Enter)
  # - with a list size, a typed number acts at once when it cannot grow into a longer valid number;
  #   if it could still grow it waits 3 s for the next digit, then accepts what was typed
  # - with is-folder-fn, only numbers that name a FOLDER act without Enter; a file number needs Enter
  # - Backspace / Ctrl-U edit the line; with paging=1 an EMPTY line turns Right/Left arrows into "+" / "-" (next/prev page),
  #   other arrow and function keys are ignored
  local prompt=$1 n=${2:-0} dirfn=${3:-} paging=${4:-0} buf="" ch c2 rc num t ok seq
  printf '%s' "$prompt"
  while :; do
    t=""
    if (( n )) && [[ $buf =~ ^[1-9][0-9]*$ ]]; then
      num=$((10#$buf)); ok=1
      [[ -n $dirfn ]] && { "$dirfn" "$num" || ok=0; }
      if (( ok )); then
        if (( num * 10 > n )); then printf '\n'; ANS_LINE=$buf; return 0; fi
        t=3
      fi
    fi
    if [[ -n $t ]]; then IFS= read -rsn1 -t "$t" ch; rc=$?; else IFS= read -rsn1 ch; rc=$?; fi
    (( rc == 1 )) && exit 0                                   # EOF
    if (( rc > 128 )); then printf '\n'; ANS_LINE=$buf; return 0; fi   # 3 s without a 2nd digit
    case $ch in
      '') printf '\n'; ANS_LINE=$buf; return 0 ;;             # Enter
      $'\x7f'|$'\b') if [[ -n $buf ]]; then buf=${buf%?}; printf '\b \b'; fi ;;
      $'\x15') buf=""; printf '\r\033[K%s' "$prompt" ;;       # Ctrl-U clears the line
      $'\e') seq=""                                           # arrow / function key: read the whole escape sequence
         if IFS= read -rsn1 -t 0.05 c2; then seq=$c2; fi
         if [[ $seq == '[' ]]; then
           while IFS= read -rsn1 -t 0.05 c2; do seq+=$c2; [[ $c2 =~ [A-Za-z~] ]] && break; done
         elif [[ $seq == O ]]; then
           if IFS= read -rsn1 -t 0.05 c2; then seq+=$c2; fi
         fi
         if (( paging )) && [[ -z $buf ]]; then
           case ${seq: -1} in
             C) printf '\n'; ANS_LINE="+"; return 0 ;;        # Right arrow = next page
             D) printf '\n'; ANS_LINE="-"; return 0 ;;        # Left arrow  = previous page
           esac
         fi ;;
      q|Q) if [[ -z $buf ]]; then printf '%s\n' "$ch"; ANS_LINE=q; return 0; fi; buf+=$ch; printf '%s' "$ch" ;;
      *) buf+=$ch; printf '%s' "$ch" ;;
    esac
  done
}

parse_num_list() { # "1,11, 21 5-9" max -> PNUMS (unique, ascending, 1-based); 1 if any token is bad / out of range
  PNUMS=(); local t a b i text=${1//,/ }; local -A seen=()
  [[ -n ${text//[[:space:]]/} ]] || return 1
  for t in $text; do
    if [[ $t =~ ^([0-9]+)-([0-9]+)$ ]]; then a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    elif [[ $t =~ ^[0-9]+$ ]]; then a=$((10#$t)); b=$a
    else return 1; fi
    (( a >= 1 && b >= a && b <= $2 )) || return 1
    for ((i=a; i<=b; i++)); do seen[$i]=1; done
  done
  mapfile -t PNUMS < <(printf '%s\n' "${!seen[@]}" | sort -n)
  return 0
}

fm_num_is_dir() { # 1-based item number -> 0 if it is a folder in the current listing
  (( $1 >= 1 && $1 <= ${#E_NAME[@]} )) && [[ ${E_TYPE[$(( $1 - 1 ))]:-} == d ]]
}

run_screen() { # run an interactive external command (e.g. rclone config) on the normal screen, then pause
  sclear; SIMPLE_NOTE=""
  sbanner; stitle "Running: $1 ${2:-}"; echo
  run_fg "$@"; local rc=$?
  printf '\n%s ⏎ %s Press any key to return to the menu... ' "$C_BG_CYN" "$C_RST"
  IFS= read -rsn1 _ </dev/tty 2>/dev/null || IFS= read -rsn1 _
  return $rc
}

menu_choose() { # title items...  -> CHOICE (1-based, 0 = back)
  local title=$1; shift
  local -a items=("$@"); local n=${#items[@]} cur=$MENU_START i top=0 vis idx
  MENU_START=0; CHOICE=0
  (( cur >= n )) && cur=0
  local ans inner col
    while true; do
      sclear; sbanner; stitle "$title"
      inner=$((S_W-2))
      printf '%s╭%s╮%s\n' "$C_CYN" "$(srule "$inner")" "$C_RST"
      for ((i=0; i<n; i++)); do
        local first=1 ln
        while IFS= read -r ln; do   # long items wrap onto indented continuation lines
          if (( first )); then
            printf '%s│%s %s%s%s %s%s%s%s│%s\n' "$C_CYN" "$C_RST" "$(sbadge_color "${items[i]}")" "$(printf ' %2d›' $((i+1)))" "$C_RST" \
              "$C_B" "$(pad "$ln" $((inner-6)))" "$C_RST" "$C_CYN" "$C_RST"; first=0
          else
            printf '%s│%s      %s%s%s%s│%s\n' "$C_CYN" "$C_RST" "$C_DIM" "$(pad "$ln" $((inner-6)))" "$C_RST" "$C_CYN" "$C_RST"
          fi
        done < <(printf '%s\n' "${items[i]}" | sanitize | fold -s -w $((inner-6)))
      done
      printf '%s╰%s╯%s\n' "$C_CYN" "$(srule "$inner")" "$C_RST"
      snotes
      if (( n >= 10 )); then
        shint "Keys: 2-9=choose at once · 1=waits 3 s for a 2nd digit (or press ⏎ = item 1) · q=back · ⌫ erase"
      else
        shint "Keys: press 1-$n to choose (no Enter) · q=back (no Enter) · ⌫ erase"
      fi
      read_cmd "${C_B}${C_CYN} ❯ ${C_RST}Choice [1-$n]: " "$n"; ans=$ANS_LINE
      case $ans in q|Q|'') CHOICE=0; return 0 ;; esac
      if [[ $ans =~ ^[0-9]+$ ]] && (( 10#$ans >= 1 && 10#$ans <= n )); then CHOICE=$((10#$ans)); return 0; fi
      SIMPLE_NOTE="Invalid choice: $ans"$'\n'
    done
}

###############################################################################
# 6. DEPENDENCIES / ENVIRONMENT
###############################################################################
check_deps() {
  local -a missing=()
  local c
  for c in rclone jq find sort stat df mktemp tr grep head tail wc date cut; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  if (( ${#missing[@]} )); then
    echo "Missing required tools: ${missing[*]}"
    echo "Install on Termux with:"
    echo "  pkg install rclone jq coreutils findutils ncurses-utils less"
    if command -v pkg >/dev/null 2>&1; then
      read -r -p "Run 'pkg install -y rclone jq coreutils findutils ncurses-utils less' now? [y/N] " a
      if [[ $a == y || $a == Y ]]; then pkg install -y rclone jq coreutils findutils ncurses-utils less || exit 1; fi
    fi
    for c in rclone jq find sort stat df mktemp tr grep head tail wc date cut; do
      command -v "$c" >/dev/null 2>&1 || { echo "Still missing: $c"; exit 1; }
    done
  fi
}

load_remotes() {
  REMOTES=()
  local l
  while IFS= read -r l; do [[ -n $l ]] && REMOTES+=("${l%:}"); done < <(rclone listremotes 2>/dev/null)
  return 0
}

LOCAL_LABELS=(); LOCAL_PATHS=()
add_root() { if [[ -d $2 && -r $2 && -x $2 ]]; then LOCAL_LABELS+=("$1"); LOCAL_PATHS+=("$2"); fi; }
local_roots() {
  LOCAL_LABELS=(); LOCAL_PATHS=()
  local d
  add_root "Termux home" "$HOME"
  add_root "Shared storage (~/storage/shared)" "$HOME/storage/shared"
  for d in "$HOME"/storage/external-*; do add_root "SD card app dir (${d##*/})" "$d"; done
  for d in /storage/*; do
    case $d in /storage/emulated|/storage/self) continue ;; esac
    add_root "Volume ${d#/storage/}" "$d"
  done
  add_root "/sdcard" "/sdcard"
  return 0
}

default_start_dir() {
  if [[ -d $HOME/storage/shared && -r $HOME/storage/shared ]]; then printf '%s' "$HOME/storage/shared"
  else printf '%s' "$HOME"; fi
}

###############################################################################
# 7. LISTING (local via find, remote via rclone lsjson; NUL-delimited, no eval)
###############################################################################
sel_clear() { SELIDX=(); }
sel_kind() { # all|files|dirs : select every item of that kind in the current folder (all pages) -> SEL_N
  local i; SEL_N=0
  for ((i=0; i<${#E_NAME[@]}; i++)); do
    case $1 in files) [[ ${E_TYPE[i]} == f ]] || continue ;; dirs) [[ ${E_TYPE[i]} == d ]] || continue ;; esac
    SELIDX[$i]=1; SEL_N=$((SEL_N+1))
  done
}

# Loads P_REMOTE/P_PATH of panel ACT into E_* arrays. On failure the arrays are untouched.
load_listing() {
  local r=${P_REMOTE[ACT]} p=${P_PATH[ACT]} raw="$TMP_DIR/list.raw" srt="$TMP_DIR/list.srt" rc t s m n
  LIST_ERR=""
  if [[ -z $r ]]; then
    if [[ ! -d $p ]]; then LIST_ERR="Not a directory: $p"; return 1; fi
    if [[ ! -r $p || ! -x $p ]]; then
      LIST_ERR="Permission denied: $p (run termux-setup-storage / check Android permissions)"; return 1; fi
    find -L "$p" -mindepth 1 -maxdepth 1 -printf '%y\037%s\037%TY-%Tm-%Td %TH:%TM\037%f\0' >"$raw" 2>"$TMP_DIR/err"
    rc=$?
    if (( rc != 0 )) && [[ ! -s $raw ]]; then
      LIST_ERR="Listing failed: $(sanitize <"$TMP_DIR/err" | head -n 1)"; return 1; fi
  else
    rclone lsjson --no-mimetype "${LIST_FLAGS[@]}" "$(fq "$r" "$p")" >"$TMP_DIR/list.json" 2>"$TMP_DIR/err"
    rc=$?
    if (( rc != 0 )); then
      LIST_ERR="Listing failed (rclone exit $rc): $(sanitize <"$TMP_DIR/err" | tail -n 2 | tr '\n' ' ')"; return 1; fi
    if ! jq -j '.[] | [(if .IsDir then "d" else "f" end), (.Size|tostring),
                        ((.ModTime // "")[0:16] | sub("T";" ")), .Name] | join("\u001f"), "\u0000"' \
         <"$TMP_DIR/list.json" >"$raw" 2>"$TMP_DIR/err"; then
      LIST_ERR="Could not parse listing (invalid JSON from rclone)."; return 1; fi
  fi
  local -a keys=(-k1,1)
  local rev=""; (( SORT_REV )) && rev=r
  case $SORT_KEY in
    size) keys+=("-k2,2n$rev" -k4,4f) ;;
    time) keys+=("-k3,3$rev" -k4,4f) ;;
    *)    keys+=("-k4,4f$rev") ;;
  esac
  sort -z -t $'\037' "${keys[@]}" <"$raw" >"$srt" 2>/dev/null || cp -- "$raw" "$srt"
  E_TYPE=(); E_SIZE=(); E_TIME=(); E_NAME=()
  while IFS=$'\037' read -r -d '' t s m n; do
    [[ -z $n ]] && continue
    if (( ! SHOW_HIDDEN )) && [[ $n == .* ]]; then continue; fi
    [[ $t == d ]] || t=f
    E_TYPE+=("$t"); E_SIZE+=("$s"); E_TIME+=("$m"); E_NAME+=("$n")
  done <"$srt"
  return 0
}

fm_reload() {
  if load_listing; then LIST_FAILED=0
  else
    notify "$LIST_ERR" err
    if offer_reconnect "${P_REMOTE[ACT]}" "$LIST_ERR" && load_listing; then LIST_FAILED=0
    else LIST_FAILED=1; E_TYPE=(); E_SIZE=(); E_TIME=(); E_NAME=(); fi
  fi
  CUR=0; TOP=0; sel_clear
}

panel_goto() { # remote path : change ACT panel location; revert on failure
  local or=${P_REMOTE[ACT]} op=${P_PATH[ACT]}
  P_REMOTE[ACT]=$1; P_PATH[ACT]=$2
  if load_listing; then LIST_FAILED=0; CUR=0; TOP=0; sel_clear; return 0; fi
  notify "$LIST_ERR" err
  if offer_reconnect "$1" "$LIST_ERR" && load_listing; then LIST_FAILED=0; CUR=0; TOP=0; sel_clear; return 0; fi
  P_REMOTE[ACT]=$or; P_PATH[ACT]=$op
  return 1
}

parse_location_input() { # user input -> panel_goto
  local in=$1 r=${P_REMOTE[ACT]} name rest
  if [[ $in =~ ^([^:/]+):(.*)$ ]]; then
    name=${BASH_REMATCH[1]}; rest=${BASH_REMATCH[2]}
    local x found=0; for x in "${REMOTES[@]}"; do [[ $x == "$name" ]] && found=1; done
    if (( ! found )); then notify "Unknown remote: $name" err; return 1; fi
    panel_goto "$name" "$rest"; return   # keep a leading "/" (absolute path on sftp/ftp)
  fi
  if [[ -z $r ]]; then
    in=${in/#\~/$HOME}
    [[ $in == /* ]] || in="${P_PATH[ACT]%/}/$in"
    local abs; abs=$(cd -- "$in" 2>/dev/null && pwd) || { notify "No such directory: $in" err; return 1; }
    panel_goto "" "$abs"
  else
    panel_goto "$r" "$in"
  fi
}

get_targets() { # fills T_IDX with selected indexes, or the cursor item
  T_IDX=()
  if (( ${#SELIDX[@]} )); then
    mapfile -t T_IDX < <(printf '%s\n' "${!SELIDX[@]}" | sort -n)
  elif (( ${#E_NAME[@]} )); then
    T_IDX=("$CUR")
  fi
}

###############################################################################
# 8. JOB ENGINE (structured stats via rclone --use-json-log)
###############################################################################
meta_get() { # dir key
  local line
  while IFS= read -r line; do
    if [[ $line == "$2="* ]]; then printf '%s' "${line#*=}"; return 0; fi
  done 2>/dev/null <"$1/meta"   # redirect order matters: silence the open() error too
  return 1
}

meta_set() { # dir key value
  local d=$1 k=$2 v=${3//[$'\n\r\t']/ } t
  t="$d/meta.tmp.$BASHPID"
  { grep -v -- "^$k=" "$d/meta" 2>/dev/null; printf '%s=%s\n' "$k" "$v"; } >"$t"
  mv -f "$t" "$d/meta"
}

job_dir() { # id -> path (active or history)
  if [[ -d $JOBS_DIR/$1 ]]; then printf '%s' "$JOBS_DIR/$1"
  elif [[ -d $HIST_DIR/$1 ]]; then printf '%s' "$HIST_DIR/$1"
  else return 1; fi
}

pid_alive() { [[ -n ${1:-} && $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }

toint() { # float / exponent / junk -> integer (0 when not numeric)
  local v=${1:-0}
  [[ $v =~ ^-?[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]+)?$ ]] || { printf '0'; return; }
  printf '%.0f' "$v"
}

job_alloc() { # fresh job dir; sets JOB_ID/JOB_D. mkdir without -p so an existing id is never reused
  local n=0
  while :; do
    JOB_ID="$(date +%Y%m%d-%H%M%S)-$$-$RANDOM"; JOB_D="$JOBS_DIR/$JOB_ID"
    mkdir -- "$JOB_D" 2>/dev/null && return 0
    n=$((n+1)); (( n > 20 )) && return 1
  done
}

job_pid_ok() { # pid jobname : is this pid still OUR rclone? guards against PID reuse
  local pid=$1 id=${2##*/} cl
  pid_alive "$pid" || return 1
  if [[ -r /proc/$pid/cmdline ]]; then
    cl=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null)
    [[ $cl == *rclone* && $cl == *"$JOBS_DIR/$id/log.jsonl"* ]]
  else
    return 0   # /proc not readable here: cannot verify, fall back to the kill -0 result
  fi
}

job_create() { # label mode src dst rclone-args...   (use '@LIST@' for the files-from list)
  local label=$1 mode=$2 src=$3 dst=$4; shift 4
  job_alloc || return 1
  local d=$JOB_D
  printf '%s\0' "$@" >"$d/cmd" || { rm -rf -- "$d"; return 1; }
  : >"$d/meta"
  if [[ -n ${JOB_LIST_TMP:-} && -f $JOB_LIST_TMP ]]; then cp -- "$JOB_LIST_TMP" "$d/files.txt"; fi
  meta_set "$d" label "$label"; meta_set "$d" mode "$mode"
  meta_set "$d" src "$src"; meta_set "$d" dst "$dst"; meta_set "$d" created "$(date +%s)"
  meta_set "$d" status queued   # written last: a dir without status is a half-created job
  log_msg INFO "job $JOB_ID created: $mode $src -> $dst"
}

job_stats() { # logfile -> one TSV line with the newest valid stats event (empty if none yet)
  [[ -f $1 ]] || return 1
  # Malformed / partial / non-stats lines are ignored (fromjson? and the type check).
  tail -n 300 "$1" | jq -rR 'fromjson? | select((.stats? | type) == "object") | .stats |
    [(.bytes // 0), (.totalBytes // 0), (.speed // 0), (.eta // -1), (.transfers // 0),
     (.totalTransfers // 0), (.errors // 0), (.elapsedTime // 0), ((.transferring // [])[0].name // "")] | @tsv' 2>/dev/null | tail -n 1
}

job_last_errors() { # job dir -> the newest error messages rclone wrote (full text)
  [[ -f $1/log.jsonl ]] && tail -n 300 "$1/log.jsonl" | jq -rR 'fromjson? | select(.level == "error") | (.msg // empty)' 2>/dev/null | sanitize | tail -n 3
  [[ -s $1/stderr ]] && sanitize <"$1/stderr" | tail -n 3
  return 0
}

###############################################################################
# Android notifications (termux-api). Sent from the detached job worker, so they
# still arrive when the UI is closed. Every call is time-limited and never fatal.
###############################################################################
tnotify() { # id title content [priority: high|default|low]
  (( NOTIFY )) || return 0
  command -v termux-notification >/dev/null 2>&1 || return 0
  local content
  content=$(printf '%s' "$3" | sanitize | tr '\n' ' ' | cut -c1-300)
  timeout 10 termux-notification --id "$1" --group rclone-commander --title "$2" --content "$content" \
    --priority "${4:-high}" --vibrate 300,150,300 \
    --action "am start -n com.termux/.app.TermuxActivity" </dev/null >/dev/null 2>&1 \
    || log_msg WARN "termux-notification failed (Termux:API app installed? notification permission granted?)"
  return 0
}

tnotify_clear() { # id
  command -v termux-notification-remove >/dev/null 2>&1 && timeout 10 termux-notification-remove "$1" </dev/null >/dev/null 2>&1
  return 0
}

job_notify() { # id status dir : one notification for a finished job (cancelled = user's own action, no alert)
  local id=$1 st=$2 d=$3 label files bytes el err h body
  tnotify_clear "rclone-$id-err"
  label=$(meta_get "$d" label); files=$(meta_get "$d" files); bytes=$(meta_get "$d" bytes); el=$(meta_get "$d" elapsed)
  [[ -n $label ]] || label="transfer $id"
  case $st in
    done)
      body="$label - ${files:-0} file(s), $(hsize "${bytes:-0}"), $(fmt_dur "${el:-0}")"
      tnotify "rclone-$id" "✔ Transfer complete" "$body" default ;;
    failed)
      err=$(job_last_errors "$d" | tail -n 1)
      if is_auth_error "$err"; then h="Token expired - open Remote Manager > Test connectivity to reconnect."
      else h=$(hint_text "$err"); fi
      body="$label - ${err:-see the job log}"; [[ -n $h ]] && body="$body | $h"
      tnotify "rclone-$id" "✖ Transfer FAILED" "$body" high ;;
    interrupted)
      tnotify "rclone-$id" "⚠ Transfer interrupted" "$label - process vanished (killed?). Check the log and verify before retrying." high ;;
  esac
  return 0
}

job_batch_check() { # called by the worker after a job ended: one summary when the whole queue is idle
  local d s n ok bad can
  for d in "$JOBS_DIR"/*/; do d=${d%/}; s=$(meta_get "$d" status); [[ $s == running || $s == queued ]] && return 0; done
  mkdir -- "$APP_DIR/batch.lock" 2>/dev/null || return 0     # only one worker sends the summary
  if [[ -f $APP_DIR/batch.counts ]]; then
    n=$(wc -l <"$APP_DIR/batch.counts"); ok=$(grep -c '^done$' "$APP_DIR/batch.counts" || true)
    bad=$(grep -cE '^(failed|interrupted)$' "$APP_DIR/batch.counts" || true); can=$(grep -c '^cancelled$' "$APP_DIR/batch.counts" || true)
    rm -f "$APP_DIR/batch.counts"
    if (( n >= 2 )); then
      tnotify "rclone-batch" "Transfer queue finished" "$ok done, $bad failed, $can cancelled" $( (( bad )) && echo high || echo default )
    fi
  fi
  rmdir "$APP_DIR/batch.lock" 2>/dev/null
  return 0
}

job_watch_errors() { # dir pid : alert once when a running job first reports errors (runs as a background poller)
  local d=$1 pid=$2 er id=${1##*/}
  while kill -0 "$pid" 2>/dev/null; do
    sleep 20
    [[ -e $d/live_alerted ]] && return 0
    er=$(job_stats "$d/log.jsonl" | cut -f7)
    if [[ $er =~ ^[0-9]+$ ]] && (( er > 0 )); then
      : >"$d/live_alerted"
      tnotify "rclone-$id-err" "⚠ Transfer reports errors" "$(meta_get "$d" label) - $er error(s) so far, still running. $(job_last_errors "$d" | tail -n 1)" high
      return 0
    fi
  done
  return 0
}

job_archive() { # dir status : write history line and move to history
  local d=$1 st=$2 id=${1##*/} line
  meta_set "$d" status "$st"; meta_set "$d" end "$(date +%s)"
  # '-' placeholders keep every TSV field non-empty
  line=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$id" "$st" "$(meta_get "$d" label)" \
    "$(meta_get "$d" src)" "$(meta_get "$d" dst)" "$(meta_get "$d" bytes)" "$(meta_get "$d" files)" \
    "$(meta_get "$d" errors)" "$(meta_get "$d" start)" | awk -F'\t' -v OFS='\t' '{for(i=1;i<=NF;i++) if($i=="") $i="-"; print}')
  printf '%s\n' "$line" >>"$HISTORY_TSV"
  if ! mv -- "$d" "$HIST_DIR/$id"; then log_msg ERROR "could not move job $id to history"; return 1; fi
  log_msg INFO "job $id finished: $st"
  job_notify "$id" "$st" "$HIST_DIR/$id"
}

job_run_sync() { # id : run one queued job to completion (called in a detached background subshell)
  local id=$1 d="$JOBS_DIR/$1"
  [[ -d $d ]] || return 1
  # Atomic claim: no double start, and a cancel cannot race a start.
  mkdir -- "$d/claim" 2>/dev/null || return 1
  [[ $(meta_get "$d" status) == queued ]] || return 1
  if [[ -e $d/cancel ]]; then job_archive "$d" cancelled; return 0; fi
  local -a args=() run=() rrun=() cur=(); local a pid rc st line attempt=1 maxatt=$((AUTO_RETRIES+1))
  mapfile -d '' -t args <"$d/cmd"
  for a in "${args[@]}"; do [[ $a == '@LIST@' ]] && a="$d/files.txt"; run+=("$a"); done
  # Retry passes must not skip an existing destination file: a bad (short/corrupt) file would otherwise be kept.
  for a in "${run[@]}"; do [[ $a == --ignore-existing || $a == --update ]] || rrun+=("$a"); done
  cur=("${run[@]}")
  rm -f "$d/paused" "$d/log.jsonl" "$d/log.all.jsonl"
  while :; do
    meta_set "$d" attempt "$attempt/$maxatt"
    # --stats-log-level NOTICE + --log-level NOTICE: stats events are always written to the log.
    rclone "${cur[@]}" --ask-password=false --use-json-log --stats "$STATS_EVERY" --stats-log-level NOTICE \
      --low-level-retries 10 --retries-sleep 5s \
      --log-level NOTICE --log-file "$d/log.jsonl" </dev/null >/dev/null 2>"$d/stderr" &
    pid=$!
    # pid + start are recorded BEFORE status=running, so "running" always has a pid to verify
    meta_set "$d" pid "$pid"; (( attempt == 1 )) && meta_set "$d" start "$(date +%s)"; meta_set "$d" status running
    [[ -e $d/cancel ]] && kill -TERM "$pid" 2>/dev/null   # cancel arrived before the pid was known
    local wpid=""
    if (( NOTIFY && NOTIFY_LIVE )); then job_watch_errors "$d" "$pid" & wpid=$!; fi
    wait "$pid"; rc=$?
    [[ -n $wpid ]] && { kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null; }
    (( rc == 0 )) && break
    [[ -e $d/cancel ]] && break
    (( attempt >= maxatt )) && break
    # Only corruption-type failures trigger an automatic re-run of the job.
    grep -qE 'corrupted on transfer|sizes differ|hashes differ|Sizes differ' "$d/log.jsonl" 2>/dev/null || break
    log_msg WARN "job $id: corrupted transfer detected, re-running (attempt $((attempt+1))/$maxatt)"
    cat "$d/log.jsonl" >>"$d/log.all.jsonl" 2>/dev/null; rm -f "$d/log.jsonl"
    attempt=$((attempt+1)); cur=("${rrun[@]}")
  done
  # A successful exit is reported as done even if a cancel arrived at the very end.
  if (( rc == 0 )); then st=done; elif [[ -e $d/cancel ]]; then st=cancelled; else st=failed; fi
  local b tb sp eta tr ttr er el nm
  line=$(job_stats "$d/log.jsonl")
  if [[ -n $line ]]; then
    IFS=$'\t' read -r b tb sp eta tr ttr er el nm <<<"$line"
    meta_set "$d" stats 1; meta_set "$d" bytes "$(toint "$b")"; meta_set "$d" total "$(toint "$tb")"
    meta_set "$d" files "$(toint "$tr")"; meta_set "$d" files_total "$(toint "$ttr")"
    meta_set "$d" errors "$(toint "$er")"; meta_set "$d" elapsed "$(toint "$el")"
  else
    meta_set "$d" stats 0
  fi
  meta_set "$d" rc "$rc"
  printf '%s\n' "$st" >>"$APP_DIR/batch.counts"
  job_archive "$d" "$st"
  job_batch_check
}

jobs_launch() { # ids... : start queued jobs per QUEUE_MODE, detached from the UI
  local id
  (( $(count_running) == 0 )) && rm -rf -- "$APP_DIR/batch.counts" "$APP_DIR/batch.lock"
  if [[ $QUEUE_MODE == concurrent ]]; then
    for id in "$@"; do
      ( trap '' HUP; job_run_sync "$id" ) >/dev/null 2>&1 </dev/null &
      disown 2>/dev/null
    done
  else
    ( trap '' HUP; for id in "$@"; do job_run_sync "$id"; done ) >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null
  fi
  return 0
}

job_cancel() { # id
  local d pid st; d=$(job_dir "$1") || return 1
  [[ $d == "$JOBS_DIR"/* ]] || return 1
  st=$(meta_get "$d" status)
  if [[ $st == queued ]]; then
    # claim it so a starting worker cannot also run it; if the claim fails the job is starting now
    if mkdir -- "$d/claim" 2>/dev/null; then job_archive "$d" cancelled; return 0; fi
  elif [[ $st != running ]]; then return 1; fi
  touch "$d/cancel"
  pid=$(meta_get "$d" pid)
  if job_pid_ok "$pid" "$d"; then kill -CONT "$pid" 2>/dev/null; kill -TERM "$pid" 2>/dev/null; fi
  rm -f "$d/paused"
  return 0
}

job_pause()  { local d pid; d=$(job_dir "$1") || return 1; pid=$(meta_get "$d" pid)
  [[ $(meta_get "$d" status) == running ]] && job_pid_ok "$pid" "$d" && kill -STOP "$pid" 2>/dev/null && touch "$d/paused"; }
job_resume() { local d pid; d=$(job_dir "$1") || return 1; pid=$(meta_get "$d" pid)
  [[ -e $d/paused ]] && job_pid_ok "$pid" "$d" && kill -CONT "$pid" 2>/dev/null && rm -f "$d/paused"; }

job_clone() { # id -> new queued job (retry). Never auto-started.
  local d nd; d=$(job_dir "$1") || return 1
  job_alloc || return 1
  nd=$JOB_D
  cp -- "$d/cmd" "$nd/cmd" || { rm -rf -- "$nd"; return 1; }
  [[ -f $d/files.txt ]] && cp -- "$d/files.txt" "$nd/files.txt"
  : >"$nd/meta"
  meta_set "$nd" label "retry: $(meta_get "$d" label)"; meta_set "$nd" mode "$(meta_get "$d" mode)"
  meta_set "$nd" src "$(meta_get "$d" src)"; meta_set "$nd" dst "$(meta_get "$d" dst)"
  meta_set "$nd" created "$(date +%s)"; meta_set "$nd" status queued
}

count_running() {
  local d n=0
  for d in "$JOBS_DIR"/*/; do
    d=${d%/}; [[ $(meta_get "$d" status) == running ]] && n=$((n+1))
  done
  printf '%d' "$n"
}

recover_jobs() { # never restarts anything; only records what happened
  local d st pid
  for d in "$JOBS_DIR"/*/; do
    d=${d%/}; st=$(meta_get "$d" status); pid=$(meta_get "$d" pid)
    if [[ -z $st ]]; then                      # crash while the job was being created
      if [[ -s $d/cmd ]]; then meta_set "$d" note "half-created job"; job_archive "$d" interrupted
      else rm -rf -- "$d"; fi
      log_msg WARN "cleaned half-created job ${d##*/}"
    elif [[ $st == running ]] && ! job_pid_ok "$pid" "$d"; then
      meta_set "$d" note "process gone; outcome unknown - check the log and verify before retrying"
      job_archive "$d" interrupted
      log_msg WARN "job ${d##*/} was interrupted (process gone); not restarted"
    elif [[ $st == queued && -d $d/claim ]]; then
      rmdir "$d/claim" 2>/dev/null              # stale claim from a worker that died before starting
    fi
  done
  return 0
}

status_color() {
  case $1 in
    running) printf '%s' "$C_CYN" ;; done) printf '%s' "$C_GRN" ;;
    failed|interrupted) printf '%s' "$C_RED" ;; cancelled) printf '%s' "$C_YEL" ;;
    *) printf '%s' "$C_DIM" ;;
  esac
}

job_log_view() { # id
  local d f="$TMP_DIR/joblog.txt"; d=$(job_dir "$1") || return
  {
    printf 'Job %s\nLabel : %s\nSource: %s\nDest  : %s\nStatus: %s (rclone exit %s)\n\n' "$1" \
      "$(meta_get "$d" label)" "$(meta_get "$d" src)" "$(meta_get "$d" dst)" "$(meta_get "$d" status)" "$(meta_get "$d" rc)"
    if [[ -f $d/log.jsonl || -f $d/log.all.jsonl ]]; then
      cat "$d/log.all.jsonl" "$d/log.jsonl" 2>/dev/null | jq -rR 'fromjson? | select(.level != null and (.stats? | not)) | "\((.time // "")[0:19]) \(.level) \(.msg // "")"' \
        2>/dev/null | tail -n 400
    fi
    if [[ -s $d/stderr ]]; then printf '\n--- stderr ---\n'; tail -n 50 "$d/stderr"; fi
  } >"$f"
  page_file "$f"
}

job_monitor() { # id : live structured progress screen
  local id=$1 d st b tb sp eta tr ttr er el nm have pct barw filled i bar line note age now mt pid etas pstate ln
  local -a L
  sclear
  while true; do
    d=$(job_dir "$id") || { notify "Job not found" err; return 0; }
    st=$(meta_get "$d" status)
    have=0; b=0; tb=0; sp=0; eta=-1; tr=0; ttr=0; er=0; el=0; nm=""
    if [[ $st == running || $st == queued ]]; then
      line=$(job_stats "$d/log.jsonl")
      if [[ -n $line ]]; then IFS=$'\t' read -r b tb sp eta tr ttr er el nm <<<"$line"; have=1; fi
    elif [[ $(meta_get "$d" stats) == 1 ]]; then
      have=1; b=$(meta_get "$d" bytes); tb=$(meta_get "$d" total); tr=$(meta_get "$d" files)
      ttr=$(meta_get "$d" files_total); er=$(meta_get "$d" errors); el=$(meta_get "$d" elapsed)
    fi
    b=$(toint "$b"); tb=$(toint "$tb"); sp=$(toint "$sp"); eta=$(toint "$eta")
    tr=$(toint "$tr"); ttr=$(toint "$ttr"); er=$(toint "$er"); el=$(toint "$el")
    term_size
    pct=0; (( tb > 0 )) && pct=$(( b * 100 / tb )); (( pct > 100 )) && pct=100
    barw=$((COLS-12)); (( barw < 10 )) && barw=10
    filled=$(( barw * pct / 100 )); bar=""
    for ((i=0; i<barw; i++)); do if (( i < filled )); then bar+="#"; else bar+="-"; fi; done
    local fb eb; fb=$(srule "$filled" █); eb=$(srule $((barw - filled)) ░); bar="${C_GRN}${fb}${C_DIM}${eb}${C_RST}"
    etas="-"; (( eta >= 0 )) && etas=$(fmt_dur "$eta")
    pstate=""; [[ -e $d/paused ]] && pstate=" (PAUSED)"
    # Distinguish "running, no statistics yet" from "no log activity" and from "process gone".
    note=""
    if [[ $st == running && ! -e $d/paused ]]; then
      now=$(date +%s); pid=$(meta_get "$d" pid)
      if ! job_pid_ok "$pid" "$d"; then
        note="rclone process not found - job probably killed (marked interrupted on refresh)"
      else
        if [[ -f $d/log.jsonl ]]; then mt=$(stat -c %Y "$d/log.jsonl" 2>/dev/null || echo "$now"); else mt=$(toint "$(meta_get "$d" start)"); fi
        (( mt > 0 )) || mt=$now
        age=$(( now - mt ))
        if (( age >= 30 )); then note="No log output for ${age}s - stalled or backend busy (not necessarily failed)"
        elif (( ! have )); then note="Running - waiting for the first statistics line"; fi
      fi
    fi
    L=()
    L+=("${C_B}Job ${id}${C_RST}")
    local rcs=""; [[ -n $(meta_get "$d" rc) ]] && rcs="  exit $(meta_get "$d" rc)"
    L+=("Status : $(status_color "$st")${st}${pstate}${C_RST}${rcs}")
    local att; att=$(meta_get "$d" attempt)
    if [[ -n $att && ${att%/*} != 1 ]]; then L+=("Attempt: ${C_YEL}${att}${C_RST} (re-run after corrupted transfer)"); fi
    L+=("Op     : $(tail_trunc "$(meta_get "$d" label)" $((COLS-9)))")
    L+=("From   : $(tail_trunc "$(meta_get "$d" src)" $((COLS-9)))")
    L+=("To     : $(tail_trunc "$(meta_get "$d" dst)" $((COLS-9)))")
    if (( have )); then
      L+=("File   : $(tail_trunc "${nm:-n/a}" $((COLS-9)))")
      L+=("[$bar] ${pct}%")
      L+=("Bytes  : $(hsize "$b") / $( ((tb > 0)) && hsize "$tb" || printf '?')")
      L+=("Speed  : $(hsize "$sp")/s   ETA: $etas")
      L+=("Files  : done $tr / known $ttr (left $(( ttr > tr ? ttr - tr : 0 )))")
      L+=("Errors : $er   Elapsed: $(fmt_dur "$el")")
    else
      L+=("Progress: no statistics available")
    fi
    if [[ -n $note ]]; then
      while IFS= read -r ln || [[ -n $ln ]]; do L+=("${C_YEL}${ln}${C_RST}"); done < <(printf '%s' "$note" | fold -s -w $((COLS-2)))
    fi
    if [[ $st == failed || $st == interrupted || ( $st == running && $er -gt 0 ) ]]; then
      line=$(job_last_errors "$d")
      if [[ -n $line ]]; then
        L+=("${C_RED}Last errors from rclone:${C_RST}")
        while IFS= read -r ln || [[ -n $ln ]]; do L+=("${C_RED}${ln}${C_RST}"); done < <(printf '%s' "$line" | fold -s -w $((COLS-2)))
        if is_auth_error "$line"; then
          L+=("${C_YEL}Token expired: Remote Manager > Test connectivity offers to reconnect the remote, then retry the job.${C_RST}")
        elif [[ -n $(hint_text "$line") ]]; then
          L+=("${C_YEL}Hint: $(hint_text "$line")${C_RST}")
        fi
      fi
    fi
    if [[ $st != running && $st != queued ]]; then
      if [[ -n $(meta_get "$d" note) ]]; then
        while IFS= read -r ln || [[ -n $ln ]]; do L+=("$ln"); done < <(meta_get "$d" note | fold -s -w $((COLS-2)))
      fi
      L+=("")
      while IFS= read -r ln || [[ -n $ln ]]; do L+=("$ln"); done < <(printf '%s' "Finished. Retry re-runs the whole job; finished files are skipped only if the existing-file policy was skip/newer. rclone does not resume partial files for most backends." | fold -s -w $((COLS-2)))
    fi
    if [[ -t 1 ]]; then printf '\e[H'; fi   # redraw in place (no clear) so the screen does not flicker
    sbanner; stitle "Job monitor  ·  live (${MON_REFRESH}s)"
    for ln in "${L[@]}"; do printf '  %s\e[K\n' "$ln"; done
    printf '\e[K\n'; snotes
    slegend "c cancel job" "p pause" "r resume" "l view log" "q back"; shint "$H_MONITOR"
    if [[ -t 1 ]]; then printf '\e[J'; fi
    read_key "$MON_REFRESH"
    case $KEY in
      q|Q|ESC|LEFT) return 0 ;;
      c) if confirm "Cancel this job?"; then job_cancel "$id" && notify "Cancel requested" ok; fi ;;
      p) job_pause "$id" && notify "Paused (SIGSTOP; network sessions may time out)" || notify "Cannot pause" err ;;
      r) job_resume "$id" && notify "Resumed" ok || notify "Not paused" err ;;
      l) job_log_view "$id" ;;
    esac
  done
}

jobs_after_create() { # ids...
  (( $# )) || return 0
  local first=$1
  if confirm "Start $# job(s) now? (n = leave queued)" Y; then
    jobs_launch "$@"; sleep 1; job_monitor "$first"
  else notify "$# job(s) queued - start them from Transfer Manager." ok; fi
}

jobs_screen() {
  local -a ids=(); local cur=0 top=0 d id st n vis i idx lbl
  recover_jobs   # records jobs whose process vanished (never restarts them)
  while true; do
    ids=()
    for d in "$JOBS_DIR"/*/; do ids+=("$(basename "${d%/}")"); done
    local -a hs=(); for d in "$HIST_DIR"/*/; do hs+=("$(basename "${d%/}")"); done
    for ((i=${#hs[@]}-1; i>=0 && i>=${#hs[@]}-30; i--)); do ids+=("${hs[i]}"); done
    n=${#ids[@]}
    (( cur >= n )) && cur=$((n-1)); (( cur < 0 )) && cur=0
    local st lbl
    if true; then
      sclear; sbanner; stitle "Jobs (active first, then recent)"
      sbox_top "$C_CYN"
      (( n == 0 )) && sline "$C_CYN" "${C_DIM}(no jobs yet)${C_RST}" 13
      for ((i=0; i<n; i++)); do
        d=$(job_dir "${ids[i]}"); st=$(meta_get "$d" status); lbl=$(meta_get "$d" label | sanitize)
        sline "$C_CYN" "${C_B}${C_GRN}$(printf '%3d' $((i+1)))${C_RST} $(status_color "$st")$(pad "$st" 11)${C_RST} $(sfit "$lbl" $((S_W-4-16)))" $(( 16 + ${#lbl} > S_W-4 ? S_W-4 : 16 + ${#lbl} ))
      done
      sbox_bot "$C_CYN"
      snotes
      slegend "N open monitor" "s N start job" "c N cancel job" "t N retry job" "l N view log" "S start ALL queued" "q back"; shint "$H_JOBS"
      read_cmd "${C_B}${C_CYN} ❯ ${C_RST}" "$n"; ans=$ANS_LINE
      local cmd=${ans%% *} arg=${ans#* }; [[ $ans == *" "* ]] || arg=""
      case $cmd in
        q|'') return ;;
        S) startable_ids ;;
        s|c|t|l) [[ $arg =~ ^[0-9]+$ ]] && (( arg>=1 && arg<=n )) || { SIMPLE_NOTE+="Bad number"$'\n'; continue; }
           id=${ids[arg-1]}
           case $cmd in s) jobs_launch "$id" ;; c) job_cancel "$id" ;; t) job_clone "$id" && SIMPLE_NOTE+="Queued retry $JOB_ID"$'\n' ;; l) job_log_view "$id" ;; esac ;;
        *) if [[ $cmd =~ ^[0-9]+$ ]] && (( cmd>=1 && cmd<=n )); then job_monitor "${ids[cmd-1]}"; fi ;;
      esac
      continue
    fi
  done
}

startable_ids() { # start every queued job according to QUEUE_MODE
  local d; local -a q=()
  for d in "$JOBS_DIR"/*/; do d=${d%/}; [[ $(meta_get "$d" status) == queued ]] && q+=("${d##*/}"); done
  if (( ${#q[@]} )); then jobs_launch "${q[@]}"; notify "Started ${#q[@]} queued job(s) ($QUEUE_MODE)" ok
  else notify "No queued jobs" err; fi
}

###############################################################################
# 9. TRANSFER OPTIONS AND JOB CONSTRUCTION
###############################################################################
topts_init() {
  T_EXISTING=$EXISTING; T_CHECKSUM=$CHECKSUM; T_TRANSFERS=$TRANSFERS; T_CHECKERS=$CHECKERS
  T_BWLIMIT=$BWLIMIT; T_RETRIES=$RETRIES; T_DRYRUN=0; T_EMPTY=$EMPTY_DIRS; T_RECURSE=1
}

prompt_number() { # label current -> ANS (validated 1..64) ; returns 1 if invalid
  ask "$1 [$2]: " "$2" || return 1
  [[ $ANS =~ ^[0-9]+$ ]] && (( 10#$ANS >= 1 && 10#$ANS <= 64 ))
}

transfer_options_dialog() { # 0 = continue, 1 = cancel
  topts_init
  local pos=0
  while true; do
    MENU_START=$pos
    menu_choose "Transfer options (safe defaults)" \
      "Continue" \
      "Existing files: $T_EXISTING  (skip | overwrite | newer)" \
      "Checksum comparison: $(yn "$T_CHECKSUM")" \
      "Include subdirectories: $(yn "$T_RECURSE")" \
      "Transfers: $T_TRANSFERS" "Checkers: $T_CHECKERS" \
      "Bandwidth limit: ${T_BWLIMIT:-none}" "Retries: $T_RETRIES" \
      "Dry run: $(yn "$T_DRYRUN")" "Create empty dirs: $(yn "$T_EMPTY")" "Cancel"
    pos=$((CHOICE-1))
    case $CHOICE in
      1) return 0 ;;
      2) case $T_EXISTING in skip) T_EXISTING=overwrite ;; overwrite) T_EXISTING=newer ;; *) T_EXISTING=skip ;; esac ;;
      3) T_CHECKSUM=$((1-T_CHECKSUM)) ;;
      4) T_RECURSE=$((1-T_RECURSE)) ;;
      5) prompt_number "Transfers" "$T_TRANSFERS" && T_TRANSFERS=$ANS || notify "Invalid (1-64)" err ;;
      6) prompt_number "Checkers" "$T_CHECKERS" && T_CHECKERS=$ANS || notify "Invalid (1-64)" err ;;
      7) if ask "Bandwidth limit e.g. 2M (empty = none): " "$T_BWLIMIT" && setting_valid BWLIMIT "$ANS"; then T_BWLIMIT=$ANS
         else notify "Invalid bandwidth limit" err; fi ;;
      8) prompt_number "Retries" "$T_RETRIES" && T_RETRIES=$ANS || notify "Invalid (1-64)" err ;;
      9) T_DRYRUN=$((1-T_DRYRUN)) ;;
      10) T_EMPTY=$((1-T_EMPTY)) ;;
      11|0) return 1 ;;
    esac
  done
}

build_flags() { # mode -> XFLAGS
  XFLAGS=(--transfers "$T_TRANSFERS" --checkers "$T_CHECKERS" --retries "$T_RETRIES")
  [[ -n $T_BWLIMIT ]] && XFLAGS+=(--bwlimit "$T_BWLIMIT")
  if [[ $1 != sync ]]; then
    case $T_EXISTING in skip) XFLAGS+=(--ignore-existing) ;; newer) XFLAGS+=(--update) ;; esac
  fi
  (( T_CHECKSUM )) && XFLAGS+=(--checksum)
  (( T_DRYRUN )) && XFLAGS+=(--dry-run)
  (( T_EMPTY )) && XFLAGS+=(--create-empty-src-dirs)
  (( ! T_RECURSE )) && XFLAGS+=(--max-depth 1)
  return 0
}

maybe_dryrun_first() { # for destructive modes
  (( DRYRUN_FIRST && ! T_DRYRUN )) || return 0
  if confirm "Do a DRY RUN first (recommended; nothing is changed)?" Y; then
    T_DRYRUN=1; notify "Dry run: review the job log, then repeat without dry run." ok
  fi
}

# queue_nl_jobs mode sr sp dr dp names... : one copyto/moveto job per name that contains a newline
# (such names cannot be written to a --files-from list). Appends to the caller's `created` array.
queue_nl_jobs() {
  local mode=$1 sr=$2 sp=$3 dr=$4 dp=$5; shift 5
  local verb=copyto n s t
  [[ $mode == move ]] && verb=moveto
  for n in "$@"; do
    s=$(fq "$sr" "$(join_path "$sp" "$n")"); t=$(fq "$dr" "$(join_path "$dp" "$n")")
    if job_create "$mode (name contains newline)" "$mode" "$s" "$t" "$verb" "$s" "$t" "${XFLAGS[@]}"; then created+=("$JOB_ID"); fi
  done
}

###############################################################################
# 9b. DESTINATION PICKER (manual destination for every transfer)
# Reuses the file-manager browser (load_listing / panel_goto / fm_dispatch / pick_location)
# on a THIRD panel slot (index 2). The real panels A/B, the listing arrays, the cursor and the
# selection are saved first and always restored, so browsing never changes the source panel.
###############################################################################
DEST_R=""; DEST_P=""; PICK_SRC=""; XFER_DIR=""
LAST_DEST_FILE="$APP_DIR/last_dest"; LAST_R=""; LAST_P=""; HAVE_LAST=0
SV_ACT=0; SV_CUR=0; SV_TOP=0; SV_FAILED=0; SV_ERR=""
SV_TYPE=(); SV_SIZE=(); SV_TIME=(); SV_NAME=(); SV_SEL=()

dest_state_save() {
  SV_ACT=$ACT; SV_CUR=$CUR; SV_TOP=$TOP; SV_FAILED=$LIST_FAILED; SV_ERR=$LIST_ERR
  SV_TYPE=("${E_TYPE[@]}"); SV_SIZE=("${E_SIZE[@]}"); SV_TIME=("${E_TIME[@]}"); SV_NAME=("${E_NAME[@]}")
  SV_SEL=("${!SELIDX[@]}")
}

dest_state_restore() {
  local k
  ACT=$SV_ACT; CUR=$SV_CUR; TOP=$SV_TOP; LIST_FAILED=$SV_FAILED; LIST_ERR=$SV_ERR
  E_TYPE=("${SV_TYPE[@]}"); E_SIZE=("${SV_SIZE[@]}"); E_TIME=("${SV_TIME[@]}"); E_NAME=("${SV_NAME[@]}")
  SELIDX=(); for k in "${SV_SEL[@]}"; do SELIDX[$k]=1; done
  unset 'P_REMOTE[2]' 'P_PATH[2]' 'P_ROOT[2]'
}

dest_browse() { # interactive browse of panel slot 2. 0 = a folder was chosen (DEST_R/DEST_P), 1 = back
  local n i ps=20 page=0 start end ans cmd
  while true; do
    if true; then
      n=${#E_NAME[@]}; start=$((page*ps)); end=$((start+ps)); (( end > n )) && end=$n
      sclear; sbanner; stitle "[Destination] $(loc_str 2)"
      printf '%s  from: %s%s\n' "$C_DIM" "$(printf '%s' "$PICK_SRC" | sanitize)" "$C_RST"
      sfm_box "$start" "$end"
      printf '%s  %d folder/file(s) · page %d/%d%s\n' "$C_DIM" "$n" $((page+1)) $(( (n+ps-1)/ps > 0 ? (n+ps-1)/ps : 1 )) "$C_RST"
      snotes
      slegend "N open folder" ".. go up" "s USE THIS FOLDER" "n new folder" "l change location" ": jump to path" ".⏎ hidden folders: $(yn $SHOW_HIDDEN)" "→ or + next page" "← or - prev page" "q back to menu"; shint "$H_DEST"
      read_cmd "${C_B}${C_GRN} ❯ dest ${C_RST}" "$n" fm_num_is_dir 1; ans=$ANS_LINE
      cmd=$ans
      case $cmd in
        s|S) DEST_R=${P_REMOTE[2]}; DEST_P=${P_PATH[2]}; return 0 ;;
        q|Q) return 1 ;;
        '..') fm_dispatch BACKSPACE; page=0 ;;
        '+') (( end < n )) && page=$((page+1)) ;;
        '-') (( page > 0 )) && page=$((page-1)) ;;
        l|n|R|.) fm_dispatch "$cmd"; page=0 ;;
        ':') fm_dispatch ':'; page=0 ;;
        *) if [[ $cmd =~ ^[0-9]+$ ]] && (( cmd >= 1 && cmd <= n )); then
             if [[ ${E_TYPE[cmd-1]} == d ]]; then CUR=$((cmd-1)); fm_open_cur; page=0; else SIMPLE_NOTE+="Not a folder."$'\n'; fi
           fi ;;
      esac
    fi
  done
}

dest_manual() { # type a destination; validated, never silently replaced. 0 = DEST_R/DEST_P set
  local in r p anc
  ask "Destination (/abs/path, ~/path, or remote:folder): " || return 1
  in=$ANS
  [[ -n $in ]] || return 1
  if [[ $in == *$'\n'* ]]; then notify "Invalid destination" err; return 1; fi
  if [[ $in =~ ^([^:/]+):(.*)$ ]]; then
    r=${BASH_REMATCH[1]}; p=${BASH_REMATCH[2]}
    load_remotes
    local x found=0; for x in "${REMOTES[@]}"; do [[ $x == "$r" ]] && found=1; done
    (( found )) || { notify "Unknown remote: $r (configured: ${REMOTES[*]:-none})" err; return 1; }
    P_REMOTE[2]=$r; P_PATH[2]=$p; ACT=2
    if ! load_listing; then
      notify "Cannot list $r:$p - $LIST_ERR" err
      if offer_reconnect "$r" "$LIST_ERR" && load_listing; then :
      else
        # A missing folder and an unreachable remote look alike to rclone: let the user decide explicitly.
        confirm "Use $r:$p anyway? (only if the folder does not exist yet; rclone will create it)" N || return 1
      fi
    fi
    DEST_R=$r; DEST_P=$p; return 0
  fi
  in=${in/#\~/$HOME}
  if [[ $in != /* ]]; then notify "Local destinations must be absolute (start with / or ~)" err; return 1; fi
  [[ $in != / ]] && in=${in%/}
  if [[ -e $in ]]; then
    [[ -d $in ]] || { notify "Not a directory: $in" err; return 1; }
    if [[ ! -w $in || ! -x $in ]]; then notify "Not writable: $in (check Android storage permission)" err; return 1; fi
    DEST_R=""; DEST_P=$(cd -- "$in" 2>/dev/null && pwd) || { notify "Cannot enter $in" err; return 1; }
    return 0
  fi
  anc=${in%/*}; while [[ -n $anc && ! -d $anc ]]; do anc=${anc%/*}; done; [[ -z $anc ]] && anc=/
  if [[ ! -w $anc || ! -x $anc ]]; then notify "Cannot create $in: $anc is not writable" err; return 1; fi
  confirm "$in does not exist; it will be created by the transfer. Continue?" N || return 1
  DEST_R=""; DEST_P=$in; return 0
}

last_dest_load() { # reads the remembered destination (2 lines: remote, path); HAVE_LAST=1 when usable
  LAST_R=""; LAST_P=""; HAVE_LAST=0
  [[ -f $LAST_DEST_FILE ]] || return 0
  { IFS= read -r LAST_R; IFS= read -r LAST_P; } <"$LAST_DEST_FILE" 2>/dev/null
  [[ -n $LAST_P || -n $LAST_R ]] && HAVE_LAST=1
  return 0
}

last_dest_save() { # DEST_R/DEST_P -> remembered for next time (a failed save is harmless)
  [[ $DEST_R == *$'\n'* || $DEST_P == *$'\n'* ]] && return 0
  local t="$LAST_DEST_FILE.tmp.$$"
  { printf '%s\n%s\n' "$DEST_R" "$DEST_P" >"$t" && mv -f "$t" "$LAST_DEST_FILE"; } 2>/dev/null \
    && chmod 600 "$LAST_DEST_FILE" 2>/dev/null || rm -f -- "$t"
  return 0
}

last_dest_ok() { # is the remembered destination still usable? prints the reason on failure
  local x
  if [[ -n $LAST_R ]]; then
    load_remotes
    for x in "${REMOTES[@]}"; do [[ $x == "$LAST_R" ]] && return 0; done
    printf 'Remote "%s" no longer exists' "$LAST_R"; return 1
  fi
  [[ -d $LAST_P ]] || { printf 'Folder %s is not accessible any more' "$LAST_P"; return 1; }
  [[ -w $LAST_P && -x $LAST_P ]] || { printf 'Folder %s is not writable' "$LAST_P"; return 1; }
  return 0
}

pick_destination() { # mode other_panel source_text -> DEST_R/DEST_P. 0 = chosen, 1 = cancelled (no job must be created)
  local mode=$1 other=$2 rc=1 c why
  PICK_SRC=${3:-}; DEST_R=""; DEST_P=""
  dest_state_save
  P_REMOTE[2]=""; P_PATH[2]=$HOME   # placeholder; only used after a location has been loaded successfully
  while true; do
    ACT=$SV_ACT
    last_dest_load   # re-read every time: always the most recent destination, even from another session
    if (( HAVE_LAST )); then
      menu_choose "Destination for ${mode^^} (from $PICK_SRC)" \
        "Last used destination: $(loc_fmt "$LAST_R" "$LAST_P")" \
        "Browse local storage" "Browse a remote" "Enter path manually" "Cancel"
    else
      menu_choose "Destination for ${mode^^} (from $PICK_SRC)" \
        "Browse local storage" "Browse a remote" "Enter path manually" "Cancel"
    fi
    c=$CHOICE
    if (( HAVE_LAST && c == 1 )); then
      if why=$(last_dest_ok); then DEST_R=$LAST_R; DEST_P=$LAST_P; rc=0; break; fi
      notify "$why - pick another destination" err; continue
    fi
    (( HAVE_LAST && c >= 2 )) && c=$((c-1))
    case $c in
      1|2) ACT=2
         if pick_location "$([[ $c == 1 ]] && echo L || echo R)"; then
           if dest_browse; then rc=0; break; fi
         fi ;;
      3) if dest_manual; then rc=0; break; fi ;;
      4|0) break ;;
    esac
  done
  (( rc == 0 )) && last_dest_save
  dest_state_restore
  return $rc
}

act_transfer() { # copy | move  (active panel selection -> a destination chosen manually)
  local mode=$1 other=$((1-ACT))
  get_targets
  (( ${#T_IDX[@]} )) || { XFER_DIR=""; notify "Nothing selected" err; return; }
  local sr=${P_REMOTE[ACT]} sp=${P_PATH[ACT]} dr dp
  pick_destination "$mode" "$other" "$(loc_str "$ACT")" || { XFER_DIR=""; notify "Destination selection cancelled - no job created" ok; return; }
  dr=$DEST_R; dp=$DEST_P
  # u / g shortcuts keep their meaning: upload = local -> remote, download = remote -> local
  if [[ ${XFER_DIR:-} == upload && ( -n $sr || -z $dr ) ]]; then XFER_DIR=""; notify "Upload needs a local source and a remote destination" err; return; fi
  if [[ ${XFER_DIR:-} == download && ( -z $sr || -n $dr ) ]]; then XFER_DIR=""; notify "Download needs a remote source and a local destination" err; return; fi
  XFER_DIR=""
  if [[ $sr == "$dr" && $sp == "$dp" ]]; then notify "Source and destination are the same location" err; return; fi
  transfer_options_dialog || { notify "Cancelled" ok; return; }
  local -a files=() dirs=(); local i nd=0 nf=0
  for i in "${T_IDX[@]}"; do if [[ ${E_TYPE[i]} == d ]]; then dirs+=("$i"); else files+=("$i"); fi; done
  sclear
  printf '%s%s%s\n  from: %s\n    to: %s\n  items: %d file(s), %d folder(s)\n  existing: %s  checksum: %s  dry-run: %s\n' \
    "$C_B" "${mode^^}" "$C_RST" "$(fq "$sr" "$sp")" "$(fq "$dr" "$dp")" "${#files[@]}" "${#dirs[@]}" \
    "$T_EXISTING" "$(yn "$T_CHECKSUM")" "$(yn "$T_DRYRUN")"
  if [[ $mode == move ]]; then
    printf '%sMOVE removes source files after they are transferred successfully.%s\n' "$C_YEL" "$C_RST"
    if [[ $T_EXISTING == overwrite ]]; then printf '%sOverwrite is on: differing files at the destination are replaced.%s\n' "$C_RED" "$C_RST"; fi
  fi
  [[ $sr == "$dr" ]] && printf '%sSame remote: rclone will use server-side operations where the backend supports them.%s\n' "$C_DIM" "$C_RST"
  [[ $sr != "$dr" && -n $sr && -n $dr ]] && printf '%sRemote to remote: data may flow through this phone unless the backend supports server-side transfer.%s\n' "$C_DIM" "$C_RST"
  confirm "Create the job(s)?" || { notify "Cancelled" ok; return; }
  [[ $mode == move ]] && maybe_dryrun_first
  build_flags "$mode"
  local -a created=() nlnames=(); local srcspec dstspec name sdir ddir refused=0
  if (( ${#files[@]} )); then
    : >"$TMP_DIR/files.txt"
    for i in "${files[@]}"; do
      name=${E_NAME[i]}
      # a files-from list is newline-delimited: names containing a newline get their own argv-safe job
      if [[ $name == *$'\n'* ]]; then nlnames+=("$name"); continue; fi
      printf '%s\n' "$name" >>"$TMP_DIR/files.txt"; nf=$((nf+1))
    done
    if (( nf )); then
      JOB_LIST_TMP="$TMP_DIR/files.txt"
      job_create "$mode $nf file(s)" "$mode" "$(fq "$sr" "$sp")" "$(fq "$dr" "$dp")" \
        "$mode" "$(fq "$sr" "$sp")" "$(fq "$dr" "$dp")" --files-from-raw @LIST@ "${XFLAGS[@]}" && created+=("$JOB_ID")
      JOB_LIST_TMP=""
    fi
    if (( ${#nlnames[@]} )); then queue_nl_jobs "$mode" "$sr" "$sp" "$dr" "$dp" "${nlnames[@]}"; fi
  fi
  for i in "${dirs[@]}"; do
    name=${E_NAME[i]}
    sdir=$(join_path "$sp" "$name"); ddir=$(join_path "$dp" "$name")
    if path_inside "$dr" "$ddir" "$sr" "$sdir"; then refused=$((refused+1)); continue; fi
    srcspec=$(fq "$sr" "$sdir"); dstspec=$(fq "$dr" "$ddir")
    local -a extra=(); [[ $mode == move ]] && extra=(--delete-empty-src-dirs)
    job_create "$mode folder $name" "$mode" "$srcspec" "$dstspec" "$mode" "$srcspec" "$dstspec" "${XFLAGS[@]}" "${extra[@]}" && created+=("$JOB_ID")
  done
  if (( refused )); then notify "Skipped $refused folder(s): destination lies inside the source (would recurse forever)" err; fi
  if (( ${#created[@]} == 0 )); then return; fi
  jobs_after_create "${created[@]}"
}

new_transfer_dirs() { # whole-directory copy / move / sync from the active panel to a destination chosen manually
  local other=$((1-ACT))
  local sr=${P_REMOTE[ACT]} sp=${P_PATH[ACT]} dr dp
  local src dst; src=$(fq "$sr" "$sp")
  menu_choose "Directory transfer from $(loc_str "$ACT")" \
    "Copy contents (safe, keeps source)" "Move contents (removes source files after transfer)" \
    "Sync (makes destination match source - DELETES extras at destination)" "Swap source/destination panels"
  local mode
  case $CHOICE in
    1) mode=copy ;; 2) mode=move ;; 3) mode=sync ;;
    4) ACT=$other; fm_reload; notify "Source is now $(loc_str "$ACT")" ok; return ;;
    *) return ;;
  esac
  pick_destination "$mode" "$other" "$(loc_str "$ACT")" || { notify "Destination selection cancelled - no job created" ok; return; }
  dr=$DEST_R; dp=$DEST_P; dst=$(fq "$dr" "$dp")
  if [[ $src == "$dst" ]]; then notify "Source and destination are identical" err; return; fi
  if path_inside "$dr" "$dp" "$sr" "$sp"; then notify "Destination lies inside the source: refused (would recurse forever)" err; return; fi
  if [[ $mode == sync ]]; then
    if [[ -z $dp || $dp == / ]]; then notify "Refusing to sync into a root directory; choose a subfolder as destination." err; return; fi
    sclear
    printf '%sSYNC WARNING%s\nDestination: %s\nFiles at the destination that do NOT exist in the source will be DELETED.\nSource: %s\n' "$C_RED" "$C_RST" "$dst" "$src"
    confirm_typed "Proceed?" SYNC || { notify "Cancelled" ok; return; }
  fi
  transfer_options_dialog || { notify "Cancelled" ok; return; }
  if [[ $mode != copy ]]; then maybe_dryrun_first; fi
  if [[ $mode == move ]]; then confirm "Move: source files are removed after successful transfer. Continue?" || return; fi
  sclear
  printf '%s%s%s\n  from: %s\n    to: %s\n  existing: %s  checksum: %s  dry-run: %s\n' "$C_B" "${mode^^}" "$C_RST" \
    "$src" "$dst" "$([[ $mode == sync ]] && echo 'n/a (sync)' || echo "$T_EXISTING")" "$(yn "$T_CHECKSUM")" "$(yn "$T_DRYRUN")"
  confirm "Create the job?" "$([[ $mode == copy ]] && echo Y || echo N)" || { notify "Cancelled - no job created" ok; return; }
  build_flags "$mode"
  local -a extra=(); [[ $mode == move ]] && extra=(--delete-empty-src-dirs)
  job_create "$mode $(loc_str "$ACT") -> $(loc_fmt "$dr" "$dp")" "$mode" "$src" "$dst" \
    "$mode" "$src" "$dst" "${XFLAGS[@]}" "${extra[@]}" && jobs_after_create "$JOB_ID"
}

###############################################################################
# 10. FILE MANAGER ACTIONS
###############################################################################
cur_spec() { fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "${E_NAME[CUR]}")"; }

valid_name() { # new file/folder name
  local n=$1
  [[ -n $n && $n != . && $n != .. && $n != */* && $n != *$'\n'* ]]
}

name_in_listing() { local x; for x in "${E_NAME[@]}"; do [[ $x == "$1" ]] && return 0; done; return 1; }

act_mkdir() {
  ask "New folder name: " || return
  valid_name "$ANS" || { notify "Invalid folder name" err; return; }
  name_in_listing "$ANS" && { notify "Already exists: $ANS" err; return; }
  local spec; spec=$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "$ANS")")
  if rc_quiet mkdir "$spec"; then log_msg INFO "mkdir $spec"; fm_reload; notify "Created $ANS" ok
  else notify "mkdir failed: $LAST_ERR" err; auth_recover "$spec" "$LAST_ERR"; fi
}

act_rename() {
  (( ${#E_NAME[@]} )) || return
  local old=${E_NAME[CUR]}
  ask "Rename '$old' to: " "$old" || return
  [[ $ANS == "$old" ]] && return
  valid_name "$ANS" || { notify "Invalid name" err; return; }
  name_in_listing "$ANS" && { notify "Target name already exists" err; return; }
  local new=$ANS src dst
  src=$(cur_spec); dst=$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "$new")")
  if rc_quiet moveto "$src" "$dst"; then log_msg INFO "rename $src -> $dst"; fm_reload; notify "Renamed" ok
  else notify "Rename failed: $LAST_ERR" err; auth_recover "$src" "$LAST_ERR"; fi
}

act_delete() {
  get_targets
  (( ${#T_IDX[@]} )) || return
  local i nd=0 nf=0 first=""
  for i in "${T_IDX[@]}"; do if [[ ${E_TYPE[i]} == d ]]; then nd=$((nd+1)); else nf=$((nf+1)); fi; first=${E_NAME[i]}; done
  sclear
  printf '%sDELETE%s from %s\n  %d file(s), %d folder(s) (folders are removed recursively with purge)\n' "$C_RED" "$C_RST" "$(loc_str "$ACT")" "$nf" "$nd"
  for i in "${T_IDX[@]:0:8}"; do printf '   - %s\n' "$(printf '%s' "${E_NAME[i]}" | sanitize)"; done
  (( ${#T_IDX[@]} > 8 )) && printf '   ... and %d more\n' $(( ${#T_IDX[@]} - 8 ))
  printf '%sLocal deletes are permanent. Remote deletes may go to the provider trash depending on backend settings.%s\n' "$C_DIM" "$C_RST"
  if (( nd )); then confirm_typed "Recursive delete" DELETE || { notify "Cancelled" ok; return; }
  else confirm "Delete ${#T_IDX[@]} file(s)?" || { notify "Cancelled" ok; return; }; fi
  local ok=0 fail=0 spec failspec=""
  for i in "${T_IDX[@]}"; do
    spec=$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "${E_NAME[i]}")")
    if [[ ${E_TYPE[i]} == d ]]; then rc_quiet purge "$spec"; else rc_quiet deletefile "$spec"; fi
    if (( $? == 0 )); then ok=$((ok+1)); log_msg INFO "deleted $spec"; else fail=$((fail+1)); failspec=$spec; log_msg ERROR "delete failed $spec: $LAST_ERR"; fi
  done
  fm_reload
  if (( fail )); then notify "Deleted $ok, FAILED $fail (see Logs). Last error: $LAST_ERR" err; auth_recover "$failspec" "$LAST_ERR"; else notify "Deleted $ok item(s)" ok; fi
}

act_details() {
  (( ${#E_NAME[@]} )) || return
  local spec f="$TMP_DIR/details.txt"; spec=$(cur_spec)
  {
    printf 'Name    : %s\nType    : %s\nSize    : %s\nModified: %s\nLocation: %s\n' "${E_NAME[CUR]}" \
      "$([[ ${E_TYPE[CUR]} == d ]] && echo directory || echo file)" \
      "$([[ ${E_TYPE[CUR]} == d ]] && echo n/a || hsize "${E_SIZE[CUR]}")" "${E_TIME[CUR]}" "$spec"
    if has_flag lsjson --stat && rc_quiet lsjson --stat --hash --no-mimetype "$spec"; then
      printf '\n--- rclone ---\n'
      jq -r '"Size bytes: \(.Size)\nModTime   : \(.ModTime // "n/a")\nHashes    : \((.Hashes // {}) | to_entries | map("\(.key)=\(.value)") | join("\n            "))"' "$TMP_DIR/out" 2>/dev/null
    fi
  } >"$f"
  page_file "$f"
}

act_size() {
  (( ${#E_NAME[@]} )) || return
  [[ ${E_TYPE[CUR]} == d ]] || { notify "Not a folder" err; return; }
  busy "Calculating size (Ctrl-C aborts)..."
  if rc_quiet size --json "$(cur_spec)"; then
    local c b; c=$(jq -r '.count' "$TMP_DIR/out"); b=$(jq -r '.bytes' "$TMP_DIR/out")
    notify "${E_NAME[CUR]}: $c file(s), $(hsize "$b") ($b bytes)" ok
  else notify "Size failed: $LAST_ERR" err; auth_recover "$(cur_spec)" "$LAST_ERR"; fi
}

act_preview() {
  (( ${#E_NAME[@]} )) || return
  [[ ${E_TYPE[CUR]} == f ]] || { notify "Select a file to preview" err; return; }
  local f="$TMP_DIR/preview.bin" spec; spec=$(cur_spec)
  if ! rc_quiet cat --count 16384 "$spec"; then notify "Preview failed: $LAST_ERR" err; auth_recover "$spec" "$LAST_ERR"; return; fi
  head -c 16384 "$TMP_DIR/out" >"$f"
  if [[ $(tr -d '\000' <"$f" | wc -c) -ne $(wc -c <"$f") ]]; then
    local meta=""
    if [[ -z ${P_REMOTE[ACT]} ]]; then
      if command -v ffprobe >/dev/null 2>&1; then meta=$(ffprobe -hide_banner -loglevel error -show_format -show_streams "$spec" 2>&1 | head -n 60)
      elif command -v mediainfo >/dev/null 2>&1; then meta=$(mediainfo "$spec" 2>&1 | head -n 60); fi
    fi
    if [[ -n $meta ]]; then printf '%s\n' "$meta" >"$f"; page_file "$f"
    else notify "Binary file - no preview (media metadata needs a local file and ffprobe/mediainfo)" err; fi
    return
  fi
  page_file "$f"
}

act_open() {
  (( ${#E_NAME[@]} )) || return
  if [[ -n ${P_REMOTE[ACT]} ]]; then notify "Remote file: download it first (g), then open locally" err; return; fi
  [[ ${E_TYPE[CUR]} == f ]] || { notify "Select a file" err; return; }
  if command -v termux-open >/dev/null 2>&1; then termux-open -- "$(join_path "${P_PATH[ACT]}" "${E_NAME[CUR]}")" 2>/dev/null && notify "Opened" ok || notify "termux-open failed" err
  else notify "termux-open not found (pkg install termux-tools)" err; fi
}

act_clip() {
  (( ${#E_NAME[@]} )) || return
  if command -v termux-clipboard-set >/dev/null 2>&1; then
    printf '%s' "$(cur_spec)" | termux-clipboard-set 2>/dev/null && notify "Path copied to clipboard" ok || notify "Clipboard failed (needs Termux:API app)" err
  else notify "termux-clipboard-set not found (pkg install termux-api + Termux:API app)" err; fi
}

act_select_pattern() {
  ask "Glob pattern (e.g. *.mp4, case-insensitive, files only): " || return
  [[ -n $ANS ]] || return
  local pat=${ANS,,} i n=0
  for ((i=0; i<${#E_NAME[@]}; i++)); do
    [[ ${E_TYPE[i]} == f ]] || continue
    # shellcheck disable=SC2053  # intentional glob match
    if [[ ${E_NAME[i],,} == $pat ]]; then SELIDX[$i]=1; n=$((n+1)); fi
  done
  notify "Selected $n file(s) matching $ANS" ok
}

act_direction() { # u = upload (local->remote), g = download (remote->local); destination is picked manually
  local want=$1
  if [[ $want == upload && -n ${P_REMOTE[ACT]} ]]; then notify "Upload needs a local source panel (x switches panel)" err; return; fi
  if [[ $want == download && -z ${P_REMOTE[ACT]} ]]; then notify "Download needs a remote source panel (x switches panel)" err; return; fi
  XFER_DIR=$want
  act_transfer copy
  XFER_DIR=""
}

pick_location() { # [L|R] choose a local root and/or a remote for the ACT panel. 0 = location loaded
  local filter=${1:-} ttl
  local_roots; load_remotes
  local -a labels=() kinds=() vals=(); local i
  if [[ $filter != R ]]; then
    for i in "${!LOCAL_PATHS[@]}"; do labels+=("Local: ${LOCAL_LABELS[i]}"); kinds+=(L); vals+=("${LOCAL_PATHS[i]}"); done
  fi
  if [[ $filter != L ]]; then
    for i in "${REMOTES[@]}"; do labels+=("Remote: $i:"); kinds+=(R); vals+=("$i"); done
  fi
  (( ${#labels[@]} )) || { notify "No $([[ $filter == R ]] && echo 'remotes configured (see Remote Manager)' || echo 'accessible locations found')" err; return 1; }
  ttl="Panel $([[ $ACT == 0 ]] && echo A || echo B) location"; (( ACT == 2 )) && ttl="Destination location"
  menu_choose "$ttl" "${labels[@]}"
  (( CHOICE )) || return 1
  local k=${kinds[CHOICE-1]} v=${vals[CHOICE-1]}
  if [[ $k == L ]]; then panel_goto "" "$v" && P_ROOT[ACT]=$v; else panel_goto "$v" "" && P_ROOT[ACT]=""; fi
}

cycle_sort() { case $SORT_KEY in name) SORT_KEY=size ;; size) SORT_KEY=time ;; *) SORT_KEY=name ;; esac; save_settings; fm_reload; notify "Sort: $SORT_KEY" ok; }

fm_help_text() {
  show_text "FILE MANAGER KEYS" "" \
   "(type the key, then press Enter - except keys marked INSTANT. Enter is shown as the symbol ⏎)" "" \
   "OPEN / NAVIGATE" \
   " N          INSTANT for a folder number: opens it. A FILE number needs Enter (shows its details)." \
   " q          INSTANT: go back one level (folder -> parent; storage root -> Storage Selection;" \
   "            remote root -> remotes list; Storage Selection -> main menu)" \
   " ..         go up one folder       → / ←  (or + / -)  INSTANT: next / previous page" \
   " l          change location (internal storage / SD card / remote)    :  jump to a path or remote:path" \
   " x          switch between panel A and panel B (two independent locations, one shown at a time)" "" \
   "SELECT (✔)" \
   " s N        select / unselect item N       s 1 4 7-9   select several (space or comma, ranges as 5-9)" \
   " a          select all (files + folders)     af  all FILES only     ad  all FOLDERS only     an  clear selection" \
   " i          invert selection     e  select by name pattern (files)" \
   " c all  m all  d all  u all  g all   select everything here and act at once (also: c files, m dirs)" "" \
   "ACT ON ITEMS" \
   " c m d      copy / move / delete the ✔ selected items, or the numbers you type: c 3, m 1 11 21, c 5-9" \
   "            (works on folders and files; one bad or out-of-range number rejects the whole command)" \
   " r N        rename item N          n  new folder          u  upload (local->remote)   g  download (remote->local)" \
   " v N p N z N y N X N   details / preview / folder size / copy path / open in an Android app (local files)" \
   " f          search          w  jobs" "" \
   "VIEW" \
   " s (alone)  change sort (name/size/time)   o  reverse sort   .  show/hide hidden files   R  refresh" "" \
   "EDITING THE LINE: Backspace erases, Ctrl-U clears it. Copy/move ask for a destination (last used is offered first)."
}

fm_open_cur() {
  (( ${#E_NAME[@]} )) || return
  if [[ ${E_TYPE[CUR]} == d ]]; then panel_goto "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "${E_NAME[CUR]}")"
  else act_details; fi
}

fm_dispatch() { # shared key/command dispatcher. returns 1 to leave the file manager
  local n=${#E_NAME[@]} listh=$((ROWS-7)) i
  case $1 in
    UP|k) (( CUR > 0 )) && CUR=$((CUR-1)) ;;
    DOWN|j) (( CUR < n-1 )) && CUR=$((CUR+1)) ;;
    PGUP) CUR=$((CUR-listh)); (( CUR < 0 )) && CUR=0 ;;
    PGDN) CUR=$((CUR+listh)); (( CUR > n-1 )) && CUR=$((n-1)); (( CUR < 0 )) && CUR=0 ;;
    HOME) CUR=0 ;; END) CUR=$((n-1)); (( CUR < 0 )) && CUR=0 ;;
    ENTER|RIGHT) fm_open_cur ;;
    BACKSPACE|LEFT)
      if (( ACT == 2 )); then panel_goto "${P_REMOTE[ACT]}" "$(parent_of "${P_REMOTE[ACT]}" "${P_PATH[ACT]}")"   # destination picker
      else fm_go_back; fi ;;
    SPACE) if (( n )); then
             if [[ -n ${SELIDX[$CUR]:-} ]]; then unset 'SELIDX[$CUR]'; else SELIDX[$CUR]=1; fi
             (( CUR < n-1 )) && CUR=$((CUR+1)); fi ;;
    a) sel_kind all; notify "Selected $SEL_N item(s) (files and folders)" ok ;;
    af) sel_clear; sel_kind files; notify "Selected $SEL_N file(s); folders left out" ok ;;
    ad) sel_clear; sel_kind dirs; notify "Selected $SEL_N folder(s); files left out" ok ;;
    an) sel_clear; notify "Selection cleared" ok ;;
    i) for ((i=0; i<n; i++)); do if [[ -n ${SELIDX[$i]:-} ]]; then unset 'SELIDX[$i]'; else SELIDX[$i]=1; fi; done ;;
    e) act_select_pattern ;;
    TAB) ACT=$((1-ACT)); fm_reload ;;
    c) act_transfer copy ;; m) act_transfer move ;; d) act_delete ;;
    r) act_rename ;; n) act_mkdir ;;
    u) act_direction upload ;; g) act_direction download ;;
    v) act_details ;; p) act_preview ;; z) act_size ;; x) act_open ;; y) act_clip ;;
    f) search_screen ;; w) jobs_screen ;;
    l) pick_location ;;
    ':') ask "Jump to path (/abs, rel, or remote:path): " && [[ -n $ANS ]] && parse_location_input "$ANS" ;;
    s) cycle_sort ;; o) SORT_REV=$((1-SORT_REV)); save_settings; fm_reload ;;
    .) SHOW_HIDDEN=$((1-SHOW_HIDDEN)); save_settings; fm_reload; notify "Hidden files: $(yn $SHOW_HIDDEN)" ok ;;
    R) fm_reload; notify "Refreshed" ok ;;
    '?'|h|H) fm_help_text ;;
    q|Q|ESC) if (( ACT == 2 )); then return 1; else fm_go_back; fi ;;   # q/ESC = Back, one level at a time
  esac
  return 0
}

# slegend "key label" ... : dim box of command hints, wrapped to the box width, key letters coloured
slegend() {
  local inner=$((S_W-2)) w=$((S_W-4)) line="" plain="" item k l len
  local bc=$C_DIM
  printf '%s╭%s╮%s\n' "$bc" "$(srule "$inner")" "$C_RST"
  for item in "$@"; do
    k=${item%% *}; l=${item#* }; len=$(( ${#k} + ${#l} + 1 ))
    if [[ -n $plain ]] && (( ${#plain} + 3 + len > w )); then
      printf '%s│%s %s%*s %s│%s\n' "$bc" "$C_RST" "$line" $((w - ${#plain})) '' "$bc" "$C_RST"; line=""; plain=""
    fi
    [[ -n $plain ]] && { line+="   "; plain+="   "; }
    line+="${C_B}${C_YEL}${k}${C_RST}${C_DIM} ${l}${C_RST}"; plain+="$k $l"
  done
  [[ -n $plain ]] && printf '%s│%s %s%*s %s│%s\n' "$bc" "$C_RST" "$line" $((w - ${#plain})) '' "$bc" "$C_RST"
  printf '%s╰%s╯%s\n' "$bc" "$(srule "$inner")" "$C_RST"
}

fm_simple() {
  local page=0 ps=15 n start end i ans cmd arg inner nw name mark ic nc sz pages
  while true; do
    n=${#E_NAME[@]}; start=$((page*ps)); end=$((start+ps)); (( end > n )) && end=$n
    pages=$(( (n+ps-1)/ps )); (( pages < 1 )) && pages=1
    sclear; sbanner
    stitle "[$([[ $ACT == 0 ]] && echo A || echo B)] $(loc_str "$ACT")"
    sfm_box "$start" "$end"
    printf '%s  %d item(s) · %d selected · page %d/%d%s\n' "$C_DIM" "$n" "${#SELIDX[@]}" $((page+1)) "$pages" "$C_RST"
    snotes
    slegend "N open folder" "N⏎ open file" "s N select" "a select all" "af files only" "ad folders only" "an clear selection" ".. go up" "c copy" "m move" "d delete" "r N rename" "n new folder" \
      "u upload→remote" "g download→local" "f search" "l change location" "x switch A/B panel" ".⏎ hidden files: $(yn $SHOW_HIDDEN)" "q back" "? all keys"; shint "$H_LIST"; shint "$H_LIST2"
    read_cmd "${C_B}${C_CYN} ❯ ${C_RST}" "$n" fm_num_is_dir 1; ans=$ANS_LINE
    cmd=${ans%% *}; arg=""; [[ $ans == *" "* ]] && arg=${ans#* }
    if [[ $cmd =~ ^[0-9]+$ ]]; then
      (( cmd >= 1 && cmd <= n )) && { CUR=$((cmd-1)); fm_open_cur; page=0; }
      continue
    fi
    case $cmd in
      c|m|d|u|g)   # an explicit list/range, the selection, or one item number: never a stale cursor
        if [[ $arg == all || $arg == files || $arg == dirs ]]; then   # e.g. "c all" / "c files" / "m dirs"
          (( n )) || { SIMPLE_NOTE+="Nothing in this folder."$'\n'; continue; }
          sel_clear; case $arg in files) sel_kind files ;; dirs) sel_kind dirs ;; *) sel_kind all ;; esac
          (( SEL_N )) || { SIMPLE_NOTE+="No $arg to select in this folder."$'\n'; continue; }
          SIMPLE_NOTE+="Selected $SEL_N item(s)"$'\n'
        elif [[ $arg == *[,\ -]* ]]; then            # e.g. "m 1,11,21"  /  "c 5-9"  /  "d 2 4 6"
          if parse_num_list "$arg" "$n"; then sel_clear; for i in "${PNUMS[@]}"; do SELIDX[$((i-1))]=1; done
          else SIMPLE_NOTE+="Bad item list. Use numbers, commas and ranges, e.g. '$cmd 1,11,21' or '$cmd 5-9' (1-$n)."$'\n'; continue; fi
        elif (( ${#SELIDX[@]} == 0 )); then
          if [[ $arg =~ ^[0-9]+$ ]] && (( arg >= 1 && arg <= n )); then CUR=$((arg-1))
          else SIMPLE_NOTE+="Select items first ('s N') or give an item number, e.g. '$cmd 3'."$'\n'; continue; fi
        fi ;;
      r|v|p|z|y|X)
        if [[ $arg =~ ^[0-9]+$ ]] && (( arg >= 1 && arg <= n )); then CUR=$((arg-1))
        else SIMPLE_NOTE+="Give an item number, e.g. '$cmd 3'."$'\n'; continue; fi ;;
      s) if [[ $arg == *[,\ -]* ]]; then          # several at once: "s 1,11,21" / "s 5-9"
           if parse_num_list "$arg" "$n"; then
             for i in "${PNUMS[@]}"; do SELIDX[$((i-1))]=1; done; SIMPLE_NOTE+="Selected ${#PNUMS[@]} item(s)"$'\n'
           else SIMPLE_NOTE+="Bad item list. Use e.g. 's 1,11,21' or 's 5-9' (1-$n)."$'\n'; fi
           continue
         elif [[ $arg =~ ^[0-9]+$ ]]; then
           if (( arg >= 1 && arg <= n )); then CUR=$((arg-1)); else SIMPLE_NOTE+="No such item"$'\n'; continue; fi
         fi ;;
    esac
    case $cmd in
      '+') (( end < n )) && page=$((page+1)) ;;
      '-') (( page > 0 )) && page=$((page-1)) ;;
      '..') fm_dispatch BACKSPACE; page=0 ;;
      x) fm_dispatch TAB; page=0 ;;
      X) act_open ;;
      s) if [[ $arg =~ ^[0-9]+$ ]]; then fm_dispatch SPACE; else cycle_sort; fi ;;
      q|Q) fm_go_back; page=0 ;;   # Back, one level at a time
      '') fm_reload ;;
      *) if (( n == 0 )) && [[ $cmd != [nlf:?] ]]; then :; else fm_dispatch "$cmd" || return; fi ;;
    esac
    [[ -n $FM_EXIT ]] && return
  done
}

###############################################################################
# 10b. FILE MANAGER NAVIGATION
#   File Manager -> Storage Selection (home) -> storage / remotes list -> folder -> subfolder ...
# Navigation state is only: the panel's location (P_REMOTE/P_PATH), the storage root it was opened
# from (P_ROOT) and the screen state machine in file_manager(). Transfer sources/destinations
# (DEST_R/DEST_P, panel slot 2) are separate and never feed Back navigation.
###############################################################################
P_ROOT=("" "")          # local panels: the storage root the panel was opened from ("" for remotes)
FM_EXIT=""              # set by fm_go_back when a root is left: home | remotes
FM_NEXT=home
FM_HOME_POS=0; FM_REMOTES_POS=0
ST_LABEL=(); ST_KIND=(); ST_VAL=()
declare -A ST_SEEN=()

fm_phys() { (cd -P -- "$1" 2>/dev/null && pwd -P); }   # physical path, used only to de-duplicate choices

st_class() { # local path -> int | ext | home | oth
  local p=$1 ph; ph=$(fm_phys "$p")
  if [[ $p == "$HOME" ]]; then echo home; return; fi
  if [[ $p == "$HOME/storage/shared" || $p == /sdcard || $p == /storage/emulated/0 || $ph == /storage/emulated/0 ]]; then echo int; return; fi
  case $p in "$HOME"/storage/external-*|/storage/*) echo ext; return ;; esac
  echo oth
}

# Builds the Storage Selection entries (ST_LABEL/ST_KIND/ST_VAL). Kind L = local root, R = remotes list,
# X = unavailable (selecting it explains why; nothing else is opened in its place).
fm_storage_scan() {
  ST_LABEL=(); ST_KIND=(); ST_VAL=(); ST_SEEN=()
  local_roots; load_remotes
  local grp i p ph label found e skip d reason
  local -a ext_phys=() order=() denied=()
  for grp in int ext home remotes oth; do
    if [[ $grp == remotes ]]; then
      if (( ${#REMOTES[@]} )); then ST_LABEL+=("Rclone Remotes (${#REMOTES[@]} configured)"); ST_KIND+=(R); ST_VAL+=("")
      else ST_LABEL+=("Rclone Remotes (none configured)"); ST_KIND+=(X)
           ST_VAL+=("No rclone remotes are configured. Use Remote Manager > New remote (rclone config) to add one."); fi
      continue
    fi
    order=("${!LOCAL_PATHS[@]}")
    if [[ $grp == ext ]]; then   # whole /storage/<id> volumes first, so app folders inside them are not listed twice
      order=(); for i in "${!LOCAL_PATHS[@]}"; do [[ ${LOCAL_PATHS[i]} == /storage/* ]] && order+=("$i"); done
      for i in "${!LOCAL_PATHS[@]}"; do [[ ${LOCAL_PATHS[i]} == /storage/* ]] || order+=("$i"); done
    fi
    found=0
    for i in "${order[@]}"; do
      p=${LOCAL_PATHS[i]}
      [[ $(st_class "$p") == "$grp" ]] || continue
      ph=$(fm_phys "$p"); [[ -n $ph ]] || ph=$p
      [[ -n ${ST_SEEN[$ph]:-} ]] && continue          # same physical directory under another name
      if [[ $grp == ext ]]; then
        skip=0; for e in "${ext_phys[@]}"; do [[ $ph == "$e"/* ]] && skip=1; done
        (( skip )) && continue
        ext_phys+=("$ph")
      fi
      ST_SEEN[$ph]=1; found=1
      case $grp in
        int) label="Internal Shared Storage - $p" ;; ext) label="SD Card / External Storage - $p" ;;
        home) label="Termux Home - $p" ;; *) label="Other location - $p" ;;
      esac
      ST_LABEL+=("$label"); ST_KIND+=(L); ST_VAL+=("$p")
    done
    (( found )) && continue
    case $grp in
      int)
        if [[ -e $HOME/storage/shared || -L $HOME/storage/shared ]]; then
          reason="Internal Shared Storage is not accessible: permission denied on $HOME/storage/shared. Re-run termux-setup-storage and allow storage access in Android settings."
        else
          reason="Internal Shared Storage is not available: $HOME/storage/shared does not exist. Run termux-setup-storage once and grant the permission."
        fi
        ST_LABEL+=("Internal Shared Storage (unavailable)"); ST_KIND+=(X); ST_VAL+=("$reason") ;;
      ext)
        denied=()
        for d in /storage/* "$HOME"/storage/external-*; do
          case $d in /storage/emulated|/storage/self) continue ;; esac
          if [[ -e $d || -L $d ]] && ! { [[ -d $d && -r $d && -x $d ]]; }; then denied+=("$d"); fi
        done
        if (( ${#denied[@]} )); then
          reason="SD Card / External Storage is not accessible: ${denied[*]}. Android denies Termux access to it; after termux-setup-storage the card's app folder appears as ~/storage/external-N."
        else
          reason="No SD card or external storage detected. After termux-setup-storage an inserted card appears as ~/storage/external-N."
        fi
        ST_LABEL+=("SD Card / External Storage (unavailable)"); ST_KIND+=(X); ST_VAL+=("$reason") ;;
      home)
        ST_LABEL+=("Termux Home (unavailable)"); ST_KIND+=(X); ST_VAL+=("Termux home is not accessible: $HOME") ;;
    esac
  done
  return 0
}

# explain: a long message wrapped to the screen width (a one-line status bar would cut it off on a phone)
explain() { # message [kind: info|ok|err]  (long message in its own boxed screen)
  SIMPLE_NOTE+="$(printf '%s' "$1" | tr '\n' ' ')"$'\n'; sclear; sbanner; snotes; pause_key
}

# Storage Selection: returns 1 when Back is pressed (leave the File Manager), 0 with FM_NEXT=browse|remotes
fm_home_menu() {
  local pos k v
  while true; do
    fm_storage_scan
    pos=$FM_HOME_POS; (( pos >= ${#ST_LABEL[@]} )) && pos=0
    MENU_START=$pos
    menu_choose "File Manager - Storage Selection" "${ST_LABEL[@]}"
    (( CHOICE )) || return 1
    FM_HOME_POS=$((CHOICE-1)); k=${ST_KIND[FM_HOME_POS]}; v=${ST_VAL[FM_HOME_POS]}
    case $k in
      L) if panel_goto "" "$v"; then P_ROOT[ACT]=$v; FM_NEXT=browse; return 0; fi
         ;;   # not opened: panel_goto already showed the full reason; stay on Storage Selection
      R) FM_NEXT=remotes; return 0 ;;
      X) explain "$v" ;;
    esac
  done
}

# Remotes list: Back returns to Storage Selection; choosing a remote opens its root
fm_remotes_menu() {
  local pos
  while true; do
    load_remotes
    if (( ${#REMOTES[@]} == 0 )); then notify "No rclone remotes are configured." err; FM_NEXT=home; return 0; fi
    pos=$FM_REMOTES_POS; (( pos >= ${#REMOTES[@]} )) && pos=0
    MENU_START=$pos
    menu_choose "File Manager - Rclone Remotes" "${REMOTES[@]/%/:}"
    if (( CHOICE == 0 )); then FM_NEXT=home; return 0; fi
    FM_REMOTES_POS=$((CHOICE-1))
    if panel_goto "${REMOTES[FM_REMOTES_POS]}" ""; then P_ROOT[ACT]=""; FM_NEXT=browse; return 0; fi
    # not opened: panel_goto already showed the full reason; stay on the remotes list
  done
}

# One level up. Folder -> parent folder; storage root -> Storage Selection; remote root -> remotes list.
# (Sets FM_EXIT instead of moving when a root is left.) Only for the real panels, never the destination picker.
fm_go_back() {
  local r=${P_REMOTE[ACT]} p=${P_PATH[ACT]} root=${P_ROOT[ACT]:-}
  p=${p%/}; root=${root%/}
  if [[ -z $r ]]; then
    if [[ -z $p || $p == "$root" ]]; then FM_EXIT=home; return 0; fi      # p empty == "/"
    panel_goto "" "$(parent_of "" "$p")"
  else
    if [[ -z $p ]]; then FM_EXIT=remotes; return 0; fi                      # remote root ("" or "/")
    panel_goto "$r" "$(parent_of "$r" "$p")"
  fi
}

file_manager() { # [remote] : always starts at Storage Selection (or, from Remote Manager, inside that remote)
  local state=home
  ACT=0; FM_EXIT=""
  if [[ -n ${1:-} ]]; then
    if panel_goto "$1" ""; then P_ROOT[ACT]=""; state=browse; else return 0; fi   # panel_goto explained the failure
  fi
  while true; do
    case $state in
      home)    fm_home_menu || return 0; state=$FM_NEXT ;;
      remotes) fm_remotes_menu; state=$FM_NEXT ;;
      browse)  FM_EXIT=""
               fm_simple
               state=${FM_EXIT:-home}; FM_EXIT="" ;;
    esac
  done
}


###############################################################################
# 11. SEARCH
###############################################################################
R_SIZE=(); R_TIME=(); R_PATH=(); declare -A RSEL=()

search_scope_spec() { fq "${P_REMOTE[ACT]}" "${P_PATH[ACT]}"; }

search_screen() {
  local spec; spec=$(search_scope_spec)
  sclear
  printf '%sSEARCH%s (recursive) in %s\nLeave a field empty to skip it. Patterns are rclone globs.\n' "$C_B" "$C_RST" "$(loc_str "$ACT")"
  local nm ext minsz maxsz newer older inc exc
  ask "Name contains: " && nm=$ANS || return
  ask "Extension (without dot, e.g. mp4): " && ext=$ANS || return
  ask "Min size (e.g. 100M): " && minsz=$ANS || return
  ask "Max size (e.g. 2G): " && maxsz=$ANS || return
  ask "Modified within last (e.g. 7d, 2w): " && newer=$ANS || return
  ask "Modified earlier than (e.g. 30d): " && older=$ANS || return
  ask "Extra include glob: " && inc=$ANS || return
  ask "Exclude glob: " && exc=$ANS || return
  local sz_re='^[0-9]+(\.[0-9]+)?[bBkKMGTP]?$' age_re='^[0-9]+(ms|[smhdwMy])?$'
  [[ -z $minsz || $minsz =~ $sz_re ]] || { notify "Bad min size" err; return; }
  [[ -z $maxsz || $maxsz =~ $sz_re ]] || { notify "Bad max size" err; return; }
  [[ -z $newer || $newer =~ $age_re ]] || { notify "Bad age" err; return; }
  [[ -z $older || $older =~ $age_re ]] || { notify "Bad age" err; return; }
  local -a fl=()
  has_flag - --ignore-case && fl+=(--ignore-case)
  [[ -n $exc ]] && fl+=("--exclude=$exc")
  if [[ -n $nm && -n $ext ]]; then fl+=("--include=*${nm}*.${ext}")
  elif [[ -n $nm ]]; then fl+=("--include=*${nm}*")
  elif [[ -n $ext ]]; then fl+=("--include=*.${ext}"); fi
  [[ -n $inc ]] && fl+=("--include=$inc")
  [[ -n $minsz ]] && fl+=(--min-size "$minsz"); [[ -n $maxsz ]] && fl+=(--max-size "$maxsz")
  [[ -n $newer ]] && fl+=(--max-age "$newer"); [[ -n $older ]] && fl+=(--min-age "$older")
  busy "Searching (Ctrl-C aborts)..."
  if ! rc_quiet lsjson -R --files-only --no-mimetype "${LIST_FLAGS[@]}" "${fl[@]}" "$spec"; then
    notify "Search failed: $LAST_ERR" err; auth_recover "$spec" "$LAST_ERR"; return; fi
  R_SIZE=(); R_TIME=(); R_PATH=(); RSEL=()
  local s t p
  while IFS=$'\037' read -r -d '' s t p; do R_SIZE+=("$s"); R_TIME+=("$t"); R_PATH+=("$p"); done < <(
    jq -j '.[] | [(.Size|tostring), ((.ModTime // "")[0:16] | sub("T";" ")), .Path] | join("\u001f"), "\u0000"' "$TMP_DIR/out")
  results_screen "$spec"
}

RPAGE=0
results_simple_draw() {
  sbox_init
  local n=${#R_PATH[@]} start=$((RPAGE*15)) end i name mark sz nw=$((S_W-2-19)) pages
  end=$((start+15)); (( end > n )) && end=$n; pages=$(( (n+14)/15 )); (( pages < 1 )) && pages=1
  sclear; sbanner; stitle "Search results: $n found, ${#RSEL[@]} selected"
  sbox_top "$C_CYN"
  (( n == 0 )) && sline "$C_CYN" "${C_DIM}(no matches)${C_RST}" 12
  for ((i=start; i<end; i++)); do
    name=${R_PATH[i]//[[:cntrl:]]/?}; (( ${#name} > nw+2 )) && name="…${name: -$((nw+1))}"
    if [[ -n ${RSEL[$i]:-} ]]; then mark="${C_B}${C_YEL}✔${C_RST}"; elif (( i == RCUR )); then mark="${C_DIM}›${C_RST}"; else mark=" "; fi
    sz=$(hsize "${R_SIZE[i]}")
    printf '%s│%s %s%3d%s %s %s %s%8s%s %s│%s\n' "$C_CYN" "$C_RST" "$C_B$C_GRN" $((i+1)) "$C_RST" "$mark" \
      "$(pad "$name" $((nw+2)))" "$C_DIM" "$sz" "$C_RST" "$C_CYN" "$C_RST"
  done
  sbox_bot "$C_CYN"
  printf '%s  page %d/%d · nothing selected = actions use item 1 (›), so select first with s N%s\n' "$C_DIM" $((RPAGE+1)) "$pages" "$C_RST"
  snotes
  slegend "s N select" "a select all" "i invert selection" "c copy selected" "m move selected" "d delete selected" "r rename selected" "x export list" "→ or + next page" "← or - prev page" "q back"; shint "$H_RESULTS"
}

results_files_list() { # selection (or cursor item) -> RS_IDX, RS_NL, RS_N and $TMP_DIR/sel.txt
  local i; RS_N=0; RS_NL=(); RS_IDX=(); : >"$TMP_DIR/sel.txt"
  (( ${#R_PATH[@]} )) || return 0     # nothing to select (also avoids an unbound-variable abort)
  if (( ${#RSEL[@]} )); then mapfile -t RS_IDX < <(printf '%s\n' "${!RSEL[@]}" | sort -n); else RS_IDX=("$RCUR"); fi
  for i in "${RS_IDX[@]}"; do
    # newline-containing paths cannot go into the newline-delimited list; they are handled separately
    if [[ ${R_PATH[i]} == *$'\n'* ]]; then RS_NL+=("${R_PATH[i]}"); continue; fi
    printf '%s\n' "${R_PATH[i]}" >>"$TMP_DIR/sel.txt"; RS_N=$((RS_N+1))
  done
}

results_screen() {
  local spec=$1 i n other=$((1-ACT)) k; RCUR=0; RTOP=0; RPAGE=0
  while true; do
    n=${#R_PATH[@]}
    results_simple_draw
    if true; then
      read_cmd "${C_B}${C_CYN} ❯ ${C_RST}" 0 "" 1; ans=$ANS_LINE
      k=${ans%% *}
      case $k in
        s) arg=${ans#* }; if parse_num_list "$arg" "$n"; then for i in "${PNUMS[@]}"; do RSEL[$((i-1))]=1; done; fi; continue ;;
        +) (( (RPAGE+1)*15 < n )) && RPAGE=$((RPAGE+1)); continue ;;
        -) (( RPAGE > 0 )) && RPAGE=$((RPAGE-1)); continue ;;
      esac
    fi
    case $k in
      UP) (( RCUR > 0 )) && RCUR=$((RCUR-1)) ;;
      DOWN) (( RCUR < n-1 )) && RCUR=$((RCUR+1)) ;;
      PGUP) RCUR=$((RCUR-10)); (( RCUR < 0 )) && RCUR=0 ;;
      PGDN) RCUR=$((RCUR+10)); (( RCUR > n-1 )) && RCUR=$((n-1)) ;;
      SPACE) if [[ -n ${RSEL[$RCUR]:-} ]]; then unset 'RSEL[$RCUR]'; else RSEL[$RCUR]=1; fi; (( RCUR < n-1 )) && RCUR=$((RCUR+1)) ;;
      a) for ((i=0; i<n; i++)); do RSEL[$i]=1; done ;;
      i) for ((i=0; i<n; i++)); do if [[ -n ${RSEL[$i]:-} ]]; then unset 'RSEL[$i]'; else RSEL[$i]=1; fi; done ;;
      c|m)
        (( n )) || continue
        local mode=copy; [[ $k == m ]] && mode=move
        local dr dp
        results_files_list
        (( RS_N + ${#RS_NL[@]} )) || { notify "Nothing selected" err; continue; }
        pick_destination "$mode" "$other" "$(loc_str "$ACT") (search results)" || { notify "Destination selection cancelled - no job created" ok; continue; }
        dr=$DEST_R; dp=$DEST_P
        if [[ ${P_REMOTE[ACT]} == "$dr" && ${P_PATH[ACT]} == "$dp" ]]; then notify "Destination is the search location itself" err; continue; fi
        transfer_options_dialog || continue
        confirm "$mode $((RS_N + ${#RS_NL[@]})) file(s) from $(fq "${P_REMOTE[ACT]}" "${P_PATH[ACT]}") to $(fq "$dr" "$dp") keeping relative paths?" || continue
        [[ $mode == move ]] && maybe_dryrun_first
        build_flags "$mode"
        local -a created=()
        if (( RS_N )); then
          JOB_LIST_TMP="$TMP_DIR/sel.txt"
          job_create "search $mode $RS_N file(s)" "$mode" "$spec" "$(fq "$dr" "$dp")" \
            "$mode" "$spec" "$(fq "$dr" "$dp")" --files-from-raw @LIST@ "${XFLAGS[@]}" && created+=("$JOB_ID")
          JOB_LIST_TMP=""
        fi
        if (( ${#RS_NL[@]} )); then queue_nl_jobs "$mode" "${P_REMOTE[ACT]}" "${P_PATH[ACT]}" "$dr" "$dp" "${RS_NL[@]}"; fi
        jobs_after_create "${created[@]}" ;;
      d)
        (( n )) || continue
        results_files_list
        sclear; printf '%sDELETE %d file(s)%s found by search in %s\n' "$C_RED" "${#RS_IDX[@]}" "$C_RST" "$(loc_str "$ACT")"
        confirm_typed "Delete these files" DELETE || { notify "Cancelled" ok; continue; }
        local ok=0 fail=0 p
        for i in "${RS_IDX[@]}"; do
          p=${R_PATH[i]}
          if rc_quiet deletefile "$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "$p")")"; then ok=$((ok+1)); log_msg INFO "deleted (search) $p"; else fail=$((fail+1)); fi
        done
        notify "Deleted $ok, failed $fail (re-run the search to refresh)" $([[ $fail -eq 0 ]] && echo ok || echo err) ;;
      r) batch_rename_results ;;
      x)
        results_files_list
        (( ${#RS_IDX[@]} )) || { notify "Nothing to export" err; continue; }
        local out base; base="$EXPORT_DIR/search-$(date +%Y%m%d-%H%M%S)"; out="$base.txt"
        cp -- "$TMP_DIR/sel.txt" "$out" || { notify "Export failed" err; continue; }
        if (( ${#RS_NL[@]} )); then   # names with newlines only fit a NUL-delimited list
          for i in "${RS_IDX[@]}"; do printf '%s\0' "${R_PATH[i]}"; done >"$base.nul"
          notify "Exported $RS_N path(s) to $out; ${#RS_NL[@]} name(s) with newlines are only in $base.nul (NUL-delimited)" ok
        else notify "Exported $RS_N path(s) to $out" ok; fi
        export_offer_move "$out" "$base.nul" ;;
      q|Q|ESC) return ;;
    esac
  done
}

batch_rename_results() {
  results_files_list; (( ${#RS_IDX[@]} )) || { notify "Nothing selected" err; return; }
  ask "Text to replace in file names: " || return; local from=$ANS
  [[ -n $from ]] || return
  ask "Replace with: " || return; local to=$ANS
  [[ $to != */* ]] || { notify "Replacement may not contain '/'" err; return; }
  local -a olds=() news=(); local i p dir base nb
  for i in "${RS_IDX[@]}"; do
    p=${R_PATH[i]}   # names are passed as arguments, so newlines in old names are safe here
    base=${p##*/}; dir=""; [[ $p == */* ]] && dir=${p%/*}
    nb=${base//"$from"/"$to"}
    valid_name "$nb" || continue
    [[ $nb == "$base" ]] && continue
    olds+=("$p"); news+=("$(join_path "$dir" "$nb")")
  done
  (( ${#olds[@]} )) || { notify "No file name would change" err; return; }
  sclear; printf 'Rename preview (%d file(s)):\n' "${#olds[@]}"
  for ((i=0; i<${#olds[@]} && i<10; i++)); do printf '  %s\n  -> %s\n' "${olds[i]//[[:cntrl:]]/?}" "${news[i]//[[:cntrl:]]/?}"; done
  confirm "Apply renames (existing targets are skipped)?" || return
  local ok=0 skip=0 fail=0 s d
  for ((i=0; i<${#olds[@]}; i++)); do
    s=$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "${olds[i]}")")
    d=$(fq "${P_REMOTE[ACT]}" "$(join_path "${P_PATH[ACT]}" "${news[i]}")")
    if path_exists "$d"; then skip=$((skip+1)); continue; fi
    if rc_quiet moveto "$s" "$d"; then ok=$((ok+1)); log_msg INFO "rename $s -> $d"; else fail=$((fail+1)); fi
  done
  notify "Renamed $ok, skipped (target exists) $skip, failed $fail. Re-run the search to refresh." ok
}

###############################################################################
# 12. BATCH OPERATIONS
###############################################################################
# Browse with the file manager (reuses the destination browser: open folders, then "s" = USE THIS FOLDER).
pick_browse() { # prompt -> PICKED_SPEC. 0 = a folder was chosen, 1 = cancelled
  local rc=1 c
  PICK_SRC=$1; PICKED_SPEC=""
  dest_state_save
  P_REMOTE[2]=""; P_PATH[2]=$HOME   # placeholder; only used after a location has loaded successfully
  while true; do
    ACT=$SV_ACT
    menu_choose "$1" "Browse local storage" "Browse a remote" "Cancel"
    c=$CHOICE
    case $c in
      1|2) ACT=2
         if pick_location "$([[ $c == 1 ]] && echo L || echo R)"; then
           if dest_browse; then PICKED_SPEC=$(fq "$DEST_R" "$DEST_P"); rc=0; break; fi
         fi ;;
      3|0) break ;;
    esac
  done
  dest_state_restore
  return $rc
}

# Local-folder variant of pick_browse: browse local storage only. 0 = chosen (PICKED_LOCAL_DIR).
pick_local_dir() { # prompt
  local rc=1
  PICK_SRC=$1; PICKED_LOCAL_DIR=""
  dest_state_save
  P_REMOTE[2]=""; P_PATH[2]=$HOME
  ACT=2
  if pick_location L && dest_browse && [[ -z $DEST_R ]]; then PICKED_LOCAL_DIR=$DEST_P; rc=0; fi
  dest_state_restore
  return $rc
}

same_file() { # byte-for-byte when cmp exists, else same size
  if command -v cmp >/dev/null 2>&1; then cmp -s -- "$1" "$2"; else [[ $(wc -c <"$1") == "$(wc -c <"$2")" ]]; fi
}

# Offer to move finished export file(s) out of the exports folder into local storage.
# Copies, checks every copy is identical, and only then deletes the originals from exports.
# 0 = moved, 1 = kept in exports (cancelled or failed).
export_offer_move() { # file...
  local -a files=(); local f
  for f in "$@"; do [[ -f $f ]] && files+=("$f"); done
  (( ${#files[@]} )) || return 1
  local name=${files[0]##*/} dl=$HOME/storage/shared/Download destdir=""
  local -a opts=() kinds=()
  if [[ -d $dl && -w $dl ]]; then opts+=("Phone Download folder, then remove from exports"); kinds+=(dl); fi
  opts+=("Browse local storage, then remove from exports" "Keep in exports folder only"); kinds+=(browse keep)
  while true; do
    menu_choose "Copy $name to local storage?" "${opts[@]}"
    (( CHOICE )) || return 1
    case ${kinds[CHOICE-1]} in
      dl) destdir=$dl; break ;;
      browse) if pick_local_dir "Save $name to"; then destdir=$PICKED_LOCAL_DIR; break; fi ;;
      keep) return 1 ;;
    esac
  done
  if [[ ! -d $destdir || ! -w $destdir ]]; then notify "Not writable: $destdir (check Android storage permission)" err; return 1; fi
  if [[ $(fm_phys "$destdir") == "$(fm_phys "$EXPORT_DIR")" ]]; then notify "That is the exports folder itself - nothing moved" err; return 1; fi
  local -a made=(); local t b
  for f in "${files[@]}"; do
    b=${f##*/}; t="$destdir/$b"
    [[ -e $t ]] && t="$destdir/${b%.*}-$(date +%H%M%S).${b##*.}"
    if cp -- "$f" "$t" && same_file "$f" "$t"; then made+=("$t")
    else
      rm -f -- "$t" "${made[@]}" 2>/dev/null
      notify "Copy to $destdir failed - file kept in exports" err; return 1
    fi
  done
  for f in "${files[@]}"; do rm -f -- "$f" || { notify "Copied, but could not delete $f from exports" err; return 0; }; done
  notify "Saved to $destdir/${made[0]##*/} (removed from exports)" ok
  return 0
}

pick_spec() { # prompt [browse] -> PICKED_SPEC (empty on cancel). "browse" adds a file-manager option.
  PICKED_SPEC=""
  local c
  if [[ ${2:-} == browse ]]; then
    menu_choose "$1" "Panel A: $(loc_str 0)" "Panel B: $(loc_str 1)" "Browse folders (file manager)" "Type a path (remote:path or /local/path)"
    c=$CHOICE
    if (( c == 3 )); then pick_browse "$1"; return; fi
    (( c == 4 )) && c=3
  else
    menu_choose "$1" "Panel A: $(loc_str 0)" "Panel B: $(loc_str 1)" "Type a path (remote:path or /local/path)"
    c=$CHOICE
  fi
  case $c in
    1) PICKED_SPEC=$(fq "${P_REMOTE[0]}" "${P_PATH[0]}") ;;
    2) PICKED_SPEC=$(fq "${P_REMOTE[1]}" "${P_PATH[1]}") ;;
    3) if ask "Path: "; then
         if [[ $ANS == -* ]]; then notify "A path may not start with '-' (write ./name)" err; else PICKED_SPEC=$ANS; fi
       fi ;;
  esac
  [[ -n $PICKED_SPEC ]]
}

batch_manifest() {
  pick_spec "Manifest of which location?" browse || return
  local out="$EXPORT_DIR/manifest-$(date +%Y%m%d-%H%M%S).tsv"
  busy "Listing recursively (Ctrl-C aborts)..."
  if ! rc_quiet lsjson -R --files-only --no-mimetype "${LIST_FLAGS[@]}" "$PICKED_SPEC"; then notify "Failed: $LAST_ERR" err; auth_recover "$PICKED_SPEC" "$LAST_ERR"; return; fi
  jq -r '.[] | [.Size, ((.ModTime // "")[0:19]), .Path] | @tsv' "$TMP_DIR/out" >"$out" || { notify "Could not write $out" err; return; }
  notify "Manifest ($(jq length "$TMP_DIR/out") files, $(hsize "$(jq '[.[].Size]|add // 0' "$TMP_DIR/out")")) saved: $out" ok
  export_offer_move "$out"
}

batch_compare() { # compare | verify
  local kind=$1 src dst
  pick_spec "SOURCE" browse || return; src=$PICKED_SPEC
  pick_spec "DESTINATION" browse || return; dst=$PICKED_SPEC
  local -a fl=(--combined "$TMP_DIR/combined.txt")
  [[ $kind == verify ]] && fl+=(--one-way)
  if confirm "Byte-for-byte comparison by downloading both sides? (slow, uses data)"; then fl+=(--download); fi
  : >"$TMP_DIR/combined.txt"
  busy "Comparing (Ctrl-C aborts)..."
  rc_quiet check "$src" "$dst" "${fl[@]}"; local rc=$?
  local same diff miss_dst miss_src err
  same=$(grep -c '^= ' "$TMP_DIR/combined.txt"); diff=$(grep -c '^\* ' "$TMP_DIR/combined.txt")
  miss_dst=$(grep -c '^- ' "$TMP_DIR/combined.txt"); miss_src=$(grep -c '^+ ' "$TMP_DIR/combined.txt")
  err=$(grep -c '^! ' "$TMP_DIR/combined.txt")
  { printf 'Source: %s\nDest  : %s\nrclone check exit code: %s (1 = differences found)\n\n' "$src" "$dst" "$rc"
    printf 'identical: %s\ndiffer: %s\nmissing on destination: %s\nmissing on source (extra at dest): %s\nerrors: %s\n\n' "$same" "$diff" "$miss_dst" "$miss_src" "$err"
    printf 'Non-identical entries (= identical lines omitted):\n'
    grep -v '^= ' "$TMP_DIR/combined.txt" | head -n 500
    [[ -n $LAST_ERR ]] && printf '\nrclone said:\n%s\n' "$LAST_ERR"
    printf '\nNote: without a hash common to both backends rclone compares sizes only.\n'
  } >"$TMP_DIR/cmp.txt"
  page_file "$TMP_DIR/cmp.txt"
}

batch_duplicates() {
  pick_spec "Find duplicate candidates in" browse || return
  local fl=(); local hashes=0
  if confirm "Include checksums (stronger evidence, but can be slow on big local trees)?"; then fl+=(--hash); hashes=1; fi
  busy "Scanning recursively (Ctrl-C aborts)..."
  if ! rc_quiet lsjson -R --files-only --no-mimetype "${LIST_FLAGS[@]}" "${fl[@]}" "$PICKED_SPEC"; then notify "Failed: $LAST_ERR" err; auth_recover "$PICKED_SPEC" "$LAST_ERR"; return; fi
  jq -r 'def grp(f): group_by(f) | map(select(length > 1));
    [ .[] | {p: .Path, n: .Name, s: .Size, h: ((.Hashes // {}) | to_entries | map("\(.key):\(.value)") | sort | join(","))} ] as $a
    | "## 1. Matching size AND checksum (strong candidates - still verify before deleting)",
      ( [ $a[] | select(.h != "" and .s > 0) ] | grp([.s, .h]) | .[] | "-- \(.[0].s) bytes", (.[] | "     \(.p)") ),
      "", "## 2. Same size only (weak candidates, contents NOT compared)",
      ( [ $a[] | select(.s > 0) ] | grp(.s) | .[] | "-- \(.[0].s) bytes", (.[] | "     \(.p)") ),
      "", "## 3. Same file name in different folders",
      ( $a | grp(.n) | .[] | "-- \(.[0].n)", (.[] | "     \(.p)") )' "$TMP_DIR/out" >"$TMP_DIR/dups.txt" 2>/dev/null
  { printf 'Duplicate CANDIDATES in %s\nNothing is deleted automatically. A matching checksum is strong evidence,\nbut only a byte-for-byte compare (Batch > Compare, byte-for-byte) confirms identity.\n' "$PICKED_SPEC"
    (( hashes )) || printf 'Checksums were not requested, so section 1 is empty.\n'
    printf '\n'; cat "$TMP_DIR/dups.txt"; } >"$TMP_DIR/dups.full.txt"
  if confirm "Also save this report to a file?"; then
    local rep="$EXPORT_DIR/duplicates-$(date +%Y%m%d-%H%M%S).txt"
    if cp -- "$TMP_DIR/dups.full.txt" "$rep"; then notify "Saved to $rep" ok; export_offer_move "$rep"
    else notify "Could not save $rep" err; fi
  fi
  page_file "$TMP_DIR/dups.full.txt"
}

# Sizes every sub-folder directly under a location and lists them largest first.
# Ctrl-C while sizing stops early and shows what was measured so far.
batch_foldersizes() {
  pick_spec "Folder sizes of which location?" browse || return
  local spec=$PICKED_SPEC base=$PICKED_SPEC
  [[ $base == *: || $base == */ ]] || base+="/"
  busy "Listing folders in $spec ..."
  if ! rc_quiet lsjson --no-mimetype --no-modtime "${LIST_FLAGS[@]}" "$spec"; then
    notify "Failed: $LAST_ERR" err; auth_recover "$spec" "$LAST_ERR"; return
  fi
  local -a dirs=(); local d
  while IFS= read -r -d '' d; do dirs+=("$d"); done < <(jq -j '.[] | select(.IsDir) | .Path + "\u0000"' "$TMP_DIR/out")
  local loose_b loose_n
  loose_b=$(jq '[.[] | select(.IsDir | not) | .Size] | add // 0' "$TMP_DIR/out")
  loose_n=$(jq '[.[] | select(.IsDir | not)] | length' "$TMP_DIR/out")
  local n=${#dirs[@]}
  (( n )) || { notify "No sub-folders in $spec" err; return; }

  local rows="$TMP_DIR/fs.rows" i=0 failed=0 ABORT=0 sz nm
  : >"$rows"
  trap 'ABORT=1' INT
  for d in "${dirs[@]}"; do
    i=$((i+1)); nm=${d//[[:cntrl:]]/?}
    if [[ -t 1 ]]; then printf '\r%s[%d/%d] %s%s\e[K' "$C_DIM" "$i" "$n" "$(midfit "$nm" $((S_W-12)))" "$C_RST"; fi
    if rclone size --json "${LIST_FLAGS[@]}" "$base$d" >"$TMP_DIR/sz.json" 2>"$TMP_DIR/err" \
       && sz=$(jq -r '[.bytes, .count] | @tsv' "$TMP_DIR/sz.json" 2>/dev/null) && [[ -n $sz ]]; then
      printf '%s\t%s\n' "$sz" "$nm" >>"$rows"
    else
      (( ABORT )) && break
      failed=$((failed+1)); printf -- '-1\t0\t%s\n' "$nm" >>"$rows"
    fi
    (( ABORT )) && break
  done
  trap 'exit 130' INT
  if [[ -t 1 ]]; then printf '\r\e[K'; fi
  local measured; measured=$(wc -l <"$rows")
  if (( loose_n > 0 )); then printf '%s\t%s\t%s\n' "$loose_b" "$loose_n" "(files directly in this folder)" >>"$rows"; fi

  local -a B=() C=() N=(); local b c total=0
  while IFS=$'\t' read -r b c nm; do
    B+=("$b"); C+=("$c"); N+=("$nm"); (( b > 0 )) && total=$((total+b))
  done < <(sort -t $'\t' -k1,1nr "$rows")

  local out="$TMP_DIR/fs.txt" pct line
  {
    printf 'Folder sizes, largest first\nLocation: %s\nDate: %s\n\n' "$spec" "$(date '+%F %T')"
    for i in "${!B[@]}"; do
      if (( B[i] < 0 )); then printf '%9s  %-6s %-13s %s\n' '?' '' '' "${N[i]}  (could not be sized)"; continue; fi
      pct=$(( total > 0 ? B[i] * 1000 / total : 0 ))
      printf -v line '%d.%d%%' $((pct/10)) $((pct%10))
      printf '%9s  %-6s %-13s %s\n' "$(hsize "${B[i]}")" "$line" "${C[i]} files" "${N[i]}"
    done
    printf '\nTotal: %s in %d folder(s)' "$(hsize "$total")" "$n"
    (( loose_n > 0 )) && printf ' plus %d loose file(s)' "$loose_n"
    printf '\n'
    (( failed )) && printf '%d folder(s) could not be sized (permissions, network or rate limit).\n' "$failed"
    (( ABORT )) && printf 'STOPPED EARLY: only %d of %d folders were measured.\n' "$measured" "$n"
  } >"$out"
  (( ABORT )) && notify "Stopped early: partial list shown" err
  page_file "$out"

  confirm "Save this list as a .txt file?" Y || return
  local tag=${spec//[^A-Za-z0-9._-]/_}; tag=${tag:0:40}
  local dest="$EXPORT_DIR/foldersizes-$tag-$(date +%Y%m%d-%H%M%S).txt"
  if cp -- "$out" "$dest"; then notify "Saved: $dest" ok; else notify "Could not save $dest" err; return; fi
  export_offer_move "$dest"
}

batch_menu() {
  while true; do
    menu_choose "Batch Operations" \
      "Selected files / extension groups -> use Search (copy/move/delete/rename/export)" \
      "Copy / move / sync an entire directory tree (panel A -> B)" \
      "Generate manifest (size, mtime, path) of a location" \
      "Compare two directories" "Verify copied files (source -> destination)" \
      "Find duplicate candidates (report only)" "Folder sizes, largest first (view / save .txt)" "Back"
    case $CHOICE in
      1) search_screen ;; 2) new_transfer_dirs ;; 3) batch_manifest ;;
      4) batch_compare compare ;; 5) batch_compare verify ;; 6) batch_duplicates ;;
      7) batch_foldersizes ;;
      8|0) return ;;
    esac
  done
}

###############################################################################
# 13. TRANSFER MANAGER, REMOTES, STORAGE, LOGS, SETTINGS, HELP
###############################################################################
transfer_manager() {
  while true; do
    menu_choose "Transfer Manager  (running: $(count_running), mode: $QUEUE_MODE)" \
      "New directory transfer (copy / move / sync, panel A <-> B)" "Jobs: monitor, cancel, pause, retry, logs" \
      "Start all queued jobs" "Wake lock: acquire (keeps CPU awake)" "Wake lock: release" "Back"
    case $CHOICE in
      1) new_transfer_dirs ;; 2) jobs_screen ;; 3) startable_ids ;;
      4) if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock && WAKE_HELD=1 && notify "Wake lock held" ok
         else notify "termux-wake-lock not found (pkg install termux-tools)" err; fi ;;
      5) command -v termux-wake-unlock >/dev/null 2>&1 && termux-wake-unlock && WAKE_HELD=0 && notify "Wake lock released" ok ;;
      6|0) return ;;
    esac
  done
}

remote_pick() { # -> PICKED_REMOTE
  load_remotes; PICKED_REMOTE=""
  (( ${#REMOTES[@]} )) || { notify "No remotes configured (use New remote)" err; return 1; }
  menu_choose "Choose remote" "${REMOTES[@]/%/:}"
  (( CHOICE )) || return 1
  PICKED_REMOTE=${REMOTES[CHOICE-1]}
}

test_remote() { # name -> tests the remote; offers "rclone config reconnect" when the token is bad
  local r=$1
  busy "Testing $r: ..."
  if rc_quiet lsd "$r:" --contimeout 15s --timeout 30s --retries 1; then
    notify "$r: OK (reachable, listing works)" ok; return 0
  fi
  notify "$r: FAILED - $LAST_ERR" err
  if offer_reconnect "$r" "$LAST_ERR"; then
    busy "Re-testing $r: ..."
    if rc_quiet lsd "$r:" --contimeout 15s --timeout 30s --retries 1; then
      notify "$r: OK after reconnect" ok; return 0
    fi
    notify "$r: still FAILED - $LAST_ERR" err
  fi
  return 1
}

remote_manager() {
  while true; do
    load_remotes
    menu_choose "Remote Manager  (${#REMOTES[@]} configured)" \
      "List remotes and types" "Test connectivity" "Browse a remote in the file manager" \
      "New remote (rclone config wizard)" "Edit / rename a remote (wizard: choose e / r)" \
      "Delete a remote" "Remote features (rclone backend features)" \
      "rclone version and update check" "Diagnostics" "Copy remote config as base64 (for bot / Render)" "Back"
    case $CHOICE in
      1) rclone listremotes --long 2>&1 | sanitize >"$TMP_DIR/rl.txt"; page_file "$TMP_DIR/rl.txt" ;;
      2) remote_pick && test_remote "$PICKED_REMOTE" ;;
      3) remote_pick && file_manager "$PICKED_REMOTE" ;;
      4|5) run_screen rclone config ; load_remotes ;;
      6) remote_pick && { sclear; printf '%sDelete remote configuration "%s"%s\nThis only removes the config entry, not data on the remote.\n' "$C_RED" "$PICKED_REMOTE" "$C_RST"
           if confirm_typed "Delete remote" "$PICKED_REMOTE"; then rc_quiet config delete "$PICKED_REMOTE" && notify "Deleted $PICKED_REMOTE" ok || notify "Failed: $LAST_ERR" err; fi; } ;;
      7) remote_pick && { rclone backend features "$PICKED_REMOTE:" 2>&1 | sanitize >"$TMP_DIR/feat.txt"; page_file "$TMP_DIR/feat.txt"
           offer_reconnect "$PICKED_REMOTE" "$(<"$TMP_DIR/feat.txt")"; } ;;
      8) { rclone version; echo; echo "Update check (needs network):"; rclone version --check 2>&1; } 2>&1 | sanitize >"$TMP_DIR/ver.txt"; page_file "$TMP_DIR/ver.txt" ;;
      9) diagnostics ;;
      10) remote_b64_copy ;;
      11|0) return ;;
    esac
  done
}

# Copies ONE remote's config, base64-encoded, to the Android clipboard (for RCLONE_CONF_B64 on Render etc.).
# Fixed export: reads the real config file and cuts that remote's section out of it, so the password
# stays in its stored (obscured) form. "rclone config show" is NOT used: it prints passwords readable,
# and rclone then rejects them ("failed to decode password - did you obscure it?").
# Temp files live in the private temp dir and are always deleted.
remote_b64_copy() {
  command -v termux-clipboard-set >/dev/null 2>&1 || { notify "termux-clipboard-set not found: pkg install termux-api, and install the Termux:API app" err; return 1; }
  command -v base64 >/dev/null 2>&1 || { notify "base64 not found: pkg install coreutils" err; return 1; }
  remote_pick || return 1
  local name=$PICKED_REMOTE cfg conf="$TMP_DIR/bot.conf" tconf="$TMP_DIR/bot.test.conf"
  local b64="" sum="" line k v bad=0 target=""
  cfg=$(rclone config file 2>/dev/null | tail -n 1)
  if [[ -z $cfg || ! -r $cfg ]]; then notify "Cannot read rclone's config file (${cfg:-path unknown})" err; return 1; fi
  IFS= read -r line <"$cfg"
  if [[ $line == RCLONE_ENCRYPT_V0* ]]; then
    notify "Your rclone config is password-encrypted, so one remote cannot be cut out of it. Remove the config password first (rclone config, then s), then try again." err
    return 1
  fi
  awk -v sec="[$name]" '{ sub(/\r$/, "") } /^\[/ { p = ($0 == sec) } p' "$cfg" >"$conf"
  if [[ ! -s $conf ]]; then notify "Remote \"$name\" was not found in $cfg" err; rm -f -- "$conf"; return 1; fi

  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^([A-Za-z0-9_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    k=${BASH_REMATCH[1]}; v=${BASH_REMATCH[2]}
    case $k in
      remote) [[ $v == *:* ]] && target=${v%%:*} ;;
      pass|password|password2) [[ -n $v && ! $v =~ ^[A-Za-z0-9_-]{22,}$ ]] && bad=1 ;;
    esac
  done <"$conf"

  if (( bad )); then
    notify "The password saved for \"$name\" is not in rclone's obscured format, so rclone itself would reject it. Re-enter it with rclone config (edit remote)." err
    confirm "Copy it anyway?" N || { rm -f -- "$conf"; return 1; }
  fi
  if [[ -n $target && $target != "$name" ]]; then
    notify "Note: \"$name\" points at remote \"$target\". The bot also needs the config of \"$target\"." ok
  fi

  # Test on a copy (rclone may rewrite the file while refreshing a token); the original is what gets exported.
  cp -- "$conf" "$tconf"
  busy "Testing $name: with only the exported settings..."
  if rc_quiet --config "$tconf" --ask-password=false lsd "$name:" --contimeout 15s --timeout 30s --retries 1; then
    notify "Test OK: $name: works from the exported settings alone" ok
  else
    notify "Test FAILED: $LAST_ERR" err
    confirm "Copy it anyway?" N || { rm -f -- "$conf" "$tconf"; return 1; }
  fi
  rm -f -- "$tconf"

  b64=$(base64 -w 0 "$conf")
  rm -f -- "$conf"
  command -v sha256sum >/dev/null 2>&1 && sum=$(printf '%s' "$b64" | sha256sum | cut -c1-8)
  if printf '%s' "$b64" | timeout 10 termux-clipboard-set >/dev/null 2>&1; then
    notify "Copied $name to the clipboard (${#b64} chars${sum:+, check $sum}). Paste it into RCLONE_CONF_B64. It contains your login: keep it private." ok
  else
    notify "Clipboard copy failed: install the Termux:API app and open it once" err
  fi
  b64=""
}

diagnostics() {
  {
    echo "rclone : $(rclone version 2>&1 | head -n 1)"
    echo "config : $(rclone config file 2>&1 | tail -n 1)   (contents are never displayed)"
    echo "remotes: ${#REMOTES[@]}"
    echo "bash   : $BASH_VERSION    jq: $(jq --version 2>&1)"
    echo "app dir: $APP_DIR"
    echo "shared storage link: $([[ -d $HOME/storage/shared ]] && echo present || echo 'MISSING - run termux-setup-storage')"
    echo "termux-open: $(command -v termux-open || echo no)   clipboard: $(command -v termux-clipboard-set || echo no)"
    echo "less: $(command -v less || echo no)   ffprobe: $(command -v ffprobe || echo no)"
    echo "wake lock tool: $(command -v termux-wake-lock || echo no)"
    echo "notifications: termux-notification $(command -v termux-notification >/dev/null 2>&1 && echo present || echo 'MISSING (pkg install termux-api + Termux:API app)'), enabled=$NOTIFY, live-error alerts=$NOTIFY_LIVE"
    echo "Running jobs: $(count_running)"
  } >"$TMP_DIR/diag.txt"
  page_file "$TMP_DIR/diag.txt"
}

storage_info() {
  {
    echo "== Local storage (df) =="
    local_roots
    local i; for i in "${!LOCAL_PATHS[@]}"; do printf '\n%s\n' "${LOCAL_LABELS[i]}: ${LOCAL_PATHS[i]}"; df -h -- "${LOCAL_PATHS[i]}" 2>&1 | tail -n 1; done
  } >"$TMP_DIR/stor.txt"
  page_file "$TMP_DIR/stor.txt"
  if confirm "Query quota of a remote (rclone about)?"; then
    remote_pick || return
    if rc_quiet about "$PICKED_REMOTE:"; then sanitize <"$TMP_DIR/out" >"$TMP_DIR/about.txt"; page_file "$TMP_DIR/about.txt"
    else notify "$PICKED_REMOTE: quota not available ($LAST_ERR)" err; offer_reconnect "$PICKED_REMOTE" "$LAST_ERR"; fi
  fi
}

history_view() {
  [[ -s $HISTORY_TSV ]] || { notify "History is empty" ok; return; }
  local f="$TMP_DIR/h.txt" id st label src dst bytes files errs start when
  : >"$f"
  # tabs -> \037 so empty fields in old history lines cannot shift columns
  while IFS=$'\037' read -r id st label src dst bytes files errs start; do
    when=$(date -d "@${start:-0}" '+%F %H:%M' 2>/dev/null) || when=$id
    printf '%s  %-11s files:%s errors:%s bytes:%s\n    %s\n    %s -> %s\n' "$when" "$st" "${files:--}" "${errs:--}" "${bytes:--}" "$label" "$src" "$dst" >>"$f"
  done < <(rev_lines <"$HISTORY_TSV" | tr '\t' '\037')
  page_file "$f"
}

logs_menu() {
  while true; do
    menu_choose "Logs and History" "Transfer history (newest first)" "Job list / job logs" \
      "Application / error log" "Clear transfer history" "Clear application log" "Back"
    case $CHOICE in
      1) history_view ;;
      2) jobs_screen ;;
      3) if [[ -s $APP_LOG ]]; then tail -n 300 "$APP_LOG" >"$TMP_DIR/l.txt"; page_file "$TMP_DIR/l.txt"; else notify "Log is empty" ok; fi ;;
      4) if confirm_typed "Delete ALL finished-job history and logs (active jobs are kept)" CLEAR; then
           rm -rf -- "${HIST_DIR:?}"/* ; : >"$HISTORY_TSV"; notify "History cleared" ok; fi ;;
      5) confirm "Clear the application log?" && { : >"$APP_LOG"; rm -f "$APP_LOG.1"; notify "Log cleared" ok; } ;;
      6|0) return ;;
    esac
  done
}

settings_menu() {
  local pos=0
  while true; do
    MENU_START=$pos
    menu_choose "Settings (saved to $SETTINGS_FILE)" \
      "Transfers: $TRANSFERS" "Checkers: $CHECKERS" "Bandwidth limit: ${BWLIMIT:-none}" "Retries: $RETRIES" \
      "Existing files default: $EXISTING" "Checksum compare default: $(yn $CHECKSUM)" "Show hidden files: $(yn $SHOW_HIDDEN)" \
      "Sort key: $SORT_KEY" "Sort reversed: $(yn $SORT_REV)" "Queue mode: $QUEUE_MODE" "Max log size (bytes): $LOG_MAX_BYTES" \
      "Create empty dirs default: $(yn $EMPTY_DIRS)" \
      "Offer dry run before move/sync: $(yn $DRYRUN_FIRST)" "Auto re-run on corrupted transfer: $AUTO_RETRIES extra attempt(s)" \
      "Notifications (termux-api): $(yn $NOTIFY)" "Alert when a running job first reports errors: $(yn $NOTIFY_LIVE)" "Send test notification" \
      "Reset to defaults" "Back"
    pos=$((CHOICE-1))
    local k=""
    case $CHOICE in
      1) k=TRANSFERS ;; 2) k=CHECKERS ;; 3) k=BWLIMIT ;; 4) k=RETRIES ;; 11) k=LOG_MAX_BYTES ;; 14) k=AUTO_RETRIES ;;
      5) case $EXISTING in skip) EXISTING=overwrite ;; overwrite) EXISTING=newer ;; *) EXISTING=skip ;; esac ;;
      6) CHECKSUM=$((1-CHECKSUM)) ;; 7) SHOW_HIDDEN=$((1-SHOW_HIDDEN)) ;;
      8) case $SORT_KEY in name) SORT_KEY=size ;; size) SORT_KEY=time ;; *) SORT_KEY=name ;; esac ;;
      9) SORT_REV=$((1-SORT_REV)) ;;
      10) [[ $QUEUE_MODE == sequential ]] && QUEUE_MODE=concurrent || QUEUE_MODE=sequential ;;
      12) EMPTY_DIRS=$((1-EMPTY_DIRS)) ;; 13) DRYRUN_FIRST=$((1-DRYRUN_FIRST)) ;;
      15) NOTIFY=$((1-NOTIFY)) ;; 16) NOTIFY_LIVE=$((1-NOTIFY_LIVE)) ;;
      17) if ! command -v termux-notification >/dev/null 2>&1; then notify "termux-notification not found: pkg install termux-api, and install the Termux:API app" err
          elif timeout 10 termux-notification --id rclone-test --title "Rclone Commander" --content "Test notification - alerts work" --priority high --vibrate 300,150,300 </dev/null >/dev/null 2>&1
          then notify "Test notification sent - if you saw nothing, allow notifications for Termux:API in Android settings" ok
          else notify "Notification failed: install the Termux:API app (F-Droid) and allow its notifications" err; fi ;;
      18) if confirm "Reset all settings to defaults?"; then
            TRANSFERS=4; CHECKERS=8; BWLIMIT=""; RETRIES=3; EXISTING=skip; CHECKSUM=0; SHOW_HIDDEN=0; SORT_KEY=name
            SORT_REV=0; QUEUE_MODE=sequential; LOG_MAX_BYTES=1048576; EMPTY_DIRS=0; DRYRUN_FIRST=1; AUTO_RETRIES=3; NOTIFY=1; NOTIFY_LIVE=1; fi ;;
      19|0) save_settings; return ;;
    esac
    if [[ -n $k ]]; then
      if ask "$k [${!k}]: " "${!k}" && setting_valid "$k" "$ANS"; then printf -v "$k" '%s' "$ANS"; else notify "Invalid value for $k" err; fi
    fi
    save_settings
  done
}

help_screen() {
  show_text "$APP_NAME v$APP_VERSION - HELP" "" \
"BASICS
 Menus: press the number to choose (no Enter); q goes back at once. In menus of 10+ items a leading 1
 waits 3 s for a second digit (or press Enter). Backspace erases, Ctrl-U clears the line.
 File lists: a folder number opens at once; a file number needs Enter; commands like 'c 3' need Enter.
 Panels: A and B are two independent browsing locations; only one is shown at a time and 'x' in the
 file manager switches between them. Copy/move/upload/download always ask for a destination
 (the last used one is offered first).

TRANSFER SAFETY
 - Default is COPY with 'skip existing'. Sync is never default and needs the word SYNC typed.
 - Move deletes source files only after rclone reports them transferred. Dry run is offered first.
 - Same-remote copy/move uses server-side operations where the backend supports it. Between two
   different remotes data normally flows through this device (rclone decides, not this script).

RESTART vs SKIP vs RESUME
 - Retry (t in Jobs) re-runs the whole command. With 'skip existing' or 'newer', finished files are skipped.
 - rclone does NOT resume a half-copied file at a byte offset for most backends; that file restarts.
 - Pause sends SIGSTOP to rclone and resume sends SIGCONT. Servers may drop idle connections meanwhile.

PROGRESS
 Jobs run detached with 'rclone --use-json-log --stats 1s' (re-run automatically on corrupted transfers); the monitor reads structured stats from the
 job log (no scraping of progress text, no open RC port). Jobs keep running if you close the UI, but
 Android can still kill Termux. Use Transfer Manager > Wake lock and disable battery optimisation for Termux.

ANDROID
 Run 'termux-setup-storage' once to get ~/storage/shared. SD cards show up as ~/storage/external-* but
 Android usually limits Termux to the app-specific folder on them.

NOT IMPLEMENTED
 Sorting by file type, true side-by-side panels, Termux:Boot integration, auto-resume after reboot,
 byte-level resume, remote rename via script (use the config wizard)."
}

###############################################################################
# 14. MAIN MENU / ENTRY POINT
###############################################################################
usage() {
  cat <<EOF
$APP_NAME v$APP_VERSION
Usage: ${0##*/} [--help] [--version]
Data dir: \$RCLONE_MANAGER_HOME (default ~/.rclone-manager)
EOF
}

main_menu() {
  while true; do
    menu_choose "Main Menu" "File Manager" "Transfer Manager" "Remote Manager" "Search Files" \
      "Batch Operations" "Storage and Space Information" "Logs and Transfer History" "Settings" "Help" "Exit"
    case $CHOICE in
      1) file_manager ;; 2) transfer_manager ;; 3) remote_manager ;; 4) search_screen ;;
      5) batch_menu ;; 6) storage_info ;; 7) logs_menu ;; 8) settings_menu ;; 9) help_screen ;;
      10|0)
        local r; r=$(count_running)
        if (( r > 0 )); then notify "$r job(s) keep running in the background after exit." ok; fi
        return ;;
    esac
  done
}

main() {
  local a
  for a in "$@"; do
    case $a in
      --help|-h) usage; exit 0 ;;
      --version) echo "$APP_VERSION"; exit 0 ;;
      *) echo "Unknown option: $a" >&2; usage >&2; exit 2 ;;
    esac
  done
  load_settings
  check_deps
  init_dirs
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  init_ui
  recover_jobs
  load_remotes
  if [[ ! -d $HOME/storage/shared ]]; then
    SIMPLE_NOTE+="Tip: run termux-setup-storage (storage link is missing)"$'\n'   # short on purpose; Storage Selection explains in full
  fi
  P_REMOTE=("" ""); P_PATH=("$(default_start_dir)" "$HOME"); P_ROOT=("${P_PATH[0]}" "$HOME")
  if (( ${#REMOTES[@]} )); then P_REMOTE[1]=${REMOTES[0]}; P_PATH[1]=""; P_ROOT[1]=""; fi
  ACT=0
  log_msg INFO "started $APP_NAME $APP_VERSION"
  main_menu
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
