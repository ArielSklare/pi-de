local M = {}

local uv = vim.uv or vim.loop
local config_path = vim.fn.stdpath('data') .. '/agent_harness.json'
local provider_names = { 'pi', 'cursor', 'codex' }
local known_providers = { pi = true, cursor = true, codex = true }

local function defaults()
  return {
    active_agent = 'pi',
    agents = {
      pi = { enabled = true },
      cursor = { enabled = true },
      codex = { enabled = true },
    },
  }
end

local function normalize(value)
  local result = defaults()
  if type(value) ~= 'table' then return result end

  if type(value.agents) == 'table' then
    for _, name in ipairs(provider_names) do
      local agent = value.agents[name]
      if type(agent) == 'table' and type(agent.enabled) == 'boolean' then
        result.agents[name].enabled = agent.enabled
      end
    end
  end

  local requested = value.active_agent
  if known_providers[requested] and result.agents[requested].enabled then
    result.active_agent = requested
  else
    for _, name in ipairs(provider_names) do
      if result.agents[name].enabled then
        result.active_agent = name
        break
      end
    end
  end

  if not result.agents[result.active_agent].enabled then
    result.agents.pi.enabled = true
    result.active_agent = 'pi'
  end

  return result
end

local function read_file(path)
  local fd = uv.fs_open(path, 'r', 384)
  if not fd then return nil end

  local stat = uv.fs_fstat(fd)
  local content = stat and uv.fs_read(fd, stat.size, 0) or nil
  uv.fs_close(fd)
  return content
end

function M.load()
  local content = read_file(config_path)
  if not content or content == '' then return defaults() end

  local ok, value = pcall(vim.json.decode, content)
  if not ok then return defaults() end
  return normalize(value)
end

function M.save(value)
  if type(value) ~= 'table' then return false end

  local ok, encoded = pcall(vim.json.encode, normalize(value))
  if not ok then return false end

  local fd = uv.fs_open(config_path, 'w', 384)
  if not fd then return false end
  if not uv.fs_chmod(config_path, 384) then
    uv.fs_close(fd)
    return false
  end

  local written = uv.fs_write(fd, encoded .. '\n', 0)
  uv.fs_close(fd)
  return written == #encoded + 1
end

function M.active()
  return M.load().active_agent
end

function M.set_active(name)
  if not known_providers[name] then return false end

  local value = M.load()
  if not value.agents[name].enabled then return false end
  value.active_agent = name
  return M.save(value)
end

return M
