--- @since 26.1.22
--- video-preview.yazi
---
--- Animated video preview: pre-extracts frames at TARGET_FPS using ffmpeg in
--- a single pass, then loops them in the preview pane via direct cache reads
--- (no per-tick fork). Renders a progress bar with current/total timestamps
--- right below the image. Supports gifs and any ffmpeg-readable video.

local M = {}

local DEFAULTS = {
	target_fps = 12,
	loop_seconds = 30, -- mode 1: D <= this -> upfront native dense extraction.
	mid_threshold = 300, -- mode 2: loop_seconds < D <= this -> upfront fps-filter timelapse.
	-- D > mid_threshold -> mode 3: lazy slideshow (one frame per tick).
	lazy_slide_seconds = 60, -- in mode 3, target one slide per N seconds of source...
	lazy_min_slides = 10, -- ...clamped between this...
	lazy_max_slides = 60, -- ...and this.
	lazy_tick = 2.0, -- seconds per slide in mode 3.
	out_w = 640,
	out_h = 360,
	jpg_quality = 7, -- 1 = best, 31 = worst
	tick_seconds = 0.020, -- yields between frames; render time bounds real fps (modes 1/2)
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

local function script_env_for_mode(mode, slides)
	local loop = opts.loop_seconds or 30
	if loop < 10 then loop = 10 end
	local env = {
		VP_TARGET_FPS = tostring(opts.target_fps),
		VP_LOOP_SECONDS = tostring(loop),
		VP_OUT_W = tostring(opts.out_w),
		VP_OUT_H = tostring(opts.out_h),
		VP_JPG_QUALITY = tostring(opts.jpg_quality),
		VP_CACHE_ROOT = opts.cache_root or "",
		VP_CACHE_CAP_MB = tostring(opts.cache_cap_mb),
		VP_CACHE_AGE_DAYS = tostring(opts.cache_age_days),
		VP_MODE = mode,
	}
	if mode == "lazy" then
		env.VP_LAZY_SLIDES = tostring(slides)
	end
	return env
end

local function compute_lazy_slides(duration)
	local per = math.max(1, opts.lazy_slide_seconds or 60)
	local min_s = math.max(1, opts.lazy_min_slides or 10)
	local max_s = math.max(min_s, opts.lazy_max_slides or 60)
	local n = math.floor(duration / per + 0.5)
	if n < min_s then n = min_s end
	if n > max_s then n = max_s end
	return n
end

local function probe_meta(file_url, mode, slides)
	local cmd = Command(SCRIPT):arg({ "--path", file_url, "--probe" })
	for k, v in pairs(script_env_for_mode(mode, slides)) do
		cmd = cmd:env(k, v)
	end
	local out = cmd:stdout(Command.PIPED):stderr(Command.PIPED):output()
	if not out or not out.stdout then return nil, "probe failed" end
	local err = out.stdout:match("ERR=(%S+)")
	if err then return nil, "probe: " .. err end
	local dir = out.stdout:match("DIR=([^\n]+)")
	local duration = tonumber(out.stdout:match("DURATION=(%d+)"))
	if not dir then return nil, "probe: no dir" end
	return { dir = dir, duration = duration }
end

local function init_upfront(file_url, mode)
	local cmd = Command(SCRIPT):arg({ "--path", file_url })
	for k, v in pairs(script_env_for_mode(mode, 0)) do
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

local function extract_lazy_slot(file_url, slot, ts, slides)
	local cmd = Command(SCRIPT):arg({
		"--path", file_url,
		"--slot", tostring(slot),
		"--ts", string.format("%.3f", ts),
	})
	for k, v in pairs(script_env_for_mode("lazy", slides)) do
		cmd = cmd:env(k, v)
	end
	cmd:stdin(Command.NULL):stdout(Command.NULL):stderr(Command.NULL):output()
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

local function pick_mode(duration)
	local loop = opts.loop_seconds or 30
	local mid = opts.mid_threshold or 300
	if duration <= loop then return "native"
	elseif duration <= mid then return "mid"
	else return "lazy"
	end
end

local function init_state(file_url)
	-- One probe with mode="upfront" gets us duration and a dir; if duration
	-- actually puts us in lazy mode, re-probe with mode="lazy" so the dir
	-- reflects the lazy cache key.
	local p, err = probe_meta(file_url, "upfront", 0)
	if not p then return { error = err } end
	local duration = p.duration or 0
	if duration <= 0 then
		-- Treat as native short clip with whatever upfront extraction gives.
		duration = opts.loop_seconds or 30
	end

	local mode = pick_mode(duration)

	if mode == "native" or mode == "mid" then
		local res = init_upfront(file_url, "upfront")
		if res.error then return res end
		res.mode = mode
		res.duration = duration
		return res
	end

	-- mode == "lazy"
	local slides = compute_lazy_slides(duration)
	local p2, err2 = probe_meta(file_url, "lazy", slides)
	if not p2 then return { error = err2 or "lazy probe failed" } end
	return {
		mode = "lazy",
		dir = p2.dir,
		duration = duration,
		count = slides,
		fps = opts.target_fps or 12,
		source_t = duration,
	}
end

local function render_playback(job, state, raw_offset)
	local effective = raw_offset % state.count
	local img_h = estimate_image_h(job.area.w, job.area.h)
	local img_area = ui.Rect({ x = job.area.x, y = job.area.y, w = job.area.w, h = img_h })
	local bar_area = ui.Rect({ x = job.area.x, y = job.area.y + img_h, w = job.area.w, h = 1 })

	local frame_path = state.dir .. "/" .. string.format("%04d.jpg", effective + 1)
	ya.image_show(Url(frame_path), img_area)

	local cur_str = fmt_time((effective + 1) * state.source_t / state.count)
	local total_str = fmt_time(state.source_t)
	local loop_real = state.count / state.fps
	local speed = (loop_real > 0) and (state.source_t / loop_real) or 1
	local speed_str = ""
	if speed >= 1.05 then
		local rounded = math.floor(speed * 10 + 0.5) / 10
		speed_str = string.format("%gx", rounded)
	end
	local sep = (#speed_str > 0) and 3 or 2
	local inner_w = bar_area.w - #cur_str - #total_str - #speed_str - sep
	if inner_w < 1 then inner_w = 1 end
	local progress = (effective + 1) / state.count
	local filled = math.floor(progress * inner_w + 0.5)
	if filled > inner_w then filled = inner_w end
	local bar = string.rep("\u{2588}", filled) .. string.rep("\u{2591}", inner_w - filled)
	local right = ((#speed_str > 0) and (" " .. speed_str) or "") .. " " .. total_str
	ya.preview_widget(job, { ui.Text(cur_str .. " " .. bar .. right):area(bar_area) })

	return effective
end

function M:peek(job)
	local file_url = tostring(job.file.url)

	local state = file_state[file_url]
	if not state then
		state = init_state(file_url)
		file_state[file_url] = state
	end

	if state.error then
		render_error(job, state.error)
		return
	end

	local raw_offset = tonumber(job.skip) or 0
	if raw_offset < 0 then raw_offset = 0 end

	if state.mode == "lazy" then
		local slot = (raw_offset % state.count) + 1
		local ts = (slot - 1) * state.duration / state.count
		local frame_path = state.dir .. "/" .. string.format("%04d.jpg", slot)

		-- Extract this slot synchronously if it isn't cached. One ffmpeg
		-- keyframe seek = ~100-300ms block, only on the first time each
		-- slot is hit. Subsequent visits to the same slot are instant.
		if not fs.cha(Url(frame_path), false) then
			extract_lazy_slot(file_url, slot, ts, state.count)
		end

		render_playback(job, state, raw_offset)

		ya.sleep(opts.lazy_tick or 2.0)
		ya.emit("peek", {
			tostring((raw_offset + 1) % state.count),
			only_if = file_url,
		})
		return
	end

	-- modes native / mid: existing animated playback
	render_playback(job, state, raw_offset)
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
