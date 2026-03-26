#!/usr/bin/env bash
# agent-notify notification panel — tmux popup overlay
# j/k or arrows to navigate, space to dismiss, q/Esc to close

set -euo pipefail

DB="$HOME/.local/share/agent-notify/registry.db"
CYAN="\033[1;36m"
BLUE="\033[1;34m"
DIM="\033[2m"
BOLD="\033[1m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
GREEN="\033[1;32m"
MAGENTA="\033[1;35m"
RESET="\033[0m"

# ── Source colors (main=blue, servers cycle green/yellow/magenta/cyan/red) ──

declare -A SOURCE_COLOR_MAP=()
declare -a SERVER_COLORS=("$GREEN" "$YELLOW" "$MAGENTA" "$CYAN" "$RED")
SERVER_COLOR_IDX=0

source_color() {
  local src="$1"
  if [ "$src" = "main" ]; then
    printf '%b' "$BLUE"
    return
  fi
  if [ -n "${SOURCE_COLOR_MAP[$src]+x}" ]; then
    printf '%b' "${SOURCE_COLOR_MAP[$src]}"
    return
  fi
  SOURCE_COLOR_MAP[$src]="${SERVER_COLORS[$SERVER_COLOR_IDX]}"
  SERVER_COLOR_IDX=$(( (SERVER_COLOR_IDX + 1) % ${#SERVER_COLORS[@]} ))
  printf '%b' "${SOURCE_COLOR_MAP[$src]}"
}

if [ ! -f "$DB" ]; then
  echo "No notifications"
  sleep 1
  exit 0
fi

# ── Load events ──────────────────────────────────────────────────────────────

load_events() {
  # Check if sessions table has the name column
  local has_name
  has_name=$(sqlite3 "$DB" "SELECT COUNT(*) FROM pragma_table_info('sessions') WHERE name='name'" 2>/dev/null)
  local name_col="''"
  [ "$has_name" = "1" ] && name_col="COALESCE(s.name, '')"

  sqlite3 -separator '|' "$DB" "
    SELECT e.id, e.type, e.status, e.payload, e.created_at,
           COALESCE(s.project, 'unknown'), COALESCE(s.worktree, 'unknown'),
           e.session_id, ${name_col}
    FROM events e
    LEFT JOIN sessions s ON e.session_id = s.id
    WHERE e.status NOT IN ('dismissed', 'stale', 'responded')
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
declare -a EVENT_TYPES=()
declare -a EVENT_STATUSES=()
declare -a EVENT_PAYLOADS=()
declare -a EVENT_TIMES=()
declare -a EVENT_PROJECTS=()
declare -a EVENT_WORKTREES=()
declare -a EVENT_SESSIONS=()
declare -a EVENT_SESSION_NAMES=()
declare -a DISPLAY_LINES=()

refresh() {
  EVENT_IDS=()
  EVENT_TYPES=()
  EVENT_STATUSES=()
  EVENT_PAYLOADS=()
  EVENT_TIMES=()
  EVENT_PROJECTS=()
  EVENT_WORKTREES=()
  EVENT_SESSIONS=()
  EVENT_SESSION_NAMES=()
  DISPLAY_LINES=()

  local raw
  raw=$(load_events)

  if [ -z "$raw" ]; then
    return
  fi

  while IFS='|' read -r eid etype estatus epayload ecreated eproject eworktree esession esname; do
    EVENT_IDS+=("$eid")
    EVENT_TYPES+=("$etype")
    EVENT_STATUSES+=("$estatus")
    EVENT_PAYLOADS+=("$epayload")
    EVENT_TIMES+=("$ecreated")
    EVENT_PROJECTS+=("$eproject")
    EVENT_WORKTREES+=("$eworktree")
    EVENT_SESSIONS+=("$esession")
    EVENT_SESSION_NAMES+=("$esname")

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
    local source="${server_label:-main}"

    # Use session name if available, fall back to project
    local name="$esname"
    if [ -z "$name" ]; then
      name="$proj"
      if [ "$wt" != "$proj" ] && [ "$wt" != "unknown" ]; then
        name="$proj / $wt"
      fi
    fi

    local scolor
    scolor=$(source_color "$source")
    local line
    line=$(printf "${DIM}[${RESET}${scolor}%s${RESET}${DIM}]${RESET} %s  %-10b ${DIM}%-8s${RESET}" \
      "$source" \
      "$name" \
      "$(type_icon "$etype")" \
      "$ago")

    DISPLAY_LINES+=("$line")
  done <<< "$raw"
}

dismiss_event() {
  local eid="$1"
  sqlite3 "$DB" "DELETE FROM events WHERE id = '$eid'" 2>/dev/null
}

# ── Detail view ──────────────────────────────────────────────────────────────

show_detail() {
  local idx="$1"
  local etype="${EVENT_TYPES[$idx]}"
  local estatus="${EVENT_STATUSES[$idx]}"
  local epayload="${EVENT_PAYLOADS[$idx]}"
  local ecreated="${EVENT_TIMES[$idx]}"
  local eproject="${EVENT_PROJECTS[$idx]}"
  local eworktree="${EVENT_WORKTREES[$idx]}"
  local eid="${EVENT_IDS[$idx]}"
  local esession="${EVENT_SESSIONS[$idx]}"
  local esname="${EVENT_SESSION_NAMES[$idx]}"

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

  local ts
  if command -v gdate &>/dev/null; then
    ts=$(gdate -d "@$ecreated" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$ecreated" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ecreated")
  else
    ts=$(date -r "$ecreated" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -d "@$ecreated" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$ecreated")
  fi

  printf "\033[2J\033[H"  # clear screen
  printf "\n"
  printf "  ${BOLD}Event Detail${RESET}\n"
  printf "  ${DIM}enter/q/Esc back  ctrl+n close${RESET}\n\n"
  printf "  ${BOLD}Type:${RESET}      %b\n" "$(type_icon "$etype")"
  printf "  ${BOLD}Status:${RESET}    %b\n" "$(status_label "$estatus")"
  printf "  ${BOLD}Project:${RESET}   %s\n" "$proj"
  [ "$wt" != "$proj" ] && [ "$wt" != "unknown" ] && \
  printf "  ${BOLD}Worktree:${RESET}  %s\n" "$wt"
  [ -n "$server_label" ] && \
  printf "  ${BOLD}Server:${RESET}    %s\n" "$server_label"
  printf "  ${BOLD}Time:${RESET}      %s (%s)\n" "$ts" "$ago"
  if [ -n "$esname" ]; then
    printf "  ${BOLD}Session:${RESET}   %s ${DIM}(%s)${RESET}\n" "$esname" "$esession"
  elif [ -n "$esession" ]; then
    printf "  ${BOLD}Session:${RESET}   ${DIM}%s${RESET}\n" "$esession"
  fi
  printf "  ${BOLD}ID:${RESET}        ${DIM}%s${RESET}\n" "$eid"
  printf "\n"
  printf "  ${BOLD}Summary:${RESET}\n"
  printf "  %s\n" "$summary"

  # Show full payload details based on type
  case "$etype" in
    error)
      local msg
      msg=$(echo "$epayload" | { grep -o '"message":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      if [ -n "$msg" ]; then
        printf "\n  ${BOLD}Error:${RESET}\n"
        printf "  ${RED}%s${RESET}\n" "$msg"
      fi
      ;;
    question)
      local text options
      text=$(echo "$epayload" | { grep -o '"text":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      if [ -n "$text" ]; then
        printf "\n  ${BOLD}Question:${RESET}\n"
        printf "  ${YELLOW}%s${RESET}\n" "$text"
      fi
      ;;
    permission)
      local tool action
      tool=$(echo "$epayload" | { grep -o '"tool":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      action=$(echo "$epayload" | { grep -o '"action":"[^"]*"' || true; } | head -1 | cut -d'"' -f4)
      if [ -n "$tool" ]; then
        printf "\n  ${BOLD}Tool:${RESET}      %s\n" "$tool"
      fi
      if [ -n "$action" ]; then
        printf "\n  ${BOLD}Action:${RESET}\n"
        printf "  ${MAGENTA}%s${RESET}\n" "$action"
      fi
      ;;
  esac

  printf "\n"

  # Wait for q/Esc to go back
  while true; do
    local dkey
    dkey=$(dd bs=1 count=1 2>/dev/null </dev/tty)
    case "$dkey" in
      q|""|$'\n') return 0 ;;  # q, Enter, or newline — back to list
      $'\x0e') return 1 ;;     # ctrl+n — close entire panel
      $'\x1b')
        local s1
        s1=$(dd bs=1 count=1 2>/dev/null </dev/tty)
        if [[ "$s1" != "[" ]]; then
          return 0  # bare Esc — back to list
        fi
        dd bs=1 count=1 2>/dev/null </dev/tty >/dev/null  # consume seq char
        ;;
    esac
  done
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
  local scroll=0
  # Reserve 4 lines for header, and cap visible items
  local max_visible=14

  printf "\033[?25l"
  local saved_tty
  saved_tty=$(stty -g </dev/tty 2>/dev/null)
  stty -echo -icanon min 1 </dev/tty 2>/dev/null

  _scroll_into_view() {
    if [[ $cur -lt $scroll ]]; then
      scroll=$cur
    elif [[ $cur -ge $((scroll + max_visible)) ]]; then
      scroll=$((cur - max_visible + 1))
    fi
    return 0
  }

  _draw() {
    local end=$((scroll + max_visible))
    [[ $end -gt $count ]] && end=$count

    printf "\n"
    printf "  ${BOLD}Notifications${RESET}  ${DIM}(%d)${RESET}" "$count"
    if [[ $count -gt $max_visible ]]; then
      printf "  ${DIM}[%d-%d]${RESET}" "$((scroll + 1))" "$end"
    fi
    printf "\n"
    printf "  ${DIM}j/k navigate  enter detail  x dismiss  ctrl+n close${RESET}\n\n"

    for (( i=scroll; i<end; i++ )); do
      if [[ $i -eq $cur ]]; then
        printf "  ${CYAN}>${RESET} %b\n" "${DISPLAY_LINES[$i]}"
      else
        printf "    %b\n" "${DISPLAY_LINES[$i]}"
      fi
    done
  }

  _clear() {
    local end=$((scroll + max_visible))
    [[ $end -gt $count ]] && end=$count
    # 4 = blank + header + help + blank, plus one line per visible item
    local total_lines=$(( 4 + end - scroll ))
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
            A) [[ $cur -gt 0 ]] && cur=$((cur - 1)); _scroll_into_view ;;
            B) [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1)); _scroll_into_view ;;
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
        _scroll_into_view
        ;;
      j)
        [[ $cur -lt $((count - 1)) ]] && cur=$((cur + 1))
        _scroll_into_view
        ;;
      x)
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
        _scroll_into_view
        _draw
        continue
        ;;
      ""|$'\n')
        # Enter — show detail view
        _clear
        show_detail "$cur"
        local detail_rc=$?
        printf "\033[2J\033[H"  # clear screen after returning
        if [[ $detail_rc -eq 1 ]]; then
          break  # ctrl+n pressed in detail — close panel
        fi
        _draw
        continue
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
