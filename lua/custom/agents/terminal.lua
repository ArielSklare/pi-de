local registry = require 'custom.agents.registry'

local M = {}
local terminals = {}

local display_names = {
  pi = 'Pi',
  cursor = 'Cursor Agent',
  codex = 'Codex',
}

local function command_for(name, provider)
  local command
  if name == 'pi' then
    command = require('custom.plugins.setup').get_pi_command()
  else
    command = provider.command
  end

  local result = {}
  for _, value in ipairs(command) do table.insert(result, value) end
  for _, value in ipairs(provider.terminal_args) do table.insert(result, value) end
  return result
end

local function shell_command(command)
  local escaped = {}
  for _, value in ipairs(command) do
    table.insert(escaped, vim.fn.shellescape(value))
  end
  return table.concat(escaped, ' ')
end

local function create(name, provider)
  local ok, toggleterm_terminal = pcall(require, 'toggleterm.terminal')
  if not ok then return nil, 'ToggleTerm terminal support is unavailable: ' .. tostring(toggleterm_terminal) end

  local created, terminal = pcall(function()
    return toggleterm_terminal.Terminal:new {
      direction = 'vertical',
      display_name = display_names[name] or name,
      cmd = shell_command(command_for(name, provider)),
      hidden = true,
    }
  end)
  if not created then return nil, ('Could not create %s terminal: %s'):format(name, terminal) end
  terminals[name] = terminal
  return terminal, nil
end

function M.open(name)
  local provider = registry.get(name)
  if not provider then
    return false, ("Unknown agent provider '%s'; choose pi, cursor, or codex"):format(tostring(name))
  end

  local terminal = terminals[name]
  local reason
  if not terminal then terminal, reason = create(name, provider) end
  if not terminal then return false, reason end

  local toggled, toggle_error = pcall(terminal.toggle, terminal)
  if not toggled then return false, ('Could not toggle %s terminal: %s'):format(name, toggle_error) end
  return true, nil
end

function M.toggle_active()
  local manager = require 'custom.agents.manager'
  return M.open(manager.current())
end

return M
