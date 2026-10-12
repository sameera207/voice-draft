-- Live feedback while recording: mic level from the growing WAV, and an
-- approximate transcript from periodic whisper-cli runs on a snapshot of the
-- audio so far. The final transcript still comes from the full recording.

local transcriber = require("dictation.transcriber")
local cleanup = require("dictation.cleanup")

local M = {}

local SAMPLE_RATE, BYTES_PER_SAMPLE = 16000, 2
local LEVEL_BYTES = 1600 -- last 50 ms

local session = nil -- { wav, snap, cfg, whisper, t0, ticker, pause, task, on_tick, on_text }

-- Offset of the PCM data in a WAV written by SoX (normally 44).
local function data_offset(f)
  f:seek("set", 0)
  local head = f:read(256) or ""
  local pos = head:find("data", 13, true)
  return pos and (pos + 7) or 44 -- pos is 1-based; data starts 8 bytes after
end

-- RMS level of the most recent audio, mapped from -60..0 dBFS to 0..1.
function M.level(path)
  local f = io.open(path, "rb")
  if not f then return 0 end
  local off = data_offset(f)
  local size = f:seek("end")
  local start = size - LEVEL_BYTES
  if start < off then f:close(); return 0 end
  if (start - off) % 2 == 1 then start = start - 1 end
  f:seek("set", start)
  local chunk = f:read(LEVEL_BYTES) or ""
  f:close()
  local n, sum = 0, 0
  for i = 1, #chunk - 1, 2 do
    local v = string.unpack("<i2", chunk, i)
    sum = sum + v * v
    n = n + 1
  end
  if n == 0 then return 0 end
  local rms = math.sqrt(sum / n) / 32768
  if rms <= 0 then return 0 end
  local db = 20 * math.log(rms, 10)
  return math.max(0, math.min(1, (db + 60) / 60))
end

-- Copy the last `window` seconds of audio into a standalone WAV.
-- Returns the number of seconds written, or nil.
local function snapshot(src, dst, window)
  local f = io.open(src, "rb")
  if not f then return nil end
  local off = data_offset(f)
  local size = f:seek("end")
  local avail = size - off
  avail = avail - avail % 2
  if avail <= 0 then f:close(); return nil end
  local want = math.min(avail, window * SAMPLE_RATE * BYTES_PER_SAMPLE)
  f:seek("set", off + avail - want)
  local data = f:read(want)
  f:close()
  local out = io.open(dst, "wb")
  if not out then return nil end
  out:write(string.pack("<c4I4c4c4I4I2I2I4I4I2I2c4I4",
    "RIFF", 36 + #data, "WAVE", "fmt ", 16, 1, 1, SAMPLE_RATE,
    SAMPLE_RATE * BYTES_PER_SAMPLE, BYTES_PER_SAMPLE, 16, "data", #data))
  out:write(data)
  out:close()
  return #data / (SAMPLE_RATE * BYTES_PER_SAMPLE)
end

local function schedule_preview(s, delay)
  s.pause = hs.timer.doAfter(delay, function()
    s.pause = nil
    if session ~= s then return end
    local secs = snapshot(s.wav, s.snap, s.cfg.ui.live_text_window or 30)
    if not secs or secs < 1 then return schedule_preview(s, 0.5) end
    local t = hs.task.new(s.whisper, function(code, stdout)
      s.task = nil
      os.remove(s.snap)
      if session ~= s then return end
      if code == 0 then
        local text = cleanup.stage1(transcriber.clean_output(stdout))
        if text ~= "" then s.on_text(text) end
      end
      schedule_preview(s, s.cfg.ui.live_text_interval or 1.0)
    end, transcriber.build_args(s.cfg, s.snap))
    if t and t:start() then s.task = t else schedule_preview(s, 2) end
  end)
end

-- on_tick(elapsed_seconds, level) ~10x/s; on_text(partial_transcript).
function M.start(cfg, wav, whisper, on_tick, on_text)
  M.stop()
  local s = {
    cfg = cfg, wav = wav, whisper = whisper,
    snap = wav:gsub("%.wav$", "") .. "-preview.wav",
    t0 = hs.timer.secondsSinceEpoch(), on_tick = on_tick, on_text = on_text,
  }
  session = s
  s.ticker = hs.timer.doEvery(0.1, function()
    if session ~= s then return end
    local ok, level = pcall(M.level, s.wav)
    on_tick(hs.timer.secondsSinceEpoch() - s.t0, ok and level or 0)
  end)
  if cfg.ui.live_text and whisper then schedule_preview(s, 1.5) end
end

-- Stop level updates and any in-flight preview transcription.
function M.stop()
  local s = session
  session = nil
  if not s then return end
  if s.ticker then s.ticker:stop() end
  if s.pause then s.pause:stop() end
  if s.task and s.task:isRunning() then s.task:terminate() end
  os.remove(s.snap)
end

return M
