-- Plain-Lua tests for the Whisper model catalog.
-- Run from the repo root:  lua tests/models_spec.lua

package.path = "./hammerspoon/?.lua;./hammerspoon/?/init.lua;" .. package.path
local models = require("dictation.models")

local passed, failed = 0, 0
local function check(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL %s\n  got:  %q\n  want: %q", name, tostring(got), tostring(want)))
  end
end

-- The real catalog shipped in the repo
local f = assert(io.open("whisper-models.tsv"))
local catalog = models.parse_catalog(f:read("*a"))
f:close()
check("catalog: has entries", #catalog >= 5, true)
check("catalog: default first", catalog[1].file, "ggml-large-v3-turbo.bin")
for _, c in ipairs(catalog) do
  check("catalog: valid file " .. c.file, models.valid_file(c.file), true)
  check("catalog: sha256 length " .. c.file, #c.sha256, 64)
  check("catalog: size " .. c.file, c.bytes > 10 * 1024 * 1024, true)
  check("catalog: label " .. c.file, c.label ~= "", true)
end
local by = {}
for _, c in ipairs(catalog) do by[c.file] = c end
check("catalog: english-only flag", by["ggml-small.en.bin"].english_only, true)
check("catalog: multilingual flag", by["ggml-small.bin"].english_only, false)

-- Parsing edge cases
local parsed = models.parse_catalog("# comment\n\nggml-x.bin\t100\tabc123\tx\tnote here\nbad line\n")
check("parse: skips comments and bad lines", #parsed, 1)
check("parse: note", parsed[1].note, "note here")

-- File name safety
check("valid_file: plain", models.valid_file("ggml-base.en.bin"), true)
check("valid_file: traversal", models.valid_file("ggml-../../etc.bin"), false)
check("valid_file: slash", models.valid_file("ggml-a/b.bin"), false)
check("valid_file: wrong prefix", models.valid_file("model.bin"), false)
check("valid_file: not a string", models.valid_file(nil), false)

-- Merge with disk
local dir = "/m"
local entries = models.entries(catalog, dir,
  { ["ggml-large-v3-turbo.bin"] = 1, ["ggml-custom.bin"] = 2 }, "/m/ggml-large-v3-turbo.bin")
check("entries: catalog then extras", #entries, #catalog + 1)
check("entries: installed", entries[1].installed, true)
check("entries: selected", entries[1].selected, true)
check("entries: not installed", entries[2].installed, false)
check("entries: extra at end", entries[#entries].file, "ggml-custom.bin")
check("entries: extra label", entries[#entries].label, "custom")
check("entries: extra not in catalog", entries[#entries].in_catalog, false)
check("entries: path", entries[2].path, "/m/" .. catalog[2].file)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
