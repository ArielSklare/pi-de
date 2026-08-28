-- toggleterm.nvim configuration for side terminal
vim.pack.add { 'akinsho/toggleterm.nvim', version = '*', opt = false }

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

-- Function to open a pi terminal
function _G.pi_open_term()
  local ToggleTerm = require('toggleterm.terminal')
  local term = ToggleTerm.get_or_create_term('pi_term', { direction = 'vertical', display_name = 'Pi' })
  if not term:is_open() then
    term:open()
    -- Send 'pi' command to start the agent
    vim.schedule(function()
      term:send('pi\n', false)
    end)
  else
    term:toggle()
  end
end

-- Keymap to open pi terminal
vim.keymap.set('n', '<leader>tp', _G.pi_open_term, { desc = 'Open Pi terminal' })