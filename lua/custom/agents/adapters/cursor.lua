local events = require 'custom.agents.events'

local CursorAdapter = {}
CursorAdapter.__index = CursorAdapter

local function close_pipe(pipe)
  if pipe and not pipe:is_closing() then pipe:close() end
end

local function default_command_runner(args, timeout)
  if not vim.system then return { code = 1, stderr = 'vim.system is unavailable' } end
  local ok, process = pcall(vim.system, args, { text = true })
  if not ok then return { code = 1, stderr = tostring(process) } end
  local waited, result = pcall(process.wait, process, timeout)
  if not waited then return { code = 1, stderr = tostring(result) } end
  return result
end

local function message_text(message)
  if type(message) ~= 'table' or type(message.content) ~= 'table' then return nil end
  local text = {}
  for _, item in ipairs(message.content) do
    if type(item) == 'table' and item.type == 'text' and type(item.text) == 'string' then
      table.insert(text, item.text)
    end
  end
  return #text > 0 and table.concat(text) or nil
end

local function tool_details(value)
  local call = value.tool_call
  if type(call) ~= 'table' then return nil, nil end
  if call.name then return call.name, call end
  for name, detail in pairs(call) do
    if type(name) == 'string' and name:match 'ToolCall$' and type(detail) == 'table' then
      return name:gsub('ToolCall$', ''), detail
    end
  end
  return nil, call
end

local function tool_output(detail)
  if type(detail) ~= 'table' then return nil end
  if type(detail.result) == 'string' then return detail.result end
  local result = detail.result
  if type(result) ~= 'table' then return nil end
  local success = result.success or result
  if type(success) ~= 'table' then return nil end
  return success.content or success.output or success.message
end

local function is_auth_error(message)
  local lowered = tostring(message or ''):lower()
  return lowered:find('not logged', 1, true)
    or lowered:find('authentication', 1, true)
    or lowered:find('unauthorized', 1, true)
end

function CursorAdapter.new(options)
  options = options or {}
  local provider = options.provider or {}
  local command = provider.command or { 'cursor-agent' }
  return setmetatable({
    executable = command[1] or 'cursor-agent',
    protocol = provider.protocol or 'stream-json',
    fallback_protocol = provider.fallback_protocol or 'terminal',
    uv = options.uv or vim.uv or vim.loop,
    command_runner = options.command_runner or default_command_runner,
    json_decode = options.json_decode or vim.json.decode,
    schedule = options.schedule or vim.schedule,
    notify = options.notify or vim.notify,
    levels = options.levels or (vim.log and vim.log.levels) or {},
    open_terminal = options.open_terminal or function(name)
      return require('custom.agents.terminal').open(name)
    end,
    auth_timeout = options.auth_timeout or 2000,
    started = false,
    fallback_opened = false,
    process = nil,
    stdout = nil,
    stderr = nil,
    stdout_buffer = '',
    stderr_buffer = '',
    callback = nil,
    stopping = false,
    process_exited = false,
    stdout_eof = false,
    stderr_eof = false,
    exit_code = nil,
    error_emitted = false,
  }, CursorAdapter)
end

function CursorAdapter:_run(arguments, timeout)
  local command = { self.executable }
  for _, argument in ipairs(arguments) do table.insert(command, argument) end
  local ok, result = pcall(self.command_runner, command, timeout)
  if not ok then return { code = 1, stderr = tostring(result) } end
  return type(result) == 'table' and result or { code = 1, stderr = 'invalid command result' }
end

function CursorAdapter:_open_fallback()
  if self.fallback_opened then return true, nil end
  local ok, opened, reason = pcall(self.open_terminal, 'cursor')
  if not ok then return false, tostring(opened) end
  if opened == false then return false, reason or 'Cursor terminal fallback is unavailable' end
  self.fallback_opened = true
  self.protocol = self.fallback_protocol
  return true, nil
end

function CursorAdapter:start()
  if self.started then return true, nil end

  local auth = self:_run({ 'status' }, self.auth_timeout)
  if auth.code ~= 0 then return false, "Cursor is not authenticated; run 'cursor-agent login'" end

  local help = self:_run({ '--help' }, self.auth_timeout)
  local help_text = tostring(help.stdout or '') .. tostring(help.stderr or '')
  if help.code ~= 0 or not help_text:find('stream-json', 1, true) then
    local opened, reason = self:_open_fallback()
    if not opened then return false, reason end
  end

  self.started = true
  return true, nil
end

function CursorAdapter:parse_event(value)
  if type(value) ~= 'table' or type(value.type) ~= 'string' then return nil end

  if value.type == 'system' and value.subtype == 'init' then
    return events.new('started', {
      provider = 'cursor', session_id = value.session_id, model = value.model,
    })
  end
  if value.type == 'assistant' and value.timestamp_ms then
    local text = message_text(value.message)
    if text then return events.new('text_delta', { provider = 'cursor', text = text }) end
  end
  if value.type == 'tool_call' then
    local name, detail = tool_details(value)
    if value.subtype == 'started' then
      return events.new('tool_started', {
        provider = 'cursor', id = value.call_id, tool = name, item = detail,
      })
    end
    if value.subtype == 'completed' then
      return events.new('tool_output', {
        provider = 'cursor', id = value.call_id, tool = name, output = tool_output(detail),
      })
    end
  end
  if value.type == 'result' then
    if value.is_error or value.subtype == 'error' then
      return events.new('error', {
        provider = 'cursor', message = value.result or 'Cursor request failed',
      })
    end
    if value.subtype == 'success' then
      return events.new('completed', {
        provider = 'cursor', session_id = value.session_id, request_id = value.request_id,
        usage = value.usage,
      })
    end
  end
  return nil
end

function CursorAdapter:_emit(event)
  if not event or not self.callback then return end
  if event.kind == 'error' then
    if self.error_emitted then return end
    self.error_emitted = true
  end
  local callback = self.callback
  self.schedule(function() callback(event) end)
end

function CursorAdapter:_consume_line(line)
  line = line:gsub('\r$', '')
  if line == '' then return end
  local ok, value = pcall(self.json_decode, line)
  if ok then self:_emit(self:parse_event(value))
  else self.notify('Invalid Cursor JSONL event', self.levels.WARN) end
end

function CursorAdapter:_drain_stdout_buffer(flush_final)
  while true do
    local newline = self.stdout_buffer:find('\n', 1, true)
    if not newline then break end
    local line = self.stdout_buffer:sub(1, newline - 1)
    self.stdout_buffer = self.stdout_buffer:sub(newline + 1)
    self:_consume_line(line)
  end
  if flush_final and self.stdout_buffer ~= '' then
    local line = self.stdout_buffer
    self.stdout_buffer = ''
    self:_consume_line(line)
  end
end

function CursorAdapter:_exit_message()
  local stderr = self.stderr_buffer:gsub('^%s+', ''):gsub('%s+$', '')
  if is_auth_error(stderr) then return "Cursor is not authenticated; run 'cursor-agent login'" end
  return stderr ~= '' and stderr or ('Cursor exited with code ' .. tostring(self.exit_code))
end

function CursorAdapter:_maybe_finalize()
  if not self.process_exited or not self.stdout_eof or not self.stderr_eof then return end

  if self.exit_code ~= 0 and not self.stopping then
    local message = self:_exit_message()
    if not is_auth_error(message) then
      local opened, reason = self:_open_fallback()
      if opened then message = message .. '; opened interactive Cursor terminal fallback'
      elseif reason then message = message .. '; terminal fallback failed: ' .. reason end
    end
    self:_emit(events.new('error', { provider = 'cursor', message = message }))
  end

  close_pipe(self.stdout)
  close_pipe(self.stderr)
  self.process, self.stdout, self.stderr = nil, nil, nil
  self.callback = nil
  self.stopping = false
end

function CursorAdapter:_consume_stdout(err, data)
  if err then self:_emit(events.new('error', { provider = 'cursor', message = 'Cursor JSONL read failed: ' .. err })) end
  if data then
    self.stdout_buffer = self.stdout_buffer .. data
    self:_drain_stdout_buffer(false)
    return
  end
  self:_drain_stdout_buffer(true)
  self.stdout_eof = true
  close_pipe(self.stdout)
  self:_maybe_finalize()
end

function CursorAdapter:_consume_stderr(err, data)
  if err then self:_emit(events.new('error', { provider = 'cursor', message = 'Cursor stderr read failed: ' .. err })) end
  if data then self.stderr_buffer = self.stderr_buffer .. data; return end
  self.stderr_eof = true
  close_pipe(self.stderr)
  self:_maybe_finalize()
end

function CursorAdapter:prompt(text, callback)
  local started, reason = self:start()
  if not started then
    if callback then callback(events.new('error', { provider = 'cursor', message = reason })) end
    return
  end
  if self.protocol == self.fallback_protocol then
    if callback then
      callback(events.new('error', {
        provider = 'cursor', message = 'Cursor structured prompts are unavailable; use the interactive terminal',
      }))
    end
    return
  end
  if self.process then
    if callback then callback(events.new('error', { provider = 'cursor', message = 'Cursor is already running a prompt' })) end
    return
  end

  self.stdout = self.uv.new_pipe(false)
  self.stderr = self.uv.new_pipe(false)
  self.stdout_buffer = ''
  self.stderr_buffer = ''
  self.callback = callback
  self.stopping = false
  self.process_exited = false
  self.stdout_eof = false
  self.stderr_eof = false
  self.exit_code = nil
  self.error_emitted = false

  local arguments = {
    '--print', '--output-format', 'stream-json', '--stream-partial-output', '--mode', 'ask', '--', text,
  }
  local process
  local spawn_error
  process, spawn_error = self.uv.spawn(self.executable, {
    args = arguments,
    cwd = self.uv.cwd(),
    stdio = { nil, self.stdout, self.stderr },
  }, function(code)
    if process and not process:is_closing() then process:close() end
    self.exit_code = code
    self.process_exited = true
    self:_maybe_finalize()
  end)

  if not process then
    close_pipe(self.stdout)
    close_pipe(self.stderr)
    self.stdout, self.stderr, self.callback = nil, nil, nil
    reason = spawn_error or 'executable not found'
    local opened, fallback_reason = self:_open_fallback()
    if opened then reason = reason .. '; opened interactive Cursor terminal fallback'
    elseif fallback_reason then reason = reason .. '; terminal fallback failed: ' .. fallback_reason end
    if callback then callback(events.new('error', { provider = 'cursor', message = reason })) end
    return
  end

  self.process = process
  self.uv.read_start(self.stdout, function(err, data) self:_consume_stdout(err, data) end)
  self.uv.read_start(self.stderr, function(err, data) self:_consume_stderr(err, data) end)
end

function CursorAdapter:stop()
  self.started = false
  if self.process and not self.process:is_closing() then
    self.stopping = true
    self.process:kill 'sigterm'
  end
end

function CursorAdapter:capabilities()
  return {
    provider = 'cursor',
    protocol = self.protocol,
    fallback_protocol = self.fallback_protocol,
    prompt = self.protocol == 'stream-json',
    stream = self.protocol == 'stream-json',
    terminal = true,
    approvals = false,
  }
end

return CursorAdapter
