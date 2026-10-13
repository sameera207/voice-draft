-- Settings window: a local HTML page in an hs.webview. The page talks to
-- this module through a WebKit message handler; replies go back through
-- evaluateJavaScript("vd.receive(...)"). The page loads no remote content,
-- and navigation away from the local file is blocked.

local config = require("dictation.config")
local cleanup = require("dictation.cleanup")
local doctor = require("dictation.doctor")
local models = require("dictation.models")

local M = {}

local W, H = 720, 620

local webview, usercontent = nil, nil
local pull_task = nil
local download = nil -- active Whisper download: { file, task, timer, total }
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

local function models_dir()
  return ctx.cfg().paths.model:match("^(.*)/[^/]*$")
end

local function whisper_entries()
  local f = io.open(ctx.root .. "/whisper-models.tsv", "r")
  local catalog = f and models.parse_catalog(f:read("*a")) or {}
  if f then f:close() end
  local dir = models_dir()
  local on_disk, partial = {}, {}
  local ok, iter, obj = pcall(hs.fs.dir, dir)
  if ok and iter then
    for name in iter, obj do
      if models.valid_file(name) then
        on_disk[name] = hs.fs.attributes(dir .. "/" .. name, "size")
      elseif name:match("%.bin%.part$") then
        partial[name:gsub("%.part$", "")] = hs.fs.attributes(dir .. "/" .. name, "size")
      end
    end
  end
  local list = models.entries(catalog, dir, on_disk, ctx.cfg().paths.model)
  for _, e in ipairs(list) do e.partial_bytes = partial[e.file] end
  return list, dir
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
  local whisper, dir = whisper_entries()
  return {
    type = "state",
    version = ctx.version,
    values = values,
    locked = locked,
    ollama_models = ctx.ollama_models() or {},
    ollama_up = ctx.ollama_models() ~= nil,
    whisper_models = whisper,
    models_dir = dir,
    downloading = download and { file = download.file } or nil,
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

-- Whisper downloads run in `voice-draft models download` (curl, checksum
-- pinned), not in Hammerspoon. Progress comes from the .part file size.
local function handle_whisper_download(file)
  if not models.valid_file(file) then return end
  if download then
    return send({ type = "whisper_done", file = file, ok = false, message = "Another download is running" })
  end
  local total
  for _, e in ipairs((whisper_entries())) do
    if e.file == file then total = e.bytes end
  end
  local dir = models_dir()
  local dl = { file = file, total = total }
  dl.task = hs.task.new(ctx.root .. "/bin/voice-draft", function(code, stdout, stderr)
    if download == dl then download = nil end
    if dl.timer then dl.timer:stop() end
    local text = ((stdout or "") .. "\n" .. (stderr or "")):gsub("\27%[[%d;?]*%a", "")
    local message
    for line in text:gmatch("[^\r\n]+") do
      if line:find("warning:") or line:find("error:") then message = line:gsub("^%s*", "") end
    end
    local ok = code == 0
    if dl.cancelled then
      message = "Download paused. Click Resume to continue."
    elseif ok then
      message = "Downloaded and verified."
    end
    send({ type = "whisper_done", file = file, ok = ok and not dl.cancelled,
           message = message or ("Download failed (exit " .. code .. ")") })
    send(state_payload())
  end, { "models", "download", file })
  if not dl.task or not dl.task:start() then
    return send({ type = "whisper_done", file = file, ok = false, message = "Couldn't start the download" })
  end
  download = dl
  dl.timer = hs.timer.doEvery(0.5, function()
    local bytes = hs.fs.attributes(dir .. "/" .. file .. ".part", "size")
      or hs.fs.attributes(dir .. "/" .. file, "size") or 0
    send({ type = "whisper_progress", file = file, bytes = bytes, total = dl.total })
  end)
  send(state_payload())
end

local function handle_whisper_cancel()
  if download and download.task and download.task:isRunning() then
    download.cancelled = true
    download.task:terminate() -- the CLI stops curl; the .part file is kept
  end
end

local function handle_whisper_delete(file)
  if not models.valid_file(file) then return end
  local dir = models_dir()
  local path = dir .. "/" .. file
  if path == ctx.cfg().paths.model then
    return send({ type = "whisper_done", file = file, ok = false, message = "That model is in use. Select another one and save first." })
  end
  if download and download.file == file then handle_whisper_cancel() end
  os.remove(path)
  os.remove(path .. ".part")
  send({ type = "whisper_done", file = file, ok = true, message = "Deleted." })
  send(state_payload())
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
  elseif action == "whisper_download" then
    handle_whisper_download(body.file)
  elseif action == "whisper_cancel" then
    handle_whisper_cancel()
  elseif action == "whisper_delete" then
    handle_whisper_delete(body.file)
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
--        open_overrides(), html_path, root }
function M.open(context, tab)
  ctx = context
  if webview then
    webview:show():bringToFront(true)
    if tab then webview:evaluateJavaScript("vd.showTab(" .. hs.json.encode({ tab }):sub(2, -2) .. ")") end
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
  webview:url("file://" .. ctx.html_path .. (tab and ("#" .. tab) or ""))
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
