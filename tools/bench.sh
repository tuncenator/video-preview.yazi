#!/usr/bin/env bash
# bench.sh -- time a cold-cache run of preview.sh and compare against source info.
# Usage: ./bench.sh /path/to/video.mp4
set -euo pipefail

LOOP_MODE=0
VIDEO=""
for arg in "$@"; do
  case "$arg" in
    --loop) LOOP_MODE=1 ;;
    -h|--help)
      echo "usage: $0 video.mp4 [--loop]"
      echo "  --loop  also measure real animation fps live (requires running yazi)"
      exit 0 ;;
    *) [[ -z "$VIDEO" ]] && VIDEO="$arg" ;;
  esac
done
[[ -z "$VIDEO" || ! -f "$VIDEO" ]] && { echo "usage: $0 video.mp4 [--loop]" >&2; exit 1; }

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCRIPT="$REPO/preview.sh"
[[ -x "$SCRIPT" ]] || { echo "no executable preview.sh at $SCRIPT" >&2; exit 1; }
command -v ffprobe >/dev/null || { echo "ffprobe required" >&2; exit 1; }

TMP="$(mktemp -d -t vp-bench.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- source info -------------------------------------------------------------
# ffprobe orders fields by its internal struct layout, not by request order,
# so use key=value output and look up each field by name.
PROBE=$(ffprobe -v error -select_streams v:0 \
  -show_entries stream=width,height,r_frame_rate,codec_name,bit_rate \
  -of default=noprint_wrappers=1 -- "$VIDEO")
if [[ -z "$PROBE" ]]; then
  echo "ffprobe could not read a video stream from: $VIDEO" >&2
  exit 1
fi
val() { printf "%s\n" "$PROBE" | awk -F= -v k="$1" '$1==k {print $2; exit}'; }
W=$(val width)
H=$(val height)
FPS_R=$(val r_frame_rate)
CODEC=$(val codec_name)
BR=$(val bit_rate)
DUR_F=$(ffprobe -v error -show_entries format=duration \
          -of default=noprint_wrappers=1:nokey=1 -- "$VIDEO")
SIZE_B=$(stat -c %s -- "$VIDEO" 2>/dev/null || stat -f %z -- "$VIDEO")
DUR_INT=$(awk -v d="$DUR_F" 'BEGIN { printf "%d", d+0.5 }')
SRC_FPS=$(awk -v r="$FPS_R" 'BEGIN {
            n=split(r,a,"/"); if (n==2 && a[2]+0>0) printf "%.2f", a[1]/a[2];
            else printf "%s", r }')
BR_FMT=$(awk -v b="$BR" 'BEGIN {
           if (b+0>0) printf "%.1f Mbit/s", b/1000000; else printf "n/a" }')
SIZE_FMT=$(awk -v s="$SIZE_B" 'BEGIN { printf "%.1f MiB", s/1048576 }')

# Detect whether the preview.sh under test has -hwaccel wired in.
if grep -q -- '-hwaccel' "$SCRIPT"; then
  HW="yes"
else
  HW="no"
fi

LOOP_DEFAULT=30
if (( DUR_INT <= LOOP_DEFAULT )); then
  TIER="tier 1 (native dense)"
else
  TIER="tier 2 (fps-filter timelapse)"
fi

echo "=== source ==="
printf "%-16s %s\n"    "file:"       "$VIDEO"
printf "%-16s %s\n"    "size:"       "$SIZE_FMT"
printf "%-16s %ss\n"   "duration:"   "$DUR_INT"
printf "%-16s %sx%s %s @ %s fps, %s\n" "video:" "$W" "$H" "$CODEC" "$SRC_FPS" "$BR_FMT"
echo

# --- run extraction ----------------------------------------------------------
START=$(date +%s.%N)
OUT=$(VP_CACHE_ROOT="$TMP" "$SCRIPT" --path "$VIDEO")
END=$(date +%s.%N)
ELAPSED=$(awk -v s="$START" -v e="$END" 'BEGIN { printf "%.2f", e-s }')

DIR=$(printf "%s\n"   "$OUT" | awk -F= '/^DIR=/      {print $2; exit}')
COUNT=$(printf "%s\n" "$OUT" | awk -F= '/^COUNT=/    {print $2; exit}')
TFPS=$(printf "%s\n"  "$OUT" | awk -F= '/^FPS=/      {print $2; exit}')
SRC_T=$(printf "%s\n" "$OUT" | awk -F= '/^SOURCE_T=/ {print $2; exit}')
ERR=$(printf "%s\n"   "$OUT" | awk -F= '/^ERR=/      {print $2; exit}')

if [[ -n "$ERR" || -z "$DIR" ]]; then
  echo "extraction failed: ${ERR:-no DIR in output}" >&2
  echo "--- raw output ---" >&2
  printf "%s\n" "$OUT" >&2
  exit 1
fi

TOTAL_B=$(du -sb "$DIR" 2>/dev/null | awk '{print $1}')
TOTAL_FMT=$(awk -v b="$TOTAL_B" 'BEGIN { printf "%.1f MiB", b/1048576 }')
AVG=$(awk -v b="$TOTAL_B" -v c="$COUNT" 'BEGIN {
        if (c+0>0) printf "%.1f KiB", b/c/1024; else printf "n/a" }')

# Extraction speed: how many seconds of source we crunched per second of wall.
EXTRACT_SPEED=$(awk -v st="$SRC_T" -v el="$ELAPSED" 'BEGIN {
                  if (el+0>0) printf "%.1fx", st/el; else printf "inf" }')

# Theoretical loop: COUNT frames at TFPS. Real playback is render-bound and
# usually slower; --loop measures the real number live.
LOOP_WALL=$(awk -v c="$COUNT" -v f="$TFPS" 'BEGIN {
              if (f+0>0) printf "%.1f", c/f; else printf "0" }')

echo "=== extraction (cold cache) ==="
printf "%-16s %s\n"          "mode:"      "$TIER"
printf "%-16s %s\n"          "hwaccel:"   "$HW"
printf "%-16s %s @ %s fps target\n" "frames:" "$COUNT" "$TFPS"
printf "%-16s %s (avg %s)\n" "output:"    "$TOTAL_FMT" "$AVG"
echo

echo "=== preview vs source ==="
printf "%-16s %ss\n"           "source duration:"  "$DUR_INT"
printf "%-16s %ss   (%s faster than source duration)\n" \
       "wait to render:"  "$ELAPSED" "$EXTRACT_SPEED"
printf "%-16s %ss   (theoretical, render-bound playback is slower)\n" \
       "ideal loop:"  "$LOOP_WALL"

# --- live render-rate measurement (opt-in) -----------------------------------
if (( LOOP_MODE == 1 )); then
  LOG="/tmp/yazi-vp-render.log"
  : > "$LOG"
  echo
  echo "=== live render measurement ==="
  echo "1. In another terminal:"
  echo "     export VP_DEBUG_RENDER_LOG=$LOG"
  echo "     yazi $(dirname "$VIDEO")"
  echo "2. Hover \"$(basename "$VIDEO")\" for >=15 seconds."
  echo "3. Press Enter here to stop."
  printf "> "
  M_START=$(date +%s.%N)
  read -r _ </dev/tty
  M_END=$(date +%s.%N)
  M_ELAPSED=$(awk -v s="$M_START" -v e="$M_END" 'BEGIN { printf "%.2f", e-s }')
  M_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)

  if (( M_LINES < 5 )); then
    echo "got $M_LINES renders in ${M_ELAPSED}s -- too few. Did you set VP_DEBUG_RENDER_LOG and hover the file?" >&2
  else
    REAL_FPS=$(awk -v l="$M_LINES" -v e="$M_ELAPSED" 'BEGIN { printf "%.2f", l/e }')
    REAL_LOOP=$(awk -v c="$COUNT" -v f="$REAL_FPS" 'BEGIN {
                  if (f+0>0) printf "%.1f", c/f; else printf "0" }')
    REAL_SPEED=$(awk -v st="$SRC_T" -v rl="$REAL_LOOP" 'BEGIN {
                   if (rl+0>0) printf "%.2fx", st/rl; else printf "inf" }')
    printf "%-16s %s renders / %ss\n" "samples:" "$M_LINES" "$M_ELAPSED"
    printf "%-16s %s\n"               "real fps:" "$REAL_FPS"
    printf "%-16s %ss   (animation plays at %s source speed)\n" \
           "real loop:" "$REAL_LOOP" "$REAL_SPEED"
  fi
  rm -f "$LOG"
fi
