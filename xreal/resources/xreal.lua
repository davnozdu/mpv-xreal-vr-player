-- SPDX-License-Identifier: LGPL-2.1-or-later
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local assdraw = require 'mp.assdraw'
local o = {prefs = '', shaders = '', autofs = false, autodecode = false}
options.read_options(o, 'xreal')
local preferences = {}
if o.prefs ~= '' then
    local file = io.open(o.prefs, 'r')
    local contents = file and file:read('*a')
    if file then file:close() end
    local decoded = contents and utils.parse_json(contents)
    if type(decoded) == 'table' then preferences = decoded end
end
local valid = {auto=true, ['2d']=true, hsbs=true, fsbs=true, vr180=true, vr360=true, vr180tb=true, vr360tb=true}
local ids = {hsbs=0, fsbs=1, vr180=2, vr360=3, vr180tb=4, vr360tb=5, ['2d']=6}
local labels = {['2d']='2D · обычное видео', hsbs='3D Half SBS', fsbs='3D Full SBS', vr180='VR180 SBS',
                vr360='VR360 SBS', vr180tb='VR180 Top/Bottom', vr360tb='VR360 Top/Bottom'}
local mode, resolved, guessed = 'auto', '2d', false
local display, output_override, yaw, pitch, fov, swapped = 'preview', 'auto', 0, 0, 70, false
local overlay = mp.create_osd_overlay('ass-events')
local overlay_visible = false
local message, notice_until = '', 0
local selected_audio
local selected_shader
local decode_sample, software_trial, decode_attempted

local function select_audio()
    if display == 'preview' then
        if selected_audio and mp.get_property('audio-device') == selected_audio then
            mp.set_property('audio-device', 'auto')
        end
        selected_audio = nil
        return
    end
    for _, device in ipairs(mp.get_property_native('audio-device-list', {})) do
        local description = (device.description or ''):lower()
        if description:find('xreal') or description:find('nreal') then
            selected_audio = device.name
            if mp.get_property('audio-device') ~= device.name then mp.set_property('audio-device', device.name) end
            return
        end
    end
end

local function save()
    if o.prefs == '' then return end
    local f = io.open(o.prefs .. '.tmp', 'w')
    if not f then return end
    f:write(utils.format_json(preferences)); f:close()
    os.rename(o.prefs .. '.tmp', o.prefs)
end

local function auto_mode(params)
    local name = (mp.get_property('filename', '') or ''):lower()
    local w, h = params.w or 0, params.h or 1
    local aspect = w / math.max(1, h)
    local tb = name:find('top.?bottom') or name:find('[_. %-]tb[_. %-]') or name:find('over.?under')
    -- Numbers must stand alone: "1360x768" is not a 360° panorama.
    if name:find('%f[%d]360%f[%D]') then return tb and 'vr360tb' or 'vr360', false end
    if name:find('%f[%d]180%f[%D]') then return tb and 'vr180tb' or 'vr180', false end
    if name:find('full.?sbs') or name:find('fsbs') then return 'fsbs', false end
    if name:find('half.?sbs') or name:find('hsbs') then return 'hsbs', false end
    if name:find('%f[%a]sbs%f[%A]') or name:find('%f[%w]3d%f[%W]') then
        return aspect > 3 and 'fsbs' or 'hsbs', false
    end
    -- This is a documented heuristic, not reliable projection metadata.
    if w >= 5760 and aspect > 1.8 and aspect < 2.2 then return 'vr180', true end
    if aspect > 3 then return 'fsbs', true end
    -- An unmarked Half SBS movie has the same size as a 2D one. Showing a
    -- stereo pair flat is less broken than splitting an ordinary movie.
    return '2d', true
end

local function actual_output()
    return output_override == 'auto' and display or output_override
end

-- One view for the Mac screen or for glasses switched to their 2D mode.
local function is_mono(output)
    return output == 'preview' or output == 'mono'
end

local function draw()
    local w, h = mp.get_osd_size()
    if w == 0 or h == 0 then return end
    local idle = mp.get_property_native('idle-active')
    local text
    if idle then
        text = 'XREAL VR Player\\NОткройте фильм: ⌘O или перетащите файл\\N3D и VR180/360 · формат в меню XREAL'
    elseif mp.get_time() < notice_until then
        text = message
    else
        if overlay_visible then overlay:remove(); overlay_visible = false end
        return
    end
    local ass = assdraw.ass_new()
    local output = actual_output()
    local function at(x, size, squeeze)
        ass:new_event(); ass:append(string.format('{\\an5\\pos(%g,%g)\\fs%g\\fscx%d\\bord1.5\\shad0\\1c&HFFFFFF&}', x, h*0.5, size, squeeze))
        ass:append(text)
    end
    if is_mono(output) then
        at(w*0.5, math.min(h*0.055, 25), 100)
    else
        at(w*0.25, math.min(h*0.05, 32), output == 'half' and 50 or 100)
        at(w*0.75, math.min(h*0.05, 32), output == 'half' and 50 or 100)
    end
    overlay.res_x = w; overlay.res_y = h; overlay.data = ass.text; overlay:update()
    overlay_visible = true
end

local function notify(text)
    message = text; notice_until = mp.get_time() + 4; draw()
end

local function apply()
    -- video-params includes our output aspect override. Read the decoder's
    -- original parameters so changing the output cannot distort each eye.
    local params = mp.get_property_native('video-dec-params')
    local output = actual_output()
    mp.set_property('video-aspect-override', output == 'full' and '32:9' or '16:9')
    if o.shaders ~= '' then
        local shader = o.shaders .. (is_mono(output) and '/xreal-preview.glsl' or '/xreal.glsl')
        if selected_shader ~= shader then
            mp.set_property_native('glsl-shaders', {shader})
            selected_shader = shader
        end
    end
    if not params or not params.w or not params.h then draw(); return end
    if mode == 'auto' then resolved, guessed = auto_mode(params) else resolved, guessed = mode, false end
    local dar = (params.dw or params.w) / math.max(1, params.dh or params.h)
    local aspect = (resolved == 'hsbs' or resolved == '2d') and dar or dar * 0.5
    mp.set_property('glsl-shader-opts', string.format(
        'xreal_mode=%d,xreal_mono=%d,eye_aspect=%.8f,swap_eyes=%d,yaw=%.4f,pitch=%.4f,fov=%.4f',
        ids[resolved], is_mono(output) and 1 or 0, math.min(10, math.max(0.1, aspect)), swapped and 1 or 0, yaw, pitch, fov))
    mp.set_property_native('user-data/xreal', {mode=mode, resolved=resolved, guessed=guessed,
        output=output, eye_aspect=aspect, yaw=yaw, pitch=pitch, fov=fov, swapped=swapped})
end

local function status()
    local decoder = mp.get_property('hwdec-current', 'no')
    local fps = mp.get_property_number('container-fps', 0)
    local dropped = mp.get_property_number('frame-drop-count', 0)
    notify(labels[resolved] .. (mode == 'auto' and ' · Auto' or '') .. (guessed and ' (по размеру кадра)' or '')
        .. '\\NВывод: ' .. actual_output() .. ' · Обзор: W/A/S/D · Центр: R · Глаза: E'
        .. string.format('\\NДекодер: %s · %.2f fps · пропущено: %d', decoder, fps, dropped)
        .. '\\NЕсли картинка неверная, выберите формат в меню XREAL')
end

mp.register_script_message('xreal-mode', function(value)
    if not valid[value] then return end
    mode = value; yaw = 0; pitch = 0
    local path = mp.get_property('path')
    if path then preferences[path] = {mode=mode, swapped=swapped}; save() end
    apply(); status()
end)
mp.register_script_message('xreal-display', function(value)
    if value ~= 'preview' and value ~= 'half' and value ~= 'full' then return end
    local changed = display ~= value
    display = value; select_audio()
    if changed then apply() end
end)
mp.register_script_message('xreal-output', function(value)
    if value ~= 'auto' and value ~= 'half' and value ~= 'full' and value ~= 'mono' then return end
    output_override = value; apply(); status()
end)
mp.register_script_message('xreal-look', function(dx, dy)
    yaw = (yaw + (tonumber(dx) or 0) + 180) % 360 - 180
    pitch = math.max(-85, math.min(85, pitch + (tonumber(dy) or 0))); apply()
end)
mp.register_script_message('xreal-fov', function(value)
    fov = math.max(35, math.min(110, fov + (tonumber(value) or 0))); apply()
end)
mp.register_script_message('xreal-reset', function() yaw=0; pitch=0; fov=70; apply(); status() end)
mp.register_script_message('xreal-swap', function()
    swapped = not swapped
    local path = mp.get_property('path')
    if path then preferences[path] = {mode=mode, swapped=swapped}; save() end
    apply(); notify(swapped and 'Глаза: правый / левый' or 'Глаза: левый / правый')
end)
mp.register_script_message('xreal-status', status)
mp.register_event('start-file', function()
    decode_sample = nil; software_trial = nil; decode_attempted = false
    if o.autodecode then
        mp.set_property('vd-queue-enable', 'no')
        mp.set_property('hwdec', 'auto-safe')
    end
    local entry = preferences[mp.get_property('path', '')]
    mode = type(entry)=='table' and valid[entry.mode] and entry.mode or 'auto'
    swapped = type(entry)=='table' and entry.swapped == true or false
    yaw=0; pitch=0; fov=70
end)
mp.register_event('file-loaded', function()
    -- No automatic notice over the movie; H or the XREAL menu shows status.
    apply()
    if o.autofs then mp.set_property_native('fullscreen', true) end
end)
mp.observe_property('video-dec-params', 'native', apply)
mp.observe_property('osd-dimensions', 'native', draw)
mp.observe_property('idle-active', 'bool', draw)
mp.add_periodic_timer(0.25, draw)
-- VideoToolbox can be slower than CPU decoding for some 8K streams. Judge
-- sustained playback after startup/seek, and only fall back when rendering
-- itself fits within the frame budget. Never repeatedly switch a movie.
local function reset_decode_sample() decode_sample = nil end
mp.register_event('seek', reset_decode_sample)
mp.observe_property('pause', 'bool', reset_decode_sample)
mp.add_periodic_timer(1, function()
    if not o.autodecode or mp.get_property_native('idle-active') or mp.get_property_native('pause') then
        decode_sample = nil; return
    end
    local params = mp.get_property_native('video-dec-params', {})
    local fps = mp.get_property_number('container-fps', 0)
    if (params.w or 0) < 5760 or fps < 48 then return end
    local decoder = mp.get_property('hwdec-current', 'no')
    if decode_attempted and not software_trial then return end
    if not software_trial and not decoder:find('videotoolbox', 1, true) then return end
    local now, pos = mp.get_time(), mp.get_property_number('time-pos', 0)
    local drops = mp.get_property_number('frame-drop-count', 0)
    if not decode_sample then decode_sample = {wall=now, pos=pos, drops=drops}; return end
    local elapsed, progress = now - decode_sample.wall, pos - decode_sample.pos
    if elapsed < 5 then return end
    local ratio = math.max(0, drops - decode_sample.drops) / math.max(1, fps * progress)
    local passes, gpu_ms = mp.get_property_native('vo-passes', {}), 0
    for _, pass in ipairs(passes.fresh or {}) do gpu_ms = gpu_ms + (pass.avg or 0) / 1000000 end
    decode_sample = nil
    if software_trial then
        if decoder == 'no' and (progress < elapsed * 0.5 or ratio >= software_trial * 0.9) then
            mp.set_property('vd-queue-enable', 'no')
            mp.set_property('hwdec', 'auto-safe')
            mp.msg.info('Automatic decoding: restored VideoToolbox; CPU trial did not improve playback')
        end
        software_trial = nil
    elseif progress >= 1 and ratio > 0.25 and gpu_ms > 0 and gpu_ms < 1000 / fps then
        decode_attempted = true; software_trial = ratio
        mp.set_property('vd-queue-enable', 'yes')
        mp.set_property('vd-queue-max-bytes', '256MiB')
        mp.set_property('vd-queue-max-samples', '4')
        mp.set_property('hwdec', 'no')
        -- mpv's hwdec property handler queues an exact seek to refill the new
        -- decoder from a keyframe while preserving playback position.
        mp.msg.info('Automatic decoding: trying CPU after sustained VideoToolbox frame drops')
        notify('Оптимизация 8K: переключение декодера')
    end
end)
-- Lightweight runtime evidence without logging the movie name or its path.
mp.add_periodic_timer(10, function()
    if mp.get_property_native('idle-active') then return end
    local passes = mp.get_property_native('vo-passes', {})
    local gpu_ms = 0
    for _, pass in ipairs(passes.fresh or {}) do gpu_ms = gpu_ms + (pass.avg or 0) / 1000000 end
    mp.msg.info('Playback: ' .. utils.format_json({
        hwdec = mp.get_property('hwdec-current', 'no'),
        source_fps = mp.get_property_number('container-fps', 0),
        display_fps = mp.get_property_number('estimated-display-fps', 0),
        dropped = mp.get_property_number('frame-drop-count', 0),
        decoder_dropped = mp.get_property_number('decoder-frame-drop-count', 0),
        gpu_ms = gpu_ms, fullscreen = mp.get_property_native('fullscreen'),
        audio = mp.get_property('current-ao', 'none'),
        output = actual_output(), time = mp.get_property_number('time-pos', 0),
    }))
end)
