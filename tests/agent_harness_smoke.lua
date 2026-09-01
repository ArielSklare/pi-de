package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local is_nvim = type(vim) == 'table' and vim.fn ~= nil
local temp_data = os.tmpname() .. '-agent-harness'

if is_nvim then
  local original_stdpath = vim.fn.stdpath
  vim.fn.stdpath = function(kind)
    if kind == 'data' then return temp_data end
    return original_stdpath(kind)
  end
else
  local function json_encode(value)
    return ('{"active_agent":"%s","agents":{"pi":{"enabled":%s},"cursor":{"enabled":%s},"codex":{"enabled":%s}}}')
      :format(
        value.active_agent,
        tostring(value.agents.pi.enabled),
        tostring(value.agents.cursor.enabled),
        tostring(value.agents.codex.enabled)
      )
  end

  local function json_decode(value)
    local result = { active_agent = value:match('"active_agent"%s*:%s*"([^"]+)"'), agents = {} }
    for _, name in ipairs { 'pi', 'cursor', 'codex' } do
      local enabled = value:match('"' .. name .. '"%s*:%s*{%s*"enabled"%s*:%s*(%a+)')
      result.agents[name] = { enabled = enabled == 'true' }
    end
    return result
  end

  local function fs_open(path, flags, mode)
    local file = io.open(path, flags == 'r' and 'rb' or 'wb')
    if file and flags ~= 'r' then os.execute(('chmod %o %q'):format(mode, path)) end
    return file
  end

  os.execute(('mkdir -p %q'):format(temp_data))
  vim = {
    fn = {
      stdpath = function(kind)
        assert(kind == 'data')
        return temp_data
      end,
      executable = function(command)
        return command == 'present-agent' and 1 or 0
      end,
    },
    json = { encode = json_encode, decode = json_decode },
    log = { levels = { ERROR = 'ERROR', WARN = 'WARN' } },
    notify = function() end,
    uv = {
      fs_open = fs_open,
      fs_fstat = function(file)
        local current = file:seek()
        local size = file:seek('end')
        file:seek('set', current)
        return { size = size }
      end,
      fs_read = function(file, size, offset)
        file:seek('set', offset)
        return file:read(size)
      end,
      fs_write = function(file, value, offset)
        file:seek('set', offset)
        local ok = file:write(value)
        file:flush()
        return ok and #value or nil
      end,
      fs_close = function(file) file:close() end,
      fs_chmod = function(path, mode)
        local result = os.execute(('chmod %o %q'):format(mode, path))
        return result == true or result == 0
      end,
    },
  }
end

if is_nvim then vim.fn.mkdir(temp_data, 'p') end

local function assert_equal(actual, expected, message)
  if actual ~= expected then
    error(('%s: expected %s, got %s'):format(message, tostring(expected), tostring(actual)), 2)
  end
end

local config = require 'custom.agents.config'
local registry = require 'custom.agents.registry'
local events = require 'custom.agents.events'

assert_equal(config.active(), 'pi', 'the default active agent')
local default_config = config.load()
assert_equal(default_config.agents.pi.enabled, true, 'Pi is enabled by default')
assert_equal(default_config.agents.cursor.enabled, true, 'Cursor is enabled by default')
assert_equal(default_config.agents.codex.enabled, true, 'Codex is enabled by default')

local providers = registry.all()
assert_equal(providers.pi.command[1], 'pi', 'Pi executable')
assert_equal(providers.pi.protocol, 'rpc', 'Pi protocol')
assert_equal(providers.cursor.command[1], 'cursor-agent', 'Cursor executable')
assert_equal(providers.cursor.protocol, 'stream-json', 'Cursor protocol')
assert_equal(providers.cursor.fallback_protocol, 'terminal', 'Cursor terminal fallback protocol')
assert_equal(providers.codex.command[1], 'codex', 'Codex executable')
assert_equal(providers.codex.protocol, 'exec-json', 'Codex active protocol')
assert_equal(providers.codex.preferred_protocol, 'app-server', 'Codex future preferred protocol')
assert_equal(providers.codex.fallback_protocol, 'exec-json', 'Codex fallback protocol')
assert_equal(providers.codex.sandbox, 'read-only', 'Codex safe sandbox default')
assert_equal(providers.codex.approval_policy, 'on-request', 'Codex approval default')
assert_equal(#providers.pi.terminal_args, 0, 'Pi terminal args')
assert_equal(#providers.cursor.terminal_args, 0, 'Cursor terminal args')
assert_equal(#providers.codex.terminal_args, 0, 'Codex terminal args')
assert_equal(registry.get('missing'), nil, 'unknown provider lookup')

local original_executable = vim.fn.executable
vim.fn.executable = function() return 0 end
local available, reason = registry.available 'pi'
assert_equal(available, false, 'missing executable availability')
assert(type(reason) == 'string' and reason:find('pi', 1, true), 'missing executable reason must name pi')
assert(reason:find('install', 1, true), 'missing executable reason must suggest installation')
vim.fn.executable = function(command) return command == 'pi' and 1 or 0 end
available, reason = registry.available 'pi'
vim.fn.executable = original_executable
assert_equal(available, true, 'present executable availability')
assert_equal(reason, nil, 'present executable reason')

local kinds = {
  'started',
  'text_delta',
  'tool_started',
  'tool_output',
  'approval_required',
  'completed',
  'error',
}
for _, kind in ipairs(kinds) do
  local payload = { provider = 'test' }
  local event = events.new(kind, payload)
  assert_equal(event.kind, kind, kind .. ' event kind')
  assert_equal(event.payload, payload, kind .. ' event payload')
end

local ok = pcall(events.new, 'unknown_event', {})
assert_equal(ok, false, 'unknown event kinds are rejected')

local function decode_codex_json(value)
  local event_type = assert(value:match '"type":"([^"]+)"', 'missing Codex fixture event type')
  local result = {
    type = event_type,
    thread_id = value:match '"thread_id":"([^"]+)"',
    turn_id = value:match '"turn_id":"([^"]+)"',
    id = value:match '^.-"id":"([^"]+)"',
    command = value:match '^.-"command":"([^"]+)"',
  }
  local item_type = value:match '"item":.-"type":"([^"]+)"'
  if item_type then
    result.item = {
      id = value:match '"item":.-"id":"([^"]+)"',
      type = item_type,
      command = value:match '"item":.-"command":"([^"]+)"',
      delta = value:match '"delta":"([^"]*)"',
      text = value:match '"text":"([^"]*)"',
      aggregated_output = value:match '"aggregated_output":"([^"]*)"',
    }
    if result.item.aggregated_output then
      result.item.aggregated_output = result.item.aggregated_output:gsub('\\n', '\n')
    end
  end
  local error_message = value:match '"error":.-"message":"([^"]+)"'
  if error_message then result.error = { message = error_message } end
  return result
end

local codex_fixture_lines = {}
for line in assert(io.lines 'tests/fixtures/codex-events.jsonl') do
  table.insert(codex_fixture_lines, line)
end
assert_equal(#codex_fixture_lines, 9, 'Codex fixture event count')

local codex_command_calls = {}
local function codex_command_runner(args)
  table.insert(codex_command_calls, table.concat(args, ' '))
  if args[2] == 'login' then return { code = 0, stdout = 'Logged in' } end
  if args[2] == 'app-server' then return { code = 0, stdout = 'Usage: codex app-server' } end
  return { code = 1, stderr = 'unexpected command' }
end

local codex_pipes = {}
local codex_spawn
local fake_codex_uv = {}
function fake_codex_uv.new_pipe()
  local pipe = { writes = {}, closing = false }
  function pipe:is_closing() return self.closing end
  function pipe:close() self.closing = true end
  function pipe:write(value, callback)
    table.insert(self.writes, value)
    if callback then callback(nil) end
  end
  table.insert(codex_pipes, pipe)
  return pipe
end
function fake_codex_uv.cwd() return '/workspace' end
function fake_codex_uv.read_start(pipe, callback) pipe.reader = callback end
function fake_codex_uv.spawn(executable, options, on_exit)
  codex_spawn = { executable = executable, options = options, on_exit = on_exit }
  local process = { closing = false }
  function process:is_closing() return self.closing end
  function process:close() self.closing = true end
  function process:kill() self.closing = true; on_exit(0) end
  return process
end

local CodexAdapter = require 'custom.agents.adapters.codex'
local codex_events = {}
local codex_adapter = CodexAdapter.new {
  provider = providers.codex,
  uv = fake_codex_uv,
  command_runner = codex_command_runner,
  json_decode = decode_codex_json,
  schedule = function(callback) callback() end,
  notify = function() end,
  levels = { ERROR = 'ERROR', WARN = 'WARN' },
}
local expected_codex_kinds = {
  'started', 'started', 'text_delta', 'text_delta', 'tool_started',
  'tool_output', 'approval_required', 'completed', 'error',
}
for index, line in ipairs(codex_fixture_lines) do
  local normalized = codex_adapter:parse_event(decode_codex_json(line))
  assert(normalized, 'Codex fixture event ' .. index .. ' is normalized')
  assert_equal(normalized.kind, expected_codex_kinds[index], 'Codex fixture event kind ' .. index)
end
assert_equal(codex_adapter:parse_event { type = 'unknown' }, nil, 'unknown Codex events are ignored')

local codex_started, codex_start_error = codex_adapter:start()
assert_equal(codex_started, true, 'authenticated Codex starts')
assert_equal(codex_start_error, nil, 'authenticated Codex start reason')
assert_equal(codex_command_calls[1], 'codex login status', 'Codex auth is checked once before startup')
assert_equal(codex_command_calls[2], nil, 'Codex does not probe an inactive app-server transport')
local codex_capabilities = codex_adapter:capabilities()
assert_equal(codex_capabilities.protocol, 'exec-json', 'Codex reports the active exec JSON transport')
assert_equal(codex_capabilities.preferred_protocol, 'app-server', 'Codex retains app-server as the future preferred transport')
assert_equal(codex_capabilities.fallback_protocol, 'exec-json', 'Codex retains exec JSON fallback')
assert_equal(codex_capabilities.sandbox, 'read-only', 'Codex capability exposes sandbox')
assert_equal(codex_capabilities.approval_policy, 'on-request', 'Codex capability exposes approval policy')

codex_adapter:prompt('hello Codex', function(event) table.insert(codex_events, event) end)
assert_equal(codex_spawn.executable, 'codex', 'Codex exec executable')
assert_equal(
  table.concat(codex_spawn.options.args, ' '),
  'exec --json --sandbox read-only -c approval_policy="on-request" -',
  'Codex exec fallback keeps safe noninteractive arguments'
)
assert_equal(codex_pipes[1].writes[1], 'hello Codex', 'Codex prompt is written without shell interpolation')
codex_pipes[2].reader(nil, codex_fixture_lines[1] .. '\n' .. codex_fixture_lines[3] .. '\n')
assert_equal(codex_events[1].kind, 'started', 'Codex JSONL stream emits normalized lifecycle events')
assert_equal(codex_events[2].payload.text, 'Hello ', 'Codex JSONL stream emits normalized text')
codex_pipes[2].reader(nil, codex_fixture_lines[8])
codex_spawn.on_exit(0)
assert_equal(#codex_events, 2, 'process exit waits for stdout EOF before finalizing JSONL')
codex_pipes[3].reader(nil, nil)
assert_equal(#codex_events, 2, 'stderr EOF alone does not discard buffered stdout')
codex_pipes[2].reader(nil, nil)
assert_equal(codex_events[3].kind, 'completed', 'stdout EOF flushes a final unterminated JSONL event')
assert_equal(codex_adapter.callback, nil, 'Codex clears the callback after process exit and stream EOF')

local runtime_events = {}
local runtime_notifications = {}
local runtime_adapter = CodexAdapter.new {
  provider = providers.codex,
  uv = fake_codex_uv,
  command_runner = function() return { code = 0 } end,
  json_decode = decode_codex_json,
  schedule = function(callback) callback() end,
  notify = function(message) table.insert(runtime_notifications, message) end,
  levels = { ERROR = 'ERROR', WARN = 'WARN' },
}
runtime_adapter:prompt('fail once', function(event) table.insert(runtime_events, event) end)
local runtime_spawn = codex_spawn
local runtime_stdout, runtime_stderr = codex_pipes[5], codex_pipes[6]
runtime_spawn.on_exit(17)
runtime_stderr.reader(nil, 'provider unavailable')
runtime_stderr.reader(nil, nil)
assert_equal(#runtime_events, 0, 'nonzero exit waits for stdout EOF before reporting failure')
runtime_stdout.reader(nil, nil)
assert_equal(#runtime_events, 1, 'nonzero Codex exit emits one callback event')
assert_equal(runtime_events[1].kind, 'error', 'nonzero Codex exit emits a normalized error')
assert_equal(runtime_events[1].payload.message, 'provider unavailable', 'nonzero Codex exit preserves stderr')
assert_equal(#runtime_notifications, 0, 'runtime failures are callback-owned rather than adapter notifications')

local streamed_error_events = {}
local streamed_error_adapter = CodexAdapter.new {
  provider = providers.codex,
  uv = fake_codex_uv,
  command_runner = function() return { code = 0 } end,
  json_decode = decode_codex_json,
  schedule = function(callback) callback() end,
  notify = function() end,
  levels = { ERROR = 'ERROR', WARN = 'WARN' },
}
streamed_error_adapter:prompt('streamed failure', function(event) table.insert(streamed_error_events, event) end)
local streamed_error_spawn = codex_spawn
local streamed_error_stdout, streamed_error_stderr = codex_pipes[8], codex_pipes[9]
streamed_error_stdout.reader(nil, codex_fixture_lines[9] .. '\n')
streamed_error_spawn.on_exit(1)
streamed_error_stderr.reader(nil, 'duplicate process failure')
streamed_error_stderr.reader(nil, nil)
streamed_error_stdout.reader(nil, nil)
assert_equal(#streamed_error_events, 1, 'streamed and process-exit failures emit exactly one error')
assert_equal(streamed_error_events[1].kind, 'error', 'the streamed provider error is preserved')

local fallback_adapter = CodexAdapter.new {
  provider = providers.codex,
  uv = fake_codex_uv,
  command_runner = function(args)
    if args[2] == 'login' then return { code = 0 } end
    return { code = 2, stderr = 'unknown subcommand app-server' }
  end,
  json_decode = decode_codex_json,
  schedule = function(callback) callback() end,
  notify = function() end,
  levels = {},
}
assert_equal(fallback_adapter:start(), true, 'Codex starts when app-server is absent')
assert_equal(fallback_adapter:capabilities().protocol, 'exec-json', 'Codex falls back to exec JSON')

local auth_checks = 0
local auth_notifications = {}
local unauthenticated_adapter = CodexAdapter.new {
  provider = providers.codex,
  uv = fake_codex_uv,
  command_runner = function()
    auth_checks = auth_checks + 1
    return { code = 1, stderr = 'Not logged in' }
  end,
  json_decode = decode_codex_json,
  schedule = function(callback) callback() end,
  notify = function(message) table.insert(auth_notifications, message) end,
  levels = {},
}
local auth_started, auth_error = unauthenticated_adapter:start()
assert_equal(auth_started, false, 'unauthenticated Codex fails startup')
assert(auth_error:find('codex login', 1, true), 'unauthenticated Codex gives login remedy')
assert_equal(auth_checks, 1, 'unauthenticated Codex does not retry')
assert_equal(#auth_notifications, 0, 'authentication failure notification is manager-owned')

local function decode_cursor_json(value)
  local position = 1

  local function skip_space()
    local _, last = value:find('^[ \t\r\n]*', position)
    position = (last or position - 1) + 1
  end

  local parse_value
  local function parse_string()
    assert(value:sub(position, position) == '"', 'expected JSON string')
    position = position + 1
    local output = {}
    while position <= #value do
      local character = value:sub(position, position)
      position = position + 1
      if character == '"' then return table.concat(output) end
      if character == '\\' then
        local escaped = value:sub(position, position)
        position = position + 1
        local replacements = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        if escaped == 'u' then
          local code = assert(tonumber(value:sub(position, position + 3), 16), 'invalid JSON unicode escape')
          position = position + 4
          table.insert(output, code < 128 and string.char(code) or '?')
        else
          local replacement = replacements[escaped]
          assert(replacement, 'invalid JSON escape')
          table.insert(output, replacement)
        end
      else
        table.insert(output, character)
      end
    end
    error('unterminated JSON string')
  end

  local function parse_array()
    position = position + 1
    local result = {}
    skip_space()
    if value:sub(position, position) == ']' then position = position + 1; return result end
    while true do
      table.insert(result, parse_value())
      skip_space()
      local separator = value:sub(position, position)
      position = position + 1
      if separator == ']' then return result end
      assert(separator == ',', 'expected JSON array separator')
    end
  end

  local function parse_object()
    position = position + 1
    local result = {}
    skip_space()
    if value:sub(position, position) == '}' then position = position + 1; return result end
    while true do
      skip_space()
      local key = parse_string()
      skip_space()
      assert(value:sub(position, position) == ':', 'expected JSON object colon')
      position = position + 1
      result[key] = parse_value()
      skip_space()
      local separator = value:sub(position, position)
      position = position + 1
      if separator == '}' then return result end
      assert(separator == ',', 'expected JSON object separator')
    end
  end

  function parse_value()
    skip_space()
    local character = value:sub(position, position)
    if character == '"' then return parse_string() end
    if character == '{' then return parse_object() end
    if character == '[' then return parse_array() end
    local literal = value:sub(position)
    if literal:sub(1, 4) == 'true' then position = position + 4; return true end
    if literal:sub(1, 5) == 'false' then position = position + 5; return false end
    if literal:sub(1, 4) == 'null' then position = position + 4; return nil end
    local number = literal:match('^-?%d+%.?%d*[eE]?[+-]?%d*')
    assert(number and number ~= '', 'invalid JSON value')
    position = position + #number
    return tonumber(number)
  end

  local decoded = parse_value()
  skip_space()
  assert(position > #value, 'trailing JSON data')
  return decoded
end

local cursor_fixture_lines = {}
for line in assert(io.lines 'tests/fixtures/cursor-events.jsonl') do table.insert(cursor_fixture_lines, line) end
assert_equal(#cursor_fixture_lines, 6, 'Cursor fixture event count')

local cursor_command_calls = {}
local cursor_terminal_opens = 0
local function cursor_command_runner(args)
  table.insert(cursor_command_calls, table.concat(args, ' '))
  if args[2] == 'status' then return { code = 0, stdout = 'Logged in' } end
  if args[2] == '--help' then return { code = 0, stdout = '--output-format text | json | stream-json' } end
  return { code = 1, stderr = 'unexpected command' }
end

local cursor_pipes = {}
local cursor_spawn
local fake_cursor_uv = {}
function fake_cursor_uv.new_pipe()
  local pipe = { closing = false }
  function pipe:is_closing() return self.closing end
  function pipe:close() self.closing = true end
  table.insert(cursor_pipes, pipe)
  return pipe
end
function fake_cursor_uv.cwd() return '/workspace' end
function fake_cursor_uv.read_start(pipe, callback) pipe.reader = callback end
function fake_cursor_uv.spawn(executable, options, on_exit)
  cursor_spawn = { executable = executable, options = options, on_exit = on_exit }
  local process = { closing = false }
  function process:is_closing() return self.closing end
  function process:close() self.closing = true end
  function process:kill() self.closing = true; on_exit(0) end
  return process
end

local CursorAdapter = require 'custom.agents.adapters.cursor'
local cursor_events = {}
local cursor_adapter = CursorAdapter.new {
  provider = providers.cursor,
  uv = fake_cursor_uv,
  command_runner = cursor_command_runner,
  json_decode = decode_cursor_json,
  schedule = function(callback) callback() end,
  notify = function() end,
  open_terminal = function() cursor_terminal_opens = cursor_terminal_opens + 1; return true end,
  levels = { WARN = 'WARN' },
}
local normalized_cursor_fixtures = {}
local expected_cursor_kinds = { 'started', 'text_delta', 'tool_started', 'tool_output', 'completed', 'error' }
for index, line in ipairs(cursor_fixture_lines) do
  local normalized = cursor_adapter:parse_event(decode_cursor_json(line))
  assert(normalized, 'Cursor fixture event ' .. index .. ' is normalized')
  assert_equal(normalized.kind, expected_cursor_kinds[index], 'Cursor fixture event kind ' .. index)
  normalized_cursor_fixtures[index] = normalized
end
assert_equal(normalized_cursor_fixtures[1].payload.session_id, 'session-fixture', 'Cursor init session payload')
assert_equal(normalized_cursor_fixtures[1].payload.model, 'cursor-model', 'Cursor init model payload')
assert_equal(normalized_cursor_fixtures[2].payload.text, 'cursor fixture ready', 'Cursor text payload')
assert_equal(normalized_cursor_fixtures[3].payload.id, 'call-fixture', 'Cursor tool start id payload')
assert_equal(normalized_cursor_fixtures[3].payload.tool, 'read', 'Cursor tool start name payload')
assert_equal(normalized_cursor_fixtures[3].payload.item.args.path, '/tmp/cursor-fixture/input.txt', 'Cursor tool args retain wire shape')
assert_equal(normalized_cursor_fixtures[4].payload.tool, 'read', 'Cursor tool output name payload')
assert_equal(normalized_cursor_fixtures[4].payload.output, 'fixture-tool-content\n', 'Cursor tool output payload')
assert_equal(normalized_cursor_fixtures[5].payload.request_id, 'request-fixture', 'Cursor completion request payload')
assert_equal(normalized_cursor_fixtures[6].payload.message, 'Authentication required', 'Cursor auth error payload')
assert_equal(cursor_adapter:parse_event { type = 'thinking', subtype = 'delta' }, nil, 'Cursor thinking is ignored')

local cursor_started, cursor_start_error = cursor_adapter:start()
assert_equal(cursor_started, true, 'authenticated Cursor starts')
assert_equal(cursor_start_error, nil, 'authenticated Cursor start reason')
assert_equal(cursor_command_calls[1], 'cursor-agent status', 'Cursor auth is checked once before startup')
assert_equal(cursor_command_calls[2], 'cursor-agent --help', 'Cursor stream-json support is checked once')
local cursor_capabilities = cursor_adapter:capabilities()
assert_equal(cursor_capabilities.protocol, 'stream-json', 'Cursor reports stream-json protocol')
assert_equal(cursor_capabilities.fallback_protocol, 'terminal', 'Cursor reports terminal fallback')

cursor_adapter:prompt('--not-a-Cursor-option', function(event) table.insert(cursor_events, event) end)
assert_equal(cursor_spawn.executable, 'cursor-agent', 'Cursor executable')
assert_equal(
  table.concat(cursor_spawn.options.args, ' '),
  '--print --output-format stream-json --stream-partial-output --mode ask -- --not-a-Cursor-option',
  'Cursor separates prompt text from options without shell interpolation'
)
cursor_pipes[1].reader(nil, cursor_fixture_lines[1] .. '\n' .. cursor_fixture_lines[2] .. '\n')
assert_equal(cursor_events[1].kind, 'started', 'Cursor stream emits normalized lifecycle events')
assert_equal(cursor_events[2].payload.text, 'cursor fixture ready', 'Cursor stream emits normalized text')
cursor_spawn.on_exit(0)
cursor_pipes[2].reader(nil, nil)
cursor_pipes[1].reader(nil, cursor_fixture_lines[5])
cursor_pipes[1].reader(nil, nil)
assert_equal(cursor_events[3].kind, 'completed', 'Cursor flushes final unterminated JSONL event')
assert_equal(cursor_terminal_opens, 0, 'compatible stream-json does not open terminal fallback')

local cursor_auth_checks = 0
local cursor_unauthenticated = CursorAdapter.new {
  provider = providers.cursor,
  uv = fake_cursor_uv,
  command_runner = function()
    cursor_auth_checks = cursor_auth_checks + 1
    return { code = 1, stderr = 'Not logged in' }
  end,
  open_terminal = function() cursor_terminal_opens = cursor_terminal_opens + 1; return true end,
}
local cursor_auth_started, cursor_auth_error = cursor_unauthenticated:start()
assert_equal(cursor_auth_started, false, 'unauthenticated Cursor fails startup')
assert(cursor_auth_error:find('cursor%-agent login'), 'unauthenticated Cursor gives login remedy')
assert_equal(cursor_auth_checks, 1, 'unauthenticated Cursor does not retry or probe the protocol')
assert_equal(cursor_terminal_opens, 0, 'unauthenticated Cursor does not enter a fallback loop')

local cursor_status_failure = CursorAdapter.new {
  provider = providers.cursor,
  command_runner = function() return { code = 1, stderr = 'status command timed out' } end,
}
local status_started, status_error = cursor_status_failure:start()
assert_equal(status_started, false, 'failed Cursor status command fails startup')
assert(status_error:find('status command timed out', 1, true), 'failed Cursor status command preserves its actual error')
assert(not status_error:find('login', 1, true), 'failed Cursor status command is not labeled unauthenticated')

local fallback_opens = 0
local cursor_fallback = CursorAdapter.new {
  provider = providers.cursor,
  uv = fake_cursor_uv,
  command_runner = function(args)
    if args[2] == 'status' then return { code = 0 } end
    return { code = 0, stdout = '--output-format text | json' }
  end,
  open_terminal = function(name)
    assert_equal(name, 'cursor', 'Cursor fallback provider')
    fallback_opens = fallback_opens + 1
    return true
  end,
}
assert_equal(cursor_fallback:start(), true, 'Cursor falls back when stream-json is incompatible')
assert_equal(cursor_fallback:capabilities().protocol, 'terminal', 'Cursor fallback reports terminal protocol')
assert_equal(fallback_opens, 1, 'Cursor incompatible protocol opens ToggleTerm once')
cursor_fallback:prompt('not retried', function(event) table.insert(cursor_events, event) end)
assert_equal(fallback_opens, 1, 'Cursor prompt does not retry terminal fallback')
assert_equal(cursor_events[#cursor_events].kind, 'error', 'terminal fallback reports structured prompt unavailability')

local function run_cursor_exit(stdout_line, stderr, code)
  local pipes = {}
  local spawned
  local terminal_opens = 0
  local runtime_uv = {}
  function runtime_uv.new_pipe()
    local pipe = { closing = false }
    function pipe:is_closing() return self.closing end
    function pipe:close() self.closing = true end
    table.insert(pipes, pipe)
    return pipe
  end
  function runtime_uv.cwd() return '/workspace' end
  function runtime_uv.read_start(pipe, callback) pipe.reader = callback end
  function runtime_uv.spawn(_, _, on_exit)
    spawned = { on_exit = on_exit }
    local process = { closing = false }
    function process:is_closing() return self.closing end
    function process:close() self.closing = true end
    function process:kill() self.closing = true end
    return process
  end

  local adapter = CursorAdapter.new {
    provider = providers.cursor,
    uv = runtime_uv,
    command_runner = cursor_command_runner,
    json_decode = decode_cursor_json,
    schedule = function(callback) callback() end,
    notify = function() end,
    open_terminal = function() terminal_opens = terminal_opens + 1; return true end,
    levels = { WARN = 'WARN' },
  }
  local emitted = {}
  adapter:prompt('failure fixture', function(event) table.insert(emitted, event) end)
  if stdout_line then pipes[1].reader(nil, stdout_line .. '\n') end
  spawned.on_exit(code)
  pipes[2].reader(nil, stderr)
  pipes[2].reader(nil, nil)
  pipes[1].reader(nil, nil)
  return emitted, terminal_opens
end

local auth_exit_events, auth_exit_fallbacks = run_cursor_exit(cursor_fixture_lines[6], '', 1)
assert_equal(#auth_exit_events, 1, 'streamed Cursor auth failure emits one error')
assert_equal(auth_exit_events[1].kind, 'error', 'streamed Cursor auth failure event kind')
assert(auth_exit_events[1].payload.message:find('Authentication required', 1, true), 'streamed Cursor auth failure preserves provider error')
assert(auth_exit_events[1].payload.message:find('cursor%-agent login'), 'streamed Cursor auth failure includes login remedy')
assert_equal(auth_exit_fallbacks, 0, 'streamed Cursor auth failure does not open terminal fallback')

local rate_limit_line = '{"type":"result","subtype":"error","is_error":true,"result":"Rate limit exceeded","request_id":"request-rate"}'
local rate_exit_events, rate_exit_fallbacks = run_cursor_exit(rate_limit_line, '', 1)
assert_equal(#rate_exit_events, 1, 'streamed Cursor rate-limit failure emits one error')
assert_equal(rate_exit_events[1].payload.message, 'Rate limit exceeded', 'streamed Cursor rate-limit preserves provider error')
assert_equal(rate_exit_fallbacks, 0, 'streamed Cursor rate-limit does not open terminal fallback')

local process_exit_events, process_exit_fallbacks = run_cursor_exit(nil, 'Model is unavailable', 2)
assert_equal(#process_exit_events, 1, 'ordinary Cursor nonzero exit emits one error')
assert_equal(process_exit_events[1].payload.message, 'Model is unavailable', 'ordinary Cursor nonzero exit preserves stderr')
assert_equal(process_exit_fallbacks, 0, 'ordinary Cursor nonzero exit does not open terminal fallback')

local protocol_exit_events, protocol_exit_fallbacks = run_cursor_exit(nil, "error: unknown option '--stream-partial-output'", 2)
assert_equal(#protocol_exit_events, 1, 'Cursor protocol incompatibility emits one error')
assert(protocol_exit_events[1].payload.message:find("unknown option '--stream-partial-output'", 1, true), 'protocol incompatibility preserves stderr')
assert_equal(protocol_exit_fallbacks, 1, 'Cursor protocol incompatibility opens terminal fallback')

local spawn_fallbacks = 0
local spawn_failure_uv = {
  cwd = function() return '/workspace' end,
  new_pipe = function()
    return {
      is_closing = function() return false end,
      close = function() end,
    }
  end,
  spawn = function() return nil, 'spawn failed' end,
}
local spawn_failure_events = {}
local spawn_failure_adapter = CursorAdapter.new {
  provider = providers.cursor,
  uv = spawn_failure_uv,
  command_runner = cursor_command_runner,
  open_terminal = function() spawn_fallbacks = spawn_fallbacks + 1; return true end,
}
spawn_failure_adapter:prompt('spawn fixture', function(event) table.insert(spawn_failure_events, event) end)
assert_equal(spawn_fallbacks, 1, 'Cursor spawn failure opens terminal fallback')
assert_equal(spawn_failure_events[1].kind, 'error', 'Cursor spawn failure emits an error')
assert(spawn_failure_events[1].payload.message:find('spawn failed', 1, true), 'Cursor spawn failure preserves the spawn error')

assert_equal(config.set_active('cursor'), true, 'persisting a known active agent')
assert_equal(config.active(), 'cursor', 'persisted active agent')
local active_changed, active_error = config.set_active('missing')
assert_equal(active_changed, false, 'rejecting an unknown active agent')
assert(type(active_error) == 'string' and active_error:find('Unknown', 1, true), 'unknown active agent reason')
local config_with_secrets = config.load()
config_with_secrets.api_key = 'must-not-be-saved'
config_with_secrets.agents.pi.token = 'must-not-be-saved'
assert_equal(config.save(config_with_secrets), true, 'saving sanitized harness configuration')

assert_equal(config.save {
  active_agent = 'cursor',
  agents = {
    pi = { enabled = true },
    cursor = { enabled = false },
    codex = { enabled = true },
  },
}, true, 'saving a disabled requested active agent')
assert_equal(config.active(), 'pi', 'save falls back from a disabled requested active agent')

assert_equal(config.save {
  active_agent = 'cursor',
  agents = {
    pi = { enabled = false },
    cursor = { enabled = false },
    codex = { enabled = false },
  },
}, true, 'saving an all-disabled configuration')
local normalized_saved_all_disabled = config.load()
assert_equal(normalized_saved_all_disabled.active_agent, 'pi', 'all-disabled save selects Pi fallback')
assert(normalized_saved_all_disabled.agents.pi.enabled == true, 'all-disabled save enables Pi fallback')

local config_path = temp_data .. '/agent_harness.json'
local invalid_config = assert(io.open(config_path, 'wb'))
invalid_config:write '{"active_agent":"pi","agents":{"pi":{"enabled":false},"cursor":{"enabled":true},"codex":{"enabled":true}}}\n'
invalid_config:close()
local normalized_persisted_config = config.load()
assert_equal(normalized_persisted_config.active_agent, 'cursor', 'load falls back from a persisted disabled active agent')
assert_equal(normalized_persisted_config.agents.pi.enabled, false, 'load preserves normalized provider enablement')

invalid_config = assert(io.open(config_path, 'wb'))
invalid_config:write '{"active_agent":"codex","agents":{"pi":{"enabled":false},"cursor":{"enabled":false},"codex":{"enabled":false}}}\n'
invalid_config:close()
local normalized_persisted_all_disabled = config.load()
assert_equal(normalized_persisted_all_disabled.active_agent, 'pi', 'all-disabled persisted config selects Pi fallback')
assert(normalized_persisted_all_disabled.agents.pi.enabled == true, 'all-disabled persisted config enables Pi fallback')

assert_equal(config.save(config_with_secrets), true, 'restoring sanitized harness configuration')

local pi_home = temp_data .. '/home'
os.execute(('mkdir -p %q'):format(pi_home .. '/.pi/agent'))
local base_auth = assert(io.open(pi_home .. '/.pi/agent/auth.json', 'wb'))
base_auth:write '{"provider":"existing-login"}\n'
base_auth:close()
local original_api = vim.api
local original_env = vim.env
local original_schedule = vim.schedule
local original_expand = vim.fn.expand
local original_list_extend = vim.list_extend
vim.api = { nvim_create_user_command = function() end }
vim.env = {}
vim.schedule = function() end
vim.list_extend = function(target, values)
  for _, value in ipairs(values) do table.insert(target, value) end
  return target
end
vim.fn.expand = function(value) return value == '~' and pi_home or value end
package.loaded['custom.plugins.setup'] = nil
local pi_setup = require 'custom.plugins.setup'
assert_equal(pi_setup.has_base_auth(), true, 'setup reuses the existing Pi auth store')
assert_equal(table.concat(pi_setup.get_pi_command 'rpc', ' '), 'pi --mode rpc', 'base auth needs no credential arguments')
package.loaded['custom.plugins.setup'] = nil
vim.api = original_api
vim.env = original_env
vim.schedule = original_schedule
vim.list_extend = original_list_extend
vim.fn.expand = original_expand

local created_terminals = {}
package.preload['custom.plugins.setup'] = function()
  return { get_pi_command = function() return { 'pi', '--model', "model with space and 'quote'", '$(not-shell-code)' } end }
end
package.preload['toggleterm.terminal'] = function()
  local Terminal = {}
  function Terminal:new(options)
    local instance = { options = options, toggles = 0 }
    function instance:toggle() self.toggles = self.toggles + 1 end
    table.insert(created_terminals, instance)
    return instance
  end
  return { Terminal = Terminal }
end
local original_shellescape = vim.fn.shellescape
local shellescaped_values = {}
vim.fn.shellescape = function(value)
  table.insert(shellescaped_values, value)
  return '<' .. value .. '>'
end
package.loaded['custom.agents.terminal'] = nil
local terminal = require 'custom.agents.terminal'
local terminal_opened, terminal_error = terminal.open 'pi'
assert_equal(terminal_opened, true, 'opening the Pi terminal: ' .. tostring(terminal_error))
assert_equal(
  created_terminals[1].options.cmd,
  "<pi> <--model> <model with space and 'quote'> <$(not-shell-code)>",
  'Pi terminal command construction'
)
assert_equal(
  table.concat(shellescaped_values, '|'),
  "pi|--model|model with space and 'quote'|$(not-shell-code)",
  'every terminal argument is escaped independently'
)
assert_equal(created_terminals[1].options.display_name, 'Pi', 'Pi terminal display name')
assert_equal(terminal.open('cursor'), true, 'opening the Cursor terminal')
assert_equal(created_terminals[2].options.cmd, '<cursor-agent>', 'Cursor terminal command construction')
assert_equal(created_terminals[2].options.display_name, 'Cursor Agent', 'Cursor terminal display name')
assert_equal(terminal.open('codex'), true, 'opening the Codex terminal')
assert_equal(created_terminals[3].options.cmd, '<codex>', 'Codex terminal command construction')
assert_equal(created_terminals[3].options.display_name, 'Codex', 'Codex terminal display name')
assert_equal(terminal.open('pi'), true, 'reopening the Pi terminal')
assert_equal(#created_terminals, 3, 'one ToggleTerm instance per provider')
local opened, open_error = terminal.open 'missing'
assert_equal(opened, false, 'unknown terminal provider is rejected')
assert(type(open_error) == 'string' and open_error:find('Unknown', 1, true), 'unknown terminal provider reason')
assert_equal(config.set_active('cursor'), true, 'selecting Cursor for active terminal routing')
terminal.toggle_active()
assert_equal(created_terminals[2].toggles, 2, 'active terminal routes to Cursor')
assert_equal(config.set_active('pi'), true, 'restoring Pi after terminal routing')
vim.fn.shellescape = original_shellescape
package.loaded['custom.agents.terminal'] = nil
package.loaded['custom.agents.manager'] = nil
package.loaded['custom.plugins.setup'] = nil
package.loaded['toggleterm.terminal'] = nil
package.preload['custom.plugins.setup'] = nil
package.preload['toggleterm.terminal'] = nil

local command_calls = {}
local command_manager = {
  select = function(name) table.insert(command_calls, 'select:' .. name); return true end,
  start = function() table.insert(command_calls, 'start'); return true end,
  stop = function() table.insert(command_calls, 'stop'); return true end,
  toggle_terminal = function() table.insert(command_calls, 'toggle') end,
}
package.preload['custom.agents.manager'] = function() return command_manager end
local original_fs = vim.fs
local original_ui = vim.ui
local original_keymap = vim.keymap
local command_original_stdpath = vim.fn.stdpath
original_api = vim.api
local registered_commands = {}
vim.fs = {
  joinpath = function(...) return table.concat({ ... }, '/') end,
  dir = function() return function() return nil end end,
}
vim.api = { nvim_create_user_command = function(name, callback) registered_commands[name] = callback end }
vim.fn.stdpath = function() return '/tmp' end
vim.ui = {
  select = function(items, options, callback)
    assert_equal(table.concat(items, ','), 'pi,cursor,codex', 'agent selection options')
    assert_equal(options.format_item('cursor'), 'Cursor Agent', 'agent selection display name')
    callback('cursor')
  end,
}
package.loaded['custom.plugins.init'] = nil
require 'custom.plugins.init'
registered_commands.AgentSelect()
registered_commands.AgentStart()
registered_commands.AgentStop()
registered_commands.AgentToggle()
assert_equal(table.concat(command_calls, ','), 'select:cursor,start,stop,toggle', 'agent command routing')
package.loaded['custom.plugins.init'] = nil
package.loaded['custom.agents.manager'] = nil
package.preload['custom.agents.manager'] = nil
vim.fs = original_fs
vim.api = original_api
vim.fn.stdpath = command_original_stdpath
vim.ui = original_ui
vim.keymap = original_keymap

local plugin_terminal_calls = {}
package.preload['custom.agents.terminal'] = function()
  return {
    open = function(name) table.insert(plugin_terminal_calls, 'open:' .. name); return true end,
  }
end
package.preload['custom.agents.manager'] = function()
  return {
    toggle_terminal = function() table.insert(plugin_terminal_calls, 'toggle') end,
  }
end
local original_pack = vim.pack
local original_version = vim.version
local original_o = vim.o
original_keymap = vim.keymap
local configured_toggleterm
local terminal_keymaps = {}
vim.pack = { add = function() end }
vim.version = { range = function() return '*' end }
vim.o = { lines = 40, columns = 120, shell = '/bin/sh' }
vim.keymap = { set = function(_, lhs, callback) terminal_keymaps[lhs] = callback end }
package.preload.toggleterm = function()
  return { setup = function(options) configured_toggleterm = options end }
end
package.loaded['custom.plugins.toggleterm'] = nil
require 'custom.plugins.toggleterm'
assert(configured_toggleterm, 'ToggleTerm is configured')
terminal_keymaps['<leader>tp']()
terminal_keymaps['<leader>ta']()
assert_equal(table.concat(plugin_terminal_calls, ','), 'open:pi,toggle', 'agent terminal keymap routing')
package.loaded['custom.plugins.toggleterm'] = nil
package.loaded['custom.agents.terminal'] = nil
package.loaded['custom.agents.manager'] = nil
package.loaded.toggleterm = nil
package.preload['custom.agents.terminal'] = nil
package.preload['custom.agents.manager'] = nil
package.preload.toggleterm = nil
vim.pack = original_pack
vim.version = original_version
vim.o = original_o
vim.keymap = original_keymap

local function decode_json_string(value)
  local result = {}
  local index = 1
  while index <= #value do
    local character = value:sub(index, index)
    if character ~= '\\' then
      table.insert(result, character)
      index = index + 1
    else
      local escaped = value:sub(index + 1, index + 1)
      local replacements = { n = '\n', r = '\r', t = '\t', ['"'] = '"', ['\\'] = '\\' }
      assert(replacements[escaped], 'unsupported JSON escape in Pi fixture: ' .. escaped)
      table.insert(result, replacements[escaped])
      index = index + 2
    end
  end
  return table.concat(result)
end

local function decode_pi_json(value)
  if value == 'this is not json' then error 'invalid JSON' end

  local replacement = value:match '^%{"newText":"(.*)"%}$'
  if replacement then return { newText = decode_json_string(replacement) } end

  local kind = value:match '"type":"([^"]+)"'
  assert(kind, 'missing Pi fixture message type')
  local message = {
    type = kind,
    id = value:match '"id":"([^"]+)"',
    success = value:match '"success":true' ~= nil,
  }
  if value:match '"accepted":true' then message.data = { accepted = true } end
  local text = value:match '"text":"(.*)"}}$'
  if text then message.data = { text = decode_json_string(text) } end
  return message
end

local function encode_pi_json(value)
  local fields = {
    ('"id":"%s"'):format(value.id),
    ('"type":"%s"'):format(value.type),
  }
  if value.message then
    local escaped = value.message:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
    table.insert(fields, ('"message":"%s"'):format(escaped))
  end
  return '{' .. table.concat(fields, ',') .. '}'
end

local fixture_lines = {}
for line in assert(io.lines 'tests/fixtures/pi-events.jsonl') do
  table.insert(fixture_lines, line)
end
assert_equal(#fixture_lines, 5, 'Pi fixture event count')

local buffer = {
  lines = { 'local value = 1' },
  changedtick = 7,
  clears = 0,
  extmarks = {},
}
local fake_api = {}
function fake_api.nvim_create_namespace(name)
  assert_equal(name, 'pi_suggestions', 'Pi suggestion namespace')
  return 41
end
function fake_api.nvim_buf_is_valid(bufnr) return bufnr == 1 end
function fake_api.nvim_buf_get_lines(_, start_line, end_line)
  local result = {}
  for index = start_line + 1, end_line do table.insert(result, buffer.lines[index]) end
  return result
end
function fake_api.nvim_buf_set_lines(_, start_line, end_line, _, lines)
  local updated = {}
  for index = 1, start_line do table.insert(updated, buffer.lines[index]) end
  for _, line in ipairs(lines) do table.insert(updated, line) end
  for index = end_line + 1, #buffer.lines do table.insert(updated, buffer.lines[index]) end
  buffer.lines = updated
  buffer.changedtick = buffer.changedtick + 1
end
function fake_api.nvim_buf_clear_namespace(_, namespace)
  assert_equal(namespace, 41, 'cleared Pi suggestion namespace')
  buffer.clears = buffer.clears + 1
  buffer.extmarks = {}
end
function fake_api.nvim_buf_set_extmark(_, namespace, line, column, options)
  assert_equal(namespace, 41, 'Pi highlight namespace')
  table.insert(buffer.extmarks, { line = line, column = column, group = options.line_hl_group })
end
function fake_api.nvim_buf_get_changedtick() return buffer.changedtick end
function fake_api.nvim_buf_line_count() return #buffer.lines end
function fake_api.nvim_buf_get_name() return '/tmp/example.lua' end
function fake_api.nvim_get_current_buf() return 1 end

local pipes = {}
local fake_uv = {}
function fake_uv.new_pipe()
  local pipe = { writes = {}, closing = false }
  function pipe:is_closing() return self.closing end
  function pipe:close() self.closing = true end
  function pipe:write(value, callback)
    table.insert(self.writes, value)
    if callback then callback(nil) end
  end
  table.insert(pipes, pipe)
  return pipe
end
function fake_uv.cwd() return '/tmp' end
function fake_uv.read_start(pipe, callback) pipe.reader = callback end
function fake_uv.spawn(executable, options, on_exit)
  assert_equal(executable, 'pi', 'Pi RPC executable')
  assert_equal(options.args[1], '--mode', 'Pi RPC mode flag')
  assert_equal(options.args[2], 'rpc', 'Pi RPC mode')
  local process = { closing = false }
  function process:is_closing() return self.closing end
  function process:close() self.closing = true end
  function process:kill(signal)
    assert_equal(signal, 'sigterm', 'Pi stop signal')
    on_exit(0)
  end
  return process
end

local notifications = {}
local PiAdapter = require 'custom.agents.adapters.pi'
local pi_adapter = PiAdapter.new {
  api = fake_api,
  uv = fake_uv,
  setup = { get_pi_command = function() return { 'pi', '--mode', 'rpc' } end },
  json_decode = decode_pi_json,
  json_encode = encode_pi_json,
  schedule = function(callback) callback() end,
  notify = function(message, level) table.insert(notifications, { message = message, level = level }) end,
  levels = { ERROR = 'ERROR', WARN = 'WARN', INFO = 'INFO' },
  split = function(value)
    local result = {}
    for line in (value .. '\n'):gmatch '(.-)\n' do table.insert(result, line) end
    return result
  end,
  trim = function(value) return value:match '^%s*(.-)%s*$' end,
  get_filetype = function() return 'lua' end,
}

local capabilities = pi_adapter:capabilities()
assert_equal(capabilities.provider, 'pi', 'Pi adapter provider capability')
assert_equal(capabilities.prompt, true, 'Pi adapter prompt capability')
assert_equal(capabilities.suggestions, true, 'Pi adapter suggestion capability')

local prompt_data
pi_adapter:prompt('hello', function(data) prompt_data = data end)
local stdin = pipes[1]
local stdout = pipes[2]
assert(stdin.writes[1]:find('"id":"1"', 1, true), 'first Pi request keeps string ID 1')
assert(stdin.writes[1]:find('"type":"prompt"', 1, true), 'Pi prompt keeps JSONL RPC type')
stdout.reader(nil, fixture_lines[1]:gsub('"1"', '"99"', 1) .. '\n')
assert_equal(prompt_data, nil, 'unmatched Pi response is not correlated')
stdout.reader(nil, fixture_lines[1] .. '\n' .. fixture_lines[2] .. '\n')
assert_equal(prompt_data.accepted, true, 'matching Pi response is correlated')
assert(notifications[#notifications].message:find('Invalid Pi RPC response', 1, true) ~= nil, 'invalid Pi JSON warns')

local suggestion_result = false
pi_adapter:suggest_edits(1, 0, 1, function(result) suggestion_result = result end)
assert(stdin.writes[2]:find('"id":"2"', 1, true), 'suggestion prompt keeps sequential request ID')
stdout.reader(nil, fixture_lines[3] .. '\n')
stdout.reader(nil, fixture_lines[4] .. '\n')
assert(stdin.writes[3]:find('"id":"3"', 1, true), 'settled event requests last assistant text')
assert(stdin.writes[3]:find('"type":"get_last_assistant_text"', 1, true), 'settled event keeps Pi RPC command')
stdout.reader(nil, fixture_lines[5] .. '\n')
assert_equal(suggestion_result, true, 'valid JSON replacement is applied')
assert_equal(table.concat(buffer.lines, '\n'), 'local value = 2\nreturn value', 'replacement text decoding')
assert_equal(#buffer.extmarks, 2, 'every suggested replacement line is highlighted')
assert_equal(buffer.extmarks[1].group, 'PiSuggestion', 'Pi suggestion highlight group')
pi_adapter:discard_suggestions()
assert_equal(table.concat(buffer.lines, '\n'), 'local value = 1', 'discard restores original lines')
assert_equal(#buffer.extmarks, 0, 'discard clears suggestion highlights')

local changed_result = true
pi_adapter:suggest_edits(1, 0, 1, function(result) changed_result = result end)
stdout.reader(nil, '{"type":"response","id":"4","success":true,"data":{"accepted":true}}\n')
stdout.reader(nil, '{"type":"agent_settled"}\n')
buffer.changedtick = buffer.changedtick + 1
stdout.reader(nil, fixture_lines[5]:gsub('"3"', '"5"', 1) .. '\n')
assert_equal(changed_result, nil, 'changedtick rejects stale Pi suggestion')
assert_equal(table.concat(buffer.lines, '\n'), 'local value = 1', 'stale suggestion leaves buffer unchanged')
assert(notifications[#notifications].message:find('Buffer changed while Pi was working', 1, true), 'changedtick rejection warns')
pi_adapter:accept_suggestions()
pi_adapter:stop()

local successful_spawn = fake_uv.spawn
fake_uv.spawn = function() return nil, 'spawn failed' end
local failed_adapter = PiAdapter.new {
  api = fake_api,
  uv = fake_uv,
  setup = { get_pi_command = function() return { 'pi', '--mode', 'rpc' } end },
  json_decode = decode_pi_json,
  json_encode = encode_pi_json,
  schedule = function(callback) callback() end,
  notify = function() end,
  levels = { ERROR = 'ERROR' },
  split = function(value) return { value } end,
  trim = function(value) return value end,
  get_filetype = function() return 'lua' end,
}
local failed_start, failed_reason = failed_adapter:start()
assert_equal(failed_start, false, 'failed Pi spawn is reported')
assert_equal(failed_reason, 'spawn failed', 'failed Pi spawn reason is preserved')
for index = #pipes - 2, #pipes do
  assert(pipes[index].closing == true, 'failed Pi spawn closes allocated pipe ' .. index)
end
fake_uv.spawn = successful_spawn

package.loaded['custom.agents.adapters.pi'] = nil
package.loaded['custom.agents.adapters.cursor'] = nil
package.loaded['custom.agents.adapters.codex'] = nil

local adapter_calls = {}
local adapter_factories = { pi = 0, cursor = 0, codex = 0 }
local adapter_behavior = {}
local function fake_adapter(name)
  local adapter
  adapter = {
    start = function()
      table.insert(adapter_calls, name .. ':start')
      if adapter_behavior[name] and adapter_behavior[name].start then
        return adapter_behavior[name].start()
      end
      return true
    end,
    stop = function()
      table.insert(adapter_calls, name .. ':stop')
      if adapter_behavior[name] and adapter_behavior[name].stop then
        return adapter_behavior[name].stop()
      end
    end,
    prompt = function(_, text, callback)
      table.insert(adapter_calls, name .. ':prompt:' .. text)
      if adapter_behavior[name] and adapter_behavior[name].prompt then
        return adapter_behavior[name].prompt(text, callback)
      end
      if callback then callback(name .. ':reply') end
    end,
    request = function(_, command_type, params, callback)
      table.insert(adapter_calls, name .. ':request:' .. command_type .. ':' .. tostring(params.value))
      if callback then callback(name .. ':request-reply') end
    end,
    _apply_suggested_edit = function(_, bufnr, edit, callback)
      table.insert(adapter_calls, ('%s:apply:%d:%s'):format(name, bufnr, edit.newText))
      adapter.pending_suggestions = (adapter.pending_suggestions or 0) + 1
      if callback then callback(true) end
    end,
    suggest_edits = function(_, bufnr, start_line, end_line, callback)
      table.insert(adapter_calls, ('%s:suggest:%d:%d:%d'):format(name, bufnr, start_line, end_line))
      if callback then callback(true) end
    end,
    accept_suggestions = function()
      table.insert(adapter_calls, name .. ':accept:' .. tostring(adapter.pending_suggestions or 0))
      adapter.pending_suggestions = 0
    end,
    discard_suggestions = function()
      table.insert(adapter_calls, name .. ':discard:' .. tostring(adapter.pending_suggestions or 0))
      adapter.pending_suggestions = 0
    end,
    capabilities = function() return { provider = name, prompt = true } end,
  }
  return adapter
end

for _, name in ipairs { 'pi', 'cursor', 'codex' } do
  local provider_name = name
  package.preload['custom.agents.adapters.' .. provider_name] = function()
    return {
      new = function()
        adapter_factories[provider_name] = adapter_factories[provider_name] + 1
        return fake_adapter(provider_name)
      end,
    }
  end
end

local terminal_toggles = {}
local terminal_behavior = {}
package.preload['custom.agents.terminal'] = function()
  return {
    open = function(name)
      table.insert(terminal_toggles, name)
      if terminal_behavior.open then return terminal_behavior.open(name) end
      return true
    end,
  }
end

assert_equal(config.set_active('pi'), true, 'resetting active agent for manager tests')
vim.fn.executable = function(command)
  if command == 'pi' or command == 'cursor-agent' or command == 'codex' then return 1 end
  return 0
end
local manager = require 'custom.agents.manager'
assert_equal(manager.current(), 'pi', 'manager reads the persisted active agent')
local selected, select_error = manager.select 'missing'
assert_equal(selected, false, 'manager rejects an unknown provider')
assert(type(select_error) == 'string' and select_error:find('Unknown', 1, true), 'unknown provider selection reason')
assert_equal(manager.current(), 'pi', 'unknown selection does not change the active agent')

local initial_capabilities = manager.capabilities()
assert_equal(initial_capabilities.provider, 'pi', 'capabilities load the active adapter')
assert_equal(adapter_factories.pi, 1, 'capabilities cache the active adapter')
local started, start_error = manager.start()
assert_equal(started, true, 'manager starts the active adapter')
assert_equal(start_error, nil, 'successful manager start reason')
assert_equal(adapter_factories.pi, 1, 'start reuses the capabilities adapter')
selected, select_error = manager.select 'cursor'
assert_equal(selected, true, 'manager selects a known provider')
assert_equal(select_error, nil, 'successful provider selection reason')
assert_equal(config.active(), 'cursor', 'manager selection persists through config')
assert_equal(adapter_calls[1], 'pi:start', 'initial adapter start')
assert_equal(adapter_calls[2], 'pi:stop', 'switch stops the old adapter first')
assert_equal(adapter_calls[3], 'cursor:start', 'switch starts the new adapter second')

local capabilities = manager.capabilities()
assert_equal(capabilities.provider, 'cursor', 'capabilities delegate to the active adapter')
local prompt_reply
manager.prompt('hello', function(reply) prompt_reply = reply end)
assert_equal(adapter_calls[4], 'cursor:prompt:hello', 'prompt delegates to the active adapter')
assert_equal(prompt_reply, 'cursor:reply', 'prompt callback is preserved')
manager.toggle_terminal()
assert_equal(terminal_toggles[1], 'cursor', 'terminal toggle uses the active provider')
assert_equal(config.set_active('pi'), true, 'forcing persisted/runtime active-agent divergence')
assert_equal(manager.current(), 'cursor', 'persisted config cannot replace manager runtime authority')
manager.toggle_terminal()
assert_equal(terminal_toggles[2], 'cursor', 'terminal toggle uses manager.current during config divergence')
assert_equal(config.set_active('cursor'), true, 'restoring persisted active agent after divergence test')

local original_notify = vim.notify
local notifications = {}
vim.notify = function(message) table.insert(notifications, message) end
terminal_behavior.open = function() return false, 'terminal toggle failed' end
local toggled, toggle_reason = manager.toggle_terminal()
assert_equal(toggled, false, 'terminal failure propagates through manager')
assert_equal(toggle_reason, 'terminal toggle failed', 'terminal failure reason propagates through manager')
assert_equal(notifications[1], 'terminal toggle failed', 'terminal failure notifies through manager')

terminal_behavior.open = function() error 'terminal exploded' end
local toggle_ok
toggle_ok, toggled, toggle_reason = pcall(manager.toggle_terminal)
vim.notify = original_notify
terminal_behavior.open = nil
assert_equal(toggle_ok, true, 'terminal exceptions do not escape manager')
assert_equal(toggled, false, 'terminal exception is reported as failure')
assert(type(toggle_reason) == 'string' and toggle_reason:find('terminal exploded', 1, true), 'terminal exception reason propagates')
manager.stop()
assert_equal(adapter_calls[5], 'cursor:stop', 'stop delegates to the active adapter')

assert_equal(manager.select('codex'), true, 'manager persists another known provider while stopped')
notifications = {}
vim.notify = function(message) table.insert(notifications, message) end
vim.fn.executable = function() return 0 end
started, start_error = manager.start()
vim.notify = original_notify
vim.fn.executable = original_executable
assert_equal(started, false, 'manager rejects an unavailable provider')
assert(type(start_error) == 'string' and start_error:find('codex', 1, true), 'unavailable reason names executable')
assert(start_error:find('install', 1, true), 'unavailable reason suggests installation')
assert(start_error:find('login', 1, true), 'unavailable reason suggests authentication')
assert_equal(notifications[1], start_error, 'unavailable provider notifies without throwing')

assert_equal(manager.select('cursor'), true, 'manager selects Cursor while stopped')
notifications = {}
vim.notify = function(message) table.insert(notifications, message) end
vim.fn.executable = function() return 0 end
started, start_error = manager.start()
vim.notify = original_notify
vim.fn.executable = function(command)
  if command == 'pi' or command == 'cursor-agent' or command == 'codex' then return 1 end
  return 0
end
assert_equal(started, false, 'manager rejects unavailable Cursor')
assert(start_error:find('cursor%-agent'), 'Cursor unavailable reason names registry executable')
assert(start_error:find('cursor%-agent login'), 'Cursor unavailable reason includes login remedy')

assert_equal(config.set_active('pi'), true, 'resetting active agent for failed start cleanup')
package.loaded['custom.agents.manager'] = nil
manager = require 'custom.agents.manager'
adapter_behavior.pi = {
  start = function() return false, 'partial start' end,
}
local calls_before_failed_start = #adapter_calls
started, start_error = manager.start()
adapter_behavior.pi = nil
assert_equal(started, false, 'manager reports a partial start failure')
assert_equal(start_error, 'partial start', 'manager preserves the start failure')
assert_equal(adapter_calls[calls_before_failed_start + 1], 'pi:start', 'partial start is attempted')
assert_equal(adapter_calls[calls_before_failed_start + 2], 'pi:stop', 'partial start is cleaned up')

package.loaded['custom.agents.manager'] = nil
manager = require 'custom.agents.manager'
assert_equal(manager.start(), true, 'manager starts before failed switch stop')
adapter_behavior.pi = { stop = function() error 'stop exploded' end }
local calls_before_failed_switch = #adapter_calls
selected, select_error = manager.select 'cursor'
adapter_behavior.pi = nil
assert_equal(selected, false, 'manager aborts selection when the old adapter cannot stop')
assert(type(select_error) == 'string' and select_error:find('stop exploded', 1, true), 'failed stop selection reason')
assert_equal(manager.current(), 'pi', 'failed old stop keeps the active provider')
assert_equal(config.active(), 'pi', 'failed old stop does not persist the replacement')
assert_equal(adapter_calls[calls_before_failed_switch + 1], 'pi:stop', 'switch attempts to stop old adapter')
assert_equal(adapter_calls[calls_before_failed_switch + 2], nil, 'switch does not start replacement after failed stop')

package.loaded['custom.agents.manager'] = nil
manager = require 'custom.agents.manager'
assert_equal(manager.start(), true, 'manager starts before prompt exception')
notifications = {}
local prompt_error
adapter_behavior.pi = { prompt = function() error 'prompt exploded' end }
vim.notify = function(message) table.insert(notifications, message) end
local prompt_ok = pcall(manager.prompt, 'explode', function(_, err) prompt_error = err end)
vim.notify = original_notify
adapter_behavior.pi = nil
vim.fn.executable = original_executable
assert_equal(prompt_ok, true, 'prompt exceptions do not escape the manager')
assert(type(prompt_error) == 'string' and prompt_error:find('prompt exploded', 1, true), 'prompt exception reaches callback')
assert(type(notifications[1]) == 'string' and notifications[1]:find('prompt exploded', 1, true), 'prompt exception notifies')

manager.stop()
assert_equal(config.set_active('pi'), true, 'resetting active agent for Pi facade ownership test')
package.loaded['custom.agents.manager'] = nil
package.loaded['custom.plugins.pi'] = nil
manager = require 'custom.agents.manager'
local pi_factories_before_facade = adapter_factories.pi
vim.fn.executable = function(command)
  return (command == 'pi' or command == 'cursor-agent' or command == 'codex') and 1 or 0
end
original_api = vim.api
local compatibility_commands = {}
vim.api = setmetatable({
  nvim_create_user_command = function(name, callback) compatibility_commands[name] = callback end,
  nvim_buf_line_count = function() return 12 end,
}, { __index = original_api })
local pi_facade = require 'custom.plugins.pi'
local facade_adapter = pi_facade.adapter()
assert_equal(facade_adapter, manager.adapter('pi'), 'Pi facade exposes the manager-owned adapter')
assert_equal(adapter_factories.pi, pi_factories_before_facade + 1, 'manager and facade share one Pi adapter factory instance')

local facade_calls_start = #adapter_calls
assert_equal(manager.start(), true, 'manager starts the shared Pi adapter before compatibility commands')
compatibility_commands.PiStart()
pi_facade.pi_request('status', { value = 'one' }, function() end)
pi_facade.apply_suggested_edit(9, { newText = 'replacement' }, function() end)
compatibility_commands.PiSuggest { range = 1, line1 = 3, line2 = 5, buf = 9 }
assert_equal(manager.select('cursor'), true, 'switches away with a pending Pi suggestion')
compatibility_commands.PiDiscard()
assert(pi_facade.adapter() == facade_adapter, 'Pi discard reuses the adapter that owns pending suggestion originals')
pi_facade.apply_suggested_edit(9, { newText = 'second replacement' }, function() end)
assert_equal(manager.select('cursor'), true, 'switches away with another pending Pi suggestion')
compatibility_commands.PiAccept()
assert(pi_facade.adapter() == facade_adapter, 'Pi accept reuses the adapter that owns pending suggestion highlights')
compatibility_commands.PiStop()
local facade_calls = {}
for index = facade_calls_start + 1, #adapter_calls do table.insert(facade_calls, adapter_calls[index]) end
assert_equal(table.concat(facade_calls, ','), table.concat({
  'pi:start',
  'pi:request:status:one',
  'pi:apply:9:replacement',
  'pi:suggest:9:2:5',
  'pi:stop',
  'cursor:start',
  'cursor:stop',
  'pi:start',
  'pi:discard:1',
  'pi:apply:9:second replacement',
  'pi:stop',
  'cursor:start',
  'cursor:stop',
  'pi:start',
  'pi:accept:1',
  'pi:stop',
}, ','), 'Pi pending suggestions survive provider switching on the shared adapter')
assert_equal(adapter_factories.pi, pi_factories_before_facade + 1, 'Pi facade operations do not construct a second adapter')
vim.api = original_api
vim.fn.executable = original_executable
package.loaded['custom.plugins.pi'] = nil

local config_file = assert(io.open(config_path, 'rb'))
local saved_config = config_file:read '*a'
config_file:close()
assert(not saved_config:find('must-not-be-saved', 1, true), 'harness config must not contain credentials')

if not is_nvim then
  local stat = assert(io.popen(('stat -c %%a %q'):format(config_path)))
  assert_equal(stat:read('*l'), '600', 'config file permissions')
  stat:close()
end

if is_nvim then
  local stat = assert((vim.uv or vim.loop).fs_stat(config_path))
  assert_equal(stat.mode % 512, 384, 'config file permissions')
  vim.fn.delete(temp_data, 'rf')
else
  os.execute(('rm -rf %q'):format(temp_data))
end

print 'agent_harness_smoke: PASS'
