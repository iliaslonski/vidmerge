#!/bin/bash
# vidmerge.sh — merge Xiaomi camera 1-minute clips into a single video file.
#
# Recognized filename formats:
#   * 1766763309000.mp4       — Mi Home → Photos export (timestamp in ms)
#   * 29M53S_1780082993.mp4   — directly from SD card (MMmSSs_ + timestamp in s)
#
# By default merges ALL recognized .mp4 files in the folder. Optionally filter
# by time with --from / --to / --duration.
#
# Uses ffmpeg concat demuxer with -c copy (no re-encoding, fast, no quality loss),
# provided all clips have the same codec/resolution/fps — for one camera that's
# always the case.

set -euo pipefail

# ───────────────────────── Help ─────────────────────────
print_help() {
  cat <<'EOF'
Usage:
  ./vidmerge.sh                                       # merge ALL files in folder (default)
  ./vidmerge.sh --from "today 14:00" --to "today 15:30"
  ./vidmerge.sh --from "yesterday 22:00" --to "today 02:00"
  ./vidmerge.sh --from "14:00" --duration 90m         # no date = today
  ./vidmerge.sh --from "2026-05-30 14:00" --to "2026-05-30 15:30"
  ./vidmerge.sh --verify-tz                           # check timezone alignment
  ./vidmerge.sh -h | --help

Without range flags the script merges all recognized minute-clips in the folder.
The filter applies only when at least one of --from, --to, --duration is given.

Options:
  --from   <STR>   Range start. Local Mac time.
                   Formats: "YYYY-MM-DD HH:MM[:SS]"
                            "today HH:MM"     / "сегодня HH:MM"
                            "yesterday HH:MM" / "вчера HH:MM"
                            "HH:MM[:SS]"      (= today)
  --to     <STR>   Range end (exclusive). Same formats.
  --duration <D>   Duration from --from. Examples: 90m, 1h30m, 2h, 30s
  --dir    <PATH>  Folder with clips (default: current directory).
  --output <FILE>  Output file name (default: built from range and comment).
  --comment <STR>  Event comment (e.g. "Lidl"). Default: current folder name.
                   Saved into file name and into mp4 metadata (title/comment) —
                   visible in QuickTime/VLC and indexed by Spotlight.
                   For no comment at all pass an empty string: --comment ""
                   In the interactive prompt you can also type a new comment.
  --verify-tz      Timezone check: compare filename timestamp against
                   the file's mtime and creation_time from video metadata.
  -y, --yes        Skip confirmation prompts.
  -v, --verbose    Show ffmpeg's full output (bitrate, fps, progress, warnings).
  -h, --help       This help.

Recognized filename formats:
  1766763309000.mp4       (Mi Home Export — milliseconds)
  29M53S_1780082993.mp4   (directly from SD card — seconds)
EOF
}

# ──────────────────────── Argument parsing ────────────────────────
DIR="$(pwd)"
FROM_STR=""
TO_STR=""
DURATION_STR=""
OUTPUT=""
COMMENT=""
COMMENT_EXPLICIT=0   # was --comment passed (even empty)?
VERIFY_TZ=0
ASSUME_YES=0
VERBOSE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)       FROM_STR="${2:-}"; shift 2 ;;
    --to)         TO_STR="${2:-}"; shift 2 ;;
    --duration)   DURATION_STR="${2:-}"; shift 2 ;;
    --all)        shift ;;   # no-op, kept for backward compatibility (default = all)
    --dir)        DIR="${2:-}"; shift 2 ;;
    --output|-o)  OUTPUT="${2:-}"; shift 2 ;;
    --comment)    COMMENT="${2:-}"; COMMENT_EXPLICIT=1; shift 2 ;;
    --verify-tz)  VERIFY_TZ=1; shift ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    -v|--verbose) VERBOSE=1; shift ;;
    -h|--help)    print_help; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; print_help; exit 1 ;;
  esac
done

cd "$DIR"

# Default comment = current folder name. User can opt out via --comment ""
if [[ $COMMENT_EXPLICIT -eq 0 ]]; then
  COMMENT="$(basename "$(pwd)")"
fi

# Slug for the file name — whitelist approach:
# keep Unicode letters, Unicode digits, '_', '.', '-'. Everything else (spaces,
# commas, brackets, quotes, slashes, etc.) becomes '_'. Then collapse runs of '_'.
# Perl with -CSDA handles UTF-8 correctly regardless of locale.
comment_slug() {
  echo "$1" | perl -CSDA -pe 's/[^\p{L}\p{N}_.-]/_/g' | tr -s '_' | sed 's/^_//;s/_$//'
}

# ─────────────────────── Dependencies ───────────────────────
command -v ffmpeg  >/dev/null || { echo "ffmpeg not found. brew install ffmpeg"  >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe not found. brew install ffmpeg" >&2; exit 1; }

# ───────────────────── Visual chrome (header + status markers) ─────────────────────
# Block-only aesthetic. Heavy frame around the header, ▓▓ markers for state lines.
# The frame is fixed width (64) and never changes — content lines elsewhere flow free.

# Header: light fade frame + V4 camera icon (single sphere with volumetric shading).
# Frame uses only ░ ▒ (no █), so the camera stays the only dense visual element.
# Inner width is 62 visible chars; helper pads each line accounting for ANSI escapes.
HEADER_INNER_WIDTH=62
header_line() {
  local content="$1"
  # Strip ANSI escape sequences before measuring, then pad to inner width.
  local content_len
  content_len=$(printf '%s' "$content" | perl -CSDA -pe 's/\e\[[0-9;]*m//g' | wc -m | tr -d ' ')
  local pad=$(( HEADER_INNER_WIDTH - content_len ))
  (( pad < 0 )) && pad=0
  local padding
  padding=$(printf '%*s' "$pad" '')
  printf "░%s%s░\n" "$content" "$padding"
}
print_header() {
  local R="$C_RESET" B="$C_BOLD" D="$C_DIM"
  local bar
  bar=$(printf '%*s' "$HEADER_INNER_WIDTH" '' | tr ' ' '▒')
  printf '\n'
  printf "░%s░\n" "$bar"
  header_line ""
  header_line "    ▗▄▄▄▄▖"
  header_line "    █░${B}◉${R} ▒█     ${B}vidmerge${R} ${D}· version \"good enough 01\"${R}"
  header_line "    █░ ▒▒█     ${D}Xiaomi camera clip merger · by @slonski${R}"
  header_line "    ▝▀▀▀▀▘"
  header_line ""
  printf "░%s░\n" "$bar"
}

# Status line: dense marker · bold title · dim aside.
# By default no color (neutral). Pass a color for emphasized states (Done, Warning).
# Usage: print_status "▓▓" "Ready to merge" "let's see"
#        print_status "▓▓" "✓ Done" "that worked" "$C_GREEN"
print_status() {
  local marker="$1" title="$2" aside="${3:-}" color="${4:-}"
  if [[ -n "$aside" ]]; then
    printf "${color}${C_BOLD}%s${C_RESET} ${C_BOLD}%s${C_RESET} ${C_DIM}— %s${C_RESET}\n" "$marker" "$title" "$aside"
  else
    printf "${color}${C_BOLD}%s${C_RESET} ${C_BOLD}%s${C_RESET}\n" "$marker" "$title"
  fi
}

# ───────────────────── Time utilities ─────────────────────
# Time string → epoch seconds (local Mac time). Supported formats:
#   "YYYY-MM-DD HH:MM[:SS]"
#   "today HH:MM[:SS]"     / "сегодня HH:MM[:SS]"
#   "yesterday HH:MM[:SS]" / "вчера HH:MM[:SS]"
#   "HH:MM[:SS]"  (= today)
#
# NOTE: BSD date substitutes CURRENT seconds if %S is not in the format.
# So when input has no seconds, we append ":00" and parse strictly.
parse_local_to_sec() {
  local s="$1"
  local sec date_prefix="" time_part="$s"

  shopt -s nocasematch
  if   [[ "$s" =~ ^(today|сегодня)[[:space:]]+(.+)$ ]]; then
    date_prefix=$(date "+%Y-%m-%d")
    time_part="${BASH_REMATCH[2]}"
  elif [[ "$s" =~ ^(yesterday|вчера)[[:space:]]+(.+)$ ]]; then
    date_prefix=$(date -v -1d "+%Y-%m-%d")
    time_part="${BASH_REMATCH[2]}"
  elif [[ "$s" =~ ^[0-9]{1,2}:[0-9]{2}(:[0-9]{2})?$ ]]; then
    date_prefix=$(date "+%Y-%m-%d")
    time_part="$s"
  fi
  shopt -u nocasematch

  [[ -n "$date_prefix" ]] && s="$date_prefix $time_part"

  if sec=$(date -j -f "%Y-%m-%d %H:%M:%S" "$s" +%s 2>/dev/null); then
    echo "$sec"; return 0
  fi
  if sec=$(date -j -f "%Y-%m-%d %H:%M:%S" "${s}:00" +%s 2>/dev/null); then
    echo "$sec"; return 0
  fi
  echo "Invalid time format: '$1'. Examples: \"2026-05-30 14:00\", \"today 14:00\", \"yesterday 22:00\", \"14:00\"" >&2
  return 1
}

# "90m" / "1h30m" / "2h" / "45s" / "3600" → seconds
parse_duration_to_sec() {
  local d="$1"
  if [[ "$d" =~ ^[0-9]+$ ]]; then echo "$((d * 60))"; return 0; fi
  local total=0 rest="$d" n unit
  while [[ -n "$rest" ]]; do
    if [[ "$rest" =~ ^([0-9]+)([hms])(.*)$ ]]; then
      n="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
      case "$unit" in
        h) total=$((total + n * 3600)) ;;
        m) total=$((total + n * 60))   ;;
        s) total=$((total + n))        ;;
      esac
    else
      echo "Invalid duration: '$d'. Examples: 90m, 1h30m, 2h, 45s" >&2
      return 1
    fi
  done
  echo "$total"
}

sec_to_local() { date -j -r "$1" "+%Y-%m-%d %H:%M:%S"; }

# Seconds → "1h 23m 45s" (leading zero components dropped)
human_duration() {
  local total=${1%.*}
  (( total < 0 )) && total=0
  local h=$(( total / 3600 ))
  local m=$(( (total % 3600) / 60 ))
  local s=$(( total % 60 ))
  if   (( h > 0 )); then printf "%dh %02dm %02ds" "$h" "$m" "$s"
  elif (( m > 0 )); then printf "%dm %02ds" "$m" "$s"
  else                   printf "%ds" "$s"
  fi
}

# Bytes → "540 MB" / "1.2 GB" / "320 KB"
human_size() {
  local b="$1"
  if   (( b >= 1073741824 )); then awk -v n="$b" 'BEGIN{printf "%.1f GB", n/1073741824}'
  elif (( b >= 1048576    )); then awk -v n="$b" 'BEGIN{printf "%.0f MB", n/1048576}'
  elif (( b >= 1024       )); then awk -v n="$b" 'BEGIN{printf "%.0f KB", n/1024}'
  else echo "${b} B"
  fi
}

# ANSI colors — disabled when stdout is not a tty (e.g. piped to file).
# We use color sparingly — only for success (bright green) and warnings (yellow).
# Bright green (92) is more reliably read as "green" on themed palettes than 32.
if [[ -t 1 ]]; then
  C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'; C_GREEN=$'\033[92m'
  C_YELLOW=$'\033[33m'; C_CYAN=$'\033[36m'; C_RESET=$'\033[0m'
else
  C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_RESET=""
fi

print_header

# Extract Unix timestamp (seconds) from either filename format.
# 13-digit timestamps (milliseconds) divided by 1000; 10-digit kept as-is.
file_timestamp_s() {
  local base="${1%.mp4}"
  local ts
  if [[ "$base" =~ ^[0-9]+[Mm][0-9]+[Ss]_([0-9]+)$ ]]; then
    ts="${BASH_REMATCH[1]}"
  elif [[ "$base" =~ ^[0-9]+$ ]]; then
    ts="$base"
  else
    return 1
  fi
  if (( ${#ts} >= 13 )); then
    echo $((ts / 1000))
  else
    echo "$ts"
  fi
}

is_recognized_name() {
  local base="${1%.mp4}"
  [[ "$base" =~ ^[0-9]{10,16}$ ]] || [[ "$base" =~ ^[0-9]+[Mm][0-9]+[Ss]_[0-9]+$ ]]
}

# ──────────────────── Collect files ───────────────────
shopt -s nullglob
all_mp4=(*.mp4)
shopt -u nullglob

if [[ ${#all_mp4[@]} -eq 0 ]]; then
  echo "⚠  No .mp4 files in $DIR" >&2
  exit 1
fi

declare -a valid_files invalid_names
for f in "${all_mp4[@]}"; do
  [[ "$f" == "$OUTPUT"        ]] && continue
  [[ "$f" == "full_video.mp4" ]] && continue
  [[ "$f" == merged_*.mp4     ]] && continue
  if is_recognized_name "$f"; then
    valid_files+=("$f")
  else
    invalid_names+=("$f")
  fi
done

if [[ ${#invalid_names[@]} -gt 0 ]]; then
  echo "⚠  Skipped files with unrecognized names: ${invalid_names[*]}" >&2
fi

if [[ ${#valid_files[@]} -eq 0 ]]; then
  echo "⚠  No files with recognizable names in $DIR" >&2
  echo "  Expected formats:" >&2
  echo "    1766763309000.mp4       (Mi Home Export)" >&2
  echo "    29M53S_1780082993.mp4   (directly from SD card)" >&2
  exit 1
fi

# ──────────────────── Sort by timestamp ───────────────────
# Sort "ts<TAB>file" pairs numerically by ts, then unpack into parallel arrays.
declare -a tag_lines=()
for f in "${valid_files[@]}"; do
  ts=$(file_timestamp_s "$f")
  tag_lines+=("${ts}"$'\t'"${f}")
done
IFS=$'\n' tag_lines=($(printf '%s\n' "${tag_lines[@]}" | sort -n)); unset IFS

valid_files=()
declare -a valid_ts=()
for line in "${tag_lines[@]}"; do
  valid_ts+=("${line%%$'\t'*}")
  valid_files+=("${line#*$'\t'}")
done

first_ts_s="${valid_ts[0]}"
last_ts_s="${valid_ts[${#valid_ts[@]}-1]}"

# ───────────────────── Timezone check ─────────────────────
if [[ $VERIFY_TZ -eq 1 ]]; then
  sample="${valid_files[0]}"
  ts_s=$(file_timestamp_s "$sample")
  mtime_s=$(stat -f "%m" "$sample")
  meta=$(ffprobe -v error -show_entries format_tags=creation_time \
                 -of default=nw=1:nk=1 "$sample" 2>/dev/null || true)

  echo "Sample file: $sample"
  echo "  Filename timestamp → local: $(sec_to_local "$ts_s")"
  echo "  File mtime         → local: $(sec_to_local "$mtime_s")"
  [[ -n "$meta" ]] && echo "  Video creation_time (UTC): $meta"
  echo "  Mac timezone: $(date +%Z), offset $(date +%z)"

  diff=$((mtime_s - ts_s)); abs=${diff#-}
  if (( abs <= 90 )); then
    echo "  ✓ Filename timestamp matches mtime (Δ=${diff}s). Timezone OK."
  else
    echo "  ⚠ Name↔mtime delta = ${diff}s. Camera might be in a different timezone."
    echo "     In that case pass --from/--to adjusted for the offset."
  fi
  exit 0
fi

# ───────────────────── Resolve range ─────────────────────
range_from_s=""
range_to_s=""

if [[ -n "$FROM_STR" ]]; then range_from_s=$(parse_local_to_sec "$FROM_STR"); fi
if [[ -n "$TO_STR"   ]]; then range_to_s=$(parse_local_to_sec "$TO_STR");     fi
if [[ -n "$DURATION_STR" ]]; then
  [[ -z "$range_from_s" ]] && { echo "--duration requires --from" >&2; exit 1; }
  [[ -n "$range_to_s"   ]] && { echo "Use either --to or --duration, not both" >&2; exit 1; }
  dur_s=$(parse_duration_to_sec "$DURATION_STR")
  range_to_s=$((range_from_s + dur_s))
fi

# ───────────────────── Apply filter ─────────────────────
# If no range given — take everything (default behavior).
declare -a selected selected_ts
if [[ -z "$range_from_s" && -z "$range_to_s" ]]; then
  selected=("${valid_files[@]}")
  selected_ts=("${valid_ts[@]}")
else
  for i in "${!valid_files[@]}"; do
    ts="${valid_ts[$i]}"
    if [[ -n "$range_from_s" && $ts -lt $range_from_s ]]; then continue; fi
    if [[ -n "$range_to_s"   && $ts -ge $range_to_s   ]]; then continue; fi
    selected+=("${valid_files[$i]}")
    selected_ts+=("$ts")
  done
fi

if [[ ${#selected[@]} -eq 0 ]]; then
  echo "⚠  No files matched the selected range." >&2
  exit 1
fi

sel_first_ts_s="${selected_ts[0]}"
sel_last_ts_s="${selected_ts[${#selected_ts[@]}-1]}"

# ───────────────────── Codec consistency ─────────────────────
# Stream-copy breaks if clips have different codec/resolution/fps.
# Probe first, middle, and last.
probe_signature() {
  ffprobe -v error -select_streams v:0 \
          -show_entries stream=codec_name,width,height,r_frame_rate \
          -of csv=p=0 "$1"
}
sig_first=$(probe_signature "${selected[0]}")
sig_mid=$(  probe_signature "${selected[${#selected[@]}/2]}")
sig_last=$( probe_signature "${selected[${#selected[@]}-1]}")
if [[ "$sig_first" != "$sig_mid" || "$sig_first" != "$sig_last" ]]; then
  echo "⚠  Video parameters differ between files:"
  echo "    first:   $sig_first"
  echo "    middle:  $sig_mid"
  echo "    last:    $sig_last"
  echo "  Stream-copy may produce artifacts. Aborted."
  echo "  Run ffmpeg manually with re-encoding (-c:v libx264) if this is expected."
  exit 1
fi

# ───────────────────── Output name + preview + confirm ─────────────────────
# OUTPUT_USER_SET=1 if user passed --output (then don't recompute on comment change)
OUTPUT_USER_SET=0
[[ -n "$OUTPUT" ]] && OUTPUT_USER_SET=1

build_output_name() {
  [[ $OUTPUT_USER_SET -eq 1 ]] && return 0
  local from_date to_date from_time to_time comment_part=""
  from_date=$(date -j -r "$sel_first_ts_s" "+%Y-%m-%d")
  to_date=$(  date -j -r "$sel_last_ts_s"  "+%Y-%m-%d")
  from_time=$(date -j -r "$sel_first_ts_s" "+%H-%M")
  to_time=$(  date -j -r "$sel_last_ts_s"  "+%H-%M")
  [[ -n "$COMMENT" ]] && comment_part="_$(comment_slug "$COMMENT")"
  if [[ "$from_date" == "$to_date" ]]; then
    OUTPUT="merged_${from_date}_${from_time}_to_${to_time}${comment_part}.mp4"
  else
    OUTPUT="merged_${from_date}_${from_time}_to_${to_date}_${to_time}${comment_part}.mp4"
  fi
}

# Duration and size estimates (don't depend on COMMENT — compute once)
est_duration_s=$(( ${#selected[@]} * 60 ))
est_bytes=0
for f in "${selected[@]}"; do
  est_bytes=$(( est_bytes + $(stat -f "%z" "$f") ))
done

show_preview() {
  echo
  print_status "▓▓" "Ready to merge" "let's see"
  printf "   Files:        ${C_BOLD}%d${C_RESET}\n" "${#selected[@]}"
  printf "   Start:        %s\n" "$(sec_to_local "$sel_first_ts_s")"
  printf "   End:          %s\n" "$(sec_to_local "$sel_last_ts_s")"
  printf "   Duration:     ≈ ${C_BOLD}%s${C_RESET}\n" "$(human_duration "$est_duration_s")"
  printf "   Size:         ≈ ${C_BOLD}%s${C_RESET}\n" "$(human_size "$est_bytes")"
  if [[ -n "$COMMENT" ]]; then
    printf "   Comment:      ${C_BOLD}%s${C_RESET}  ${C_DIM}(in file name & video metadata)${C_RESET}\n" "$COMMENT"
  else
    printf "   Comment:      ${C_DIM}(none)${C_RESET}\n"
  fi
  printf "   ${C_DIM}Specs:        %s${C_RESET}\n" "$sig_first"
  printf "   Output:       %s\n" "$OUTPUT"
}

build_output_name
if [[ $ASSUME_YES -eq 1 ]]; then
  show_preview
else
  # Interactive loop: preview → answer.
  # Contract: Enter = proceed · q = quit · any other text = new comment.
  COMMENT_MAX_LEN=50
  while true; do
    show_preview
    echo
    echo "${C_DIM}[Enter]  start merge${C_RESET}"
    echo "${C_DIM}[q]      cancel${C_RESET}"
    echo "${C_DIM}[text]   set as new comment (up to ${COMMENT_MAX_LEN} chars, saved in file name + metadata)${C_RESET}"
    read -r -p "> " a
    case "$a" in
      "")
        if [[ -e "$OUTPUT" ]]; then
          read -r -p "File $OUTPUT already exists. Overwrite? [y/N]: " ow
          [[ "$ow" =~ ^[yY]$ ]] || { echo "Cancelled"; continue; }
        fi
        break
        ;;
      q|Q)
        echo "Cancelled"; exit 0
        ;;
      *)
        char_len=$(printf %s "$a" | wc -m | tr -d ' ')
        if (( char_len > COMMENT_MAX_LEN )); then
          echo "${C_YELLOW}⚠  Comment too long (${char_len} of ${COMMENT_MAX_LEN} chars). Bit much.${C_RESET}"
        else
          COMMENT="$a"
          build_output_name
        fi
        ;;
    esac
  done
fi

# ───────────────────── Merge ─────────────────────
tmp_list=$(mktemp -t vidmerge_concat.XXXXXX)
trap 'rm -f "$tmp_list"' EXIT
for f in "${selected[@]}"; do
  printf "file '%s'\n" "$(pwd)/$f" >> "$tmp_list"
done

# mp4 metadata (title + comment) — written if comment is set
metadata_args=()
if [[ -n "$COMMENT" ]]; then
  metadata_args=(-metadata "title=$COMMENT" -metadata "comment=$COMMENT")
fi

# ffmpeg logging: by default quiet (one "Merging…" line);
# with --verbose — full stream (bitrate, fps, progress).
if [[ $VERBOSE -eq 1 ]]; then
  ffmpeg_log_args=(-hide_banner -loglevel warning -stats)
else
  ffmpeg_log_args=(-hide_banner -loglevel error)
  echo
  printf "${C_BOLD}▸ Merging files…   ░ ░ ░  →  ▓▓▓${C_RESET}\n"
fi

ffmpeg "${ffmpeg_log_args[@]}" -y \
       -f concat -safe 0 -i "$tmp_list" \
       -c copy ${metadata_args[@]+"${metadata_args[@]}"} "$OUTPUT"

# ───────────────────── Summary ─────────────────────
out_dur_raw=$(ffprobe -v error -show_entries format=duration \
                      -of default=nw=1:nk=1 "$OUTPUT" 2>/dev/null || echo "0")
out_bytes=$(stat -f "%z" "$OUTPUT")

echo
print_status "▓▓" "✓ Done" "that worked" "$C_GREEN"
printf "   File:         ${C_BOLD}%s${C_RESET}\n" "$OUTPUT"
printf "   Duration:     ${C_BOLD}%s${C_RESET}\n" "$(human_duration "$out_dur_raw")"
printf "   Size:         ${C_BOLD}%s${C_RESET}\n" "$(human_size "$out_bytes")"

# Offer to reveal the file in Finder, then a small parting note.
if [[ $ASSUME_YES -eq 0 && -t 0 ]]; then
  echo
  read -r -p "Reveal in Finder? [Enter=yes, n=no]: " a
  echo
  if [[ -z "$a" || "$a" =~ ^[yY]$ ]]; then
    open -R "$OUTPUT"
    printf "${C_DIM}Off you go.${C_RESET}\n"
  else
    printf "${C_DIM}Alright then.${C_RESET}\n"
  fi
fi
