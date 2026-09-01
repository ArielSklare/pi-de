local events = require 'custom.agents.events'

local CodexAdapter = {}
CodexAdapter.__index = CodexAdapter

local function close_pipe(pipe)
  if pipe and not pipe:is_closing() then pipe:close() end
end

local function default_command_runner(args, timeout)
  if not vim.system then
    return { code = 1, stderr = 'vim.system is unavailable' }
  end
  local ok, process = pcall(vim.system, args, { text = true })
  if not ok then return { code = 1, stderr = tostring(process) } end
  local waited, result = pcall(process.wait, process, timeout)
  if not waited then return { code = 1, stderr = tostring(result) } end
  return result
end

local function item_text(item)
  if type(item) ~= 'table' then return nil end
  return item.delta or item.text or item.message or item.content
end

local function error_message(value)
  local detail = value.error or value.message
  if type(detail) == 'table' then return detail.message or detail.code end
  return detail
end

function CodexAdapter.new(options)
  options = options or {}
  local provider = options.provider or {}
  local command = provider.command or { 'codex' }
  return setmetatable({
    executable = command[1] or 'codex',
    sandbox = options.sandbox or provider.sandbox or 'read-only',
    approval_policy = options.approval_policy or provider.approval_policy or 'on-request',
    preferred_protocol = provider.protocol or 'app-server',
    fallback_protocol = provider.fallback_protocol or 'exec-json',
    protocol = provider.fallback_protocol or 'exec-json',
    uv = options.uv or vim.uv or vim.loop,
    command_runner = options.command_runner or default_command_runner,
    json_decode = options.json_decode or vim.json.decode,
    schedule = options.schedule or vim.schedule,
    notify = options.notify or vim.notify,
    levels = options.levels or (vim.log and vim.log.levels) or {},
    auth_timeout = options.auth_timeout or 2000,
    probe_timeout = options.probe_timeout or 2000,
    started = false,
    process = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    stdout_buffer = '',
    stderr_buffer = '',
    callback = nil,
    stopping = false,
  }, CodexAdapter)
end

function CodexAdapter:_run(arguments, timeout)
  local command = { self.executable }
  for _, argument in ipairs(arguments) do table.insert(command, argument) end
  local ok, result = pcall(self.command_runner, command, timeout)
  if not ok then return { code = 1, stderr = tostring(result) } end
  return type(result) == 'table' and result or { code = 1, stderr = 'invalid command result' }
end

function CodexAdapter:start()
  if self.started then return true, nil end

  local auth = self:_run({ 'login', 'status' }, self.auth_timeout)
  if auth.code ~= 0 then
    local reason = "Codex is not authenticated; run 'codex login'"
    self.notify(reason, self.levels.ERROR)
    return false, reason
  end

  local probe = self:_run({ 'app-server', '--help' }, self.probe_timeout)
  self.protocol = probe.code == 0 and self.preferred_protocol or self.fallback_protocol
  self.started = true
  return true, nil
end

function CodexAdapter:parse_event(value)
  if type(value) ~= 'table' or type(value.type) ~= 'string' then return nil end

  local event_type = value.type
  local item = value.item or value.message
  if event_type == 'thread.started' then
    return events.new('started', { provider = 'codex', phase = 'thread', thread_id = value.thread_id })
  end
  if event_type == 'turn.started' then
    return events.new('started', { provider = 'codex', phase = 'turn', turn_id = value.turn_id })
  end
  if event_type == 'message.delta' or event_type == 'response.output_text.delta' then
    return events.new('text_delta', { provider = 'codex', text = value.delta or value.text or '' })
  end
  if event_type == 'approval.requested' or event_type == 'item.approval_requested' then
    return events.new('approval_required', {
      provider = 'codex',
      id = value.id or (item and item.id),
      command = value.command or (item and item.command),
      item = item,
    })
  end
  if event_type == 'turn.completed' then
    return events.new('completed', { provider = 'codex', turn_id = value.turn_id, usage = value.usage })
  end
  if event_type == 'turn.failed' or event_type == 'error' then
    return events.new('error', {
      provider = 'codex',
      turn_id = value.turn_id,
      message = error_message(value) or 'Codex request failed',
    })
  end

  if event_type == 'item.started' and type(item) == 'table' then
    if item.type == 'command_execution' or item.type == 'tool_call' then
      return events.new('tool_started', {
        provider = 'codex', id = item.id, command = item.command, tool = item.name,
      })
    end
    if item.type == 'approval_request' then
      return events.new('approval_required', {
        provider = 'codex', id = item.id, command = item.command, item = item,
      })
    end
  end

  if (event_type == 'item.updated' or event_type == 'item.completed') and type(item) == 'table' then
    if item.type == 'agent_message' or item.type == 'message' then
      local text = item_text(item)
      if text then return events.new('text_delta', { provider = 'codex', id = item.id, text = text }) end
    end
    if item.type == 'command_execution' or item.type == 'tool_call' then
      local output = item.delta or item.aggregated_output or item.output
      if output then
        return events.new('tool_output', {
          provider = 'codex', id = item.id, output = output, exit_code = item.exit_code,
        })
      end
    end
  end

  return nil
end

function CodexAdapter:_emit(event)
  if event and self.callback then
    local callback = self.callback
    self.schedule(function() callback(event) end)
  end
end

function CodexAdapter:_consume_stdout(err, data)
  if err then
    self:_emit(events.new('error', { provider = 'codex', message = 'Codex JSONL read failed: ' .. err }))
    return
  end
  if not data then return end

  self.stdout_buffer = self.stdout_buffer .. data
  while true do
    local newline = self.stdout_buffer:find('\n', 1, true)
    if not newline then break end
    local line = self.stdout_buffer:sub(1, newline - 1):gsub('\r$', '')
    self.stdout_buffer = self.stdout_buffer:sub(newline + 1)
    if line ~= '' then
      local ok, value = pcall(self.json_decode, line)
      if ok then
        self:_emit(self:parse_event(value))
      else
        self.notify('Invalid Codex JSONL event', self.levels.WARN)
      end
    end
  end
end

function CodexAdapter:prompt(text, callback)
  local started, reason = self:start()
  if not started then
    if callback then callback(events.new('error', { provider = 'codex', message = reason })) end
    return
  end
  if self.process and not self.process:is_closing() then
    if callback then callback(events.new('error', { provider = 'codex', message = 'Codex is already running a prompt' })) end
    return
  end

  self.stdin = self.uv.new_pipe(false)
  self.stdout = self.uv.new_pipe(false)
  self.stderr = self.uv.new_pipe(false)
  self.stdout_buffer = ''
  self.stderr_buffer = ''
  self.callback = callback
  self.stopping = false

  local arguments = {
    'exec', '--json', '--sandbox', self.sandbox,
    '-c', ('approval_policy="%s"'):format(self.approval_policy), '-',
  }
  local process
  local spawn_error
  process, spawn_error = self.uv.spawn(self.executable, {
    args = arguments,
    cwd = self.uv.cwd(),
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code)
    close_pipe(self.stdin)
    close_pipe(self.stdout)
    close_pipe(self.stderr)
    if process and not process:is_closing() then process:close() end
    local was_stopping = self.stopping
    local stderr = self.stderr_buffer
    self.process, self.stdin, self.stdout, self.stderr = nil, nil, nil, nil
    self.callback = nil
    self.stopping = false
    if code ~= 0 and not was_stopping then
      local message
      local lowered = stderr:lower()
      if lowered:find('not logged', 1, true) or lowered:find('authentication', 1, true) then
        message = "Codex is not authenticated; run 'codex login'"
      else
        message = stderr ~= '' and stderr:gsub('^%s+', ''):gsub('%s+$', '') or ('Codex exited with code ' .. code)
      end
      self.notify(message, self.levels.ERROR)
    end
  end)

  if not process then
    close_pipe(self.stdin)
    close_pipe(self.stdout)
    close_pipe(self.stderr)
    self.stdin, self.stdout, self.stderr, self.callback = nil, nil, nil, nil
    reason = spawn_error or 'executable not found'
    self.notify('Failed to start Codex: ' .. reason, self.levels.ERROR)
    if callback then callback(events.new('error', { provider = 'codex', message = reason })) end
    return
  end

  self.process = process
  self.uv.read_start(self.stdout, function(err, data) self:_consume_stdout(err, data) end)
  self.uv.read_start(self.stderr, function(_, data)
    if data then self.stderr_buffer = self.stderr_buffer .. data end
  end)
  self.stdin:write(text, function(err)
    if err then self:_emit(events.new('error', { provider = 'codex', message = err })) end
    close_pipe(self.stdin)
  end)
end

function CodexAdapter:stop()
  self.started = false
  if self.process and not self.process:is_closing() then
    self.stopping = true
    self.process:kill 'sigterm'
  end
end

function CodexAdapter:capabilities()
  return {
    provider = 'codex',
    protocol = self.protocol,
    preferred_protocol = self.preferred_protocol,
    fallback_protocol = self.fallback_protocol,
    prompt = true,
    stream = true,
    approvals = self.approval_policy ~= 'never',
    sandbox = self.sandbox,
    approval_policy = self.approval_policy,
  }
end

return CodexAdapter
