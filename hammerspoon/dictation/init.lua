-- Local Dictation: entry point, state machine and hotkeys.
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

local M = {}

local cfg, cfg_err = config.load()
local state = "IDLE"
local run = nil            -- current dictation: { wav, app, t0, ... }
local watchdog, max_timer, perm_timer = nil, nil, nil
local hk_toggle, hk_cancel = nil, nil
local system_prompt = nil

local LOG_PATH = os.getenv("HOME") .. "/Library/Logs/local-dictation.log"

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
-- Prompt file (repo/prompts/cleanup_system.txt, found through the symlink)
---------------------------------------------------------------------------

local function load_system_prompt()
  local src = debug.getinfo(1, "S").source:gsub("^@", "")
  local dir = src:match("^(.*)/[^/]*$") or "."
  local real = hs.fs.pathToAbsolute(dir) or dir
  local path = real .. "/../../prompts/cleanup_system.txt"
  local f = io.open(path, "r")
  if not f then return nil, path end
  local template = f:read("*a")
  f:close()
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
  return doctor.run(cfg)
end

function M.state()
  return state
end

local function menu()
  local items = {
    { title = "Local Dictation: " .. ui.label(state), disabled = true },
    { title = "-" },
    { title = state == "RECORDING" and "Stop recording" or "Start recording",
      fn = M.toggle, disabled = state ~= "IDLE" and state ~= "RECORDING" },
    { title = "Cancel", fn = M.cancel, disabled = state == "IDLE" },
    { title = "-" },
  }
  local modes = {}
  for _, m in ipairs({ "off", "regex", "llm" }) do
    modes[#modes + 1] = { title = m, checked = cfg.cleanup.mode == m,
      fn = function() cfg.cleanup.mode = m end }
  end
  items[#items + 1] = { title = "Cleanup mode (this session)", menu = modes }
  items[#items + 1] = { title = "Run doctor", fn = function()
    hs.openConsole()
    M.doctor()
  end }
  items[#items + 1] = { title = "Reload Hammerspoon", fn = hs.reload }
  return items
end

local function bind_hotkeys()
  if hk_toggle then return end
  hk_toggle = hs.hotkey.bind(cfg.hotkey_toggle.mods, cfg.hotkey_toggle.key, M.toggle)
  hk_cancel = hs.hotkey.bind(cfg.hotkey_cancel.mods, cfg.hotkey_cancel.key, M.cancel)
end

function M.start()
  ui.setup(cfg, menu)
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
