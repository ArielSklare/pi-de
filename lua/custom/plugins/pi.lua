-- Compatibility facade for the manager-owned Pi adapter and its original user commands.
local api = vim.api
local manager = require 'custom.agents.manager'
local M = {}

local function pi_adapter(start_process)
  if manager.current() ~= 'pi' then
    local selected, reason = manager.select 'pi'
    if not selected then return nil, reason end
  end

  if start_process then
    local started, reason = manager.start()
    if not started then return nil, reason end
  end

  return manager.adapter 'pi'
end

function M.adapter()
  return pi_adapter(false)
end

function M.start_pi()
  if manager.current() ~= 'pi' then
    local selected, reason = manager.select 'pi'
    if not selected then return false, reason end
  end
  return manager.start()
end

function M.stop_pi()
  if manager.current() ~= 'pi' then return true, nil end
  return manager.stop()
end

function M.pi_request(command_type, params, callback)
  local adapter, reason = pi_adapter(true)
  if not adapter then
    if callback then callback(nil, reason) end
    return
  end
  return adapter:request(command_type, params, callback)
end

function M.apply_suggested_edit(bufnr, edit, callback)
  local adapter, reason = pi_adapter(false)
  if not adapter then
    if callback then callback(nil, reason) end
    return
  end
  return adapter:_apply_suggested_edit(bufnr, edit, callback)
end

function M.suggest_edits(bufnr, start_line, end_line, callback)
  local adapter, reason = pi_adapter(true)
  if not adapter then
    if callback then callback(nil, reason) end
    return
  end
  return adapter:suggest_edits(bufnr, start_line, end_line, callback)
end

function M.accept_suggestions()
  local adapter = pi_adapter(false)
  if adapter then return adapter:accept_suggestions() end
end

function M.discard_suggestions()
  local adapter = pi_adapter(false)
  if adapter then return adapter:discard_suggestions() end
end

api.nvim_create_user_command('PiStart', function() M.start_pi() end, {})
api.nvim_create_user_command('PiStop', function() M.stop_pi() end, {})
api.nvim_create_user_command('PiSuggest', function(options)
  local start_line = options.range > 0 and (options.line1 - 1) or 0
  local end_line = options.range > 0 and options.line2 or api.nvim_buf_line_count(0)
  M.suggest_edits(options.buf, start_line, end_line, function() end)
end, { range = true })
api.nvim_create_user_command('PiAccept', function() M.accept_suggestions() end, {})
api.nvim_create_user_command('PiDiscard', function() M.discard_suggestions() end, {})

return M
