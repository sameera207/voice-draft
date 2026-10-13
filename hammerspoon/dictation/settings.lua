-- Settings window: a local HTML page in an hs.webview. The page talks to
-- this module through a WebKit message handler; replies go back through
-- evaluateJavaScript("vd.receive(...)"). The page loads no remote content,
-- and navigation away from the local file is blocked.

local config = require("dictation.config")
local cleanup = require("dictation.cleanup")
local doctor = require("dictation.doctor")

local M = {}

local W, H = 720, 620

local webview, usercontent = nil, nil
local pull_task = nil
local ctx = nil -- provided by init.lua (see M.open)

-- Settings the window shows, as dotted keys.
local FIELDS = {
  "hotkey_toggle", "hotkey_cancel",
  "ui.overlay", "ui.live_text", "ui.sounds", "ui.alerts",
  "cleanup.mode", "cleanup.ollama.model", "cleanup.llm_min_words",
  "cleanup.ollama.timeout_seconds", "vocabulary",
  "paths.model", "whisper.language", "whisper.threads",
  "recording.max_seconds", "insert.require_same_app",
  "debug", "log_text", "keep_audio",
}

local function send(payload)
  if not webview then return end
  local ok, json = pcall(hs.json.encode, payload)
  if ok then webview:evaluateJavaScript("vd.receive(" .. json .. ")") end
end

local function state_payload()
  local cfg = ctx.cfg()
  local values, locked = {}, {}
  for _, key in ipairs(FIELDS) do
    local v = config.get_path(cfg, key)
    if v == nil then v = "" end -- JSON has no nil; the page treats "" as unset
    values[key] = v
    if config.is_locked(ctx.locked(), key) then locked[#locked + 1] = key end
  end
  local whisper = {}
  for _, path in ipairs(ctx.whisper_models()) do
    whisper[#whisper + 1] = { path = path, name = path:match("ggml%-(.+)%.bin$") or path }
  end
  return {
    type = "state",
    version = ctx.version,
    values = values,
    locked = locked,
    ollama_models = ctx.ollama_models() or {},
    ollama_up = ctx.ollama_models() ~= nil,
    whisper_models = whisper,
    overrides_path = config.override_path,
  }
end

local function handle_save(values)
  local ok_values, errors = config.validate_all(values or {})
  local cfg = ctx.cfg()
  local changed, hotkeys_changed = {}, false
  for key, wrapped in pairs(ok_values) do
    local before = config.get_path(cfg, key)
    if not config.is_locked(ctx.locked(), key)
       and hs.json.encode({ before }) ~= hs.json.encode({ wrapped.value }) then
      ctx.set(key, wrapped.value)
      changed[#changed + 1] = key
      if key:find("^hotkey_") then hotkeys_changed = true end
    end
  end
  if hotkeys_changed then
    local ok, err = ctx.rebind_hotkeys()
    if not ok then errors.hotkey_toggle = err end
  end
  send({ type = "saved", changed = changed, errors = errors })
  send(state_payload())
end

-- Run stage 1 and the LLM on sample text with the form's (unsaved) model.
local function handle_test(msg)
  local text = msg.text or ""
  local t0 = hs.timer.secondsSinceEpoch()
  local s1 = cleanup.stage1(text)
  local s1_time = hs.timer.secondsSinceEpoch() - t0
  if s1 == "" then
    return send({ type = "test", stage1 = "", llm = "", note = "Nothing left after stage 1." })
  end
  local ocfg = {}
  for k, v in pairs(ctx.cfg().cleanup.ollama) do ocfg[k] = v end
  if type(msg.model) == "string" and msg.model ~= "" then ocfg.model = msg.model end
  ocfg.timeout_seconds = math.max(ocfg.timeout_seconds or 8, 30) -- first load can be slow
  send({ type = "test", stage1 = s1, stage1_seconds = s1_time, running = true })
  local t1 = hs.timer.secondsSinceEpoch()
  cleanup.llm(s1, ocfg, ctx.system_prompt(), function(ok, result, kind)
    local secs = hs.timer.secondsSinceEpoch() - t1
    if ok then
      send({ type = "test", stage1 = s1, stage1_seconds = s1_time, llm = result,
             llm_seconds = secs, model = ocfg.model })
    else
      local note = kind == "invalid"
        and ("The model's reply was rejected (" .. tostring(result) .. "), so dictation would paste the stage 1 text.")
        or ("Ollama error: " .. tostring(result))
      send({ type = "test", stage1 = s1, stage1_seconds = s1_time, llm = "",
             llm_seconds = secs, model = ocfg.model, note = note })
    end
  end)
end

-- `ollama pull` with progress. The Ollama server does the download.
local function handle_pull(model)
  local ok = config.validate("cleanup.ollama.model", model)
  if not ok then return send({ type = "pull", model = model, done = true, ok = false, line = "Invalid model name" }) end
  if pull_task and pull_task:isRunning() then
    return send({ type = "pull", model = model, done = true, ok = false, line = "Another pull is running" })
  end
  local ollama = doctor.resolve_bin(nil, "ollama")
  if not ollama then
    return send({ type = "pull", model = model, done = true, ok = false, line = "ollama command not found" })
  end
  local last_pct, last_line = nil, nil
  local function last_text_line(s)
    s = (s or ""):gsub("\27%[[%d;?]*%a", "")
    local line
    for l in s:gmatch("[^\r\n]+") do
      if l:find("%S") then line = l end
    end
    return line
  end
  pull_task = hs.task.new(ollama, function(code, stdout, stderr)
    pull_task = nil
    local msg = code == 0 and ("Pulled " .. model)
      or last_text_line(stderr) or last_text_line(stdout) or last_line or ("exit " .. code)
    ctx.refresh_ollama_models(function() send(state_payload()) end)
    send({ type = "pull", model = model, done = true, ok = code == 0, line = msg })
  end, function(_, stdout, stderr)
    local chunk = (stdout or "") .. (stderr or "")
    last_line = last_text_line(chunk) or last_line
    local pct
    for p in chunk:gmatch("(%d+)%%") do pct = tonumber(p) end
    if pct and pct ~= last_pct then
      last_pct = pct
      send({ type = "pull", model = model, percent = pct })
    end
    return true
  end, { "pull", model })
  pull_task:start()
  send({ type = "pull", model = model, percent = 0 })
end

local function on_message(msg)
  local body = msg.body
  if type(body) ~= "table" then return end
  local action = body.action
  if action == "load" then
    ctx.refresh_ollama_models(function() send(state_payload()) end)
    send(state_payload())
  elseif action == "save" then
    handle_save(body.values)
  elseif action == "test" then
    handle_test(body)
  elseif action == "pull" then
    handle_pull(body.model)
  elseif action == "suspend_hotkeys" then
    ctx.suspend_hotkeys(body.active == true)
  elseif action == "open_overrides" then
    ctx.open_overrides()
  elseif action == "close" then
    M.close()
  end
end

-- ctx: { cfg(), locked(), set(key, value), version, system_prompt(),
--        ollama_models(), refresh_ollama_models(cb), whisper_models(),
--        rebind_hotkeys() -> ok, err, suspend_hotkeys(bool),
--        open_overrides(), html_path }
function M.open(context)
  ctx = context
  if webview then
    webview:show():bringToFront(true)
    return
  end
  usercontent = hs.webview.usercontent.new("voicedraft")
  usercontent:setCallback(on_message)

  local screen = hs.screen.mainScreen():frame()
  local rect = { x = screen.x + (screen.w - W) / 2, y = screen.y + (screen.h - H) / 3, w = W, h = H }
  webview = hs.webview.new(rect, { developerExtrasEnabled = false }, usercontent)
  webview:windowStyle({ "titled", "closable", "miniaturizable" })
  webview:windowTitle("voice-draft settings")
  webview:allowTextEntry(true)
  webview:allowNewWindows(false)
  webview:deleteOnClose(true)
  webview:policyCallback(function(action, _, details)
    if action == "navigationAction" then
      local url = details and details.request and details.request.URL or ""
      return url:find("^file:") ~= nil or url == "about:blank"
    end
    return true
  end)
  webview:windowCallback(function(action)
    if action == "closing" then
      webview = nil; usercontent = nil
      ctx.suspend_hotkeys(false) -- in case the window closed mid-recording
    end
  end)
  webview:url("file://" .. ctx.html_path)
  webview:show()
  webview:bringToFront(true)
end

-- Run JavaScript in the open window (for checks from the console).
function M.eval(js, callback)
  if webview then webview:evaluateJavaScript(js, callback) end
end

function M.close()
  if webview then webview:delete(); webview = nil; usercontent = nil end
  if ctx then ctx.suspend_hotkeys(false) end
end

function M.is_open()
  return webview ~= nil
end

return M
