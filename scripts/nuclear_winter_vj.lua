-- ============================================================
--  nuclear_winter_vj.lua  v2.0
--  OBS Lua Script — Dual-Room VJ MUTEX Controller
--  Front Room: 4 slots   Back Room: 4 slots
--  User-assignable sources via Script Properties
-- ============================================================

local obs    = obslua
local ffi    = require("ffi")

-- ── CONSTANTS ────────────────────────────────────────────────
local VJ_SLOTS_PER_ROOM = 4
local LOOP_DURATION     = 120   -- seconds before media restart
local COOLDOWN_SECS     = 2     -- guard against double-fire

-- ── RUNTIME STATE ────────────────────────────────────────────
local front_sources   = {}   -- [1..4] source name strings
local back_sources    = {}   -- [1..4] source name strings

local front_active    = nil  -- slot number currently live (FR)
local back_active     = nil  -- slot number currently live (BR)

local front_waiting   = {}   -- [slot] = true while media is cued
local back_waiting    = {}
local front_cooldown  = {}   -- [slot] = true during cooldown
local back_cooldown   = {}

local connected_signals = {}  -- [source_name] = true

local hotkeys = {}            -- keyed by "front_slot_N" / "back_slot_N" / "clear_front" / "clear_back"
local loop_timers = {}        -- [source_name] = timer handle

-- ── HELPERS ──────────────────────────────────────────────────
local function log(msg)
    print("[NW VJ] " .. tostring(msg))
end

local function get_source(name)
    if not name or name == "" then return nil end
    return obs.obs_get_source_by_name(name)
end

local VJ_TITLES_FR = "VJ - Titles - Front"
local VJ_TITLES_BR = "VJ - Titles - Back"

local function set_visible(scene_name, source_name, visible)
    local vj_src = obs.obs_get_source_by_name(scene_name)
    if not vj_src then
        log("ERROR: Cannot find scene: " .. scene_name)
        return
    end
    local scene = obs.obs_scene_from_source(vj_src)
    if not scene then
        log("ERROR: obs_scene_from_source returned nil for: " .. scene_name)
        obs.obs_source_release(vj_src)
        return
    end
    local item = obs.obs_scene_find_source(scene, source_name)
    if item then
        obs.obs_sceneitem_set_visible(item, visible)
        log("set_visible OK: [" .. scene_name .. "] " .. source_name .. " → " .. tostring(visible))
    else
        log("ERROR: source not found in " .. scene_name .. ": " .. source_name)
    end
    obs.obs_source_release(vj_src)
end

local function restart_media(source_name)
    local src = get_source(source_name)
    if src then
        log("restart_media: " .. source_name)
        obs.obs_source_media_restart(src)
        obs.obs_source_release(src)
    else
        log("ERROR: restart_media could not find source: " .. source_name)
    end
end

local function stop_loop_timer(source_name)
    if loop_timers[source_name] then
        obs.timer_remove(loop_timers[source_name])
        loop_timers[source_name] = nil
    end
end

local function start_loop_timer(source_name)
    stop_loop_timer(source_name)
    local cb = function()
        restart_media(source_name)
    end
    obs.timer_add(cb, LOOP_DURATION * 1000)
    loop_timers[source_name] = cb
end

-- ── ROOM OPERATIONS ──────────────────────────────────────────
local function hide_all(room)
    local sources    = (room == "FR") and front_sources or back_sources
    local scene_name = (room == "FR") and VJ_TITLES_FR  or VJ_TITLES_BR
    for _, name in ipairs(sources) do
        if name and name ~= "" then
            set_visible(scene_name, name, false)
            stop_loop_timer(name)
        end
    end
end

local function deactivate(room)
    if room == "FR" then
        front_active = nil
    else
        back_active = nil
    end
    hide_all(room)
end

local function clear_room(room)
    log("Clear " .. room)
    deactivate(room)
    if room == "FR" then
        for i = 1, VJ_SLOTS_PER_ROOM do
            front_waiting[i]  = false
            front_cooldown[i] = false
        end
    else
        for i = 1, VJ_SLOTS_PER_ROOM do
            back_waiting[i]  = false
            back_cooldown[i] = false
        end
    end
end

local function activate_vj(room, slot)
    local sources = (room == "FR") and front_sources or back_sources
    local name    = sources[slot]
    if not name or name == "" then
        log("Slot " .. slot .. " in " .. room .. " has no source assigned.")
        return
    end

    hide_all(room)

    if room == "FR" then front_active = slot else back_active = slot end

    local scene_name = (room == "FR") and VJ_TITLES_FR or VJ_TITLES_BR
    set_visible(scene_name, name, true)
    restart_media(name)
    start_loop_timer(name)
    log(room .. " → slot " .. slot .. " (" .. name .. ")")
end

-- ── MEDIA-ENDED SIGNAL ────────────────────────────────────────
local function on_media_ended(calldata)
    local src  = obs.calldata_source(calldata, "source")
    if not src then return end
    local name = obs.obs_source_get_name(src)

    -- find which room/slot owns this source
    local function check_room(room, sources, active, waiting, cooldown)
        for i, sname in ipairs(sources) do
            if sname == name then
                if active == i and not cooldown[i] then
                    if not waiting[i] then
                        waiting[i]  = true
                        cooldown[i] = true
                        obs.timer_add(function()
                            cooldown[i] = false
                            obs.timer_remove(obs.timer_callback)
                        end, COOLDOWN_SECS * 1000)
                        restart_media(name)
                        waiting[i] = false
                    end
                end
                return true
            end
        end
        return false
    end

    if not check_room("FR", front_sources, front_active, front_waiting, front_cooldown) then
        check_room("BR", back_sources,  back_active,  back_waiting,  back_cooldown)
    end
end

local function connect_media_signal(source_name)
    if not source_name or source_name == "" then return end
    if connected_signals[source_name] then return end
    local src = get_source(source_name)
    if src then
        local handler = obs.obs_source_get_signal_handler(src)
        obs.signal_handler_connect(handler, "media_ended", on_media_ended)
        obs.obs_source_release(src)
        connected_signals[source_name] = true
        log("Signal connected: " .. source_name)
    end
end

-- ── HOTKEY CALLBACKS ─────────────────────────────────────────
local function make_slot_cb(room, slot)
    return function(pressed)
        if not pressed then return end
        activate_vj(room, slot)
    end
end

local function make_clear_cb(room)
    return function(pressed)
        if not pressed then return end
        clear_room(room)
    end
end

-- ── SCRIPT PROPERTIES ────────────────────────────────────────
function script_properties()
    local props = obs.obs_properties_create()

    obs.obs_properties_add_text(props, "_fr_header", "── FRONT ROOM ──────────────────────", obs.OBS_TEXT_INFO)
    for i = 1, VJ_SLOTS_PER_ROOM do
        obs.obs_properties_add_text(props,
            "front_slot_" .. i .. "_source",
            "FR Slot " .. i .. " Source Name",
            obs.OBS_TEXT_DEFAULT)
    end

    obs.obs_properties_add_text(props, "_br_header", "── BACK ROOM ───────────────────────", obs.OBS_TEXT_INFO)
    for i = 1, VJ_SLOTS_PER_ROOM do
        obs.obs_properties_add_text(props,
            "back_slot_" .. i .. "_source",
            "BR Slot " .. i .. " Source Name",
            obs.OBS_TEXT_DEFAULT)
    end

    return props
end

-- ── SCRIPT DEFAULTS ───────────────────────────────────────────
function script_defaults(settings)
    obs.obs_data_set_default_string(settings, "front_slot_1_source", "Forced Hand")
    obs.obs_data_set_default_string(settings, "front_slot_2_source", "Midnight")
    obs.obs_data_set_default_string(settings, "front_slot_3_source", "Aggrofemm")
    obs.obs_data_set_default_string(settings, "front_slot_4_source", "Unit:77")
    -- Back Room slots intentionally blank — user assigns at runtime
end

-- ── SCRIPT UPDATE (settings changed) ─────────────────────────
function script_update(settings)
    -- Rebuild source tables
    front_sources = {}
    back_sources  = {}
    for i = 1, VJ_SLOTS_PER_ROOM do
        front_sources[i] = obs.obs_data_get_string(settings, "front_slot_" .. i .. "_source")
        back_sources[i]  = obs.obs_data_get_string(settings, "back_slot_"  .. i .. "_source")
    end

    -- Connect media signals for any newly assigned sources
    for _, name in ipairs(front_sources) do connect_media_signal(name) end
    for _, name in ipairs(back_sources)  do connect_media_signal(name) end

    log("Sources updated — FR: " .. table.concat(front_sources, ", ")
        .. "  BR: " .. table.concat(back_sources, ", "))
end

-- ── SCRIPT LOAD ───────────────────────────────────────────────
function script_load(settings)
    -- Register stable slot hotkeys — Front Room
    for i = 1, VJ_SLOTS_PER_ROOM do
        local id    = "front_slot_" .. i
        local label = "FR: VJ " .. i
        hotkeys[id] = obs.obs_hotkey_register_frontend(id, label, make_slot_cb("FR", i))
        local saved = obs.obs_data_get_array(settings, id)
        obs.obs_hotkey_load(hotkeys[id], saved)
        obs.obs_data_array_release(saved)
    end

    -- Register stable slot hotkeys — Back Room
    for i = 1, VJ_SLOTS_PER_ROOM do
        local id    = "back_slot_" .. i
        local label = "BR: VJ " .. i
        hotkeys[id] = obs.obs_hotkey_register_frontend(id, label, make_slot_cb("BR", i))
        local saved = obs.obs_data_get_array(settings, id)
        obs.obs_hotkey_load(hotkeys[id], saved)
        obs.obs_data_array_release(saved)
    end

    -- Clear hotkeys
    hotkeys["clear_front"] = obs.obs_hotkey_register_frontend(
        "clear_front", "FR: Clear VJs", make_clear_cb("FR"))
    local cf = obs.obs_data_get_array(settings, "clear_front")
    obs.obs_hotkey_load(hotkeys["clear_front"], cf)
    obs.obs_data_array_release(cf)

    hotkeys["clear_back"] = obs.obs_hotkey_register_frontend(
        "clear_back", "BR: Clear VJs", make_clear_cb("BR"))
    local cb = obs.obs_data_get_array(settings, "clear_back")
    obs.obs_hotkey_load(hotkeys["clear_back"], cb)
    obs.obs_data_array_release(cb)

    -- Apply settings (populates source tables + connects signals)
    script_update(settings)

    log("v2.0 loaded — " .. VJ_SLOTS_PER_ROOM .. " slots per room, FR + BR active.")
end

-- ── SCRIPT SAVE ───────────────────────────────────────────────
function script_save(settings)
    for key, hk in pairs(hotkeys) do
        local arr = obs.obs_hotkey_save(hk)
        obs.obs_data_set_array(settings, key, arr)
        obs.obs_data_array_release(arr)
    end
end

-- ── SCRIPT DESCRIPTION ───────────────────────────────────────
function script_description()
    return "Nuclear Winter — Dual-Room VJ MUTEX Controller v2.0\n\n" ..
           "Assign OBS source names to FR/BR slots in Script Properties.\n" ..
           "Bind hotkeys in Settings → Hotkeys (search 'FR:' or 'BR:').\n" ..
           "Selecting a slot hides all others in that room automatically."
end
