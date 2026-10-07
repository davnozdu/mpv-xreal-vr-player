-- SPDX-License-Identifier: LGPL-2.1-or-later
-- A second real mpv client drives the production client without a network/IPC socket.
local mp = require 'mp'
local utils = require 'mp.utils'
local options = require 'mp.options'
local o = {scenario='', report=''}
options.read_options(o, 'xreal_test')
local file = assert(io.open(o.scenario, 'r'))
local steps = assert(utils.parse_json(file:read('*a'))); file:close()
local tests, index, started = {}, 0, 0
local timer

local function finish(error)
    local out = assert(io.open(o.report, 'w'))
    out:write(utils.format_json({passed=#tests, tests=tests, error=error})); out:close()
    if error then mp.msg.error(error) end
    if timer then timer:kill() end
    mp.commandv('quit', error and '1' or '0')
end

local function next_step()
    index = index + 1
    if index > #steps then finish(); return end
    started = mp.get_time()
    for _, args in ipairs(steps[index].actions) do mp.commandv(unpack(args)) end
end

timer = mp.add_periodic_timer(0.05, function()
    if index == 0 then next_step(); return end
    local step = steps[index]
    local state = mp.get_property_native('user-data/xreal', {})
    local elapsed = mp.get_time() - started
    if elapsed < 0.15 then return end
    local matches = true
    for key, value in pairs(step.expected or {}) do
        if state[key] ~= value then matches = false end
    end
    if step.path and mp.get_property('path') ~= step.path then matches = false end
    if step.aspect then
        local aspect = mp.get_property_number('video-aspect-override', 0)
        if math.abs(aspect - step.aspect) > 0.001 then matches = false end
    end
    if step.eye_aspect and math.abs((state.eye_aspect or 0) - step.eye_aspect) > 0.001 then matches = false end
    if step.mono ~= nil then
        local opts = mp.get_property('glsl-shader-opts', '')
        if not opts:find('xreal_mono=' .. step.mono, 1, true) then matches = false end
    end
    if matches then
        tests[#tests + 1] = {test=step.name, passed=true}
        next_step()
    elseif elapsed > 10 then
        finish(step.name .. ': timeout; state=' .. utils.format_json(state))
    end
end)
