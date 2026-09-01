local config = require 'custom.agents.config'
local registry = require 'custom.agents.registry'

local M = {}

local active_name = config.active()
local active_adapter
local adapters = {}
local state = 'stopped'

local auth_remedies = {
  pi = "configure authentication with the 'pi' CLI",
  cursor = "run 'cursor-agent login'",
  codex = "run 'codex login'",
}

local function notify_error(message)
  local level = vim.log and vim.log.levels and vim.log.levels.ERROR or nil
  vim.notify(message, level)
end

local function unavailable_reason(name)
  local provider = registry.get(name)
  if not provider then
    return ("Unknown agent provider '%s'; choose pi, cursor, or codex"):format(tostring(name))
  end

  local executable = provider.command[1]
  return ("Agent provider '%s' is unavailable: executable '%s' was not found in PATH; install '%s' or %s")
    :format(name, executable, executable, auth_remedies[name] or 'authenticate with its CLI')
end

local function check_available(name)
  local available = registry.available(name)
  if available then return true, nil end

  local reason = unavailable_reason(name)
  notify_error(reason)
  return false, reason
end

local function create_adapter(name)
  local ok, factory = pcall(require, 'custom.agents.adapters.' .. name)
  if not ok then
    return nil, ("Agent provider '%s' adapter could not be loaded: %s"):format(name, factory)
  end
  if type(factory.new) ~= 'function' then
    return nil, ("Agent provider '%s' adapter does not provide new()"):format(name)
  end

  local created, adapter = pcall(factory.new, {
    name = name,
    provider = registry.get(name),
  })
  if not created then
    return nil, ("Agent provider '%s' adapter could not be created: %s"):format(name, adapter)
  end
  return adapter, nil
end

local function adapter_for(name)
  if adapters[name] then return adapters[name], nil end

  local adapter, reason = create_adapter(name)
  if adapter then adapters[name] = adapter end
  return adapter, reason
end

local function get_active_adapter()
  local adapter, reason = adapter_for(active_name)
  if adapter then active_adapter = adapter end
  return adapter, reason
end

local function stop_adapter(adapter, name)
  if not adapter or type(adapter.stop) ~= 'function' then return true, nil end

  local called, stopped, stop_error = pcall(adapter.stop, adapter)
  if not called then
    return false, ("Agent provider '%s' failed to stop: %s"):format(name, stopped)
  end
  if stopped == false then
    return false, stop_error or ("Agent provider '%s' failed to stop"):format(name)
  end
  return true, nil
end

local function cleanup_active()
  local stopped, reason = stop_adapter(active_adapter, active_name)
  if stopped then
    state = 'stopped'
    return true, nil
  end

  notify_error(reason)
  return false, reason
end

function M.current()
  return active_name
end

function M.adapter(expected_name)
  if expected_name and expected_name ~= active_name then
    return nil, ("Agent provider '%s' is not active"):format(expected_name)
  end
  return get_active_adapter()
end

function M.start()
  if state == 'running' then return true, nil end
  if state == 'starting' then return false, 'Active agent is already starting' end

  local available, reason = check_available(active_name)
  if not available then return false, reason end

  local adapter
  adapter, reason = get_active_adapter()
  if not adapter then
    notify_error(reason)
    return false, reason
  end
  active_adapter = adapter

  if type(adapter.start) ~= 'function' then
    reason = ("Agent provider '%s' does not support start"):format(active_name)
    notify_error(reason)
    return false, reason
  end

  state = 'starting'
  local called, started, start_error = pcall(adapter.start, adapter)
  if not called then
    started, start_error = false, started
  end
  if not started then
    reason = start_error or ("Agent provider '%s' failed to start"):format(active_name)
    notify_error(reason)
    cleanup_active()
    return false, reason
  end

  state = 'running'
  return true, nil
end

function M.stop()
  if state == 'stopped' then return true, nil end
  return cleanup_active()
end

function M.select(name)
  if not registry.get(name) then
    return false, ("Unknown agent provider '%s'; choose pi, cursor, or codex"):format(tostring(name))
  end

  if name == active_name then return config.set_active(name) end

  local needs_stop = state ~= 'stopped'
  local next_adapter
  local reason
  if needs_stop then
    local available
    available, reason = check_available(name)
    if not available then return false, reason end
    next_adapter, reason = adapter_for(name)
    if not next_adapter then
      notify_error(reason)
      return false, reason
    end

    local stopped
    stopped, reason = cleanup_active()
    if not stopped then return false, reason end
  end

  local persisted
  persisted, reason = config.set_active(name)
  if not persisted then return false, reason end

  active_name = name
  active_adapter = next_adapter or adapters[name]

  if needs_stop then return M.start() end
  return true, nil
end

function M.toggle_terminal()
  local ok, terminal = pcall(require, 'custom.agents.terminal')
  if not ok or type(terminal.toggle_active) ~= 'function' then
    notify_error('Agent terminal is unavailable')
    return
  end
  terminal.toggle_active()
end

function M.prompt(text, callback)
  local started, reason = M.start()
  if not started then
    if callback then callback(nil, reason) end
    return
  end

  if type(active_adapter.prompt) ~= 'function' then
    reason = ("Agent provider '%s' does not support prompts"):format(active_name)
    notify_error(reason)
    if callback then callback(nil, reason) end
    return
  end
  local callback_called = false
  local delegated_callback
  if callback then
    delegated_callback = function(...)
      callback_called = true
      return callback(...)
    end
  end

  local ok, prompt_error = pcall(active_adapter.prompt, active_adapter, text, delegated_callback)
  if not ok then
    reason = ("Agent provider '%s' prompt failed: %s"):format(active_name, prompt_error)
    notify_error(reason)
    if callback and not callback_called then pcall(callback, nil, reason) end
  end
end

function M.capabilities()
  local adapter = active_adapter
  if not adapter then adapter = select(1, get_active_adapter()) end
  if not adapter or type(adapter.capabilities) ~= 'function' then return {} end

  local ok, capabilities = pcall(adapter.capabilities, adapter)
  return ok and type(capabilities) == 'table' and capabilities or {}
end

return M
