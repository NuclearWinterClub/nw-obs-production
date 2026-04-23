-- ============================================================
--  Nuclear Winter — VJ Mutex Pocket System
--  OBS Lua Script — CANON v1.0
-- ============================================================
--  CONFIGURATION — only edit this section
-- ============================================================

local SCENE_NAME   = "VJ Titles"  -- exact OBS scene name
local REPLAY_DELAY = 20           -- seconds between video replays
local COOLDOWN     = 3            -- seconds to ignore signals after replay starts

local FRONT_VJS = {
    { source = "Forced Hand", label = "Forced Hand" },
    { source = "Midnight",    label = "Midnight"    },
    { source = "Aggrofemm",   label = "Aggrofemm"   },
    { source = "Unit:77",     label = "Unit:77"     },
}

local BACK_VJS = {
    -- Add Back Room VJs here when ready, e.g.:
    -- { source = "BR Name", label = "BR Name" },
}

-- ============================================================
--  SYSTEM — no edits needed below this line
-- ============================================================

local obs = obslua

local active_vj    = { front = nil, back = nil }
local hotkey_ids   = {}
local timer_funcs  = {}
local waiting      = {}
local cooldown     = {}
local settings_ref = nil
local initialized  = false

local function get_scene_item(source_name)
    local scene_source = obs.obs_get_source_by_name(SCENE_NAME)
    if not scene_source then
        obs.script_log(obs.LOG_WARNING, "Could not find scene: " .. SCENE_NAME)
        return nil
    end
    local scene = obs.obs_scene_from_source(scene_source)
    local item  = obs.obs_scene_find_source(scene, source_name)
    obs.obs_source_release(scene_source)
    return item
end

local function set_visible(source_name, visible)
    local item = get_scene_item(source_name)
    if item then
        obs.obs_sceneitem_set_visible(item, visible)
    end
end

local function stop_media(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if source then
        obs.obs_source_media_stop(source)
        obs.obs_source_release(source)
    end
end

local function restart_media(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if source then
        obs.obs_source_media_restart(source)
        obs.obs_source_release(source)
    end
end

local function schedule_once(key, delay_ms, callback)
    if timer_funcs[key] then
        obs.timer_remove(timer_funcs[key])
        timer_funcs[key] = nil
    end
    local function one_shot()
        obs.timer_remove(timer_funcs[key])
        timer_funcs[key] = nil
        callback()
    end
    timer_funcs[key] = one_shot
    obs.timer_add(one_shot, delay_ms)
end

local function cancel_timer(key)
    if timer_funcs[key] then
        obs.timer_remove(timer_funcs[key])
        timer_funcs[key] = nil
    end
end

local function start_cooldown(source_name)
    cooldown[source_name] = true
    schedule_once("cooldown_" .. source_name, COOLDOWN * 1000, function()
        cooldown[source_name] = false
        obs.script_log(obs.LOG_INFO, "Cooldown ended: " .. source_name)
    end)
end

local function do_replay(source_name)
    waiting[source_name] = false
    if active_vj.front == source_name or active_vj.back == source_name then
        obs.script_log(obs.LOG_INFO, "Replaying: " .. source_name)
        start_cooldown(source_name)
        restart_media(source_name)
        set_visible(source_name, true)
    end
end

local function on_media_ended(source_name)
    if cooldown[source_name] then
        obs.script_log(obs.LOG_INFO, "Signal blocked by cooldown: " .. source_name)
        return
    end
    if waiting[source_name] then
        obs.script_log(obs.LOG_INFO, "Signal blocked, already waiting: " .. source_name)
        return
    end
    if active_vj.front ~= source_name and active_vj.back ~= source_name then return end
    obs.script_log(obs.LOG_INFO, "Media ended, waiting " .. REPLAY_DELAY .. "s: " .. source_name)
    set_visible(source_name, false)
    waiting[source_name] = true
    schedule_once("replay_" .. source_name, REPLAY_DELAY * 1000, function()
        do_replay(source_name)
    end)
end

local function connect_media_signals(source_name)
    local source = obs.obs_get_source_by_name(source_name)
    if not source then
        obs.script_log(obs.LOG_WARNING, "Could not find source: " .. source_name)
        return
    end
    local handler = obs.obs_source_get_signal_handler(source)
    obs.signal_handler_connect(handler, "media_ended", function()
        on_media_ended(source_name)
    end)
    obs.obs_source_release(source)
    obs.script_log(obs.LOG_INFO, "Connected signals for: " .. source_name)
end

local function deactivate(source_name)
    cancel_timer("replay_" .. source_name)
    cancel_timer("cooldown_" .. source_name)
    waiting[source_name]  = false
    cooldown[source_name] = false
    stop_media(source_name)
    set_visible(source_name, false)
end

local function hide_all(vj_list)
    for _, vj in ipairs(vj_list) do
        deactivate(vj.source)
    end
end

local function activate_vj(room, vj)
    local vj_list = (room == "front") and FRONT_VJS or BACK_VJS
    if active_vj[room] == vj.source then
        deactivate(vj.source)
        active_vj[room] = nil
        obs.script_log(obs.LOG_INFO, "Deactivated: " .. vj.source)
    else
        hide_all(vj_list)
        waiting[vj.source]  = false
        cooldown[vj.source] = false
        start_cooldown(vj.source)
        restart_media(vj.source)
        set_visible(vj.source, true)
        active_vj[room] = vj.source
        obs.script_log(obs.LOG_INFO, "Activated: " .. vj.source)
    end
end

local function clear_room(room)
    local vj_list = (room == "front") and FRONT_VJS or BACK_VJS
    hide_all(vj_list)
    active_vj[room] = nil
    obs.script_log(obs.LOG_INFO, "Cleared room: " .. room)
end

local function register_hotkeys()
    if initialized then return end
    initialized = true
    obs.script_log(obs.LOG_INFO, "Registering hotkeys...")
    for _, vj in ipairs(FRONT_VJS) do
        local key    = "front_" .. vj.source
        local label  = "FR: " .. vj.label
        local vj_ref = vj
        local id = obs.obs_hotkey_register_frontend(key, label,
            function(pressed) if pressed then activate_vj("front", vj_ref) end end)
        hotkey_ids[key] = id
        if settings_ref then
            local a = obs.obs_data_get_array(settings_ref, key)
            obs.obs_hotkey_load(id, a)
            obs.obs_data_array_release(a)
        end
        obs.script_log(obs.LOG_INFO, "Registered: " .. label)
        waiting[vj.source]  = false
        cooldown[vj.source] = false
    end
    for _, vj in ipairs(BACK_VJS) do
        local key    = "back_" .. vj.source
        local label  = "BR: " .. vj.label
        local vj_ref = vj
        local id = obs.obs_hotkey_register_frontend(key, label,
            function(pressed) if pressed then activate_vj("back", vj_ref) end end)
        hotkey_ids[key] = id
        if settings_ref then
            local a = obs.obs_data_get_array(settings_ref, key)
            obs.obs_hotkey_load(id, a)
            obs.obs_data_array_release(a)
        end
        obs.script_log(obs.LOG_INFO, "Registered: " .. label)
        waiting[vj.source]  = false
        cooldown[vj.source] = false
    end
    local fr_clear_id = obs.obs_hotkey_register_frontend("clear_front", "FR: Clear VJs",
        function(pressed) if pressed then clear_room("front") end end)
    hotkey_ids["clear_front"] = fr_clear_id
    obs.script_log(obs.LOG_INFO, "Registered: FR: Clear VJs")
    local br_clear_id = obs.obs_hotkey_register_frontend("clear_back", "BR: Clear VJs",
        function(pressed) if pressed then clear_room("back") end end)
    hotkey_ids["clear_back"] = br_clear_id
    obs.script_log(obs.LOG_INFO, "Registered: BR: Clear VJs")
    if settings_ref then
        for key, id in pairs(hotkey_ids) do
            local a = obs.obs_data_get_array(settings_ref, key)
            obs.obs_hotkey_load(id, a)
            obs.obs_data_array_release(a)
        end
    end
    for _, vj in ipairs(FRONT_VJS) do connect_media_signals(vj.source) end
    for _, vj in ipairs(BACK_VJS) do connect_media_signals(vj.source) end
    obs.script_log(obs.LOG_INFO, "Nuclear Winter VJ system ready.")
    obs.timer_remove(register_hotkeys)
end

function script_load(settings)
    settings_ref = settings
    obs.script_log(obs.LOG_INFO, "Script loaded, waiting to register hotkeys...")
    obs.timer_add(register_hotkeys, 1000)
end

function script_save(settings)
    for key, id in pairs(hotkey_ids) do
        local a = obs.obs_hotkey_save(id)
        obs.obs_data_set_array(settings, key, a)
        obs.obs_data_array_release(a)
    end
end

function script_unload()
    for key, _ in pairs(timer_funcs) do
        cancel_timer(key)
    end
end

function script_description()
    return "Nuclear Winter — VJ Mutex Pocket System — CANON v1.0\n" ..
           "Scene: " .. SCENE_NAME .. "\n" ..
           "Mutually exclusive per room, independent across rooms.\n" ..
           "Edit the CONFIGURATION block to update VJ names or delay."
end
