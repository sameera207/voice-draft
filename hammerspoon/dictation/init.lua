-- voice-draft: entry point, state machine and hotkeys.
--
-- IDLE -> RECORDING -> TRANSCRIBING -> CLEANING -> INSERTING -> IDLE
-- Only one dictation runs at a time. Every failure returns to IDLE, and a
-- watchdog resets state if a stage overruns.

require("hs.ipc") -- lets `hs -c 'dictation.doctor()'` work from a shell

local config = require("dictation.config")
local recorder = require("dictation.recorder")
local transcriber = require("dictation.transcriber")
local cleanup = require("dictation.cleanup")
local inserter = require("dictation.inserter")
local ui = require("dictation.ui")
local overlay = require("dictation.overlay")
local live = require("dictation.live")
local doctor = require("dictation.doctor")
local settings_window = require("dictation.settings")

local M = {}

local cfg, cfg_err, cfg_info = config.load({ decode = hs.json.decode })
local settings = cfg_info.settings -- what settings.json holds; the UI saves this
local locked = cfg_info.locked     -- keys set in overrides.lua (read-only in the UI)
local state = "IDLE"
local run = nil            -- current dictation: { wav, app, t0, ... }
local watchdog, max_timer, perm_timer = nil, nil, nil
local hk_toggle, hk_cancel = nil, nil
local system_prompt = nil
local reload_pending, reload_timer = false, nil

local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/voice-draft.log"

local function log(msg)
  if not cfg.debug then return end
  local f = io.open(LOG_PATH, "a")
  if f then
    f:write(os.date("%Y-%m-%d %H:%M:%S "), msg, "\n")
    f:close()
  end
end

local function log_text(label, text)
  if cfg.debug and cfg.log_text then log(label .. ": " .. text) end
end

---------------------------------------------------------------------------
-- Files at the install root (found through the ~/.hammerspoon symlink)
---------------------------------------------------------------------------

local ROOT = (function()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)/[^/]*$") or "."
  local real = hs.fs.pathToAbsolute(dir) or dir
  return hs.fs.pathToAbsolute(real .. "/../..") or (real .. "/../..")
end)()

local function read_root_file(name)
  local f = io.open(ROOT .. "/" .. name, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

M.version = cleanup.trim(read_root_file("VERSION") or "dev")

local function load_system_prompt()
  local template = read_root_file("prompts/cleanup_system.txt")
  if not template then return nil, ROOT .. "/prompts/cleanup_system.txt" end
  return cleanup.render_system_prompt(template, cfg.vocabulary)
end

---------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------

local finish -- forward declaration

local function set_state(new_state, timeout_seconds)
  state = new_state
  ui.set_state(new_state)
  if cfg.ui.overlay then
    if new_state == "IDLE" then
      overlay.hide()
    elseif new_state ~= "RECORDING" then
      overlay.show_status(ui.label(new_state))
    end
  end
  if watchdog then watchdog:stop(); watchdog = nil end
  if timeout_seconds then
    local r = run
    watchdog = hs.timer.doAfter(timeout_seconds, function()
      if run ~= r then return end
      log("watchdog fired in " .. new_state)
      finish("Dictation timed out while " .. ui.label(new_state):lower())
    end)
  end
end

-- Abort or complete the current run and return to IDLE.
finish = function(message)
  if max_timer then max_timer:stop(); max_timer = nil end
  live.stop()
  transcriber.cancel()
  if run then
    if recorder.is_recording() then recorder.cancel(run.wav) end
    if not cfg.keep_audio then recorder.delete(run.wav) end
  end
  run = nil
  set_state("IDLE")
  if message then ui.alert(message) end
  if reload_pending then
    reload_timer = hs.timer.doAfter(1.5, hs.reload) -- let the alert show first
  end
end

local function elapsed(t0)
  return hs.timer.secondsSinceEpoch() - t0
end

---------------------------------------------------------------------------
-- Pipeline
---------------------------------------------------------------------------

local function insert_text(r, text)
  if run ~= r then return end
  set_state("INSERTING", 5)
  inserter.insert(text, r.app, cfg, function(result)
    if run ~= r then return end
    r.timing.total = elapsed(r.t_stop)
    print(string.format(
      "[dictation] audio %.1fs | transcribe %.2fs | cleanup %.2fs (%s) | total %.2fs",
      r.timing.audio, r.timing.transcribe, r.timing.cleanup or 0, r.cleanup_kind,
      r.timing.total))
    log(string.format("done: audio %.1fs transcribe %.2fs cleanup %.2fs total %.2fs result %s",
      r.timing.audio, r.timing.transcribe, r.timing.cleanup or 0, r.timing.total, result))
    if result == "clipboard" then
      finish("Dictation ready on clipboard")
    else
      finish(r.notice)
    end
  end)
end

local function clean_text(r, raw)
  if run ~= r then return end
  log_text("raw", raw)
  r.cleanup_kind = cfg.cleanup.mode
  if cfg.cleanup.mode == "llm" and cleanup.count_words(cleanup.stage1(raw)) < cfg.cleanup.llm_min_words then
    r.cleanup_kind = "regex, below llm_min_words"
  end
  set_state("CLEANING", (cfg.cleanup.ollama.timeout_seconds or 8) + 5)
  local t0 = hs.timer.secondsSinceEpoch()
  cleanup.process(raw, cfg, system_prompt, function(text, notice)
    if run ~= r then return end
    r.timing.cleanup = elapsed(t0)
    r.notice = notice
    log_text("clean", text)
    if text == "" then return finish("Nothing heard") end
    insert_text(r, text)
  end, log)
end

local function transcribe(r, whisper_path)
  if run ~= r then return end
  set_state("TRANSCRIBING", (cfg.whisper.timeout_seconds or 120) + 10)
  local t0 = hs.timer.secondsSinceEpoch()
  transcriber.run(cfg, whisper_path, r.wav, function(ok, result)
    if run ~= r then return end
    r.timing.transcribe = elapsed(t0)
    if not cfg.keep_audio then recorder.delete(r.wav) end
    if not ok then
      log("transcription failed: " .. result)
      return finish("Transcription failed: " .. result)
    end
    if result == "" then return finish("Nothing heard") end
    clean_text(r, result)
  end)
end

local function on_recording_ended(r, code, stderr)
  if run ~= r then return end
  if not r.stopping then
    -- SoX exited on its own: device problem.
    log("sox exited unexpectedly: " .. tostring(code) .. " " .. tostring(stderr))
    return finish("Recording failed: microphone unavailable?")
  end
  local secs = recorder.duration(r.wav)
  r.timing.audio = secs or 0
  if not secs or secs <= 0 then
    return finish("Recording was empty. Check the microphone and its permission.")
  end
  if secs < cfg.recording.min_seconds then
    return finish() -- too short: discard silently
  end
  transcribe(r, r.whisper)
end

local function stop_recording(auto)
  local r = run
  if not r or state ~= "RECORDING" then return end
  if max_timer then max_timer:stop(); max_timer = nil end
  r.app = hs.application.frontmostApplication()
  r.t_stop = hs.timer.secondsSinceEpoch()
  r.stopping = true
  live.stop()
  ui.sound("stop")
  set_state("TRANSCRIBING", 15) -- re-armed once SoX has exited
  if auto then ui.alert("Maximum length reached, transcribing") end
  recorder.stop()
end

local function start_recording()
  local checks, sox, whisper = doctor.local_checks(cfg)
  for _, c in ipairs(checks) do
    if not c.ok then return ui.alert("Dictation: " .. c.name .. " " .. c.detail, 4) end
  end
  if hs.microphoneState and not hs.microphoneState(false) then
    hs.microphoneState(true) -- trigger the system prompt
    return ui.alert("Grant Microphone access: System Settings > Privacy & Security > Microphone > Hammerspoon", 5)
  end

  local r = { wav = cfg.paths.tmp_wav, whisper = whisper, timing = {} }
  run = r
  local ok, err = recorder.start(sox, r.wav, function(code, stderr)
    on_recording_ended(r, code, stderr)
  end)
  if not ok then
    return finish("Recording failed: " .. tostring(err))
  end
  set_state("RECORDING", cfg.recording.max_seconds + 30)
  ui.sound("start")
  if cfg.ui.overlay then
    overlay.show_recording()
    live.start(cfg, r.wav, cfg.ui.live_text and whisper or nil,
      function(t, level) if run == r then overlay.tick(t, level) end end,
      function(text) if run == r and state == "RECORDING" then overlay.set_text(text) end end)
  else
    ui.alert("Recording…", 1)
  end
  max_timer = hs.timer.doAfter(cfg.recording.max_seconds, function()
    if run == r then stop_recording(true) end
  end)

  if cfg.cleanup.mode == "llm" and cfg.cleanup.ollama.preload_on_record then
    pcall(cleanup.preload, cfg.cleanup.ollama)
  end
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------

function M.toggle()
  if state == "IDLE" then
    start_recording()
  elseif state == "RECORDING" then
    stop_recording(false)
  else
    ui.alert("Still working")
  end
end

function M.cancel()
  if state == "IDLE" then return end
  finish("Dictation cancelled")
end

function M.doctor()
  return doctor.run(cfg, M.version)
end

-- Reload Hammerspoon now if idle, otherwise as soon as the current
-- dictation finishes. Used by `voice-draft update`. Returns the state.
function M.reload_when_idle()
  if state == "IDLE" then
    reload_timer = hs.timer.doAfter(0.2, hs.reload) -- let the hs CLI call return
  else
    reload_pending = true
  end
  return state
end

function M.state()
  return state
end

---------------------------------------------------------------------------
-- Settings (menu bar)
---------------------------------------------------------------------------

local ollama_models = nil -- cached names from /api/tags; nil until fetched

local function refresh_ollama_models(callback)
  local url = cfg.cleanup.ollama.url
  if not cleanup.is_loopback_url(url) then return end
  hs.http.asyncGet(url .. "/api/tags", nil, function(status, body)
    ollama_models = nil
    if status == 200 then
      local ok, data = pcall(hs.json.decode, body or "")
      if ok and type(data) == "table" then
        local names = {}
        for _, m in ipairs(data.models or {}) do names[#names + 1] = m.name end
        table.sort(names)
        ollama_models = names
      end
    end
    if callback then callback() end
  end)
end

local function whisper_models()
  local dir = cfg.paths.model:match("^(.*)/[^/]*$")
  local files = {}
  local ok, iter, obj = pcall(hs.fs.dir, dir)
  if ok and iter then
    for name in iter, obj do
      if name:match("^ggml%-.+%.bin$") then files[#files + 1] = dir .. "/" .. name end
    end
  end
  table.sort(files)
  return files
end

local function save_settings()
  hs.fs.mkdir(config.config_dir)
  local ok, err = config.save_settings(settings, function(t)
    return next(t) == nil and "{}" or hs.json.encode(t, true)
  end)
  if not ok then ui.alert("Couldn't save settings: " .. tostring(err), 4) end
  return ok
end

-- Apply a setting now and persist it to settings.json.
function M.set(key, value)
  if config.is_locked(locked, key) then
    ui.alert(key .. " is set in overrides.lua")
    return false
  end
  config.set_path(cfg, key, value)
  config.set_setting(settings, key, value)
  if key == "ui.overlay" and not value then overlay.hide() end
  if key == "vocabulary" then system_prompt = load_system_prompt() end
  if key == "cleanup.ollama.model" and cfg.cleanup.mode == "llm" then
    pcall(cleanup.preload, cfg.cleanup.ollama) -- warm the new model
  end
  return save_settings()
end

local function overrides_template()
  hs.fs.mkdir(config.config_dir)
  if hs.fs.attributes(config.override_path) then return end
  local f = io.open(config.override_path, "w")
  if not f then return end
  f:write([[
-- voice-draft overrides. Only include settings you want to change; they win
-- over the defaults and over anything set in the menu or settings window.
-- Reload Hammerspoon after editing.
return {
  -- cleanup = { ollama = { model = "gemma4:latest" } },
}
]])
  f:close()
end

function M.open_overrides()
  overrides_template()
  hs.task.new("/usr/bin/open", nil, { "-t", config.override_path }):start()
end

-- A menu item bound to a setting, disabled when overrides.lua sets it.
local function item(title, key, value, checked)
  local is_locked = config.is_locked(locked, key)
  return {
    title = title, checked = checked, disabled = is_locked,
    fn = function() M.set(key, value) end,
  }
end

local function toggle(title, key)
  local on = config.get_path(cfg, key) and true or false
  local it = item(title, key, not on, on)
  if it.disabled then it.title = title .. " (set in overrides.lua)" end
  return it
end

local function submenu(title, key, entries)
  local t = { title = title, menu = entries }
  if config.is_locked(locked, key) then t.title = title .. " (set in overrides.lua)" end
  return t
end

local rebind_hotkeys, suspend_hotkeys -- defined with the hotkey code below

function M.open_settings_window()
  settings_window.open({
    cfg = function() return cfg end,
    locked = function() return locked end,
    set = M.set,
    version = M.version,
    system_prompt = function() return system_prompt end,
    ollama_models = function() return ollama_models end,
    refresh_ollama_models = refresh_ollama_models,
    whisper_models = whisper_models,
    rebind_hotkeys = function() return rebind_hotkeys() end,
    suspend_hotkeys = function(active) suspend_hotkeys(active) end,
    open_overrides = M.open_overrides,
    html_path = ROOT .. "/hammerspoon/dictation/settings/index.html",
  })
end

local function menu()
  refresh_ollama_models() -- for next time; the menu is built synchronously

  local items = {
    { title = "voice-draft " .. M.version .. " · " .. ui.label(state), disabled = true },
    { title = "-" },
    { title = state == "RECORDING" and "Stop recording" or "Start recording",
      fn = M.toggle, disabled = state ~= "IDLE" and state ~= "RECORDING" },
    { title = "Cancel", fn = M.cancel, disabled = state == "IDLE" },
    { title = "-" },
  }

  -- Cleanup model
  local current = cfg.cleanup.ollama.model
  local models, seen = {}, false
  for _, name in ipairs(ollama_models or {}) do
    seen = seen or name == current or name == current .. ":latest"
    models[#models + 1] = item(name, "cleanup.ollama.model", name,
      name == current or name == current .. ":latest")
  end
  if not seen then
    table.insert(models, 1, { title = current .. (ollama_models and "  (not pulled)" or ""), checked = true, disabled = true })
  end
  if not ollama_models then
    models[#models + 1] = { title = "Ollama not reachable", disabled = true }
  end
  models[#models + 1] = { title = "-" }
  models[#models + 1] = { title = "Pull more with: ollama pull <model>", disabled = true }
  items[#items + 1] = submenu("Cleanup model: " .. current, "cleanup.ollama.model", models)

  -- Cleanup mode
  local mode_labels = { off = "Off (raw transcript)", regex = "Quick (regex only)", llm = "Full (regex + LLM)" }
  local modes = {}
  for _, m in ipairs({ "off", "regex", "llm" }) do
    modes[#modes + 1] = item(mode_labels[m], "cleanup.mode", m, cfg.cleanup.mode == m)
  end
  items[#items + 1] = submenu("Cleanup mode", "cleanup.mode", modes)

  -- Whisper model
  local wm = {}
  for _, path in ipairs(whisper_models()) do
    local name = path:match("ggml%-(.+)%.bin$")
    wm[#wm + 1] = item(name, "paths.model", path, path == cfg.paths.model)
  end
  if #wm == 0 then wm[1] = { title = "No models in " .. cfg.paths.model:match("^(.*)/"), disabled = true } end
  items[#items + 1] = submenu("Whisper model", "paths.model", wm)

  -- Language
  items[#items + 1] = submenu("Language", "whisper.language", {
    item("English", "whisper.language", "en", cfg.whisper.language == "en"),
    item("Auto-detect", "whisper.language", "auto", cfg.whisper.language == "auto"),
  })

  items[#items + 1] = { title = "-" }
  items[#items + 1] = toggle("Live text preview", "ui.live_text")
  items[#items + 1] = toggle("Overlay panel", "ui.overlay")
  items[#items + 1] = toggle("Sounds", "ui.sounds")
  items[#items + 1] = { title = "-" }
  if M.open_settings_window then
    items[#items + 1] = { title = "Settings…", fn = function() M.open_settings_window() end }
  end
  items[#items + 1] = { title = "Edit overrides.lua…", fn = function() M.open_overrides() end }
  items[#items + 1] = { title = "Run doctor", fn = function()
    hs.openConsole()
    M.doctor()
  end }
  items[#items + 1] = { title = "Reload Hammerspoon", fn = hs.reload }
  return items
end

-- `voice-draft config`: open the settings window, or the menu as a fallback.
-- Deferred so a `hs -c` caller returns instead of waiting on the open menu.
local popup_timer = nil
function M.settings()
  popup_timer = hs.timer.doAfter(0.05, function()
    if M.open_settings_window then M.open_settings_window() else ui.popup(menu()) end
  end)
end

M.menu_items = menu -- for inspection from the console

local function bind_hotkeys()
  if hk_toggle then return true end
  local ok, err = pcall(function()
    hk_toggle = hs.hotkey.bind(cfg.hotkey_toggle.mods, cfg.hotkey_toggle.key, M.toggle)
    hk_cancel = hs.hotkey.bind(cfg.hotkey_cancel.mods, cfg.hotkey_cancel.key, M.cancel)
  end)
  if not ok then
    if hk_toggle then hk_toggle:delete(); hk_toggle = nil end
    return false, "couldn't bind hotkey: " .. tostring(err)
  end
  return true
end

-- Re-bind after a hotkey change in the settings window.
rebind_hotkeys = function()
  if not hs.accessibilityState(false) then return true end -- bound once granted
  if hk_toggle then hk_toggle:delete(); hk_toggle = nil end
  if hk_cancel then hk_cancel:delete(); hk_cancel = nil end
  return bind_hotkeys()
end

-- While the settings window records a new shortcut, the current hotkeys
-- must not fire (they would swallow the key press and start dictating).
suspend_hotkeys = function(active)
  for _, hk in ipairs({ hk_toggle, hk_cancel }) do
    if active then hk:disable() else hk:enable() end
  end
end

function M.start()
  ui.setup(cfg, menu)
  refresh_ollama_models()
  if cfg_err then ui.alert("Dictation: " .. cfg_err, 5) end

  if not cleanup.is_loopback_url(cfg.cleanup.ollama.url) then
    ui.alert("Dictation disabled: Ollama URL must be a loopback address (" .. cfg.cleanup.ollama.url .. ")", 6)
    ui.teardown()
    return false
  end

  local missing
  system_prompt, missing = load_system_prompt()
  if not system_prompt and cfg.cleanup.mode == "llm" then
    cfg.cleanup.mode = "regex"
    ui.alert("Dictation: cleanup prompt not found, using regex cleanup only", 4)
    print("[dictation] prompt file not found at " .. tostring(missing))
  end

  if hs.accessibilityState(false) then
    bind_hotkeys()
  else
    hs.accessibilityState(true)
    ui.alert("Dictation needs Accessibility access: System Settings > Privacy & Security > Accessibility > enable Hammerspoon", 6)
    perm_timer = hs.timer.doEvery(2, function()
      if hs.accessibilityState(false) then
        perm_timer:stop(); perm_timer = nil
        bind_hotkeys()
        ui.alert("Dictation ready")
      end
    end)
  end
  return true
end

M.start()

dictation = M -- global so dictation.doctor() works in the Hammerspoon console
return M
