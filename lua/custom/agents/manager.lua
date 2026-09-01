local config = require 'custom.agents.config'
local registry = require 'custom.agents.registry'

local M = {}

local active_name = config.active()
local active_adapter
local adapters = {}
local state = 'stopped'
local stop_waiters = {}
local pending_transition
local transition_waiting = false
local handle_adapter_exit

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
    open_terminal = function(provider_name)
      local loaded, terminal = pcall(require, 'custom.agents.terminal')
      if not loaded then return false, 'Agent terminal is unavailable: ' .. tostring(terminal) end
      return terminal.open(provider_name)
    end,
    on_exit = function(code, expected) handle_adapter_exit(name, code, expected) end,
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

handle_adapter_exit = function(name, _, expected)
  if expected or name ~= active_name or adapters[name] ~= active_adapter then return end
  if state == 'running' or state == 'starting' then state = 'stopped' end
end

local function finish_stop(stopped, reason)
  state = stopped and 'stopped' or 'running'
  local waiters = stop_waiters
  stop_waiters = {}
  if not stopped and reason then notify_error(reason) end
  for _, waiter in ipairs(waiters) do waiter(stopped, reason) end
end

local function stop_adapter(adapter, name, callback)
  if not adapter or type(adapter.stop) ~= 'function' then
    callback(true, nil)
    return true, nil
  end

  local completed = false
  local function complete(stopped, stop_error)
    if completed then return end
    completed = true
    if stopped == false then
      callback(false, stop_error or ("Agent provider '%s' failed to stop"):format(name))
    else
      callback(true, nil)
    end
  end

  local called, stopped, stop_error = pcall(adapter.stop, adapter, complete)
  if not called then
    local reason = ("Agent provider '%s' failed to stop: %s"):format(name, stopped)
    complete(false, reason)
    return false, reason
  end
  if stopped == false then
    local reason = stop_error or ("Agent provider '%s' failed to stop"):format(name)
    complete(false, reason)
    return false, reason
  end
  return true, nil
end

local function cleanup_active(callback)
  callback = callback or function() end
  if state == 'stopped' then
    callback(true, nil)
    return true, nil
  end

  table.insert(stop_waiters, callback)
  if state == 'stopping' then return true, nil end

  state = 'stopping'
  local accepted, reason = stop_adapter(active_adapter, active_name, finish_stop)
  if not accepted and state == 'stopping' then finish_stop(false, reason) end
  return accepted, reason
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
  if state == 'running' then
    if not active_adapter or type(active_adapter.is_running) ~= 'function' or active_adapter:is_running() then
      return true, nil
    end
    state = 'stopped'
  end
  if state == 'starting' then return false, 'Active agent is already starting' end
  if state == 'stopping' then return false, 'Active agent is still stopping' end

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

function M.stop(callback)
  if state == 'stopped' then
    if callback then callback(true, nil) end
    return true, nil
  end
  return cleanup_active(callback)
end

local function complete_pending_transition(stopped, stop_reason)
  local transition = pending_transition
  pending_transition = nil
  transition_waiting = false
  if not transition then return end

  if not stopped then
    transition.completed = true
    transition.success = false
    transition.reason = stop_reason
    if transition.callback then transition.callback(false, stop_reason) end
    return
  end

  local persisted, reason = config.set_active(transition.name)
  if not persisted then
    transition.completed = true
    transition.success = false
    transition.reason = reason
    notify_error(reason)
    if transition.callback then transition.callback(false, reason) end
    return
  end

  active_name = transition.name
  active_adapter = transition.adapter
  transition.success, transition.reason = M.start()
  transition.completed = true
  if transition.callback then transition.callback(transition.success, transition.reason) end
end

function M.select(name, callback)
  if not registry.get(name) then
    local reason = ("Unknown agent provider '%s'; choose pi, cursor, or codex"):format(tostring(name))
    notify_error(reason)
    if callback then callback(false, reason) end
    return false, reason
  end

  if name == active_name and state ~= 'stopping' then
    local persisted, reason = config.set_active(name)
    if not persisted then notify_error(reason) end
    if callback then callback(persisted, reason) end
    return persisted, reason
  end

  if state == 'stopped' then
    local persisted, reason = config.set_active(name)
    if persisted then
      active_name = name
      active_adapter = adapters[name]
    else
      notify_error(reason)
    end
    if callback then callback(persisted, reason) end
    return persisted, reason
  end

  local available, reason = check_available(name)
  if not available then
    if callback then callback(false, reason) end
    return false, reason
  end

  local next_adapter
  next_adapter, reason = adapter_for(name)
  if not next_adapter then
    notify_error(reason)
    if callback then callback(false, reason) end
    return false, reason
  end

  local superseded = pending_transition
  local transition = {
    name = name,
    adapter = next_adapter,
    callback = callback,
    completed = false,
  }
  pending_transition = transition
  if superseded and superseded.callback then
    superseded.callback(false, 'Agent selection was superseded by a newer request')
  end

  if not transition_waiting then
    transition_waiting = true
    local accepted, stop_reason = cleanup_active(complete_pending_transition)
    if not accepted and not transition.completed then return false, stop_reason end
  end

  if transition.completed then return transition.success, transition.reason end
  return true, nil
end

function M.toggle_terminal()
  local loaded, terminal = pcall(require, 'custom.agents.terminal')
  if not loaded then
    local reason = 'Agent terminal is unavailable: ' .. tostring(terminal)
    notify_error(reason)
    return false, reason
  end
  if type(terminal.open) ~= 'function' then
    local reason = 'Agent terminal is unavailable: open() is not supported'
    notify_error(reason)
    return false, reason
  end

  local called, toggled, reason = pcall(terminal.open, active_name)
  if not called then
    reason = ('Could not toggle %s terminal: %s'):format(active_name, toggled)
    notify_error(reason)
    return false, reason
  end
  if toggled == false then
    reason = reason or ('Could not toggle %s terminal'):format(active_name)
    notify_error(reason)
    return false, reason
  end
  return true, nil
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
