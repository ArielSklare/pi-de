-- You can add your own plugins here or in other files in this directory!
--  I promise not to create any merge conflicts in this directory :)
--
-- See the kickstart.nvim README for more information

-- Iterate over all Lua files in the plugins directory and load them
local plugins_dir = vim.fs.joinpath(vim.fn.stdpath 'config', 'lua', 'custom', 'plugins')
for file_name, type in vim.fs.dir(plugins_dir, { follow = true }) do
  if (type == 'file' or type == 'link') and file_name:match '%.lua$' and file_name ~= 'init.lua' then
    local module = file_name:gsub('%.lua$', '')
    require('custom.plugins.' .. module)
  end
end

local manager = require 'custom.agents.manager'
local provider_names = { 'pi', 'cursor', 'codex' }
local display_names = { pi = 'Pi', cursor = 'Cursor Agent', codex = 'Codex' }

vim.api.nvim_create_user_command('AgentSelect', function()
  vim.ui.select(provider_names, {
    prompt = 'Select active agent:',
    format_item = function(name) return display_names[name] end,
  }, function(name)
    if not name then return end
    local selected, reason = manager.select(name)
    if not selected then vim.notify(reason, vim.log.levels.ERROR) end
  end)
end, { desc = 'Select the active agent provider' })

vim.api.nvim_create_user_command('AgentStart', function() manager.start() end, {
  desc = 'Start the active agent',
})
vim.api.nvim_create_user_command('AgentStop', function() manager.stop() end, {
  desc = 'Stop the active agent',
})
vim.api.nvim_create_user_command('AgentToggle', function() manager.toggle_terminal() end, {
  desc = 'Toggle the active agent terminal',
})
