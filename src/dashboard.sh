#!/bin/bash
# =============================================================================
# dashboard.sh — Orchestrator Worker Status Dashboard
#
# Usage:
#   ./dashboard.sh            — single render
#   watch -n 5 ./dashboard.sh — live refresh every 5 seconds
#
# Reads:  ~/.claude/orchestrator/workers/*.json  (one JSON file per worker)
#
# Required JSON fields per file (spawn-worker.sh schema):
#   id              string   — unique name, e.g. "worker-alpha"
#   project_dir     string   — absolute path to project directory
#   phase           string   — current phase, e.g. "implementing"
#   progress        number   — integer 0-100
#   status          string   — "active" | "stuck" | "crashed"
#   spawned_at      string   — ISO 8601 UTC, e.g. "2026-03-03T08:00:00Z"
#   last_output_at  string   — ISO 8601 UTC
#   spent_usd       number   — float (dollars)
#   budget_usd      number   — float (dollars)
#   notes           string   — one-line free-form description
#
# Dependencies: bash (3.2+, macOS default), jq, tput, awk, date (BSD), sed, tr
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# 0. GUARD
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    printf 'Error: jq is required but not installed.\nInstall: brew install jq\n' >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# 1. TERMINAL GEOMETRY
# -----------------------------------------------------------------------------
TERM_COLS=$(tput cols 2>/dev/null || echo 80)
if [ "$TERM_COLS" -lt 80 ] 2>/dev/null; then TERM_COLS=80; fi

# -----------------------------------------------------------------------------
# 2. ANSI COLOR CONSTANTS
#
#    Uses ANSI-C quoting  $'\033[Xm'  so variables hold actual ESC bytes.
#    This means color vars can be interpolated directly into strings without
#    needing `printf '%b'`.  sed stripping also works correctly on them.
# -----------------------------------------------------------------------------
ESC=$'\033'

RESET="${ESC}[0m"
BOLD="${ESC}[1m"
DIM="${ESC}[2m"

FG_GREEN="${ESC}[32m"
FG_YELLOW="${ESC}[33m"
FG_RED="${ESC}[31m"
FG_CYAN="${ESC}[36m"
FG_WHITE="${ESC}[97m"
FG_GRAY="${ESC}[90m"
FG_MAGENTA="${ESC}[35m"

BOLD_CYAN="${ESC}[1;36m"
BOLD_WHITE="${ESC}[1;97m"
BOLD_GREEN="${ESC}[1;32m"
BOLD_YELLOW="${ESC}[1;33m"
BOLD_RED="${ESC}[1;31m"

# Return the ANSI color string for a given status
status_color() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        active)    printf '%s' "$BOLD_GREEN"  ;;
        stuck)     printf '%s' "$BOLD_YELLOW" ;;
        crashed)   printf '%s' "$BOLD_RED"    ;;
        completed) printf '%s' "$FG_CYAN"     ;;
        *)         printf '%s' "$FG_GRAY"     ;;
    esac
}

# Single-character icon per status
status_icon() {
    case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
        active)    printf '>' ;;
        stuck)     printf '~' ;;
        crashed)   printf 'X' ;;
        completed) printf '✓' ;;
        *)         printf '?' ;;
    esac
}

# -----------------------------------------------------------------------------
# 3. BOX-DRAWING CHARACTERS (Unicode box-drawing block, UTF-8)
# -----------------------------------------------------------------------------
H='─'   # U+2500
V='│'   # U+2502
TL='┌'  # U+250C
TR='┐'  # U+2510
BL='└'  # U+2514
BR='┘'  # U+2518
LT='├'  # U+251C
RT='┤'  # U+2524
CT='┼'  # U+253C

BAR_FULL='█'    # U+2588  filled block
BAR_EMPTY='░'   # U+2591  light shade (empty)

# Print a character N times
repeat_char() {
    local ch="$1" n="$2" out='' i
    if [ "$n" -le 0 ] 2>/dev/null; then printf ''; return; fi
    for i in $(seq 1 "$n"); do out="${out}${ch}"; done
    printf '%s' "$out"
}

# Print a horizontal box border: hbar LEFT FILL RIGHT TOTAL_WIDTH
hbar() {
    local l="$1" ch="$2" r="$3" w="$4"
    printf '%s%s%s' "$l" "$(repeat_char "$ch" $(( w - 2 )))" "$r"
}

# Pad TEXT to exactly WIDTH *visible* characters.
# Strips ANSI escapes before measuring so colored strings are padded correctly.
# pad_cell TEXT WIDTH [right]
pad_cell() {
    local text="$1" width="$2" align="${3:-left}"
    # Strip actual ESC bytes (\x1b) and their sequences for length measurement
    local visible
    visible=$(printf '%s' "$text" | sed 's/\x1b\[[0-9;]*m//g')
    local vlen=${#visible}
    local pad_len=$(( width - vlen ))
    if [ "$pad_len" -lt 0 ]; then pad_len=0; fi
    local spaces
    spaces=$(repeat_char ' ' "$pad_len")
    if [ "$align" = 'right' ]; then
        printf '%s%s' "$spaces" "$text"
    else
        printf '%s%s' "$text" "$spaces"
    fi
}

# -----------------------------------------------------------------------------
# 4. PROGRESS BAR
#    progress_bar PERCENT WIDTH
#    Prints a WIDTH-char bar colored by progress level:
#       >=70%  green   ████████░░░░
#       >=30%  yellow  ████░░░░░░░░
#        <30%  red     █░░░░░░░░░░░
# -----------------------------------------------------------------------------
progress_bar() {
    local pct="$1" width="$2"
    if [ "$pct" -lt 0 ]   2>/dev/null; then pct=0;   fi
    if [ "$pct" -gt 100 ] 2>/dev/null; then pct=100; fi

    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))

    # Guard: seq 1 0 outputs two lines in bash 3.2, so skip loop when count=0.
    local bar='' i
    if [ "$filled" -gt 0 ]; then
        for i in $(seq 1 "$filled"); do bar="${bar}${BAR_FULL}";  done
    fi
    if [ "$empty" -gt 0 ]; then
        for i in $(seq 1 "$empty");  do bar="${bar}${BAR_EMPTY}"; done
    fi

    local color
    if   [ "$pct" -ge 70 ]; then color="$FG_GREEN"
    elif [ "$pct" -ge 30 ]; then color="$FG_YELLOW"
    else                          color="$FG_RED"
    fi

    printf '%s%s%s' "$color" "$bar" "$RESET"
}

# -----------------------------------------------------------------------------
# 5. TIME HELPERS (macOS BSD date)
#    date -j -f FORMAT STRING +OUTPUT  parses a timestamp on macOS.
# -----------------------------------------------------------------------------
NOW_EPOCH=$(date -u +%s)

# iso_to_epoch ISO8601_UTC_STRING  →  unix timestamp integer
iso_to_epoch() {
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null || echo 0
}

# seconds_to_hms N  →  "2h 05m 30s"
seconds_to_hms() {
    local secs="$1"
    if [ "$secs" -lt 0 ] 2>/dev/null; then secs=0; fi
    local h=$(( secs / 3600 ))
    local m=$(( (secs % 3600) / 60 ))
    local s=$(( secs % 60 ))
    printf '%dh %02dm %02ds' "$h" "$m" "$s"
}

# age_label SECS  →  "5m 30s ago"
age_label() {
    local secs="$1"
    if   [ "$secs" -ge 3600 ] 2>/dev/null; then
        printf '%dh %02dm ago' "$(( secs/3600 ))" "$(( (secs%3600)/60 ))"
    elif [ "$secs" -ge 60 ]   2>/dev/null; then
        printf '%dm %02ds ago' "$(( secs/60 ))" "$(( secs%60 ))"
    else
        printf '%ds ago' "$secs"
    fi
}

# Seconds elapsed since a heartbeat ISO timestamp
heartbeat_age() {
    local hb_epoch
    hb_epoch=$(iso_to_epoch "$1")
    echo $(( NOW_EPOCH - hb_epoch ))
}

# -----------------------------------------------------------------------------
# 6. DATA DIRECTORY
# -----------------------------------------------------------------------------
DATA_DIR="${ORCH_DIR:-${HOME}/.claude/orchestrator}/workers"

if [ ! -d "$DATA_DIR" ]; then
    printf 'Error: data directory not found: %s\n' "$DATA_DIR" >&2
    exit 1
fi

# bash 3.2 compatible: no mapfile.  Use while+read with process substitution.
JSON_FILES=()
while IFS= read -r f; do
    JSON_FILES+=("$f")
done < <(ls -1 "${DATA_DIR}"/*.json 2>/dev/null | sort)

if [ "${#JSON_FILES[@]}" -eq 0 ]; then
    printf 'No worker JSON files found in %s\n' "$DATA_DIR" >&2
    exit 0
fi

# -----------------------------------------------------------------------------
# 7. PARSE ALL WORKERS
#    One jq call per file.  All needed fields extracted as @tsv in one pass.
#    bash 3.2: no associative arrays — use parallel indexed arrays.
# -----------------------------------------------------------------------------
W_ID=()
W_PROJECT=()
W_PHASE=()
W_PROGRESS=()
W_STATUS=()
W_STARTED=()
W_HEARTBEAT=()
W_BUDGET_SPENT=()
W_BUDGET_LIMIT=()
W_TASKS_DONE=()
W_TASKS_TOTAL=()
W_NOTES=()

idx=0
for f in "${JSON_FILES[@]}"; do
    raw=$(jq -r '
        [
            (.id              // "unknown"),
            ((.project_dir    // "unknown") | split("/") | last),
            (.phase           // "unknown"),
            ((.progress       // 0) | tostring),
            (.status          // "unknown"),
            (.spawned_at      // "1970-01-01T00:00:00Z"),
            (.last_output_at  // "1970-01-01T00:00:00Z"),
            ((.spent_usd      // 0) | tostring),
            ((.budget_usd     // 0) | tostring),
            "0",
            "0",
            (.notes           // "")
        ] | @tsv
    ' "$f" 2>/dev/null) || continue

    IFS=$'\t' read -r \
        _id _project _phase _progress _status \
        _started _heartbeat _bspent _blimit \
        _tdone _ttotal _notes \
    <<< "$raw"

    W_ID[$idx]="$_id"
    W_PROJECT[$idx]="$_project"
    W_PHASE[$idx]="$_phase"
    W_PROGRESS[$idx]="$_progress"
    W_STATUS[$idx]="$_status"
    W_STARTED[$idx]="$_started"
    W_HEARTBEAT[$idx]="$_heartbeat"
    W_BUDGET_SPENT[$idx]="$_bspent"
    W_BUDGET_LIMIT[$idx]="$_blimit"
    W_TASKS_DONE[$idx]="$_tdone"
    W_TASKS_TOTAL[$idx]="$_ttotal"
    W_NOTES[$idx]="$_notes"

    idx=$(( idx + 1 ))
done

WORKER_COUNT=$idx

# -----------------------------------------------------------------------------
# 8. SUMMARY TOTALS
# -----------------------------------------------------------------------------
total_budget="0"
total_active=0
total_stuck=0
total_crashed=0
total_completed=0
earliest_start=99999999999

for i in $(seq 0 $(( WORKER_COUNT - 1 ))); do
    # Float addition: use LC_NUMERIC=C + awk -v to bypass locale decimal issues.
    # Pass values as awk variables (not shell-interpolated into awk source) so
    # jq's period-decimal output is not mangled by the system locale (e.g. de_DE).
    total_budget=$(LC_NUMERIC=C awk -v a="$total_budget" -v b="${W_BUDGET_SPENT[$i]}" \
                   'BEGIN {printf "%.2f", a + b}')

    case "$(echo "${W_STATUS[$i]}" | tr '[:upper:]' '[:lower:]')" in
        active)    total_active=$(( total_active + 1 ))    ;;
        stuck)     total_stuck=$(( total_stuck + 1 ))      ;;
        crashed)   total_crashed=$(( total_crashed + 1 ))  ;;
        completed) total_completed=$(( total_completed + 1 )) ;;
    esac

    start_epoch=$(iso_to_epoch "${W_STARTED[$i]}")
    if [ "$start_epoch" -lt "$earliest_start" ] 2>/dev/null; then
        earliest_start=$start_epoch
    fi
done

if [ "$earliest_start" -eq 99999999999 ] 2>/dev/null; then
    earliest_start=$NOW_EPOCH
fi

total_runtime_secs=$(( NOW_EPOCH - earliest_start ))
if [ "$total_runtime_secs" -lt 0 ] 2>/dev/null; then total_runtime_secs=0; fi

# -----------------------------------------------------------------------------
# 9. COLUMN WIDTH CONSTANTS
#    All widths in visible (printable) characters.
# -----------------------------------------------------------------------------
CW_WORKER=15    # worker_id    (max expected: "worker-epsilon" = 14 chars)
CW_PROJECT=16   # project      (max expected: "frontend-cleanup" = 16 chars)
CW_PHASE=12     # phase
CW_BAR=12       # progress bar
CW_PCT=5        # " 72%"
CW_STATUS=10    # "> active"
CW_HB=15        # "5m 30s ago"

# BOX_INNER_W: total width between the outer left │ and outer right │
# Each column contributes: 1 (│) + 1 (space) + CW + 1 (space)
# The first │ is provided by the left border; last │ by right border.
# Pattern inside: │ col │ col │ ... │ col │
# = (CW + 2) per col * NUM_COLS + (NUM_COLS - 1) interior │ + 2 outer │ on edges
# But we measure BOX_INNER_W as the count between (not including) the outer │:
# = sum of [(1 │) + (1 sp) + CW + (1 sp)] for cols 2..7 + (1 sp) + CW_WORKER + (1 sp)
# Simplification: BOX_INNER_W = sum(CW + 2) * NUM_COLS + (NUM_COLS + 1) for separators
# Easier to just compute directly:
BOX_INNER_W=$(( CW_WORKER + 2 + 1 \
              + CW_PROJECT + 2 + 1 \
              + CW_PHASE + 2 + 1 \
              + CW_BAR + 2 + 1 \
              + CW_PCT + 2 + 1 \
              + CW_STATUS + 2 + 1 \
              + CW_HB + 2 ))

# -----------------------------------------------------------------------------
# 10. RENDERING HELPERS
# -----------------------------------------------------------------------------

top_border()  { hbar "$TL" "$H" "$TR" "$BOX_INNER_W"; printf '\n'; }
bot_border()  { hbar "$BL" "$H" "$BR" "$BOX_INNER_W"; printf '\n'; }
mid_divider() { hbar "$LT" "$H" "$RT" "$BOX_INNER_W"; printf '\n'; }

# Divider row with ┼ cross-junctions at each column boundary
header_divider() {
    # Column separator positions (1-based offset inside box, i.e. between the outer │)
    local p1=$(( 1 + CW_WORKER  + 2 ))
    local p2=$(( p1 + 1 + CW_PROJECT  + 2 ))
    local p3=$(( p2 + 1 + CW_PHASE    + 2 ))
    local p4=$(( p3 + 1 + CW_BAR      + 2 ))
    local p5=$(( p4 + 1 + CW_PCT      + 2 ))
    local p6=$(( p5 + 1 + CW_STATUS   + 2 ))

    local inner=$(( BOX_INNER_W - 2 ))
    local out="$LT"
    local pos
    for pos in $(seq 1 "$inner"); do
        if [ "$pos" -eq "$p1" ] || [ "$pos" -eq "$p2" ] || [ "$pos" -eq "$p3" ] || \
           [ "$pos" -eq "$p4" ] || [ "$pos" -eq "$p5" ] || [ "$pos" -eq "$p6" ]; then
            out="${out}${CT}"
        else
            out="${out}${H}"
        fi
    done
    printf '%s%s\n' "$out" "$RT"
}

# Column header row
# pad_cell strips ANSI for measurement, so we pass just the column width (CW_*).
# The ANSI bytes are present in the output but do not affect the visible width
# that pad_cell measures — so no ANSI overhead correction is needed here.
print_header_row() {
    printf '%s' "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}WORKER${RESET}"    $CW_WORKER)"           "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}PROJECT${RESET}"   $CW_PROJECT)"          "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}PHASE${RESET}"     $CW_PHASE)"            "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}PROGRESS${RESET}"  $CW_BAR)"              "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}PCT${RESET}"       $CW_PCT right)"        "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}STATUS${RESET}"    $CW_STATUS)"           "$V"
    printf ' %s %s' "$(pad_cell "${BOLD_WHITE}HEARTBEAT${RESET}" $CW_HB)"               "$V"
    printf '\n'
}

# One worker data row
# pad_cell handles colored strings correctly: it strips ANSI for measurement,
# so we just pass CW_* target widths — no ANSI overhead corrections needed.
print_data_row() {
    local id="$1" proj="$2" phase="$3" bar="$4" pct="$5" status="$6" hb="$7"

    local sc icon
    sc=$(status_color "$status")
    icon=$(status_icon "$status")
    local status_cell="${sc}${icon} ${status}${RESET}"

    printf '%s' "$V"
    printf ' %s %s' "$(pad_cell "$id"          $CW_WORKER)"    "$V"
    printf ' %s %s' "$(pad_cell "$proj"        $CW_PROJECT)"   "$V"
    printf ' %s %s' "$(pad_cell "$phase"       $CW_PHASE)"     "$V"
    printf ' %s %s' "$(pad_cell "$bar"         $CW_BAR)"       "$V"
    printf ' %s %s' "$(pad_cell "$pct"         $CW_PCT right)" "$V"
    printf ' %s %s' "$(pad_cell "$status_cell" $CW_STATUS)"    "$V"
    printf ' %s %s' "$(pad_cell "$hb"          $CW_HB)"        "$V"
    printf '\n'
}

# Full-width section heading inside a box
section_label() {
    local text="$1"
    local inner=$(( BOX_INNER_W - 2 ))
    local colored="${BOLD_CYAN}${BOLD}${text}${RESET}"
    local ansi_overhead=$(( ${#BOLD_CYAN} + ${#BOLD} + ${#RESET} ))
    local pad_right=$(( inner - ${#text} - 1 ))
    if [ "$pad_right" -lt 0 ]; then pad_right=0; fi
    printf '%s %s%s%s\n' "$V" "$colored" "$(repeat_char ' ' $pad_right)" "$V"
}

# Key=value summary line inside a box.
# kv_line LABEL VALUE [VALUE_COLOR]
# LABEL may itself contain ANSI color codes (e.g. for colored worker IDs).
# VALUE_COLOR defaults to plain white; plain labels get DIM styling.
kv_line() {
    local label="$1" value="$2" color="${3:-$FG_WHITE}"
    local inner=$(( BOX_INNER_W - 2 ))

    # Measure the *visible* (printable) length of the label
    local label_vis
    label_vis=$(printf '%s' "$label" | sed 's/\x1b\[[0-9;]*m//g')
    local label_vis_len=${#label_vis}

    # Pad label column to 22 visible chars for consistent value alignment
    local lpad=$(( 22 - label_vis_len ))
    if [ "$lpad" -lt 0 ]; then lpad=0; fi

    # Assemble the full line:  indent + label + padding + value + reset
    local line="  ${label}$(repeat_char ' ' $lpad)${color}${value}${RESET}"

    # Measure visible length for right-padding to box inner width
    local line_vis
    line_vis=$(printf '%s' "$line" | sed 's/\x1b\[[0-9;]*m//g')
    local pad_len=$(( inner - ${#line_vis} ))
    if [ "$pad_len" -lt 0 ]; then pad_len=0; fi

    printf '%s%s%s%s\n' "$V" "$line" "$(repeat_char ' ' $pad_len)" "$V"
}

# Blank line inside a box
box_blank() {
    local inner=$(( BOX_INNER_W - 2 ))
    printf '%s%s%s\n' "$V" "$(repeat_char ' ' $inner)" "$V"
}

# -----------------------------------------------------------------------------
# 11. RENDER
# -----------------------------------------------------------------------------

# Under `watch`, the screen is cleared before each invocation via $WATCH_INTERVAL.
# When run directly, clear ourselves.
if [ -z "${WATCH_INTERVAL:-}" ]; then
    clear
fi

# Position cursor at top-left (harmless under watch which already did this)
printf '\033[H'

render_time=$(date '+%Y-%m-%d %H:%M:%S')

printf '\n'
printf '%sORCHESTRATOR WORKER DASHBOARD%s' "$BOLD_CYAN" "$RESET"
printf '  %s%s%s\n' "$FG_GRAY" "$render_time" "$RESET"
printf '\n'

# ── WORKER TABLE ──────────────────────────────────────────────────────────────
top_border
print_header_row
header_divider

for i in $(seq 0 $(( WORKER_COUNT - 1 ))); do
    pct="${W_PROGRESS[$i]}"
    bar=$(progress_bar "$pct" $CW_BAR)
    pct_label=$(printf '%3d%%' "$pct")

    hb_secs=$(heartbeat_age "${W_HEARTBEAT[$i]}")
    hb_label=$(age_label "$hb_secs")

    print_data_row \
        "${W_ID[$i]}" \
        "${W_PROJECT[$i]}" \
        "${W_PHASE[$i]}" \
        "$bar" \
        "$pct_label" \
        "${W_STATUS[$i]}" \
        "$hb_label"

    if [ "$i" -lt $(( WORKER_COUNT - 1 )) ]; then
        mid_divider
    fi
done

bot_border

# ── SUMMARY PANEL ─────────────────────────────────────────────────────────────
printf '\n'
top_border
section_label 'SUMMARY'
mid_divider

kv_line 'Total runtime:'      "$(seconds_to_hms "$total_runtime_secs")"    "$FG_CYAN"
kv_line 'Total budget spent:' "\$${total_budget}"                           "$FG_MAGENTA"

box_blank

kv_line 'Active    workers:'  "$total_active workers running"               "$BOLD_GREEN"
kv_line 'Stuck     workers:'  "$total_stuck workers (stale heartbeat)"      "$BOLD_YELLOW"
kv_line 'Crashed   workers:'  "$total_crashed workers (terminated)"         "$BOLD_RED"
kv_line 'Completed workers:'  "$total_completed workers (finished)"         "$FG_CYAN"

box_blank
section_label 'WORKER NOTES'
mid_divider

for i in $(seq 0 $(( WORKER_COUNT - 1 ))); do
    note="${W_NOTES[$i]}"
    [ -z "$note" ] && continue
    sc=$(status_color "${W_STATUS[$i]}")
    # Build colored label; ansi_overhead = color + reset bytes
    local_label="${sc}${W_ID[$i]}${RESET}"
    kv_line "$local_label" "$note"
done

box_blank
bot_border

# ── LEGEND ────────────────────────────────────────────────────────────────────
printf '\n'
printf '  Legend: '
printf ' %s>%s active'    "$BOLD_GREEN"  "$RESET"
printf '   %s~%s stuck'   "$BOLD_YELLOW" "$RESET"
printf '   %sX%s crashed'  "$BOLD_RED"   "$RESET"
printf '   %s✓%s completed' "$FG_CYAN"  "$RESET"
printf '     %s[%s]%s full'  "$FG_GREEN" "$(repeat_char "$BAR_FULL"  6)" "$RESET"
printf '   %s[%s]%s empty\n' "$FG_GRAY"  "$(repeat_char "$BAR_EMPTY" 6)" "$RESET"
printf '\n'
printf '  %sData dir : %s%s\n' "$FG_GRAY" "$DATA_DIR" "$RESET"
printf '  %sRefresh  : watch -n 5 %s%s\n' "$FG_GRAY" "$0" "$RESET"
printf '\n'
