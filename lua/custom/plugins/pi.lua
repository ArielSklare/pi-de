-- Compatibility facade for the Pi adapter and its original user commands.
local api = vim.api
local adapter = require('custom.agents.adapters.pi').new { name = 'pi' }
local M = {}

function M.adapter()
  return adapter
end

function M.start_pi()
  return adapter:start()
end

function M.stop_pi()
  return adapter:stop()
end

function M.pi_request(command_type, params, callback)
  return adapter:request(command_type, params, callback)
end

function M.apply_suggested_edit(bufnr, edit, callback)
  return adapter:_apply_suggested_edit(bufnr, edit, callback)
end

function M.suggest_edits(bufnr, start_line, end_line, callback)
  return adapter:suggest_edits(bufnr, start_line, end_line, callback)
end

function M.accept_suggestions()
  return adapter:accept_suggestions()
end

function M.discard_suggestions()
  return adapter:discard_suggestions()
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
