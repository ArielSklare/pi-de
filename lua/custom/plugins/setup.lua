-- First start interface for Pi agent configuration
local uv = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn
local M = {}

local config_path = vim.fn.stdpath('data') .. '/pi_config.json'

-- Load config if exists
function M.load_config()
  local f = io.open(config_path, 'r')
  if f then
    local content = f:read('*a')
    f:close()
    local ok, config = pcall(vim.json.decode, content)
    if ok and config then
      return config
    end
  end
  return nil
end

-- Save config
function M.save_config(config)
  local f = io.open(config_path, 'w')
  if f then
    f:write(vim.json.encode(config))
    f:close()
    return true
  end
  return false
end

-- Prompt for API key and LLM selection
function M.prompt_setup()
  -- Check if we already have config
  if M.load_config() then
    return
  end
  vim.notify('Pi agent setup required', vim.log.levels.INFO)
  -- API key input (we'll ask for provider and key)
  vim.ui.input({ prompt = 'Enter API key for Pi (leave empty to use env): ', default = '' }, function(api_key)
    if api_key == nil then
      api_key = ''
    end
    -- Provider selection
    vim.ui.select({ 'google', 'openai', 'anthropic', 'azure', 'groq' }, {
      prompt = 'Select provider for Pi agent:',
      default = 'google',
    }, function(provider, idx)
      if provider == nil then
        provider = 'google'
      end
      -- Model selection (optional)
      vim.ui.input({ prompt = 'Enter model pattern (optional, e.g., gemini-2.0-flash): ', default = '' }, function(model)
        if model == nil then
          model = ''
        end
        local config = {
          api_key = api_key,
          provider = provider,
          model = model,
        }
        if M.save_config(config) then
          vim.notify('Pi configuration saved', vim.log.levels.INFO)
          -- Set environment variables for pi agent
          if api_key ~= '' then
            if provider == 'google' then
              uv.os_setenv('GEMINI_API_KEY', api_key)
            elseif provider == 'openai' then
              uv.os_setenv('OPENAI_API_KEY', api_key)
            elseif provider == 'anthropic' then
              uv.os_setenv('ANTHROPIC_API_KEY', api_key)
            elseif provider == 'azure' then
              uv.os_setenv('AZURE_OPENAI_API_KEY', api_key)
            elseif provider == 'groq' then
              uv.os_setenv('GROQ_API_KEY', api_key)
            end
          end
          if model ~= '' then
            uv.os_setenv('PI_DEFAULT_MODEL', model)
          end
        else
          vim.notify('Failed to save pi configuration', vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

-- Call setup on plugin load (defer to ensure UI ready)
vim.schedule(function()
  M.prompt_setup()
end)

return M