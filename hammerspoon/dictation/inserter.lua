-- Paste text into the focused app via the clipboard, then restore it.
-- Never sends Return.

local M = {}

local TEXT_UTI = "public.utf8-plain-text"
-- nspasteboard.org convention: clipboard managers skip transient items.
local TRANSIENT_UTI = "org.nspasteboard.TransientType"

-- Held at module level: Hammerspoon may garbage-collect unreferenced timers.
local restore_timer = nil

local function same_app(a, b)
  return a and b and a:pid() == b:pid()
end

-- result passed to done(): "pasted" | "clipboard" (focus changed)
function M.insert(text, target_app, cfg, done)
  local front = hs.application.frontmostApplication()
  if cfg.insert.require_same_app and target_app and not same_app(front, target_app) then
    hs.pasteboard.setContents(text)
    return done("clipboard")
  end

  local saved = hs.pasteboard.readAllData() or {}
  local ok = pcall(hs.pasteboard.writeAllData, { [TEXT_UTI] = text, [TRANSIENT_UTI] = "" })
  if not ok or hs.pasteboard.getContents() ~= text then
    hs.pasteboard.setContents(text)
  end
  local count = hs.pasteboard.changeCount()

  hs.eventtap.keyStroke({ "cmd" }, "v", 0)

  restore_timer = hs.timer.doAfter((cfg.insert.restore_clipboard_after_ms or 300) / 1000, function()
    restore_timer = nil
    -- Only restore if nothing else touched the clipboard meanwhile.
    if hs.pasteboard.changeCount() == count then
      if next(saved) then
        if not pcall(hs.pasteboard.writeAllData, saved) then
          hs.pasteboard.clearContents()
        end
      else
        hs.pasteboard.clearContents()
      end
    end
    done("pasted")
  end)
end

return M
