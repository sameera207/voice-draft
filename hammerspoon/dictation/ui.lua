-- Menu bar item, on-screen alerts and optional sounds.

local M = {}

local ICONS = { IDLE = "🎙", RECORDING = "🔴", WORKING = "⏳" }
local LABELS = {
  IDLE = "Idle", RECORDING = "Recording…", TRANSCRIBING = "Transcribing…",
  CLEANING = "Cleaning up…", INSERTING = "Inserting…",
}

local cfg, bar, menu_fn = nil, nil, nil

function M.setup(config, menu)
  cfg, menu_fn = config, menu
  if cfg.ui.menubar then
    if bar then bar:delete() end
    bar = hs.menubar.new()
    if bar then bar:setMenu(function() return menu_fn() end) end
  end
  M.set_state("IDLE")
end

function M.teardown()
  if bar then bar:delete(); bar = nil end
end

function M.set_state(state)
  if not bar then return end
  local icon = ICONS[state] or ICONS.WORKING
  bar:setTitle(icon)
  bar:setTooltip("voice-draft: " .. (LABELS[state] or state))
end

function M.label(state)
  return LABELS[state] or state
end

function M.alert(msg, seconds)
  if cfg and not cfg.ui.alerts then
    print("[dictation] " .. msg)
    return
  end
  hs.alert.closeAll()
  hs.alert.show(msg, seconds or 1.5)
end

local SOUNDS = { start = "Tink", stop = "Pop" }

function M.sound(kind)
  if not (cfg and cfg.ui.sounds) then return end
  local s = hs.sound.getByName(SOUNDS[kind] or kind)
  if s then s:play() end
end

return M
