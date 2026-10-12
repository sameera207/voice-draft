-- Default settings, merged with ~/.config/local-dictation/overrides.lua.
-- The override file returns a table with only the keys you want to change,
-- e.g.  return { cleanup = { ollama = { model = "llama3.2:3b" } } }

local M = {}

local HOME = os.getenv("HOME") or ""

M.override_path = HOME .. "/.config/local-dictation/overrides.lua"

function M.defaults()
  return {
    hotkey_toggle = { mods = { "ctrl", "alt" }, key = "d" },
    hotkey_cancel = { mods = { "ctrl", "alt", "shift" }, key = "d" },

    paths = {            -- nil means auto-detect in /opt/homebrew/bin, /usr/local/bin
      sox = nil,
      whisper = nil,
      model = HOME .. "/.local/share/local-dictation/models/ggml-large-v3-turbo.bin",
      tmp_wav = "/tmp/local-dictation.wav",
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
        think = nil,       -- set false to disable reasoning on thinking models
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

    debug = false,         -- true: log to ~/Library/Logs/local-dictation.log, never log transcripts unless log_text = true
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

-- Returns config, error_message_or_nil.
function M.load(path)
  path = path or M.override_path
  local cfg = M.defaults()
  local f = io.open(path, "r")
  if not f then return cfg end
  f:close()
  local ok, over = pcall(dofile, path)
  if not ok then return cfg, "Bad overrides file: " .. tostring(over) end
  if type(over) ~= "table" then return cfg, "Overrides file must return a table" end
  return M.merge(cfg, over)
end

return M
