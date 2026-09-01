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
assert_equal(providers.codex.command[1], 'codex', 'Codex executable')
assert_equal(providers.codex.protocol, 'app-server', 'Codex protocol')
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
  return { get_pi_command = function() return { 'pi', '--model', 'model with space' } end }
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
vim.fn.shellescape = function(value) return "'" .. value .. "'" end
package.loaded['custom.agents.terminal'] = nil
local terminal = require 'custom.agents.terminal'
local terminal_opened, terminal_error = terminal.open 'pi'
assert_equal(terminal_opened, true, 'opening the Pi terminal: ' .. tostring(terminal_error))
assert_equal(created_terminals[1].options.cmd, "'pi' '--model' 'model with space'", 'Pi terminal command construction')
assert_equal(created_terminals[1].options.display_name, 'Pi', 'Pi terminal display name')
assert_equal(terminal.open('cursor'), true, 'opening the Cursor terminal')
assert_equal(created_terminals[2].options.cmd, "'cursor-agent'", 'Cursor terminal command construction')
assert_equal(created_terminals[2].options.display_name, 'Cursor Agent', 'Cursor terminal display name')
assert_equal(terminal.open('codex'), true, 'opening the Codex terminal')
assert_equal(created_terminals[3].options.cmd, "'codex'", 'Codex terminal command construction')
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
    toggle_active = function() table.insert(plugin_terminal_calls, 'toggle') end,
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
package.loaded.toggleterm = nil
package.preload['custom.agents.terminal'] = nil
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
package.preload['custom.agents.terminal'] = function()
  return {
    toggle_active = function() table.insert(terminal_toggles, config.active()) end,
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
manager.stop()
assert_equal(adapter_calls[5], 'cursor:stop', 'stop delegates to the active adapter')

assert_equal(manager.select('codex'), true, 'manager persists another known provider while stopped')
local notifications = {}
local original_notify = vim.notify
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
