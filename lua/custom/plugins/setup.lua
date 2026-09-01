-- First-start configuration for the Pi agent integration.
-- Pi's own auth store (~/.pi/agent/auth.json) is preferred and never copied here.
-- Optional provider/model overrides are non-secret; credentials remain Pi-owned.
local uv = vim.uv or vim.loop
local M = {}

local config_path = vim.fn.stdpath('data') .. '/pi_config.json'

local function agent_dir()
  return vim.env.PI_CODING_AGENT_DIR or (vim.fn.expand('~') .. '/.pi/agent')
end

local function auth_path()
  return agent_dir() .. '/auth.json'
end

local function read_json(path)
  local file = io.open(path, 'r')
  if not file then return nil end
  local content = file:read('*a')
  file:close()
  local ok, value = pcall(vim.json.decode, content)
  return ok and type(value) == 'table' and value or nil
end

function M.has_base_auth()
  local auth = read_json(auth_path())
  return auth ~= nil and next(auth) ~= nil
end

local function sanitize_config(config)
  if type(config) ~= 'table' then return nil end
  return {
    auth_source = config.auth_source == 'override' and 'override' or 'pi',
    provider = type(config.provider) == 'string' and config.provider or nil,
    model = type(config.model) == 'string' and config.model or nil,
  }
end

function M.load_config()
  local config = read_json(config_path)
  if not config then return nil end

  local sanitized = sanitize_config(config)
  local needs_migration = config.api_key ~= nil
    or config.auth_source ~= sanitized.auth_source
    or config.provider ~= sanitized.provider
    or config.model ~= sanitized.model
  if needs_migration then M.save_config(sanitized) end
  return sanitized
end

function M.save_config(config)
  local sanitized = sanitize_config(config)
  if not sanitized then return false end
  local fd = uv.fs_open(config_path, 'w', 384)
  if not fd then return false end
  local ok = uv.fs_write(fd, vim.json.encode(sanitized), -1)
  uv.fs_close(fd)
  if not ok then return false end
  uv.fs_chmod(config_path, 384)
  return true
end

-- Retained as a compatibility no-op. Setup must never mutate Neovim's process environment.
function M.apply_config(config)
  return sanitize_config(config or M.load_config())
end

-- Build a Pi command using only non-secret flags. Pi resolves credentials itself.
function M.get_pi_command(mode)
  local config = M.load_config()
  local command = { 'pi' }
  if mode then vim.list_extend(command, { '--mode', mode }) end
  if config and config.auth_source ~= 'pi' then
    if config.provider and config.provider ~= '' then
      vim.list_extend(command, { '--provider', config.provider })
    end
    if config.model and config.model ~= '' then
      vim.list_extend(command, { '--model', config.model })
    end
  end
  return command
end

local function save_override()
  vim.ui.select({ 'google', 'openai', 'anthropic', 'azure', 'groq' }, {
    prompt = 'Select provider for Pi agent:',
  }, function(provider)
    if not provider then return end
    vim.ui.input({ prompt = 'Model override (optional): ', default = '' }, function(model)
      if model == nil then return end
      local config = {
        auth_source = 'override',
        provider = provider,
        model = model,
      }
      if M.save_config(config) then
        vim.notify('Pi provider/model override saved; authentication remains Pi-owned', vim.log.levels.INFO)
      else
        vim.notify('Failed to save Pi configuration', vim.log.levels.ERROR)
      end
    end)
  end)
end

function M.prompt_setup(force)
  if not force and M.load_config() then return end

  local options = {}
  if M.has_base_auth() then
    table.insert(options, 'Use existing Pi login (' .. auth_path() .. ')')
  end
  table.insert(options, 'Configure provider/model override (use Pi-owned authentication)')

  vim.ui.select(options, { prompt = 'Select authentication for embedded Pi:' }, function(choice)
    if not choice then return end
    if choice:match('^Use existing Pi login') then
      if M.save_config({ auth_source = 'pi' }) then
        vim.notify('Embedded Pi will use your existing Pi login and default model', vim.log.levels.INFO)
      else
        vim.notify('Failed to save Pi configuration', vim.log.levels.ERROR)
      end
    else
      save_override()
    end
  end)
end

vim.api.nvim_create_user_command('PiSetup', function() M.prompt_setup(true) end, {
  desc = 'Choose authentication and model settings for embedded Pi',
})

vim.schedule(function() M.prompt_setup(false) end)

return M
