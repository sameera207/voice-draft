-- Plain-Lua tests for stage 1 cleanup and LLM output validation.
-- Run from the repo root:  lua tests/cleanup_spec.lua   (or luajit)

package.path = "./hammerspoon/?.lua;./hammerspoon/?/init.lua;" .. package.path
local cleanup = require("dictation.cleanup")
local config = require("dictation.config")

local passed, failed = 0, 0

local function check(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print(string.format("FAIL %s\n  got:  %q\n  want: %q", name, tostring(got), tostring(want)))
  end
end

---------------------------------------------------------------------------
-- Stage 1
---------------------------------------------------------------------------

local stage1_cases = {
  -- Cases from the spec
  { "um so I think uh we should go", "So I think we should go" },
  { "the the build is broken", "The build is broken" },
  { "[BLANK_AUDIO]", "" },
  { "run git worktree add, um, dash b feature", "Run git worktree add, dash b feature" },
  { "You know, that works", "That works" },
  { "I know you know the answer", "I know you know the answer" },

  -- Fillers
  { "Um, so we need a fix.", "So we need a fix." },
  { "It broke uh. Then we fixed it", "It broke. Then we fixed it" },
  { "hmm let me think, erm, about it", "Let me think, about it" },
  { "like so I was saying", "Like so I was saying" },
  { "Umm, okay", "Okay" },

  -- you know / I mean
  { "it's, you know, fine", "It's fine" },
  { "That is good, you know.", "That is good." },
  { "I mean, it works. I mean, mostly.", "It works. Mostly." },
  { "I mean it", "I mean it" },
  { "do you know the way", "Do you know the way" },

  -- Repeats
  { "I I think so", "I think so" },
  { "I want to I want to go home", "I want to go home" },
  { "we should, we should ship it", "We should ship it" },
  { "I had had enough", "I had had enough" },
  { "no, no, no", "No, no, no" },

  -- Artifacts
  { "(music) hello there", "Hello there" },
  { "[Music] hello [BLANK_AUDIO] there", "Hello there" },
  { "call foo(bar) now", "Call foo(bar) now" },
  { "index arr[0] please", "Index arr[0] please" },
  { "the function (which is slow) runs", "The function (which is slow) runs" },

  -- Whitespace and punctuation
  { "hello , world  .", "Hello, world." },
  { "first line\nsecond line", "First line second line" },
  { "para one\n\num para two", "Para one\n\nPara two" },

  -- Code is never touched
  { "`um um` is a string", "`um um` is a string" },
  { "set --force --force flag", "Set --force --force flag" },
  { "open src/um/uh.lua now", "Open src/um/uh.lua now" },
  { "use 1 1 twice", "Use 1 1 twice" },
  { "myVar is set", "myVar is set" },
  { "`npm test` passes", "`npm test` passes" },

  -- Empty
  { "", "" },
  { "  um  uh  ", "" },
}

for i, c in ipairs(stage1_cases) do
  check("stage1 #" .. i .. " " .. string.format("%q", c[1]), cleanup.stage1(c[1]), c[2])
end

---------------------------------------------------------------------------
-- Validation
---------------------------------------------------------------------------

local src = "I want to speak my thoughts and have them converted and put into Claude Code today."

local function valid(out, s)
  local ok, res = cleanup.validate(out, s or src)
  return ok and res or ("REJECT:" .. tostring(res))
end

check("validate: accepts good output", valid(src), src)
check("validate: preamble 'Sure, here is'",
  valid("Sure, here is the cleaned text: " .. src):match("^REJECT") ~= nil, true)
check("validate: preamble 'Here is'",
  valid("Here is the cleaned text:\n" .. src):match("^REJECT") ~= nil, true)
check("validate: 10% length", valid("I want."):match("^REJECT") ~= nil, true)
check("validate: too long",
  valid(src .. " " .. src):match("^REJECT") ~= nil, true)
check("validate: empty", valid("   "):match("^REJECT") ~= nil, true)
check("validate: strips quotes", valid('"' .. src .. '"'), src)
check("validate: strips transcript tags", valid("<transcript>" .. src .. "</transcript>"), src)
check("validate: strips think block", valid("<think>hmm</think>\n" .. src), src)
check("validate: allows 'Sure' when speaker said it",
  valid("Sure, let's ship the release on Friday after tests pass.",
    "sure, let's ship the release on Friday after tests pass"),
  "Sure, let's ship the release on Friday after tests pass.")

---------------------------------------------------------------------------
-- Request building
---------------------------------------------------------------------------

local ocfg = { model = "qwen2.5:3b", keep_alive = "30m" }
local req = cleanup.build_request("hello world", ocfg, "SYS")
check("request: model", req.model, "qwen2.5:3b")
check("request: think omitted when nil", req.think, nil)
check("request: think false from defaults",
  cleanup.build_request("hi", config.defaults().cleanup.ollama, "S").think, false)
check("request: stream", req.stream, false)
check("request: temperature", req.options.temperature, 0)
check("request: num_predict min", req.options.num_predict, 256)
check("request: message count", #req.messages, 6)
check("request: last message wrapped", req.messages[6].content, "<transcript>hello world</transcript>")
local long = string.rep("word ", 400)
check("request: num_predict scales", cleanup.build_request(long, ocfg, "S").options.num_predict, 780)
check("system prompt vocab",
  cleanup.render_system_prompt("Known terms: {{vocabulary}}", { "MCP", "100%" }),
  "Known terms: MCP, 100%")

---------------------------------------------------------------------------
-- Whisper output filtering
---------------------------------------------------------------------------

local transcriber = require("dictation.transcriber")
check("whisper: blank audio", transcriber.clean_output(" [BLANK_AUDIO]\n"), "")
check("whisper: music tag", transcriber.clean_output(" (upbeat music)\n"), "")
check("whisper: 'Thank you.' on silence", transcriber.clean_output(" Thank you.\n"), "")
check("whisper: 'you'", transcriber.clean_output(" you\n"), "")
check("whisper: joins lines", transcriber.clean_output(" Hello there.\n And more.\n"), "Hello there.\nAnd more.")
check("whisper: real thanks kept", transcriber.clean_output(" Thank you for the review, it helped.\n"),
  "Thank you for the review, it helped.")
check("whisper: timestamps dropped",
  transcriber.clean_output("[00:00:00.000 --> 00:00:02.000]   Hello.\n"), "Hello.")

local args = transcriber.build_args(config.defaults(), "/tmp/x.wav")
check("whisper args: no timestamps", table.concat(args, " "):find("-nt -np", 1, true) ~= nil, true)
check("whisper args: prompt", args[#args - 0]:find("^Claude Code, ") ~= nil, true)

---------------------------------------------------------------------------
-- Config
---------------------------------------------------------------------------

check("loopback: localhost", cleanup.is_loopback_url("http://localhost:11434"), true)
check("loopback: 127.0.0.1", cleanup.is_loopback_url("http://127.0.0.1:11434"), true)
check("loopback: ::1", cleanup.is_loopback_url("http://[::1]:11434"), true)
check("loopback: remote", cleanup.is_loopback_url("http://192.168.1.5:11434"), false)
check("loopback: lookalike", cleanup.is_loopback_url("http://localhost.evil.com"), false)

local merged = config.merge(config.defaults(), {
  cleanup = { ollama = { model = "llama3.2:3b" } },
  vocabulary = { "Only" },
})
check("merge: nested override", merged.cleanup.ollama.model, "llama3.2:3b")
check("merge: sibling kept", merged.cleanup.ollama.keep_alive, "30m")
check("merge: arrays replaced", #merged.vocabulary, 1)
check("merge: untouched default", merged.cleanup.mode, "llm")

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
