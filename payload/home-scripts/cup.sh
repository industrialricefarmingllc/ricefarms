#!/bin/bash
MAX_RETRIES=10

view_logs() {
  local logfile
  logfile=$(mktemp)
  docker-compose logs "$@" -f --tail 100 >> "$logfile" 2>&1 &
  local docker_pid=$!

  local LOG_LINES=()
  local scroll_offset=0
  local auto_scroll=1
  local last_line_count=0

  tput smcup
  tput civis
  printf '\033[?1000h\033[?1006h'
  trap 'printf "\033[?1000l\033[?1006l"; tput cnorm; tput rmcup; [[ -n "$docker_pid" ]] && kill "$docker_pid" 2>/dev/null; [[ -n "$logfile" ]] && rm -f "$logfile"; exit 130' INT TERM
  trap 'printf "\033[?1000l\033[?1006l"; tput cnorm; tput rmcup; [[ -n "$docker_pid" ]] && kill "$docker_pid" 2>/dev/null; [[ -n "$logfile" ]] && rm -f "$logfile"' EXIT

  _log_draw() {
    local term_rows total max_scroll end i
    term_rows=$(tput lines)
    total=${#LOG_LINES[@]}
    max_scroll=$(( total - term_rows ))
    [[ $max_scroll -lt 0 ]] && max_scroll=0
    [[ $scroll_offset -gt $max_scroll ]] && scroll_offset=$max_scroll
    [[ $scroll_offset -lt 0 ]] && scroll_offset=0
    tput cup 0 0
    end=$(( scroll_offset + term_rows ))
    [[ $end -gt $total ]] && end=$total
    for ((i=scroll_offset; i<end; i++)); do
      printf "%s\033[K\n" "${LOG_LINES[$i]}"
    done
    tput ed 2>/dev/null || printf "\033[J"
  }

  while true; do
    kill -0 "$docker_pid" 2>/dev/null || break
    local curr_lines
    if [[ -f "$logfile" ]]; then
      curr_lines=$(wc -l < "$logfile" 2>/dev/null || echo 0)
    else
      curr_lines=0
    fi
    if [[ "$curr_lines" -gt "$last_line_count" ]]; then
      local new_arr=()
      mapfile -t new_arr < <(tail -n +"$((last_line_count + 1))" "$logfile" 2>/dev/null)
      LOG_LINES+=("${new_arr[@]}")
      last_line_count=$curr_lines
      if [[ $auto_scroll -eq 1 ]]; then
        local term_rows
        term_rows=$(tput lines)
        scroll_offset=$(( ${#LOG_LINES[@]} - term_rows ))
        [[ $scroll_offset -lt 0 ]] && scroll_offset=0
      fi
      _log_draw
    fi

    local char seq full
    IFS= read -r -s -t 0.05 -n 1 char 2>/dev/null
    if [[ "$char" == "q" || "$char" == "Q" ]]; then
      break
    elif [[ "$char" == $'\033' ]]; then
      IFS= read -r -s -t 0.05 -n 10 seq 2>/dev/null
      full="${char}${seq}"
      local re=$'\033\[<([0-9]+);[0-9]+;[0-9]+[Mm]'
      if [[ "$full" =~ $re ]]; then
        local btn="${BASH_REMATCH[1]}"
        local term_rows total max_scroll
        term_rows=$(tput lines)
        total=${#LOG_LINES[@]}
        max_scroll=$(( total - term_rows ))
        [[ $max_scroll -lt 0 ]] && max_scroll=0
        if [[ "$btn" == "65" ]]; then
          auto_scroll=0
          (( scroll_offset += 3 ))
          [[ $scroll_offset -gt $max_scroll ]] && scroll_offset=$max_scroll
        elif [[ "$btn" == "64" ]]; then
          (( scroll_offset -= 3 ))
          [[ $scroll_offset -lt 0 ]] && scroll_offset=0
          [[ $scroll_offset -ge $max_scroll ]] && auto_scroll=1
        fi
        _log_draw
      fi
    fi
  done
}

for attempt in $(seq 1 $MAX_RETRIES); do
  docker-compose up -d "$@" || true
  sleep 3

  failed=$(docker-compose ps "$@" | grep -iE "\bexit(ed)?\b|\brestarting\b" | wc -l)

  if [ "$failed" -eq 0 ]; then
    view_logs "$@"
    exit 0
  fi

  echo "Attempt $attempt/$MAX_RETRIES: $failed container(s) not running, retrying..."
  sleep 2
done

echo "Failed to start all containers after $MAX_RETRIES attempts."
docker-compose logs "$@" --tail 50
exit 1
