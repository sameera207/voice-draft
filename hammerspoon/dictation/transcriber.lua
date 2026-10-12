-- whisper-cli invocation and artifact filtering.
-- clean_output / is_hallucination are pure and unit-tested.

local cleanup = require("dictation.cleanup")

local M = {}

-- Phrases Whisper tends to invent on silent or near-silent audio. Only
-- treated as noise when they are the entire transcript.
local HALLUCINATIONS = {
  "thank you", "thank you very much", "thanks", "thanks for watching",
  "thank you for watching", "thank you so much for watching",
  "please subscribe", "subscribe", "bye", "goodbye", "you",
  "i m sorry", "subtitles by the amara org community", -- normalized form
}

local function normalize(s)
  return s:lower():gsub("[%p%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.is_hallucination(text)
  local n = normalize(text)
  if n == "" then return true end
  for _, h in ipairs(HALLUCINATIONS) do
    if n == h then return true end
  end
  return false
end

-- Join whisper-cli stdout lines and drop artifacts. Returns "" for silence.
function M.clean_output(stdout)
  local lines = {}
  for line in (stdout or ""):gmatch("[^\n]+") do
    -- Drop any timestamp prefix in case -nt is ignored.
    line = line:gsub("^%s*%[[%d:%.%s%->]+%]%s*", "")
    line = cleanup.trim(line)
    if line ~= "" then lines[#lines + 1] = line end
  end
  local text = cleanup.strip_artifacts(table.concat(lines, "\n"))
  if M.is_hallucination(text) then return "" end
  return text
end

function M.build_args(cfg, wav_path)
  local args = { "-m", cfg.paths.model, "-f", wav_path, "-nt", "-np",
                 "-l", cfg.whisper.language or "en" }
  local vocab = cfg.vocabulary or {}
  if #vocab > 0 then
    -- Keep the initial prompt short: a handful of terms.
    local terms = {}
    for i = 1, math.min(#vocab, 12) do terms[i] = vocab[i] end
    args[#args + 1] = "--prompt"
    args[#args + 1] = table.concat(terms, ", ") .. "."
  end
  if cfg.whisper.threads then
    args[#args + 1] = "-t"
    args[#args + 1] = tostring(cfg.whisper.threads)
  end
  for _, a in ipairs(cfg.whisper.extra_args or {}) do args[#args + 1] = a end
  return args
end

local task, timer = nil, nil

function M.cancel()
  if timer then timer:stop(); timer = nil end
  if task and task:isRunning() then task:terminate() end
  task = nil
end

-- callback(ok, text_or_error)
function M.run(cfg, whisper_path, wav_path, callback)
  local done = false
  local function finish(...)
    if done then return end
    done = true
    if timer then timer:stop(); timer = nil end
    task = nil
    callback(...)
  end
  local t = hs.task.new(whisper_path, function(code, stdout, stderr)
    if code ~= 0 then
      local last = (stderr or ""):match("([^\n]+)\n?$") or ""
      return finish(false, string.format("whisper-cli exit %d %s", code, last))
    end
    finish(true, M.clean_output(stdout))
  end, M.build_args(cfg, wav_path))
  if not t or not t:start() then return finish(false, "could not start whisper-cli") end
  task = t
  local limit = cfg.whisper.timeout_seconds or 120
  timer = hs.timer.doAfter(limit, function()
    if t:isRunning() then t:terminate() end
    finish(false, string.format("whisper-cli exceeded %ds", limit))
  end)
end

return M
