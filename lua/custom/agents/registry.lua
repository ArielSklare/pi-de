local M = {}

local providers = {
  pi = {
    command = { 'pi' },
    terminal_args = {},
    protocol = 'rpc',
  },
  cursor = {
    command = { 'cursor-agent' },
    terminal_args = {},
    protocol = 'stream-json',
  },
  codex = {
    command = { 'codex' },
    terminal_args = {},
    protocol = 'exec-json',
    preferred_protocol = 'app-server',
    fallback_protocol = 'exec-json',
    sandbox = 'read-only',
    approval_policy = 'on-request',
  },
}

local function copy_list(value)
  local result = {}
  for index, item in ipairs(value) do
    result[index] = item
  end
  return result
end

local function copy_provider(provider)
  return {
    command = copy_list(provider.command),
    terminal_args = copy_list(provider.terminal_args),
    protocol = provider.protocol,
    preferred_protocol = provider.preferred_protocol,
    fallback_protocol = provider.fallback_protocol,
    sandbox = provider.sandbox,
    approval_policy = provider.approval_policy,
  }
end

function M.all()
  local result = {}
  for name, provider in pairs(providers) do
    result[name] = copy_provider(provider)
  end
  return result
end

function M.get(name)
  local provider = providers[name]
  return provider and copy_provider(provider) or nil
end

function M.available(name)
  local provider = providers[name]
  if not provider then
    return false, ("Unknown agent provider '%s'; choose pi, cursor, or codex"):format(tostring(name))
  end

  local executable = provider.command[1]
  local ok, result = pcall(vim.fn.executable, executable)
  if ok and result == 1 then return true, nil end

  return false,
    ("Agent provider '%s' is unavailable: executable '%s' was not found in PATH; install it and restart Neovim")
      :format(name, executable)
end

return M
