#!/usr/bin/env bash
# agent-notify notification panel — tmux popup overlay
# j/k or arrows to navigate, space to dismiss, q/Esc to close

set -euo pipefail

DB="$HOME/.local/share/agent-notify/registry.db"
CYAN="\033[1;36m"
DIM="\033[2m"
BOLD="\033[1m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

if [ ! -f "$DB" ]; then
  echo "No notifications"
  sleep 1
  exit 0
fi

# ── Load events ──────────────────────────────────────────────────────────────

load_events() {
  sqlite3 -separator '|' "$DB" "
    SELECT e.id, e.type, e.status, e.payload, e.created_at,
           COALESCE(s.project, 'unknown'), COALESCE(s.worktree, 'unknown')
    FROM events e
    LEFT JOIN sessions s ON e.session_id = s.id
    ORDER BY e.created_at DESC
    LIMIT 50
  " 2>/dev/null
}

# ── Format helpers ───────────────────────────────────────────────────────────

basename_of() { echo "${1##*/}"; }

time_ago() {
  local ts="$1"
  local now
  now=$(date +%s)
  local diff=$(( now - ts ))
  if [ "$diff" -lt 60 ]; then
    echo "${diff}s ago"
  elif [ "$diff" -lt 3600 ]; then
    echo "$(( diff / 60 ))m ago"
  elif [ "$diff" -lt 86400 ]; then
    echo "$(( diff / 3600 ))h ago"
  else
    echo "$(( diff / 86400 ))d ago"
  fi
}

type_icon() {
  case "$1" in
    done)       printf "${GREEN}done${RESET}" ;;
    error)      printf "${RED}error${RESET}" ;;
    question)   printf "${YELLOW}question${RESET}" ;;
    permission) printf "${MAGENTA}permission${RESET}" ;;
    *)          printf "$1" ;;
  esac
}

status_label() {
  case "$1" in
    pending)   printf "${YELLOW}pending${RESET}" ;;
    mac_acked) printf "${GREEN}acked${RESET}" ;;
    tg_sent)   printf "${CYAN}telegram${RESET}" ;;
    responded) printf "${DIM}responded${RESET}" ;;
    stale)     printf "${DIM}stale${RESET}" ;;
    *)         printf "$1" ;;
  esac
}

extract_summary() {
  local type="$1" payload="$2"
  case "$type" in
    done)
      echo "$payload" | { grep -o '"summary":"[^"]*"' || true; } | head -1 | cut -d'"' -f4
      ;;
    error)
      echo "$payload" | { grep -o '"message":"[^"]*"' || true; } | head -1 | cut -d'"' -f4
      ;;
    question)
      echo "$payload" | { grep -o '"text":"[^"]*"' || true; } | head -1 | cut -d'"' -f4
      ;;
    permission)
      local tool action
      tool=$(echo "$payload" | { grep -o '"tool":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      action=$(echo "$payload" | { grep -o '"action":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      echo "$tool: $action"
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── Main ─────────────────────────────────────────────────────────────────────

declare -a EVENT_IDS=()
declare -a DISPLAY_LINES=()

refresh() {
  EVENT_IDS=()
  DISPLAY_LINES=()

  local raw
  raw=$(load_events)

  if [ -z "$raw" ]; then
    return
  fi

  while IFS='|' read -r eid etype estatus epayload ecreated eproject eworktree; do
    EVENT_IDS+=("$eid")
    local proj
    proj=$(basename_of "$eproject")
    local wt
    wt=$(basename_of "$eworktree")
    local ago
    ago=$(time_ago "$ecreated")
    local summary
    summary=$(extract_summary "$etype" "$epayload")

    local server_label
    server_label=$(echo "$epayload" | grep -o '"server_label":"[^"]*"' | head -1 | cut -d'"' -f4 || true)

    local location="$proj"
    if [ "$wt" != "$proj" ] && [ "$wt" != "unknown" ]; then
      location="$proj / $wt"
    fi
    if [ -n "$server_label" ]; then
      location="${server_label}  ${location}"
    fi

    # Truncate summary
    if [ ${#summary} -gt 50 ]; then
      summary="${summary:0:47}..."
    fi

    local line
    line=$(printf "%-20b  %-12b  %b  ${DIM}%s${RESET}" \
      "$location" \
      "$(type_icon "$etype")" \
      "$(status_label "$estatus")" \
      "$ago")

    if [ -n "$summary" ]; then
      line="$line\n                      ${DIM}${summary}${RESET}"
    fi

    DISPLAY_LINES+=("$line")
  done <<< "$raw"
}

dismiss_event() {
  local eid="$1"
  sqlite3 "$DB" "DELETE FROM events WHERE id = '$eid'" 2>/dev/null
}

# ── Interactive loop ─────────────────────────────────────────────────────────

run_panel() {
  refresh

  local count=${#DISPLAY_LINES[@]}
  if [ "$count" -eq 0 ]; then
    printf "\n  ${DIM}No notifications${RESET}\n\n"
    printf "  ${DIM}ctrl+n to close${RESET}\n"
    # Wait for any key
    local saved_tty
    saved_tty=$(stty -g </dev/tty 2>/dev/null)
    stty -echo -icanon min 1 </dev/tty 2>/dev/null
    dd bs=1 count=1 2>/dev/null </dev/tty >/dev/null
    stty "$saved_tty" </dev/tty 2>/dev/null
    return
  fi

  local cur=0

  printf "\033[?25l"
  local saved_tty
  saved_tty=$(stty -g </dev/tty 2>/dev/null)
  stty -echo -icanon min 1 </dev/tty 2>/dev/null

  _draw() {
    printf "\n"
    printf "  ${BOLD}Notifications${RESET}  ${DIM}(%d)${RESET}\n" "$count"
    printf "  ${DIM}j/k navigate  space dismiss  ctrl+n close${RESET}\n\n"
    for i in "${!DISPLAY_LINES[@]}"; do
      if [[ $i -eq $cur ]]; then
        printf "  ${CYAN}>${RESET} %b\n" "${DISPLAY_LINES[$i]}"
      else
        printf "    %b\n" "${DISPLAY_LINES[$i]}"
      fi
    done
  }

  _clear() {
    # Each display line may be 1 or 2 terminal lines (summary on second line)
    local total_lines=4  # header + subtitle + blank + footer
    for line in "${DISPLAY_LINES[@]}"; do
      total_lines=$((total_lines + 1))
      # Count embedded newlines
      local nl_count
      nl_count=$(printf '%b' "$line" | grep -c '^' || true)
      if [ "$nl_count" -gt 1 ]; then
        total_lines=$((total_lines + nl_count - 1))
      fi
    done
    for (( i=0; i<total_lines; i++ )); do
      printf "\033[A\033[2K"
    done
  }

  _draw

  while true; do
    local key
    key=$(dd bs=1 count=1 2>/dev/null </dev/tty)

    case "$key" in
      $'\x1b')
        local seq1 seq2
        seq1=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        seq2=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        if [[ "$seq1" == "[" ]]; then
          case "$seq2" in
            A) [[ $cur -gt 0 ]] && cur=$((cur - 1)) ;;
            B) [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1)) ;;
          esac
        else
          # Bare escape — close
          break
        fi
        ;;
      $'\x0e')
        # Ctrl+n — close
        break
        ;;
      k)
        [[ $cur -gt 0 ]] && cur=$((cur - 1))
        ;;
      j)
        [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1))
        ;;
      " ")
        # Dismiss selected event
        local eid="${EVENT_IDS[$cur]}"
        dismiss_event "$eid"
        _clear
        refresh
        count=${#DISPLAY_LINES[@]}
        if [ "$count" -eq 0 ]; then
          printf "\n  ${DIM}No notifications${RESET}\n"
          sleep 0.5
          break
        fi
        if [ "$cur" -ge "$count" ]; then
          cur=$((count - 1))
        fi
        _draw
        continue
        ;;
      ""|$'\n')
        # Enter — no-op for now
        ;;
    esac

    _clear
    _draw
  done

  _clear
  stty "$saved_tty" </dev/tty 2>/dev/null
  printf "\033[?25h"
}

run_panel
