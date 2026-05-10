#!/usr/bin/env bash
# video-preview.yazi extractor.
#
# Three sub-modes driven by the lua side:
#  --probe                 print DIR= and DURATION=, no work.
#  --slot I --ts T         extract one frame at timestamp T into DIR/000I.jpg.
#  (no flags)              upfront extraction: full clip -> DIR/0001..NNNN.jpg.
#
# Lua picks the mode based on duration: short/mid clips use upfront extraction
# for smooth animated playback; long clips use per-slot lazy extraction so the
# UI never blocks for more than one ffmpeg keyframe-seek at a time.
set -euo pipefail
IFS=$'\n'

FILE_PATH=""
MODE="run"
SLOT=""
SLOT_TS=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) shift; FILE_PATH="${1:-}";;
    --probe) MODE="probe";;
    --slot) shift; SLOT="${1:-}"; MODE="slot";;
    --ts)   shift; SLOT_TS="${1:-}";;
    *) ;;
  esac
  shift || true
done

[[ -z "${FILE_PATH}" || ! -f "${FILE_PATH}" ]] && { echo "ERR=no_such_file"; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Lua sets these via Command:env(...). Defaults match main.lua DEFAULTS.
TARGET_FPS="${VP_TARGET_FPS:-12}"
LOOP_SECONDS="${VP_LOOP_SECONDS:-30}"
OUT_W="${VP_OUT_W:-640}"
OUT_H="${VP_OUT_H:-360}"
JPG_QUALITY="${VP_JPG_QUALITY:-7}"
CACHE_CAP_MB="${VP_CACHE_CAP_MB:-1024}"
CACHE_AGE_DAYS="${VP_CACHE_AGE_DAYS:-7}"
VP_MODE="${VP_MODE:-upfront}"
VP_LAZY_SLIDES="${VP_LAZY_SLIDES:-0}"

(( LOOP_SECONDS < 10 )) && LOOP_SECONDS=10

hash_str() {
  printf "%s" "$1" | (md5sum 2>/dev/null || sha1sum 2>/dev/null) | awk '{print $1}'
}

cache_key() {
  local st
  if st="$(stat -Lc '%n|%Y|%s' -- "$FILE_PATH" 2>/dev/null)"; then
    :
  else
    st="$(stat -f '%N|%m|%z' -- "$FILE_PATH")"
  fi
  if [[ "$VP_MODE" == "lazy" ]]; then
    hash_str "v=5|${st}|mode=lazy|slides=${VP_LAZY_SLIDES}|w=${OUT_W}|h=${OUT_H}|q=${JPG_QUALITY}"
  else
    hash_str "v=5|${st}|mode=upfront|fps=${TARGET_FPS}|loop=${LOOP_SECONDS}|w=${OUT_W}|h=${OUT_H}|q=${JPG_QUALITY}"
  fi
}

ROOT="${VP_CACHE_ROOT:-${TMPDIR:-/tmp}/yazi-video-preview}"
ROOT="${ROOT%/}"
KEY="$(cache_key)"
CDIR="${ROOT}/${KEY}"
mkdir -p "$CDIR"

# Touch atime so this entry is recently used in LRU eviction.
touch -a "$CDIR" 2>/dev/null || true

probe_duration() {
  if ! have ffprobe; then
    echo 0
    return
  fi
  ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$FILE_PATH" 2>/dev/null \
    | awk '{printf "%d", $1+0.5}'
}

# --- probe mode: dir + duration, no decode work ------------------------------
if [[ "$MODE" == "probe" ]]; then
  DURATION="$(probe_duration)"
  DURATION=${DURATION:-0}
  echo "DIR=${CDIR}"
  echo "DURATION=${DURATION}"
  exit 0
fi

prune_cache() {
  [[ ! -d "$ROOT" ]] && return 0
  if [[ "$CACHE_AGE_DAYS" -gt 0 ]]; then
    find "$ROOT" -mindepth 1 -maxdepth 1 -type d -atime "+${CACHE_AGE_DAYS}" -exec rm -rf {} + 2>/dev/null
  fi
  if [[ "$CACHE_CAP_MB" -gt 0 ]]; then
    local used_mb
    used_mb=$(du -sm "$ROOT" 2>/dev/null | awk '{print $1}')
    while [[ -n "$used_mb" && "$used_mb" -gt "$CACHE_CAP_MB" ]]; do
      local oldest
      oldest=$(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%A@ %p\n' 2>/dev/null \
               | sort -n | head -1 | awk '{print $2}')
      [[ -z "$oldest" || "$oldest" == "$CDIR" ]] && break
      rm -rf "$oldest"
      used_mb=$(du -sm "$ROOT" 2>/dev/null | awk '{print $1}')
    done
  fi
}

# --- slot mode: one keyframe seek, one frame --------------------------------
if [[ "$MODE" == "slot" ]]; then
  if [[ -z "$SLOT" || -z "$SLOT_TS" ]]; then
    echo "ERR=slot_args"
    exit 0
  fi
  if ! have ffmpeg; then
    echo "ERR=no_ffmpeg"
    exit 0
  fi
  OUT=$(printf "%s/%04d.jpg" "$CDIR" "$SLOT")
  # -ss before -i = fast keyframe seek, then one frame. ~100-300ms regardless
  # of source length.
  ffmpeg -hide_banner -loglevel error \
    -ss "$SLOT_TS" -i "$FILE_PATH" \
    -frames:v 1 \
    -vf "scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=decrease" \
    -q:v "$JPG_QUALITY" -y "$OUT" >/dev/null 2>&1 || true
  echo "IMG=${OUT}"
  exit 0
fi

# --- upfront mode: full extraction (Tier 1 native / Tier 2 fps-filter) -------
T="${LOOP_SECONDS}"

if [[ ! -f "$CDIR/.done" ]]; then
  ( prune_cache ) >/dev/null 2>&1 &
  if ! have ffmpeg; then
    echo "ERR=no_ffmpeg"
    exit 0
  fi

  DURATION="$(probe_duration)"
  DURATION=${DURATION:-0}
  (( DURATION <= 0 )) && DURATION=$LOOP_SECONDS

  T=$DURATION
  LOOP_FRAMES=$(( TARGET_FPS * LOOP_SECONDS ))
  (( LOOP_FRAMES < 1 )) && LOOP_FRAMES=1

  # Clear leftovers from a prior interrupted extraction.
  find "$CDIR" -maxdepth 1 -name '*.jpg' -delete 2>/dev/null || true

  EXTRACT_OK=0
  if (( T <= LOOP_SECONDS )); then
    # Tier 1 -- Native dense, full decode.
    VF="fps=${TARGET_FPS},scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=decrease"
    if ffmpeg -hide_banner -loglevel error -y \
         -ss 0 -t "$T" -i "$FILE_PATH" \
         -vf "$VF" -frames:v "$LOOP_FRAMES" -q:v "$JPG_QUALITY" \
         "$CDIR/%04d.jpg" >/dev/null 2>&1; then
      EXTRACT_OK=1
    fi
  else
    # Tier 2 -- fps-filter sub-sampled, full decode of T seconds. Lua only
    # calls upfront when T <= mid_threshold, so decode is bounded.
    SOURCE_FPS=$(awk -v lf="$LOOP_FRAMES" -v t="$T" 'BEGIN { printf "%.6f", lf / t }')
    VF="fps=${SOURCE_FPS},scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=decrease"
    if ffmpeg -hide_banner -loglevel error -y \
         -ss 0 -t "$T" -i "$FILE_PATH" \
         -vf "$VF" -frames:v "$LOOP_FRAMES" -q:v "$JPG_QUALITY" \
         "$CDIR/%04d.jpg" >/dev/null 2>&1; then
      EXTRACT_OK=1
    fi
  fi

  if (( EXTRACT_OK == 1 )); then
    printf "%s" "$T" > "$CDIR/.source_t"
    touch "$CDIR/.done"
  else
    echo "ERR=ffmpeg_failed"
    exit 0
  fi
fi

COUNT=$(find "$CDIR" -maxdepth 1 -name '*.jpg' 2>/dev/null | wc -l)
SOURCE_T=$(cat "$CDIR/.source_t" 2>/dev/null || echo "$T")
echo "DIR=${CDIR}"
echo "COUNT=${COUNT}"
echo "FPS=${TARGET_FPS}"
echo "SOURCE_T=${SOURCE_T}"
