-- Whisper model catalog (whisper-models.tsv at the install root) merged with
-- the model files on disk. Pure Lua so it can be unit tested.

local M = {}

-- Parse the TSV catalog: file, bytes, sha256, label, note.
function M.parse_catalog(text)
  local list = {}
  for line in (text or ""):gmatch("[^\n]+") do
    if not line:find("^%s*#") and line:find("%S") then
      local file, bytes, sha, label, note = line:match("^([^\t]+)\t(%d+)\t(%x+)\t([^\t]+)\t?([^\t]*)$")
      if file then
        list[#list + 1] = {
          file = file, bytes = tonumber(bytes), sha256 = sha, label = label, note = note,
          english_only = file:find("%.en%.bin$") ~= nil,
        }
      end
    end
  end
  return list
end

-- Is this a model file name we manage (and safe to join to the models dir)?
function M.valid_file(name)
  return type(name) == "string" and name:find("^ggml%-[%w%._%-]+%.bin$") ~= nil and not name:find("%.%.")
end

-- Merge the catalog with files on disk.
--   on_disk: { [file] = bytes }  current: full path of the selected model
-- Returns entries in catalog order, then any extra files on disk:
--   { file, path, label, note, bytes, installed, selected, in_catalog, english_only }
function M.entries(catalog, dir, on_disk, current)
  local out, seen = {}, {}
  for _, c in ipairs(catalog) do
    local path = dir .. "/" .. c.file
    out[#out + 1] = {
      file = c.file, path = path, label = c.label, note = c.note, bytes = c.bytes,
      installed = on_disk[c.file] ~= nil, selected = path == current,
      in_catalog = true, english_only = c.english_only,
    }
    seen[c.file] = true
  end
  local extras = {}
  for file, bytes in pairs(on_disk) do
    if not seen[file] then extras[#extras + 1] = file end
  end
  table.sort(extras)
  for _, file in ipairs(extras) do
    local path = dir .. "/" .. file
    out[#out + 1] = {
      file = file, path = path, label = file:match("^ggml%-(.+)%.bin$") or file,
      note = "Added by hand.", bytes = on_disk[file], installed = true,
      selected = path == current, in_catalog = false,
      english_only = file:find("%.en%.bin$") ~= nil,
    }
  end
  return out
end

return M
