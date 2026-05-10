# video-preview.yazi

Animated video preview for Yazi. Picks one of three extraction strategies per file based on duration and size, so short clips get a smooth animated loop and large or long files get a slideshow that doesn't freeze your terminal. Renders a progress bar with current/total timestamps and a speed-up badge for timelapse playback.

## Requirements

- Yazi >= 26.1.22
- `ffmpeg` (with `ffprobe`) on `$PATH`
- A terminal with sixel or kitty graphics support (foot, ghostty, kitty, wezterm)
- `python3` (optional, for auto cell-aspect detection via TIOCGWINSZ)

## Installation

```sh
ya pkg add tuncenator/video-preview.yazi
```

Or clone manually:

```sh
git clone https://github.com/tuncenator/video-preview.yazi.git ~/.config/yazi/plugins/video-preview.yazi
```

## Setup

Add to `~/.config/yazi/init.lua`:

```lua
require("video-preview"):setup()
```

Register as a previewer in `~/.config/yazi/yazi.toml`:

```toml
[plugin]
prepend_previewers = [
  { mime = "video/*",   run = "video-preview" },
  { mime = "image/gif", run = "video-preview" },
]
```

## Extraction modes

The plugin picks one of three modes per file based on duration and size. All three render into the same preview pane with the same progress-bar UI; the difference is only how the frames get into the cache.

| Mode | When | Behavior |
| --- | --- | --- |
| **native** | `D <= loop_seconds` (30s) and `size <= lazy_size_bytes` (50MB) | Upfront `fps=target_fps` extraction with `-hwaccel auto` (picks vaapi/cuda/qsv/etc., falls back to software). Dense, smooth animated playback. Cold-cache extraction ~200ms-2s. |
| **mid (timelapse)** | `loop_seconds < D <= mid_threshold` (300s) and `size <= lazy_size_bytes` | Upfront fps-filter sub-sampled. Even spacing, smooth animated playback. Cold extraction is a bounded full decode (a few seconds for typical H.264). |
| **lazy (slideshow)** | `D > mid_threshold` **or** `size > lazy_size_bytes` | One frame per UI tick, fetched via `ffmpeg -ss T -i FILE -frames:v 1` keyframe seek. On first hover lua kicks off a 4-way parallel prefetch of every slot, so most are cached by the time the slideshow reaches them. Slots written via `.tmp` + atomic rename so peek never reads a half-written jpeg. |

The size override exists because a short high-bitrate clip (e.g. 4K HEVC, 20s, 300MB) is a slow decode despite being short -- lazy mode treats it like a long file and avoids the freeze.

## Options

`require("video-preview"):setup { ... }` accepts:

| Option | Type | Default | Description |
| --- | --- | --- | --- |
| `target_fps` | integer | `12` | Playback frame rate of the animated modes (native, mid). Higher = smoother but most sixel terminals can't sustain >15fps at 640x360. |
| `loop_seconds` | integer | `30` | Clips up to this duration use the native (dense fps) extraction path. |
| `mid_threshold` | integer | `300` | Above `loop_seconds` and up to this, clips use the mid (fps-filter sub-sampled) path. Beyond this, lazy mode. |
| `lazy_size_bytes` | integer | `52428800` (50MB) | Files larger than this go straight to lazy mode regardless of duration. `0` disables. |
| `lazy_slide_seconds` | integer | `30` | In lazy mode, target one slide per N seconds of source duration. |
| `lazy_min_slides` | integer | `15` | Lower clamp on the lazy slide count. |
| `lazy_max_slides` | integer | `60` | Upper clamp on the lazy slide count. |
| `lazy_tick` | number | `1.0` | Seconds per slide in lazy mode. |
| `out_w` | integer | `640` | Frame width in pixels. Larger = sharper but slower sixel encode. |
| `out_h` | integer | `360` | Frame height in pixels. |
| `jpg_quality` | integer | `7` | ffmpeg `-q:v` for cached JPGs (1=best, 31=worst). Smaller files render faster. |
| `tick_seconds` | number | `0.020` | Sleep between frames in lua for native/mid playback. Render time bounds real fps; tick is just a yield. |
| `cell_aspect` | number | `nil` | Override terminal cell aspect (height/width) for progress-bar positioning. `nil` triggers auto-detect. |
| `cache_cap_mb` | integer | `1024` | LRU eviction cap for the frame cache directory. |
| `cache_age_days` | integer | `7` | Cache entries not accessed in this many days are pruned on each cold upfront extraction. |
| `cache_root` | string | `nil` | Override cache root. `nil` uses `$TMPDIR/yazi-video-preview`. |

Example tuned for a slow terminal:

```lua
require("video-preview"):setup {
  target_fps = 10,
  out_w = 480,
  out_h = 270,
  lazy_tick = 1.5,
}
```

Example tuned to make lazy mode rare (only the truly massive files use it):

```lua
require("video-preview"):setup {
  mid_threshold = 1200,   -- accept ~20 min of full decode
  lazy_size_bytes = 500 * 1024 * 1024,
}
```

## How it works

1. On first hover of a video, the lua plugin runs `preview.sh --probe` once. It returns the cache directory path and the clip duration without doing any decode work.
2. Lua reads file size via `fs.cha` and picks one of three modes (native / mid / lazy).
3. **Native or mid:** runs `preview.sh` synchronously for a single ffmpeg pass that writes all frames into the cache dir, marks it `.done`, and returns metadata. Subsequent peek ticks read frames directly from the cache and play them at `target_fps`.
4. **Lazy:** computes an adaptive slide count, then fires `preview.sh --prefetch` which self-forks to background and extracts every slot in parallel (4 concurrent ffmpeg keyframe seeks). Each peek tick reads its slot from the cache; if a slot isn't ready yet, lua falls back to a synchronous `preview.sh --slot I --ts T` for that one tick. Once everything is cached the loop runs entirely from cache.
5. The progress bar shows source-time current/total plus a speedup badge (`2x`, `5x`, ...) whenever the source duration exceeds the loop's real playback length.
6. A separate cleanup pass on each cold upfront extraction prunes stale cache entries by atime and size cap, running in the background so it doesn't add to user-visible latency.

The progress bar height-positions itself via an estimate of the terminal's cell aspect (auto-detected through TIOCGWINSZ if `python3` is available, falling back to `~3.0` which fits foot's defaults).

## Why a fork

This started from [`nbaud/yazi-video-timeline`](https://github.com/nbaud/yazi-video-timeline) but diverged enough that it no longer resembles upstream:

- three extraction strategies picked per file, vs. fixed-timestamp single-frame slideshow
- animated playback for short and mid clips, vs. always 2-second slideshow
- per-file lua state with direct cache reads, vs. forking a bash script every tick (still done for lazy mode only)
- progress bar with cur/total timestamps and speed-up badge tight against image bottom, vs. mediainfo dump
- adaptive slide count for lazy mode, vs. fixed 10 positions
- LRU cache cleanup
- auto cell-aspect detection

## License

MIT, see `LICENSE`.
