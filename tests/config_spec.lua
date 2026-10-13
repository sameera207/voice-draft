-- Plain-Lua tests for config layering (defaults < settings.json < overrides.lua).
-- Run from the repo root:  lua tests/config_spec.lua

package.path = "./hammerspoon/?.lua;./hammerspoon/?/init.lua;" .. package.path
local config = require("dictation.config")

local passed, failed = 0, 0

local function check(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL %s\n  got:  %q\n  want: %q", name, tostring(got), tostring(want)))
  end
end

-- Stand-ins for hs.json: the "JSON" files hold Lua table literals.
local function decode(s) return assert(load("return " .. s))() end
local function encode(t)
  local function enc(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    local parts = {}
    if v[1] ~= nil then
      for _, x in ipairs(v) do parts[#parts + 1] = enc(x) end
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys)
      for _, k in ipairs(keys) do parts[#parts + 1] = "[" .. string.format("%q", k) .. "]=" .. enc(v[k]) end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return enc(t)
end

local dir = os.tmpname()
os.remove(dir)
local settings_path, override_path = dir .. "-settings.json", dir .. "-overrides.lua"

local function write(path, text)
  local f = assert(io.open(path, "w")); f:write(text); f:close()
end

local function load_cfg()
  return config.load({ decode = decode, settings_path = settings_path, override_path = override_path })
end

---------------------------------------------------------------------------
-- No files: defaults
---------------------------------------------------------------------------

os.remove(settings_path); os.remove(override_path)
local cfg, err, info = load_cfg()
check("defaults: model", cfg.cleanup.ollama.model, "qwen2.5:3b")
check("defaults: no error", err, nil)
check("defaults: nothing locked", next(info.locked), nil)

---------------------------------------------------------------------------
-- Precedence
---------------------------------------------------------------------------

write(settings_path, '{ cleanup = { mode = "regex", ollama = { model = "gemma4:latest" } }, ui = { sounds = true } }')
write(override_path, 'return { cleanup = { ollama = { model = "llama3.2:3b" } } }')
cfg, err, info = load_cfg()
check("settings.json applies", cfg.cleanup.mode, "regex")
check("settings.json applies (ui)", cfg.ui.sounds, true)
check("overrides win over settings.json", cfg.cleanup.ollama.model, "llama3.2:3b")
check("siblings keep defaults", cfg.cleanup.ollama.keep_alive, "30m")
check("info.settings is the raw json", info.settings.cleanup.ollama.model, "gemma4:latest")
check("locked: overridden key", config.is_locked(info.locked, "cleanup.ollama.model"), true)
check("locked: other key", config.is_locked(info.locked, "cleanup.mode"), false)
check("locked: parent of overridden key", config.is_locked(info.locked, "cleanup.ollama"), true)

write(override_path, 'return { ui = { overlay = false } }')
cfg, err, info = load_cfg()
check("locked: child of overridden table", config.is_locked(info.locked, "ui.overlay"), true)
check("locked: sibling of overridden key", config.is_locked(info.locked, "ui.sounds"), false)

---------------------------------------------------------------------------
-- Bad files are reported and ignored
---------------------------------------------------------------------------

write(settings_path, "{ this is not valid")
os.remove(override_path)
cfg, err = load_cfg()
check("bad settings: error reported", err ~= nil and err:find("Bad settings file", 1, true) ~= nil, true)
check("bad settings: defaults used", cfg.cleanup.mode, "llm")

write(override_path, "return 42")
cfg, err = load_cfg()
check("bad overrides: error reported", err ~= nil and err:find("must return a table", 1, true) ~= nil, true)

---------------------------------------------------------------------------
-- set_setting stores only non-default values
---------------------------------------------------------------------------

local s = {}
config.set_setting(s, "cleanup.ollama.model", "gemma4:latest")
check("set_setting: stores change", s.cleanup.ollama.model, "gemma4:latest")
config.set_setting(s, "ui.live_text", false)
check("set_setting: stores false", s.ui.live_text, false)
config.set_setting(s, "cleanup.ollama.model", "qwen2.5:3b")
check("set_setting: default removes key and empty parents", s.cleanup, nil)
config.set_setting(s, "vocabulary", { "MCP" })
check("set_setting: arrays stored", s.vocabulary[1], "MCP")
config.set_setting(s, "vocabulary", config.defaults().vocabulary)
check("set_setting: default array removed", s.vocabulary, nil)
check("set_setting: other keys kept", s.ui.live_text, false)

---------------------------------------------------------------------------
-- Save / load round trip
---------------------------------------------------------------------------

os.remove(override_path)
local ok = config.save_settings({ cleanup = { mode = "off" } }, encode, settings_path)
check("save: ok", ok, true)
cfg = load_cfg()
check("save: round trip", cfg.cleanup.mode, "off")
check("save: no temp file left", io.open(settings_path .. ".tmp", "r"), nil)

local bad_ok, bad_err = config.save_settings({}, encode, "/nonexistent-dir/settings.json")
check("save: unwritable path fails", bad_ok, false)
check("save: error message", type(bad_err), "string")

---------------------------------------------------------------------------
-- Path helpers
---------------------------------------------------------------------------

local t = {}
config.set_path(t, "a.b.c", 1)
check("set_path/get_path", config.get_path(t, "a.b.c"), 1)
check("get_path missing", config.get_path(t, "a.x.c"), nil)

os.remove(settings_path); os.remove(override_path)
print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
