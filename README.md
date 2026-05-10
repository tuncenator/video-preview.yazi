# video-preview.yazi

Animated video preview for Yazi. Pre-extracts frames at a target FPS via a single ffmpeg pass, then loops them in the preview pane via direct cache reads (no per-tick fork). Renders a progress bar with current/total timestamps just below the image. Works for any ffmpeg-readable video and animated GIFs.

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

## Options

`require("video-preview"):setup { ... }` accepts:

| Option            | Type    | Default | Description                                                                                              |
| ----------------- | ------- | ------- | -------------------------------------------------------------------------------------------------------- |
| `target_fps`      | integer | `12`    | Playback frame rate of the loop. Higher = smoother, but most sixel terminals can't sustain >15fps at 640x360. Bump only on fast terminals.                            |
| `loop_seconds`    | integer | `30`    | Real-time length of the loop. Clips shorter than this loop natively (1x); longer clips are sub-sampled so the entire clip plays back inside `loop_seconds` (timelapse). Floor: 10. |
| `max_source_seconds` | integer | `600` | Decode at most this many seconds of source. Clips longer than this only summarize their first `max_source_seconds`. `0` disables the cap. Bounds extractor cost on very long files. |
| `out_w`           | integer | `640`   | Frame width in pixels. Larger = sharper but slower sixel encode.                                         |
| `out_h`           | integer | `360`   | Frame height in pixels.                                                                                  |
| `jpg_quality`     | integer | `7`     | ffmpeg `-q:v` for cached JPGs (1=best, 31=worst). Smaller files render faster.                           |
| `tick_seconds`    | number  | `0.020` | Sleep between frames in lua. Render time bounds the real fps; tick is just a yield.                      |
| `cell_aspect`     | number  | `nil`   | Override terminal cell aspect (height/width) for the progress-bar position. `nil` triggers auto-detect.  |
| `cache_cap_mb`    | integer | `1024`  | LRU eviction cap for the frame cache directory.                                                          |
| `cache_age_days`  | integer | `7`     | Cache entries not accessed in this many days are pruned on each cold extraction.                         |
| `cache_root`      | string  | `nil`   | Override cache root. `nil` uses `$TMPDIR/yazi-video-preview`.                                            |

Example tuned for shorter previews on lower-end hardware:

```lua
require("video-preview"):setup {
  target_fps = 18,
  loop_seconds = 30,
  out_w = 480,
  out_h = 270,
}
```

## How it works

1. On first hover of a video, the lua plugin spawns `preview.sh` once via `Command:output()`.
2. `preview.sh` runs ffmpeg in a single pass with `-vf fps=N` and `-frames:v MAX` to dump JPG frames into a cache dir keyed by file stat + settings hash.
3. The lua plugin reads back the cache directory path and frame count, then on each subsequent peek tick directly calls `ya.image_show(cache_path, area)` and renders a progress-bar widget. No bash fork per tick.
4. A separate cleanup pass on each cold extraction prunes stale entries by atime and size cap.

The progress bar height-positions itself via an estimate of the terminal's cell aspect (auto-detected through TIOCGWINSZ if `python3` is available, falling back to `~3.0` which fits foot's defaults).

## Why a fork

This started from [`nbaud/yazi-video-timeline`](https://github.com/nbaud/yazi-video-timeline) but diverged enough that it no longer resembles upstream:

- single-pass pre-extraction at native fps, vs. per-tick `ffmpeg -ss` seeks
- per-file lua state with direct cache reads, vs. forking a bash script every tick
- configurable target fps and clip length, vs. fixed 2-second ticks
- progress bar with cur/total timestamps tight against image bottom, vs. mediainfo dump
- LRU cache cleanup
- auto cell-aspect detection

## License

MIT, see `LICENSE`.
