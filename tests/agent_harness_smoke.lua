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

local adapter_calls = {}
local function fake_adapter(name)
  return {
    start = function()
      table.insert(adapter_calls, name .. ':start')
      return true
    end,
    stop = function() table.insert(adapter_calls, name .. ':stop') end,
    prompt = function(_, text, callback)
      table.insert(adapter_calls, name .. ':prompt:' .. text)
      if callback then callback(name .. ':reply') end
    end,
    capabilities = function() return { provider = name, prompt = true } end,
  }
end

for _, name in ipairs { 'pi', 'cursor', 'codex' } do
  local provider_name = name
  package.preload['custom.agents.adapters.' .. provider_name] = function()
    return { new = function() return fake_adapter(provider_name) end }
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

local started, start_error = manager.start()
assert_equal(started, true, 'manager starts the active adapter')
assert_equal(start_error, nil, 'successful manager start reason')
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
