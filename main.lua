--- @since 26.1.22
--- video-preview.yazi
---
--- Animated video preview: pre-extracts frames at TARGET_FPS using ffmpeg in
--- a single pass, then loops them in the preview pane via direct cache reads
--- (no per-tick fork). Renders a progress bar with current/total timestamps
--- right below the image. Supports gifs and any ffmpeg-readable video.

local M = {}

local DEFAULTS = {
	target_fps = 24,
	loop_seconds = 30, -- playback length of the loop. Clips longer than this are speed-fit into it; shorter clips loop natively. Floor: 10.
	max_source_seconds = 600, -- decode at most this many seconds of source. 0 disables. Bounds extractor cost on very long clips.
	out_w = 640,
	out_h = 360,
	jpg_quality = 7, -- 1 = best, 31 = worst
	tick_seconds = 0.020, -- yields between frames; render time bounds real fps
	cache_root = nil, -- defaults to $TMPDIR/yazi-video-preview
	cache_cap_mb = 1024, -- LRU evict beyond this
	cache_age_days = 7, -- evict entries not accessed in this many days
	cell_aspect = nil, -- nil = auto-detect via TIOCGWINSZ; foot default ~3.0
}

local opts = {}
for k, v in pairs(DEFAULTS) do opts[k] = v end

local SCRIPT = os.getenv("HOME") .. "/.config/yazi/plugins/video-preview.yazi/preview.sh"
local SOURCE_RATIO = 9 / 16

local file_state = {}

local PROBE_PY = [[
import sys, struct, fcntl, termios
try:
    fd = open('/dev/tty', 'rb').fileno()
    s = struct.unpack('HHHH', fcntl.ioctl(fd, termios.TIOCGWINSZ, b'\0' * 8))
    rows, cols, xpix, ypix = s
    if rows and cols and xpix and ypix:
        cw, ch = xpix / cols, ypix / rows
        print(f'{ch / cw:.3f}')
except Exception:
    pass
]]

local cell_aspect_cache

local function cell_aspect()
	if opts.cell_aspect then return opts.cell_aspect end
	if cell_aspect_cache then return cell_aspect_cache end

	local out = Command("python3")
		:arg({ "-c", PROBE_PY })
		:stdout(Command.PIPED)
		:stderr(Command.PIPED)
		:output()
	if out and out.stdout then
		local n = tonumber(out.stdout:match("([%d%.]+)"))
		if n and n > 0.5 and n < 10 then
			cell_aspect_cache = n
			return n
		end
	end
	cell_aspect_cache = 3.0 -- foot fallback
	return cell_aspect_cache
end

local function fmt_time(sec)
	if not sec or sec < 0 then sec = 0 end
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	local s = math.floor(sec % 60)
	if h > 0 then
		return string.format("%d:%02d:%02d", h, m, s)
	end
	return string.format("%d:%02d", m, s)
end

local function script_env()
	local loop = opts.loop_seconds or 30
	if loop < 10 then loop = 10 end
	local mss = opts.max_source_seconds or 600
	if mss < 0 then mss = 0 end
	return {
		VP_TARGET_FPS = tostring(opts.target_fps),
		VP_LOOP_SECONDS = tostring(loop),
		VP_MAX_SOURCE_SECONDS = tostring(mss),
		VP_OUT_W = tostring(opts.out_w),
		VP_OUT_H = tostring(opts.out_h),
		VP_JPG_QUALITY = tostring(opts.jpg_quality),
		VP_CACHE_ROOT = opts.cache_root or "",
		VP_CACHE_CAP_MB = tostring(opts.cache_cap_mb),
		VP_CACHE_AGE_DAYS = tostring(opts.cache_age_days),
	}
end

local function init_file(file_url)
	local cmd = Command(SCRIPT):arg({ "--path", file_url })
	for k, v in pairs(script_env()) do
		cmd = cmd:env(k, v)
	end
	local out = cmd:stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out then
		return { error = "extractor failed to spawn" }
	end

	local stdout = out.stdout or ""
	local err = stdout:match("ERR=(%S+)")
	if err then
		return { error = "extractor: " .. err }
	end

	local dir = stdout:match("DIR=([^\n]+)")
	local count = tonumber(stdout:match("COUNT=(%d+)") or "0")
	local fps = tonumber(stdout:match("FPS=(%d+)") or tostring(opts.target_fps))
	local source_t = tonumber(stdout:match("SOURCE_T=([%d%.]+)") or tostring(count / fps))

	if not dir or count == 0 then
		return { error = "extraction produced no frames" }
	end

	return { dir = dir, count = count, fps = fps, source_t = source_t }
end

local function render_error(job, msg)
	ya.preview_widget(job, { ui.Text(msg):area(job.area) })
end

local function estimate_image_h(area_w, area_h)
	local h_cells = math.floor(area_w * SOURCE_RATIO / cell_aspect() + 0.5)
	if h_cells < 1 then h_cells = 1 end
	if h_cells > area_h - 1 then h_cells = area_h - 1 end
	return h_cells
end

function M:setup(o)
	if o then
		for k, v in pairs(o) do opts[k] = v end
	end
	return self
end

function M:peek(job)
	local file_url = tostring(job.file.url)

	local state = file_state[file_url]
	if not state then
		state = init_file(file_url)
		file_state[file_url] = state
	end

	if state.error then
		render_error(job, state.error)
		return
	end

	local raw_offset = tonumber(job.skip) or 0
	if raw_offset < 0 then raw_offset = 0 end
	local effective = raw_offset % state.count

	local img_h = estimate_image_h(job.area.w, job.area.h)
	local img_area = ui.Rect({
		x = job.area.x,
		y = job.area.y,
		w = job.area.w,
		h = img_h,
	})
	local bar_area = ui.Rect({
		x = job.area.x,
		y = job.area.y + img_h,
		w = job.area.w,
		h = 1,
	})

	local frame_path = state.dir .. "/" .. string.format("%04d.jpg", effective + 1)
	ya.image_show(Url(frame_path), img_area)

	local cur_str = fmt_time((effective + 1) * state.source_t / state.count)
	local total_str = fmt_time(state.source_t)
	local inner_w = bar_area.w - #cur_str - #total_str - 2
	if inner_w < 1 then inner_w = 1 end
	local progress = (effective + 1) / state.count
	local filled = math.floor(progress * inner_w + 0.5)
	if filled > inner_w then filled = inner_w end
	local bar = string.rep("\u{2588}", filled) .. string.rep("\u{2591}", inner_w - filled)
	ya.preview_widget(job, { ui.Text(cur_str .. " " .. bar .. " " .. total_str):area(bar_area) })

	ya.sleep(opts.tick_seconds)
	ya.emit("peek", {
		tostring((raw_offset + 1) % math.max(state.count, 1)),
		only_if = file_url,
	})
end

function M:seek(job)
	local h = cx.active.current.hovered
	if not (h and h.url == job.file.url) then return end

	local next_skip = (tonumber(job.skip) or 0) + (tonumber(job.units) or 0)
	if next_skip < 0 then next_skip = 0 end

	ya.emit("peek", {
		tostring(next_skip),
		only_if = tostring(job.file.url),
	})
end

return M
