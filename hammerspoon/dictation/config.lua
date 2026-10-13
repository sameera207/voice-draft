-- Settings, in three layers (later wins):
--   1. defaults below
--   2. ~/.config/voice-draft/settings.json  -- written by the menu/settings UI
--   3. ~/.config/voice-draft/overrides.lua  -- hand-edited, e.g.
--        return { cleanup = { ollama = { model = "llama3.2:3b" } } }
-- Everything here is pure Lua (JSON encode/decode are passed in) so it can
-- be unit tested without Hammerspoon.

local M = {}

local HOME = os.getenv("HOME") or ""

M.config_dir = HOME .. "/.config/voice-draft"
M.override_path = M.config_dir .. "/overrides.lua"
M.settings_path = M.config_dir .. "/settings.json"

function M.defaults()
  return {
    hotkey_toggle = { mods = { "ctrl", "alt" }, key = "d" },
    hotkey_cancel = { mods = { "ctrl", "alt", "shift" }, key = "d" },

    paths = {            -- nil means auto-detect in /opt/homebrew/bin, /usr/local/bin
      sox = nil,
      whisper = nil,
      model = HOME .. "/.local/share/voice-draft/models/ggml-large-v3-turbo.bin",
      tmp_wav = "/tmp/voice-draft.wav",
    },

    recording = { min_seconds = 0.5, max_seconds = 300 },

    whisper = { language = "en", threads = nil, extra_args = {}, timeout_seconds = 120 },

    vocabulary = { "Claude Code", "Claude Desktop", "MCP", "JIRA", "Confluence",
                   "Ollama", "Hammerspoon", "worktree" },

    cleanup = {
      mode = "llm",        -- "off" | "regex" | "llm"
      llm_min_words = 15,
      ollama = {
        url = "http://localhost:11434",
        model = "qwen2.5:3b",
        keep_alive = "30m",
        timeout_seconds = 8,
        preload_on_record = true,
        think = false,     -- no reasoning: faster on thinking models (qwen3, gemma4); ignored by others
      },
    },

    insert = { restore_clipboard_after_ms = 300, require_same_app = true },

    ui = {
      menubar = true, alerts = true, sounds = false,
      overlay = true,            -- floating panel while dictating
      live_text = true,          -- approximate transcript in the panel while recording
      live_text_interval = 1.0,  -- seconds between preview transcriptions
      live_text_window = 30,     -- preview transcribes only the last N seconds
    },

    debug = false,         -- true: log to ~/Library/Logs/voice-draft.log, never log transcripts unless log_text = true
    log_text = false,
    keep_audio = false,
  }
end

local function is_array(t)
  return type(t) == "table" and (t[1] ~= nil or next(t) == nil)
end

-- Deep-merge `over` into `base`. Arrays (vocabulary, mods, extra_args) are
-- replaced, not merged.
function M.merge(base, over)
  for k, v in pairs(over or {}) do
    if type(v) == "table" and type(base[k]) == "table" and not is_array(v) and not is_array(base[k]) then
      M.merge(base[k], v)
    else
      base[k] = v
    end
  end
  return base
end

---------------------------------------------------------------------------
-- Dotted-key helpers ("cleanup.ollama.model")
---------------------------------------------------------------------------

function M.get_path(t, key)
  for part in key:gmatch("[^%.]+") do
    if type(t) ~= "table" then return nil end
    t = t[part]
  end
  return t
end

function M.set_path(t, key, value)
  local parts = {}
  for part in key:gmatch("[^%.]+") do parts[#parts + 1] = part end
  for i = 1, #parts - 1 do
    if type(t[parts[i]]) ~= "table" then t[parts[i]] = {} end
    t = t[parts[i]]
  end
  t[parts[#parts]] = value
end

-- Dotted keys of every leaf value in t (arrays count as leaves).
function M.flatten_keys(t, prefix, out)
  out = out or {}
  for k, v in pairs(t or {}) do
    local key = prefix and (prefix .. "." .. tostring(k)) or tostring(k)
    if type(v) == "table" and not is_array(v) then
      M.flatten_keys(v, key, out)
    else
      out[key] = true
    end
  end
  return out
end

local function deep_equal(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deep_equal(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

local function prune_empty(t)
  for k, v in pairs(t) do
    if type(v) == "table" and v[1] == nil then -- objects, including emptied ones
      prune_empty(v)
      if next(v) == nil then t[k] = nil end
    end
  end
  return t
end

-- Record a UI change in the settings table. Values equal to the default
-- are removed, so settings.json only holds what the user actually changed.
function M.set_setting(settings, key, value)
  if deep_equal(value, M.get_path(M.defaults(), key)) then
    M.set_path(settings, key, nil)
  else
    M.set_path(settings, key, value)
  end
  return prune_empty(settings)
end

-- Is this key (or one of its parents) set in overrides.lua?
function M.is_locked(locked, key)
  if locked[key] then return true end
  for k in pairs(locked) do
    if key:sub(1, #k + 1) == k .. "." or k:sub(1, #key + 1) == key .. "." then return true end
  end
  return false
end

---------------------------------------------------------------------------
-- Validation for values coming from the settings window
---------------------------------------------------------------------------

local VALID_MODS = { cmd = true, alt = true, ctrl = true, shift = true }

local function boolean(v)
  if type(v) == "boolean" then return true, v end
  return false, "must be on or off"
end

local function number_in(lo, hi, integer)
  return function(v)
    v = tonumber(v)
    if not v then return false, "must be a number" end
    if integer and v ~= math.floor(v) then return false, "must be a whole number" end
    if v < lo or v > hi then return false, string.format("must be between %s and %s", lo, hi) end
    return true, v
  end
end

local function hotkey(v)
  if type(v) ~= "table" or type(v.key) ~= "string" or v.key == "" then
    return false, "press a key combination"
  end
  local mods, seen = {}, {}
  for _, m in ipairs(v.mods or {}) do
    if not VALID_MODS[m] then return false, "unknown modifier " .. tostring(m) end
    if not seen[m] then seen[m] = true; mods[#mods + 1] = m end
  end
  if #mods == 0 then return false, "needs at least one modifier (⌃ ⌥ ⇧ ⌘)" end
  return true, { mods = mods, key = v.key:lower() }
end

M.VALIDATORS = {
  hotkey_toggle = hotkey,
  hotkey_cancel = hotkey,
  ["cleanup.mode"] = function(v)
    if v == "off" or v == "regex" or v == "llm" then return true, v end
    return false, "must be off, regex or llm"
  end,
  ["cleanup.ollama.model"] = function(v)
    if type(v) == "string" and v:find("^[%w%._:/%-]+$") then return true, v end
    return false, "must be an Ollama model name"
  end,
  ["cleanup.llm_min_words"] = number_in(0, 1000, true),
  ["cleanup.ollama.timeout_seconds"] = number_in(1, 120, false),
  ["whisper.language"] = function(v)
    if v == "auto" or (type(v) == "string" and v:find("^%a%a%a?$")) then return true, v:lower() end
    return false, "must be auto or a language code such as en"
  end,
  ["whisper.threads"] = function(v)
    if v == nil or v == "" or v == false then return true, nil end
    return number_in(1, 64, true)(v)
  end,
  ["paths.model"] = function(v)
    if type(v) == "string" and v:find("%.bin$") then return true, v end
    return false, "must be a ggml .bin model file"
  end,
  ["recording.max_seconds"] = number_in(10, 1800, true),
  vocabulary = function(v)
    if type(v) ~= "table" then return false, "must be a list of terms" end
    local out = {}
    for _, raw in ipairs(v) do
      if type(raw) == "string" then
        local term = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if term ~= "" then out[#out + 1] = term end
      end
    end
    if #out > 50 then return false, "keep it to 50 terms or fewer" end
    return true, out
  end,
  ["ui.overlay"] = boolean,
  ["ui.live_text"] = boolean,
  ["ui.sounds"] = boolean,
  ["ui.alerts"] = boolean,
  ["insert.require_same_app"] = boolean,
  debug = boolean,
  log_text = boolean,
  keep_audio = boolean,
}

-- Returns true, normalized_value  or  false, message.
function M.validate(key, value)
  local fn = M.VALIDATORS[key]
  if not fn then return false, "not a setting the window can change" end
  return fn(value)
end

-- Validate a whole form: { [dotted_key] = value }. Returns the normalized
-- values and a table of { [key] = message } for the ones that failed.
function M.validate_all(values)
  local ok_values, errors = {}, {}
  for key, value in pairs(values) do
    local ok, result = M.validate(key, value)
    if ok then ok_values[key] = { value = result } else errors[key] = result end
  end
  local t, c = ok_values.hotkey_toggle, ok_values.hotkey_cancel
  if t and c and t.value.key == c.value.key then
    local a, b = table.concat(t.value.mods, "+"), table.concat(c.value.mods, "+")
    local sa, sb = {}, {}
    for m in a:gmatch("[^+]+") do sa[m] = true end
    for m in b:gmatch("[^+]+") do sb[m] = true end
    local same = #t.value.mods == #c.value.mods
    for m in pairs(sa) do same = same and sb[m] end
    if same then errors.hotkey_cancel = "must differ from the start/stop hotkey" end
  end
  return ok_values, errors
end

---------------------------------------------------------------------------
-- Loading and saving
---------------------------------------------------------------------------

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

-- opts: { decode = json_decode_fn, settings_path = ..., override_path = ... }
-- Returns cfg, error_message_or_nil, info where info has
--   settings: the table from settings.json (what the UI saves back)
--   locked:   set of dotted keys that overrides.lua sets
function M.load(opts)
  opts = opts or {}
  local cfg = M.defaults()
  local errors = {}
  local info = { settings = {}, locked = {} }

  local settings_path = opts.settings_path or M.settings_path
  local text = opts.decode and read_file(settings_path)
  if text and text:find("%S") then
    local ok, t = pcall(opts.decode, text)
    if ok and type(t) == "table" then
      info.settings = t
      M.merge(cfg, t)
    else
      errors[#errors + 1] = "Bad settings file " .. settings_path .. " (ignored)"
    end
  end

  local override_path = opts.override_path or M.override_path
  if read_file(override_path) then
    local ok, over = pcall(dofile, override_path)
    if not ok then
      errors[#errors + 1] = "Bad overrides file: " .. tostring(over)
    elseif type(over) ~= "table" then
      errors[#errors + 1] = "Overrides file must return a table"
    else
      info.locked = M.flatten_keys(over)
      M.merge(cfg, over)
    end
  end

  return cfg, (#errors > 0 and table.concat(errors, "; ") or nil), info
end

-- Atomically write settings.json. Returns true or false, error.
function M.save_settings(settings, encode, path)
  path = path or M.settings_path
  local ok, text = pcall(encode, settings)
  if not ok then return false, tostring(text) end
  local tmp = path .. ".tmp"
  local f, err = io.open(tmp, "w")
  if not f then return false, err end
  f:write(text, "\n")
  f:close()
  local renamed, rerr = os.rename(tmp, path)
  if not renamed then return false, rerr end
  return true
end

return M
