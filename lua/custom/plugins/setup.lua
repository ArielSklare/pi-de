-- First-start configuration for the Pi agent integration.
-- Pi's own auth store (~/.pi/agent/auth.json) is preferred and never copied here.
-- Legacy provider overrides stay Pi-only and are never copied into agent_harness.json.
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

function M.load_config()
  local config = read_json(config_path)
  if not config then return nil end

  -- Migrate the original setup's empty override to Pi's real auth store.
  if not config.auth_source and M.has_base_auth() and (not config.api_key or config.api_key == '') then
    config = { auth_source = 'pi' }
    M.save_config(config)
  end
  return config
end

function M.save_config(config)
  local fd = uv.fs_open(config_path, 'w', 384) -- 0600; API-key overrides must never be world-readable.
  if not fd then return false end
  local ok = uv.fs_write(fd, vim.json.encode(config), -1)
  uv.fs_close(fd)
  if not ok then return false end
  uv.fs_chmod(config_path, 384)
  return true
end

local provider_env = {
  google = 'GEMINI_API_KEY',
  openai = 'OPENAI_API_KEY',
  anthropic = 'ANTHROPIC_API_KEY',
  azure = 'AZURE_OPENAI_API_KEY',
  groq = 'GROQ_API_KEY',
}

function M.apply_config(config)
  config = config or M.load_config()
  if not config or config.auth_source == 'pi' then return end
  local env_name = provider_env[config.provider]
  if env_name and config.api_key and config.api_key ~= '' then
    uv.os_setenv(env_name, config.api_key)
  end
end

-- Build a Pi command while leaving credentials in Pi's own auth store or the process environment.
function M.get_pi_command(mode)
  local config = M.load_config()
  M.apply_config(config)
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
  vim.ui.input({ prompt = 'API key (leave empty to use environment): ', default = '' }, function(api_key)
    if api_key == nil then return end
    vim.ui.select({ 'google', 'openai', 'anthropic', 'azure', 'groq' }, {
      prompt = 'Select provider for Pi agent:',
    }, function(provider)
      if not provider then return end
      vim.ui.input({ prompt = 'Model override (optional): ', default = '' }, function(model)
        if model == nil then return end
        local config = {
          auth_source = 'override',
          api_key = api_key,
          provider = provider,
          model = model,
        }
        if M.save_config(config) then
          M.apply_config(config)
          vim.notify('Pi override configuration saved', vim.log.levels.INFO)
        else
          vim.notify('Failed to save Pi configuration', vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

function M.prompt_setup(force)
  if not force and M.load_config() then return end

  local options = {}
  if M.has_base_auth() then
    table.insert(options, 'Use existing Pi login (' .. auth_path() .. ')')
  end
  table.insert(options, 'Configure provider/API key override')

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
