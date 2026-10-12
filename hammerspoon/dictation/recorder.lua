-- Microphone recording with SoX to a 16 kHz mono 16-bit WAV.

local M = {}

local WAV_HEADER_BYTES = 44
local BYTES_PER_SECOND = 16000 * 2 -- 16 kHz, mono, 16-bit

local task = nil

-- Seconds of audio in a WAV written by start(), or nil if missing.
function M.duration(path)
  local size = hs.fs.attributes(path, "size")
  if not size then return nil end
  return math.max(0, size - WAV_HEADER_BYTES) / BYTES_PER_SECOND
end

function M.delete(path)
  if path and hs.fs.attributes(path) then os.remove(path) end
end

function M.is_recording()
  return task ~= nil and task:isRunning()
end

-- Start recording. on_exit(exit_code, stderr) fires when SoX exits, either
-- after stop()/cancel() or because it failed (e.g. no input device).
function M.start(sox_path, wav_path, on_exit)
  M.delete(wav_path)
  local t
  t = hs.task.new(sox_path, function(code, _, stderr)
    if task == t then task = nil end
    on_exit(code, stderr)
  end, { "-q", "--buffer", "4096", "-d", "-r", "16000", "-c", "1", "-b", "16", wav_path })
  if not t or not t:start() then
    return false, "could not start sox"
  end
  task = t
  return true
end

-- SIGINT makes SoX stop reading the device and finalize the WAV header.
function M.stop()
  if M.is_recording() then task:interrupt() end
end

function M.cancel(wav_path)
  if M.is_recording() then
    local t = task
    task = nil
    t:terminate()
  end
  M.delete(wav_path)
end

return M
