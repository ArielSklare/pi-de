-- toggleterm.nvim configuration for side terminal
vim.pack.add {
  { src = 'https://github.com/akinsho/toggleterm.nvim', version = vim.version.range '*' },
}

local status_ok, toggleterm = pcall(require, 'toggleterm')
if not status_ok then
  return
end

toggleterm.setup{
  size = function(term)
    if term.direction == "horizontal" then
      return vim.o.lines * 0.25
    elseif term.direction == "vertical" then
      return vim.o.columns * 0.4
    end
  end,
  open_mapping = [[<c-\>]],
  hide_numbers = true,
  shade_filetypes = {},
  shade_terminals = true,
  shading_factor = 2,
  start_in_insert = true,
  insert_mappings = true,
  persist_size = true,
  direction = 'vertical',   -- vertical split on the right
  close_on_exit = true,
  shell = vim.o.shell,
}

local agent_terminal = require 'custom.agents.terminal'
local agent_manager = require 'custom.agents.manager'

-- Keep the original Pi entry point as a compatibility alias.
function _G.pi_open_term()
  local opened, reason = agent_terminal.open 'pi'
  if not opened then vim.notify(reason, vim.log.levels.ERROR) end
  return opened, reason
end

vim.keymap.set('n', '<leader>tp', _G.pi_open_term, { desc = 'Open Pi terminal' })
vim.keymap.set('n', '<leader>ta', agent_manager.toggle_terminal, { desc = 'Toggle active agent terminal' })
