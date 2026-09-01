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
    error(('%s: expected %q, got %q'):format(message, expected, actual), 2)
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
assert_equal(config.set_active('missing'), false, 'rejecting an unknown active agent')
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

local config_path = temp_data .. '/agent_harness.json'
local invalid_config = assert(io.open(config_path, 'wb'))
invalid_config:write '{"active_agent":"pi","agents":{"pi":{"enabled":false},"cursor":{"enabled":true},"codex":{"enabled":true}}}\n'
invalid_config:close()
local normalized_persisted_config = config.load()
assert_equal(normalized_persisted_config.active_agent, 'cursor', 'load falls back from a persisted disabled active agent')
assert_equal(normalized_persisted_config.agents.pi.enabled, false, 'load preserves normalized provider enablement')

assert_equal(config.save(config_with_secrets), true, 'restoring sanitized harness configuration')
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
