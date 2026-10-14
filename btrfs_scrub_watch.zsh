#!/usr/bin/env zsh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright (c) 2026 Maulik Mistry
#
# Live Gum dashboard for monitoring Btrfs scrub progress.
#
# Please share support:
#   PayPal: https://www.paypal.com/paypalme/m1st0
#   Venmo:  https://venmo.com/code?user_id=3319592654995456106&created=1753283702
#
# Usage: btrfs-scrub-watch.zsh [-i SECONDS] [MOUNTPOINT]
#   -i  seconds between btrfs queries (default 10)
#
# Design:
#   * The live view is drawn by this script with plain ANSI codes, one full frame
#     per tick, in the alternate screen. Nothing depends on cursor position, so
#     nothing can land in the wrong place.
#   * gum is used only for one-shot things (picking a filesystem, final summary),
#     where its strengths apply. Everything degrades gracefully without gum.
#   * Two clocks: a fast tick (animation, countdown, keys) and a slow poll
#     (the btrfs query).
#   * Keys: q quit, r refresh now.

setopt nounset
zmodload zsh/datetime || { print -u2 "zsh/datetime module is required."; exit 1; }

typeset -r SCRIPT=${0:t}
typeset -i INTERVAL=10
typeset TICK=0.2

usage() {
  print "Usage: $SCRIPT [-i SECONDS] [MOUNTPOINT]"
  print "  -i  seconds between btrfs queries (default $INTERVAL)"
}

while getopts ":i:h" opt; do
  case $opt in
    i) INTERVAL_ARG=$OPTARG ;;
    h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
MNT=${1:-}

if [[ -n ${INTERVAL_ARG:-} ]]; then
  [[ $INTERVAL_ARG == <1-> ]] || { print -u2 "Interval must be a whole number of seconds, 1 or more."; exit 2; }
  INTERVAL=$INTERVAL_ARG
fi
(( $+commands[btrfs] )) || { print -u2 "btrfs command not found."; exit 1; }
[[ -t 0 && -t 1 ]] || { print -u2 "This needs an interactive terminal."; exit 1; }

have_gum() { (( $+commands[gum] )); }

# ---------- privileges ----------
typeset -a SUDO=()
if (( EUID != 0 )); then
  (( $+commands[sudo] )) || { print -u2 "Run as root or install sudo."; exit 1; }
  sudo -v || exit 1          # ask for the password now, before the screen is taken over
  SUDO=(sudo -n)             # later calls must never prompt
fi

# ---------- choose filesystem (one-shot, gum is good at this) ----------
if [[ -z $MNT ]]; then
  typeset -a mounts
  mounts=( ${(f)"$(findmnt -rn -t btrfs -o TARGET | sort -u)"} )
  mounts=( ${mounts:#} )
  (( ${#mounts} )) || { print -u2 "No mounted btrfs filesystems found."; exit 1; }
  if (( ${#mounts} == 1 )); then
    MNT=${mounts[1]}
  elif have_gum; then
    MNT=$(gum choose --header "Which btrfs filesystem?" "${mounts[@]}") || exit 1
  else
    PS3="Filesystem number: "
    select MNT in "${mounts[@]}"; do [[ -n $MNT ]] && break; done
  fi
  [[ -n $MNT ]] || exit 1
fi

# ---------- look and feel ----------
if [[ -n ${NO_COLOR:-} ]]; then
  RST="" BLD="" DIM="" GRN="" RED="" YEL="" CYN=""
else
  RST=$'\e[0m' BLD=$'\e[1m' DIM=$'\e[2m' GRN=$'\e[32m' RED=$'\e[31m' YEL=$'\e[33m' CYN=$'\e[36m'
fi

typeset -i UTF=0
[[ ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff]-8* || ${LC_ALL:-${LC_CTYPE:-${LANG:-}}} == *[Uu][Tt][Ff]8* ]] && UTF=1
if (( UTF )); then
  SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  PART=(▏ ▎ ▍ ▌ ▋ ▊ ▉)
  FULL="█" EMPTY="░" RULE="─"
else
  SPIN=('|' '/' '-' '\')
  PART=()
  FULL="#" EMPTY="-" RULE="-"
fi

NIL=""   # empty but set: padding expansions need a named parameter under nounset
typeset -i ROWS=24 COLS=80
update_size() {
  local r c
  read -r r c < <(stty size 2>/dev/null) && { ROWS=$r; COLS=$c; }
}

# make_bar WIDTH HUNDREDTHS  -> BAR (HUNDREDTHS is 0..10000)
make_bar() {
  local -i w=$1 v=$2 eighths=0 full=0 rem=0 pad=0
  local a b
  (( v < 0 )) && v=0
  (( v > 10000 )) && v=10000
  if (( UTF )); then
    eighths=$(( v * w * 8 / 10000 )); full=$(( eighths / 8 )); rem=$(( eighths % 8 ))
  else
    full=$(( v * w / 10000 ))
  fi
  pad=$(( w - full )); (( rem > 0 )) && pad=$(( pad - 1 ))
  (( pad < 0 )) && pad=0
  a=${(l:full::X:)NIL}; a=${a//X/$FULL}
  b=${(l:pad::X:)NIL};  b=${b//X/$EMPTY}
  BAR="$a"
  (( rem > 0 )) && BAR+="${PART[rem]}"
  BAR+="${DIM}${b}${RST}"
}

# ---------- reading btrfs ----------
OUT=""
fld() { sed -n "s/^[[:space:]]*$1:[[:space:]]*//p" <<<"$OUT" | head -n1; }

S_status=waiting S_started=- S_elapsed=- S_left=- S_eta=- S_total=- S_scrubbed=-
S_rate=- S_errors=- S_msg=""
typeset -i S_pct=0

poll() {
  local -i rc
  local b re ip fp
  OUT=$("${SUDO[@]}" btrfs scrub status "$MNT" 2>&1); rc=$?
  S_msg=""
  if (( rc != 0 )); then
    S_status=error; S_msg=${OUT%%$'\n'*}; return
  fi
  if [[ $OUT == *"no stats available"* ]]; then
    S_status=idle S_started=- S_elapsed=- S_left=- S_eta=- S_total=- S_scrubbed=- S_rate=- S_errors=- S_pct=0
    return
  fi
  S_status=$(fld Status);            S_status=${S_status:-unknown}
  S_started=$(fld "Scrub started");  S_started=${S_started:--}
  S_elapsed=$(fld Duration);         S_elapsed=${S_elapsed:--}
  S_left=$(fld "Time left");         S_left=${S_left:--}
  S_eta=$(fld ETA);                  S_eta=${S_eta:--}
  S_total=$(fld "Total to scrub");   S_total=${S_total:--}
  S_rate=$(fld Rate);                S_rate=${S_rate:--}
  S_errors=$(fld "Error summary");   S_errors=${S_errors:--}
  b=$(fld "Bytes scrubbed")
  S_scrubbed=${b%%[[:space:]]*};     S_scrubbed=${S_scrubbed:--}
  S_pct=0
  re='\(([0-9]+)(\.([0-9]+))?%\)'
  if [[ $b =~ $re ]]; then
    ip=${match[1]} fp=${match[3]:-0}
    fp="${fp}00"; fp=${fp[1,2]}
    S_pct=$(( 10#$ip * 100 + 10#$fp ))
  elif [[ $S_status == finished ]]; then
    S_pct=10000
  fi
}

# ---------- drawing ----------
typeset -i FRAME_N=0 UPDATING=0 NEXT=0 SAW_RUNNING=0 FORCE=0
LAST_CHECK="--:--:--"
F="" L="" BAR=""

row() { printf -v L '  %s%-11s%s%s\e[K\n' "$DIM" "$1" "$RST" "$2"; F+=$L; }

render() {
  local -i rem bw cw cv now=$EPOCHSECONDS
  local spin col ptxt rule
  rem=$(( NEXT - now )); (( rem < 0 )) && rem=0
  (( FRAME_N++ ))

  case $S_status in
    running)           col=$CYN ;;
    finished)          col=$GRN ;;
    idle|waiting)      col=$DIM ;;
    aborted|error)     col=$RED ;;
    *)                 col=$YEL ;;
  esac
  if [[ $S_status == running ]]; then
    spin=${SPIN[FRAME_N % ${#SPIN} + 1]}
  else
    spin=${SPIN[1]}
  fi

  F=""
  printf -v L ' %s%s%s %sbtrfs scrub%s  %s%s%s\e[K\n' "$col" "$spin" "$RST" "$BLD" "$RST" "$DIM" "$MNT" "$RST"; F+=$L
  rule=${(l:COLS-2::X:)NIL}; rule=${rule//X/$RULE}
  F+=" ${DIM}${rule}${RST}"$'\e[K\n'

  row "Status" "${col}${S_status}${RST}"
  if [[ $S_status == error ]]; then
    row "Problem" "${RED}${S_msg}${RST}"
  elif [[ $S_status == running ]] || (( SAW_RUNNING )); then
    row "Started"   "$S_started"
    row "Elapsed"   "$S_elapsed"
    row "Time left" "$S_left${DIM}   ETA $S_eta${RST}"
    row "Rate"      "$S_rate"
    row "Scrubbed"  "$S_scrubbed of $S_total"
    if [[ $S_errors == "no errors found" ]]; then
      row "Errors" "${GRN}${S_errors}${RST}"
    else
      row "Errors" "${RED}${S_errors}${RST}"
    fi
  else
    row "Waiting" "no scrub running. Start one with: sudo btrfs scrub start $MNT"
  fi

  F+=$'\e[K\n'
  bw=$(( COLS - 16 )); (( bw > 70 )) && bw=70; (( bw < 10 )) && bw=10
  make_bar $bw $S_pct
  printf -v ptxt '%3d.%02d%%' $(( S_pct / 100 )) $(( S_pct % 100 ))
  F+="  ${col}${BAR}${RST} ${BLD}${ptxt}${RST}"$'\e[K\n'
  F+=$'\e[K\n'

  if (( UPDATING )); then
    F+="  ${YEL}checking now...${RST}"$'\e[K\n'
  else
    cw=20; cv=$(( rem * 10000 / INTERVAL ))
    make_bar $cw $cv
    printf -v L '  %sNext update in%s %s%2ds%s  %s%s%s  %slast %s%s\e[K\n' \
      "$DIM" "$RST" "$BLD" "$rem" "$RST" "$DIM" "$BAR" "$RST" "$DIM" "$LAST_CHECK" "$RST"
    F+=$L
  fi
  F+=$'\e[K\n'
  F+="  ${DIM}q quit   r refresh now${RST}"$'\e[K\n'

  printf '\e[H%s\e[J' "$F"
}

# ---------- screen lifecycle ----------
typeset -i ALT=0
enter_screen() { printf '\e[?1049h\e[?25l\e[2J'; ALT=1; }
leave_screen() { (( ALT )) && printf '\e[?25h\e[?1049l'; ALT=0; }
trap leave_screen EXIT
trap 'exit 130' INT TERM
trap update_size WINCH

summary() {
  local -i col=42
  local txt
  [[ $S_status == finished && $S_errors == "no errors found" ]] || col=196
  printf -v txt 'Scrub %s on %s\nStarted   %s\nDuration  %s\nScrubbed  %s of %s\nErrors    %s' \
    "$S_status" "$MNT" "$S_started" "$S_elapsed" "$S_scrubbed" "$S_total" "$S_errors"
  if have_gum; then
    gum style --border rounded --padding "0 2" --border-foreground "$col" "$txt"
  else
    print -r -- "$txt"
  fi
}

# ---------- main loop ----------
update_size
enter_screen
while true; do
  now=$EPOCHSECONDS
  if (( FORCE || now >= NEXT )); then
    UPDATING=1; render
    poll
    UPDATING=0; FORCE=0
    now=$EPOCHSECONDS
    strftime -s LAST_CHECK '%H:%M:%S' $now
    NEXT=$(( now + INTERVAL ))
    if [[ $S_status == running ]]; then
      SAW_RUNNING=1
    elif (( SAW_RUNNING )) && [[ $S_status == (finished|aborted|interrupted|idle) ]]; then
      render; sleep 0.5
      leave_screen
      printf '\a'
      summary
      [[ $S_status == finished && $S_errors == "no errors found" ]] && exit 0
      exit 1
    fi
  fi
  render
  if read -rsk 1 -t $TICK key; then
    case $key in
      q|Q) break ;;
      r|R) FORCE=1 ;;
    esac
  fi
done
