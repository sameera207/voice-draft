-- Transcript cleanup.
--
-- Stage 1 (stage1, validate, build_request, ...) is pure Lua with no hs.*
-- dependency so it can be unit tested with plain lua/luajit.
-- Stage 2 (llm, preload, process) talks to Ollama through hs.http and is
-- only usable inside Hammerspoon.

local M = {}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
M.trim = trim

function M.count_words(s)
  local n = 0
  for _ in (s or ""):gmatch("%S+") do n = n + 1 end
  return n
end

-- Split a token into leading punctuation, core word and trailing punctuation.
local function split_token(tok)
  local lead, core, trail = tok:match("^([%(\"']*)(.-)([,%.;:!%?%)\"']*)$")
  return lead or "", core or tok, trail or ""
end

local function core_lower(tok)
  local _, core = split_token(tok)
  return core:lower()
end

local function trailing(tok)
  local _, _, trail = split_token(tok)
  return trail
end

-- Placeholder bytes used for protected backtick spans.
local PH = "\1"

-- Does this token look like code (identifier, path, flag, number, ...)?
-- Such tokens are never removed, collapsed or re-capitalized.
local function is_code(tok)
  if tok:find(PH, 1, true) then return true end
  local _, core = split_token(tok)
  if core == "" then return false end
  if core:find("[/\\_=<>{}%[%]`@#%$%%%^&%*|~+]") then return true end
  if core:find("%d") then return true end
  if core:find("^%-") and #core > 1 then return true end -- -b, --force
  if core:find("%w[%.:]%w") then return true end         -- file.lua, a::b
  if core:find("%l%u") then return true end              -- camelCase
  if core:find("%w%(") then return true end              -- fn(
  return false
end
M.is_code = is_code

local function ends_sentence(tok)
  return tok ~= nil and trailing(tok):find("[%.!%?]") ~= nil
end

local function capitalize(tok)
  if is_code(tok) then return tok end
  return (tok:gsub("^([^%a]*)(%l)", function(pre, c) return pre .. c:upper() end, 1))
end

-- Replace a token's trailing punctuation.
local function with_trail(tok, new_trail)
  local lead, core = split_token(tok)
  return lead .. core .. new_trail
end

---------------------------------------------------------------------------
-- Whisper artifacts
---------------------------------------------------------------------------

local SOUND_WORDS = {
  "music", "applause", "laugh", "silence", "inaudible", "noise", "cough",
  "sigh", "breath", "click", "typing", "speaking", "foreign", "static",
  "beep", "wind", "chuckl", "clap", "sound", "mumbl", "indistinct", "blank",
  "crosstalk", "unintelligible", "background", "door", "phone", "ring",
}

local function is_sound_tag(content)
  local c = content:lower()
  if M.count_words(c) > 5 or not c:find("^[%a%s%-_']+$") then return false end
  for _, w in ipairs(SOUND_WORDS) do
    if c:find(w, 1, true) then return true end
  end
  return false
end

-- Remove [BLANK_AUDIO], [Music], (music), (upbeat music), *sighs*, ♪ etc.
-- Only tags that start a word are removed, so foo[0] / fn(x) survive.
function M.strip_artifacts(text)
  local s = " " .. text
  s = s:gsub("(%s)%[[^%[%]]*%]", "%1")
  s = s:gsub("(%s)%(([^%(%)]*)%)", function(sp, content)
    if is_sound_tag(content) then return sp end
  end)
  s = s:gsub("(%s)%*([^%*]*)%*", function(sp, content)
    if is_sound_tag(content) or content:find("^%a+s$") then return sp end
  end)
  s = s:gsub("\226\153\170", ""):gsub("\226\153\171", "") -- ♪ ♫
  return trim(s)
end

---------------------------------------------------------------------------
-- Stage 1
---------------------------------------------------------------------------

local FILLER_PATTERNS = {
  "^u+m+$", "^u+h+$", "^u+h+m+$", "^e+r+$", "^e+r+m+$", "^a+h+$", "^h+m+$",
}

local function is_filler(tok)
  if is_code(tok) then return false end
  local c = core_lower(tok)
  for _, p in ipairs(FILLER_PATTERNS) do
    if c:find(p) then return true end
  end
  return false
end

local PHRASES = { { "you", "know" }, { "i", "mean" } }

-- Words whose doubling is usually grammatical ("I had had", "that that").
local REPEAT_OK = { had = true, that = true }

local function tokenize(text)
  local toks = {}
  for t in text:gmatch("%S+") do
    -- Attach pure punctuation to the previous token ("word ," -> "word,").
    if t:find("^[,%.;:!%?]+$") and #toks > 0 then
      toks[#toks] = toks[#toks] .. t
    else
      toks[#toks + 1] = t
    end
  end
  return toks
end

local function at_sentence_start(out)
  return #out == 0 or ends_sentence(out[#out])
end

local function remove_fillers(toks)
  local out, cap_next = {}, false
  for _, t in ipairs(toks) do
    if is_filler(t) then
      if at_sentence_start(out) then cap_next = true end
      local term = trailing(t):match("[%.!%?]")
      if term and #out > 0 then
        -- Keep the sentence boundary the filler carried.
        local prev_trail = trailing(out[#out]):gsub("[,;:]", "")
        if not prev_trail:find("[%.!%?]") then
          out[#out] = with_trail(out[#out], prev_trail .. term)
        end
      end
    else
      if cap_next then t = capitalize(t); cap_next = false end
      out[#out + 1] = t
    end
  end
  return out
end

-- "you know" / "I mean" only when set off by commas or starting a sentence
-- and followed by a comma. "I know you know the answer" is left alone.
local function remove_phrases(toks)
  local out, i, cap_next = {}, 1, false
  while i <= #toks do
    local removed = false
    local a, b = toks[i], toks[i + 1]
    if b and not is_code(a) and not is_code(b) and trailing(a) == "" then
      for _, ph in ipairs(PHRASES) do
        if core_lower(a) == ph[1] and core_lower(b) == ph[2] then
          local bt = trailing(b)
          local prev = out[#out]
          local prev_comma = prev and trailing(prev):find(",$")
          if at_sentence_start(out) and bt == "," then
            removed, cap_next = true, true
          elseif prev_comma and bt == "," then
            out[#out] = with_trail(prev, trailing(prev):gsub(",$", ""))
            removed = true
          elseif prev_comma and bt:find("^[%.!%?]") then
            out[#out] = with_trail(prev, (trailing(prev):gsub(",$", "")) .. bt)
            removed = true
          end
          if removed then break end
        end
      end
    end
    if removed then
      i = i + 2
    else
      local t = toks[i]
      if cap_next then t = capitalize(t); cap_next = false end
      out[#out + 1] = t
      i = i + 1
    end
  end
  return out
end

local function ngram_repeats(toks, i, n)
  if i + 2 * n - 1 > #toks then return false end
  for k = 0, n - 1 do
    local a, b = toks[i + k], toks[i + n + k]
    if is_code(a) or is_code(b) then return false end
    if core_lower(a) ~= core_lower(b) or core_lower(a) == "" then return false end
    local tr = trailing(a)
    if k < n - 1 or n == 1 then
      if tr ~= "" then return false end
    elseif tr ~= "" and tr ~= "," then
      return false
    end
  end
  if n == 1 and REPEAT_OK[core_lower(toks[i])] then return false end
  return true
end

-- Collapse "the the", "I I", "I want to I want to" (phrases up to 4 words).
local function collapse_repeats(toks)
  local out, i, cap_next = {}, 1, false
  while i <= #toks do
    local dropped = false
    for n = 4, 1, -1 do
      if ngram_repeats(toks, i, n) then
        if at_sentence_start(out) then cap_next = true end
        i = i + n
        dropped = true
        break
      end
    end
    if not dropped then
      local t = toks[i]
      if cap_next then t = capitalize(t); cap_next = false end
      out[#out + 1] = t
      i = i + 1
    end
  end
  return out
end

local function clean_paragraph(p)
  local toks = tokenize(p)
  toks = remove_fillers(toks)
  toks = remove_phrases(toks)
  toks = collapse_repeats(toks)
  if #toks == 0 then return "" end
  -- Strip dangling leading punctuation left by removals (", so" -> "so").
  toks[1] = toks[1]:gsub("^[,;:]+", "")
  if toks[1] == "" then table.remove(toks, 1) end
  if #toks == 0 then return "" end
  toks[1] = capitalize(toks[1])
  return table.concat(toks, " ")
end

function M.stage1(text)
  if not text or text == "" then return "" end
  -- Protect backtick spans.
  local protected = {}
  local s = text:gsub("`[^`]*`", function(span)
    protected[#protected + 1] = span
    return PH .. #protected .. PH
  end)

  s = M.strip_artifacts(s)

  local paragraphs = {}
  s = s:gsub("\r\n?", "\n")
  for para in (s .. "\n\n"):gmatch("(.-)\n%s*\n") do
    para = para:gsub("%s*\n%s*", " ")
    local cleaned = clean_paragraph(para)
    if cleaned ~= "" then paragraphs[#paragraphs + 1] = cleaned end
  end
  s = table.concat(paragraphs, "\n\n")

  s = s:gsub(PH .. "(%d+)" .. PH, function(n) return protected[tonumber(n)] end)
  return trim(s)
end

---------------------------------------------------------------------------
-- Stage 2: request building and output validation (pure)
---------------------------------------------------------------------------

M.FEW_SHOT = {
  {
    user = "so uh I want to, I mean I speak my thoughts and then it converts it and puts it into Claude Code",
    assistant = "I want to speak my thoughts and have them converted and put into Claude Code.",
  },
  {
    user = "okay so can you can you look at the the auth module and um tell me why the tests are failing, actually no just the login tests",
    assistant = "Can you look at the auth module and tell me why the login tests are failing?",
  },
}

function M.render_system_prompt(template, vocabulary)
  local vocab = table.concat(vocabulary or {}, ", ")
  return (template:gsub("{{vocabulary}}", function() return vocab end))
end

local function wrap(t) return "<transcript>" .. t .. "</transcript>" end

function M.build_request(text, ocfg, system_prompt)
  local messages = { { role = "system", content = system_prompt } }
  for _, ex in ipairs(M.FEW_SHOT) do
    messages[#messages + 1] = { role = "user", content = wrap(ex.user) }
    messages[#messages + 1] = { role = "assistant", content = ex.assistant }
  end
  messages[#messages + 1] = { role = "user", content = wrap(text) }
  -- ~1.3 tokens per English word, 1.5x headroom.
  local num_predict = math.max(256, math.ceil(M.count_words(text) * 1.3 * 1.5))
  local req = {
    model = ocfg.model,
    messages = messages,
    stream = false,
    keep_alive = ocfg.keep_alive,
    options = { temperature = 0, num_predict = num_predict },
  }
  if ocfg.think ~= nil then req.think = ocfg.think end
  return req
end

local PREAMBLES = {
  "^sure", "^here is", "^here's", "^here’s", "^cleaned", "^certainly",
  "^of course", "^okay, here", "^ok, here", "^the cleaned", "^below is",
  "^i've cleaned", "^i have cleaned", "^cleaned%-up",
}

local function strip_wrappers(s)
  s = trim(s)
  local _, inner = s:match("^<(%w+)>(.*)</%1>$")
  if inner then s = trim(inner) end
  s = trim(s:gsub("</?transcript>", ""))
  local fenced = s:match("^```%w*\n(.*)\n```$")
  if fenced then s = trim(fenced) end
  for _, q in ipairs({ { '"', '"' }, { "'", "'" }, { "\226\128\156", "\226\128\157" } }) do
    if #s >= #q[1] + #q[2] and s:sub(1, #q[1]) == q[1] and s:sub(-#q[2]) == q[2] then
      s = trim(s:sub(#q[1] + 1, -#q[2] - 1))
      break
    end
  end
  return s
end

-- Returns true, cleaned_text  or  false, reason.
function M.validate(output, stage1_text, opts)
  opts = opts or {}
  local min_ratio, max_ratio = opts.min_ratio or 0.4, opts.max_ratio or 1.3
  if type(output) ~= "string" then return false, "no output" end
  output = output:gsub("<think>.-</think>", "")
  local s = strip_wrappers(output)
  if s == "" then return false, "empty output" end
  local low, src = s:lower(), (stage1_text or ""):lower()
  for _, p in ipairs(PREAMBLES) do
    if low:find(p) and not src:find(p) then return false, "preamble" end
  end
  local in_words, out_words = M.count_words(stage1_text), M.count_words(s)
  if in_words == 0 then return false, "empty input" end
  local ratio = out_words / in_words
  if ratio < min_ratio then return false, string.format("too short (%.0f%%)", ratio * 100) end
  if ratio > max_ratio then return false, string.format("too long (%.0f%%)", ratio * 100) end
  return true, s
end

---------------------------------------------------------------------------
-- Stage 2: Ollama client (Hammerspoon only)
---------------------------------------------------------------------------

-- Is the URL's host a loopback address?
function M.is_loopback_url(url)
  local host = (url or ""):match("^https?://%[([^%]]+)%]") or (url or ""):match("^https?://([^:/]+)")
  if not host then return false end
  host = host:lower()
  return host == "localhost" or host == "::1" or host:find("^127%.%d+%.%d+%.%d+$") ~= nil
end

-- Ask Ollama to load the model (empty messages = load only).
function M.preload(ocfg)
  local body = hs.json.encode({ model = ocfg.model, messages = {}, keep_alive = ocfg.keep_alive })
  hs.http.asyncPost(ocfg.url .. "/api/chat", body, { ["Content-Type"] = "application/json" }, function() end)
end

-- callback(ok, text_or_reason, kind) where kind is "unavailable" for
-- connection/HTTP/timeout problems and "invalid" for rejected output.
function M.llm(text, ocfg, system_prompt, callback)
  local done = false
  local function finish(...)
    if done then return end
    done = true
    callback(...)
  end
  local timer = hs.timer.doAfter(ocfg.timeout_seconds or 8, function()
    finish(false, "timeout", "unavailable")
  end)
  local body = hs.json.encode(M.build_request(text, ocfg, system_prompt))
  hs.http.asyncPost(ocfg.url .. "/api/chat", body, { ["Content-Type"] = "application/json" },
    function(status, resp)
      timer:stop()
      if status ~= 200 then
        local err = "HTTP " .. tostring(status)
        local ok, decoded = pcall(hs.json.decode, resp or "")
        if ok and type(decoded) == "table" and decoded.error then err = decoded.error end
        return finish(false, err, "unavailable")
      end
      local ok, decoded = pcall(hs.json.decode, resp or "")
      local content = ok and type(decoded) == "table" and decoded.message and decoded.message.content
      if type(content) ~= "string" then return finish(false, "bad response", "invalid") end
      local valid, result = M.validate(content, text)
      if valid then finish(true, result) else finish(false, result, "invalid") end
    end)
end

-- Run the configured cleanup on a raw transcript.
-- callback(final_text, notice) -- notice is nil or a short message to show.
function M.process(raw, cfg, system_prompt, callback, log)
  local mode = cfg.cleanup.mode
  if mode == "off" then return callback(trim(M.strip_artifacts(raw))) end
  local s1 = M.stage1(raw)
  if mode ~= "llm" or s1 == "" or M.count_words(s1) < cfg.cleanup.llm_min_words then
    return callback(s1)
  end
  local ocfg = cfg.cleanup.ollama
  M.llm(s1, ocfg, system_prompt, function(ok, result, kind)
    if ok then return callback(result) end
    if log then log("LLM cleanup failed: " .. tostring(result)) end
    if kind == "unavailable" then
      local fix = (result == "timeout") and "Cleanup timed out"
        or (tostring(result):find("not found") and ("Cleanup unavailable: run `ollama pull " .. ocfg.model .. "`"))
        or "Cleanup unavailable (is `ollama serve` running?)"
      return callback(s1, fix .. ", pasted raw transcript")
    end
    callback(s1, cfg.debug and ("LLM output rejected: " .. tostring(result)) or nil)
  end)
end

return M
