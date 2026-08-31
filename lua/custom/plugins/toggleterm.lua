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

-- Function to open a Pi terminal using the selected setup profile. Pi's default
-- profile reads credentials and the default model from ~/.pi/agent automatically.
local pi_term
function _G.pi_open_term()
  local Terminal = require('toggleterm.terminal').Terminal
  local setup = require('custom.plugins.setup')
  if not pi_term then
    local command = table.concat(vim.tbl_map(vim.fn.shellescape, setup.get_pi_command()), ' ')
    pi_term = Terminal:new {
      direction = 'vertical',
      display_name = 'Pi',
      cmd = command,
      hidden = true,
    }
  end
  pi_term:toggle()
end

-- Keymap to open pi terminal
vim.keymap.set('n', '<leader>tp', _G.pi_open_term, { desc = 'Open Pi terminal' })