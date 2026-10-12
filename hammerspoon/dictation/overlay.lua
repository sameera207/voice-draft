-- Floating on-screen panel shown while dictating: recording dot, elapsed
-- time, a scrolling level meter and the live (approximate) transcript.

local M = {}

local W, H = 560, 118
local PAD = 18
local BARS = 28
local BAR_W, BAR_GAP, BAR_MAX = 3, 3, 20
local MAX_CHARS = 190 -- about three lines at this width

local IDX_BG, IDX_DOT, IDX_TITLE, IDX_TEXT, IDX_BAR0 = 1, 2, 3, 4, 5

local canvas = nil
local levels = {}

local COLORS = {
  bg = { red = 0.08, green = 0.08, blue = 0.09, alpha = 0.86 },
  rec = { red = 1, green = 0.23, blue = 0.19, alpha = 1 },
  work = { red = 1, green = 0.74, blue = 0.18, alpha = 1 },
  title = { white = 1, alpha = 0.95 },
  text = { white = 1, alpha = 0.92 },
  dim = { white = 1, alpha = 0.5 },
  bar = { red = 1, green = 0.36, blue = 0.32, alpha = 0.9 },
}

local function frame_on_screen()
  local screen = hs.screen.mainScreen() -- screen with the focused window
  local f = screen:frame()
  return { x = f.x + (f.w - W) / 2, y = f.y + f.h - H - 70, w = W, h = H }
end

local function bar_frame(i, level)
  local h = math.max(2, level * BAR_MAX)
  local x0 = W - PAD - BARS * (BAR_W + BAR_GAP) + BAR_GAP
  return { x = x0 + (i - 1) * (BAR_W + BAR_GAP), y = 24 - h / 2, w = BAR_W, h = h }
end

local function build()
  canvas = hs.canvas.new(frame_on_screen())
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas[IDX_BG] = {
    type = "rectangle", action = "fill", fillColor = COLORS.bg,
    roundedRectRadii = { xRadius = 14, yRadius = 14 },
  }
  canvas[IDX_DOT] = {
    type = "circle", action = "fill", fillColor = COLORS.rec,
    center = { x = PAD + 7, y = 24 }, radius = 6,
  }
  canvas[IDX_TITLE] = {
    type = "text", text = "", textSize = 14, textColor = COLORS.title,
    textFont = "Helvetica Neue Medium",
    frame = { x = PAD + 22, y = 14, w = 260, h = 22 },
  }
  canvas[IDX_TEXT] = {
    type = "text", text = "", textSize = 15, textColor = COLORS.text,
    textFont = "Helvetica Neue",
    frame = { x = PAD, y = 42, w = W - 2 * PAD, h = H - 50 },
  }
  for i = 1, BARS do
    levels[i] = 0
    canvas[IDX_BAR0 + i - 1] = {
      type = "rectangle", action = "fill", fillColor = COLORS.bar,
      roundedRectRadii = { xRadius = 1.5, yRadius = 1.5 },
      frame = bar_frame(i, 0),
    }
  end
end

local function set_bars_visible(visible)
  for i = 1, BARS do
    canvas[IDX_BAR0 + i - 1].fillColor = visible and COLORS.bar or { alpha = 0 }
  end
end

-- Trim to the last MAX_CHARS characters at a word boundary.
local function tail(text)
  if #text <= MAX_CHARS then return text end
  local cut = text:sub(-MAX_CHARS)
  cut = cut:gsub("^%S*%s+", "")
  return "…" .. cut
end

function M.show_recording()
  if not canvas then build() end
  canvas:frame(frame_on_screen())
  for i = 1, BARS do levels[i] = 0; canvas[IDX_BAR0 + i - 1].frame = bar_frame(i, 0) end
  canvas[IDX_DOT].fillColor = COLORS.rec
  canvas[IDX_TITLE].text = "Recording  0:00"
  canvas[IDX_TEXT].text = "Listening…"
  canvas[IDX_TEXT].textColor = COLORS.dim
  set_bars_visible(true)
  canvas:show(0.15)
end

-- Called ~10x a second while recording.
function M.tick(elapsed, level)
  if not canvas then return end
  local s = math.floor(elapsed)
  canvas[IDX_TITLE].text = string.format("Recording  %d:%02d", math.floor(s / 60), s % 60)
  if math.floor(elapsed * 2) % 2 == 0 then
    canvas[IDX_DOT].fillColor = COLORS.rec
  else
    canvas[IDX_DOT].fillColor = { red = 1, green = 0.23, blue = 0.19, alpha = 0.35 }
  end
  table.remove(levels, 1)
  levels[BARS] = level or 0
  for i = 1, BARS do canvas[IDX_BAR0 + i - 1].frame = bar_frame(i, levels[i]) end
end

function M.set_text(text)
  if not canvas then return end
  if text and text ~= "" then
    canvas[IDX_TEXT].text = tail(text)
    canvas[IDX_TEXT].textColor = COLORS.text
  end
end

-- Working states after recording stops.
function M.show_status(label)
  if not canvas or not canvas:isShowing() then return end
  canvas[IDX_DOT].fillColor = COLORS.work
  canvas[IDX_TITLE].text = label
  canvas[IDX_TEXT].textColor = COLORS.dim
  set_bars_visible(false)
end

function M.hide()
  if canvas and canvas:isShowing() then canvas:hide(0.2) end
end

-- Render the panel to an hs.image (for checking the layout).
function M.image()
  return canvas and canvas:imageFromCanvas()
end

function M.teardown()
  if canvas then canvas:delete(); canvas = nil end
end

return M
