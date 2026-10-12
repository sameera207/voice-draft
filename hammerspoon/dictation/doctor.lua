-- Dependency and permission checks. Run dictation.doctor() in the
-- Hammerspoon console.

local cleanup = require("dictation.cleanup")

local M = {}

local SEARCH_DIRS = { "/opt/homebrew/bin", "/usr/local/bin" }

local INSTALL = {
  sox = "brew install sox",
  ["whisper-cli"] = "brew install whisper-cpp",
}

local function is_file(path)
  return path and hs.fs.attributes(path, "mode") == "file"
end

-- Resolve a binary: config override first, then Homebrew locations.
-- Hammerspoon does not inherit the shell PATH.
function M.resolve_bin(override, name)
  if override then return is_file(override) and override or nil end
  for _, dir in ipairs(SEARCH_DIRS) do
    local p = dir .. "/" .. name
    if is_file(p) then return p end
  end
  return nil
end

-- Returns a list of { name, ok, detail } for the things a recording needs.
-- Used before each recording, so it must stay fast (no network).
function M.local_checks(cfg)
  local results = {}
  local function add(name, ok, detail) results[#results + 1] = { name = name, ok = ok, detail = detail } end

  local sox = M.resolve_bin(cfg.paths.sox, "sox")
  add("sox", sox ~= nil, sox or ("missing: " .. INSTALL.sox))

  local whisper = M.resolve_bin(cfg.paths.whisper, "whisper-cli")
  add("whisper-cli", whisper ~= nil, whisper or ("missing: " .. INSTALL["whisper-cli"]))

  local size = hs.fs.attributes(cfg.paths.model, "size")
  add("whisper model", size ~= nil and size > 10 * 1024 * 1024,
    size and string.format("%s (%.0f MB)", cfg.paths.model, size / 1048576)
      or ("missing: " .. cfg.paths.model .. " (run install.sh)"))
  return results, sox, whisper
end

local function ollama_checks(cfg, add)
  local o = cfg.cleanup.ollama
  local loopback = cleanup.is_loopback_url(o.url)
  add("ollama url is loopback", loopback, o.url)
  if cfg.cleanup.mode ~= "llm" then
    add("ollama", true, "skipped (cleanup.mode = " .. cfg.cleanup.mode .. ")")
    return
  end
  if not loopback then return end
  local status, body = hs.http.get(o.url .. "/api/tags", nil)
  add("ollama reachable", status == 200,
    status == 200 and o.url or ("not reachable (status " .. tostring(status) .. "): run `ollama serve` or `brew services start ollama`"))
  if status ~= 200 then return end
  local ok, data = pcall(hs.json.decode, body or "")
  local found = false
  if ok and type(data) == "table" then
    for _, m in ipairs(data.models or {}) do
      if m.name == o.model or m.name == o.model .. ":latest" then found = true end
    end
  end
  add("ollama model pulled", found, found and o.model or ("missing: ollama pull " .. o.model))
end

function M.run(cfg, version)
  local results = M.local_checks(cfg)
  local function add(name, ok, detail) results[#results + 1] = { name = name, ok = ok, detail = detail } end

  ollama_checks(cfg, add)

  add("accessibility permission", hs.accessibilityState(false),
    "System Settings > Privacy & Security > Accessibility > enable Hammerspoon")
  if hs.microphoneState then
    add("microphone permission", hs.microphoneState(false),
      "System Settings > Privacy & Security > Microphone > enable Hammerspoon")
  else
    add("microphone permission", true, "cannot check on this Hammerspoon version; make a test recording")
  end

  local all_ok = true
  print("voice-draft doctor (version " .. tostring(version or "dev") .. ")")
  for _, r in ipairs(results) do
    all_ok = all_ok and r.ok
    print(string.format("  [%s] %-26s %s", r.ok and "PASS" or "FAIL", r.name, r.detail or ""))
  end
  print(all_ok and "All checks passed." or "Some checks failed.")
  return all_ok, results
end

return M
