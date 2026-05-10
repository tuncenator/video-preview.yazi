#!/usr/bin/env bash
# video-preview.yazi extractor.
# One-shot: extracts frames at TARGET_FPS for the entire clip (if short) or
# the first MAX_SECONDS (if long). Subsequent calls return cached metadata
# (dir + count + fps) for the lua side to read frames from directly.
set -euo pipefail
IFS=$'\n'

FILE_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path) shift; FILE_PATH="${1:-}";;
    *) ;;
  esac
  shift || true
done

[[ -z "${FILE_PATH}" || ! -f "${FILE_PATH}" ]] && { echo "ERR=no_such_file"; exit 0; }

have() { command -v "$1" >/dev/null 2>&1; }

# Lua sets these via Command:env(...). Defaults match main.lua DEFAULTS.
TARGET_FPS="${VP_TARGET_FPS:-24}"
MAX_SECONDS="${VP_MAX_SECONDS:-10}"
SHORT_THRESHOLD="${VP_SHORT_THRESHOLD:-30}"
OUT_W="${VP_OUT_W:-640}"
OUT_H="${VP_OUT_H:-360}"
JPG_QUALITY="${VP_JPG_QUALITY:-7}"
CACHE_CAP_MB="${VP_CACHE_CAP_MB:-1024}"
CACHE_AGE_DAYS="${VP_CACHE_AGE_DAYS:-7}"

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
  hash_str "${st}|fps=${TARGET_FPS}|max=${MAX_SECONDS}|short=${SHORT_THRESHOLD}|w=${OUT_W}|h=${OUT_H}|q=${JPG_QUALITY}"
}

ROOT="${VP_CACHE_ROOT:-${TMPDIR:-/tmp}/yazi-video-preview}"
ROOT="${ROOT%/}"
KEY="$(cache_key)"
CDIR="${ROOT}/${KEY}"
mkdir -p "$CDIR"

# Touch atime so this entry is recently used in LRU eviction.
touch -a "$CDIR" 2>/dev/null || true

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

if [[ ! -f "$CDIR/.done" ]]; then
  prune_cache
  if ! have ffmpeg; then
    echo "ERR=no_ffmpeg"
    exit 0
  fi

  DURATION="$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 -- "$FILE_PATH" 2>/dev/null | awk '{printf "%d", $1+0.5}')"
  DURATION=${DURATION:-0}
  (( DURATION <= 0 )) && DURATION=$MAX_SECONDS

  if (( DURATION <= SHORT_THRESHOLD )); then
    T=$DURATION
  else
    T=$MAX_SECONDS
  fi

  MAX_FRAMES=$(( TARGET_FPS * MAX_SECONDS ))
  (( MAX_FRAMES < 1 )) && MAX_FRAMES=1

  VF="fps=${TARGET_FPS},scale=${OUT_W}:${OUT_H}:force_original_aspect_ratio=decrease"
  ffmpeg -hide_banner -loglevel error -y \
    -ss 0 -t "$T" -i "$FILE_PATH" \
    -vf "$VF" -frames:v "$MAX_FRAMES" -q:v "$JPG_QUALITY" \
    "$CDIR/%04d.jpg" >/dev/null 2>&1 || true

  touch "$CDIR/.done"
fi

COUNT=$(find "$CDIR" -maxdepth 1 -name '*.jpg' 2>/dev/null | wc -l)
echo "DIR=${CDIR}"
echo "COUNT=${COUNT}"
echo "FPS=${TARGET_FPS}"
