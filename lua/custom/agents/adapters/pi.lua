local PiAdapter = {}
PiAdapter.__index = PiAdapter

local function close_pipe(pipe)
  if pipe and not pipe:is_closing() then pipe:close() end
end

local function default_dependencies(options)
  local api = options.api or vim.api
  local levels = options.levels or (vim.log and vim.log.levels) or {}
  return {
    api = api,
    uv = options.uv or vim.uv or vim.loop,
    setup = options.setup or require 'custom.plugins.setup',
    json_decode = options.json_decode or vim.json.decode,
    json_encode = options.json_encode or vim.json.encode,
    schedule = options.schedule or vim.schedule,
    notify = options.notify or vim.notify,
    levels = levels,
    split = options.split or function(value) return vim.split(value, '\n', { plain = true }) end,
    trim = options.trim or vim.trim,
    get_filetype = options.get_filetype or function(bufnr) return vim.bo[bufnr].filetype or '' end,
  }
end

function PiAdapter.new(options)
  options = options or {}
  local dependencies = default_dependencies(options)
  local self = setmetatable({
    api = dependencies.api,
    uv = dependencies.uv,
    setup = dependencies.setup,
    json_decode = dependencies.json_decode,
    json_encode = dependencies.json_encode,
    schedule = dependencies.schedule,
    notify = dependencies.notify,
    levels = dependencies.levels,
    split = dependencies.split,
    trim = dependencies.trim,
    get_filetype = dependencies.get_filetype,
    process = nil,
    stdin = nil,
    stdout = nil,
    stderr = nil,
    next_request_id = 0,
    callbacks = {},
    suggestions = {},
    stopping = false,
    stdout_buffer = '',
    stderr_buffer = '',
    settled_callback = nil,
  }, PiAdapter)

  self.suggestion_ns = self.api.nvim_create_namespace 'pi_suggestions'
  if self.api.nvim_set_hl then
    self.api.nvim_set_hl(0, 'PiSuggestion', { bg = '#3b4261', fg = '#ffffff' })
  end
  return self
end

function PiAdapter:_handle_message(message)
  if message.type == 'response' and message.id then
    local id = tostring(message.id)
    local callback = self.callbacks[id]
    if callback then
      self.callbacks[id] = nil
      self.schedule(function() callback(message.success and message.data or nil, message.error) end)
    end
  elseif message.type == 'agent_settled' and self.settled_callback then
    local callback = self.settled_callback
    self.settled_callback = nil
    self.schedule(callback)
  end
end

function PiAdapter:_consume_stdout(err, data)
  if err then
    self.schedule(function() self.notify('Pi RPC read failed: ' .. err, self.levels.ERROR) end)
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
      local ok, message = pcall(self.json_decode, line)
      if ok then
        self:_handle_message(message)
      else
        self.schedule(function() self.notify('Invalid Pi RPC response', self.levels.WARN) end)
      end
    end
  end
end

function PiAdapter:start()
  if self.process and not self.process:is_closing() then return true, nil end

  local command = self.setup.get_pi_command 'rpc'
  local executable = table.remove(command, 1)
  self.stdin = self.uv.new_pipe(false)
  self.stdout = self.uv.new_pipe(false)
  self.stderr = self.uv.new_pipe(false)
  self.stderr_buffer = ''
  self.stopping = false

  local process
  local spawn_error
  process, spawn_error = self.uv.spawn(executable, {
    args = command,
    cwd = self.uv.cwd(),
    stdio = { self.stdin, self.stdout, self.stderr },
  }, function(code)
    if self.stdout and not self.stdout:is_closing() then self.stdout:close() end
    if self.stderr and not self.stderr:is_closing() then self.stderr:close() end
    if self.stdin and not self.stdin:is_closing() then self.stdin:close() end
    if process and not process:is_closing() then process:close() end
    self.process, self.stdin, self.stdout, self.stderr = nil, nil, nil, nil
    local was_stopping = self.stopping
    self.stopping = false
    self.schedule(function()
      if code ~= 0 and not was_stopping then
        local detail = self.stderr_buffer ~= '' and (': ' .. self.trim(self.stderr_buffer)) or ''
        self.notify('Pi agent exited with code ' .. code .. detail, self.levels.ERROR)
      end
    end)
  end)

  if not process then
    close_pipe(self.stdin)
    close_pipe(self.stdout)
    close_pipe(self.stderr)
    self.process, self.stdin, self.stdout, self.stderr = nil, nil, nil, nil
    local reason = spawn_error or 'executable not found'
    self.notify('Failed to start Pi agent: ' .. reason, self.levels.ERROR)
    return false, reason
  end

  self.process = process
  self.uv.read_start(self.stdout, function(err, data) self:_consume_stdout(err, data) end)
  self.uv.read_start(self.stderr, function(_, data)
    if data then self.stderr_buffer = self.stderr_buffer .. data end
  end)
  return true, nil
end

function PiAdapter:stop()
  if self.process and not self.process:is_closing() then
    self.stopping = true
    self.process:kill 'sigterm'
  end
end

function PiAdapter:request(command_type, params, callback)
  local started = self:start()
  if not started or not self.stdin then
    if callback then callback(nil, 'Pi agent is unavailable') end
    return
  end

  self.next_request_id = self.next_request_id + 1
  local id = tostring(self.next_request_id)
  local request = {}
  for key, value in pairs(params or {}) do request[key] = value end
  request.id = id
  request.type = command_type
  if callback then self.callbacks[id] = callback end
  self.stdin:write(self.json_encode(request) .. '\n', function(err)
    if err and callback then
      self.callbacks[id] = nil
      self.schedule(function() callback(nil, err) end)
    end
  end)
end

function PiAdapter:prompt(text, callback)
  self:request('prompt', { message = text }, callback)
end

function PiAdapter:_decode_replacement(text)
  if not text then return nil end
  text = text:gsub('^%s*```[%w_-]*%s*', ''):gsub('%s*```%s*$', '')
  local first, last = text:find('{', 1, true), text:match('.*()}')
  if first and last then text = text:sub(first, last) end
  local ok, value = pcall(self.json_decode, text)
  if ok and type(value) == 'table' and type(value.newText) == 'string' then return value.newText end
  return nil
end

function PiAdapter:_apply_suggested_edit(bufnr, edit, callback)
  if not self.api.nvim_buf_is_valid(bufnr) then
    if callback then callback(nil) end
    return
  end
  local original = self.api.nvim_buf_get_lines(bufnr, edit.start_line, edit.end_line, false)
  local new_lines = self.split(edit.newText)
  if new_lines[#new_lines] == '' then table.remove(new_lines) end
  if #new_lines == 0 then new_lines = { '' } end

  self.api.nvim_buf_set_lines(bufnr, edit.start_line, edit.end_line, false, new_lines)
  self.api.nvim_buf_clear_namespace(bufnr, self.suggestion_ns, 0, -1)
  for line = edit.start_line, edit.start_line + #new_lines - 1 do
    self.api.nvim_buf_set_extmark(bufnr, self.suggestion_ns, line, 0, {
      line_hl_group = 'PiSuggestion',
      priority = 200,
    })
  end
  table.insert(self.suggestions, {
    bufnr = bufnr,
    start_line = edit.start_line,
    new_end_line = edit.start_line + #new_lines,
    original = original,
  })
  self.notify('Pi suggestion applied and highlighted', self.levels.INFO)
  if callback then callback(true) end
end

function PiAdapter:suggest_edits(bufnr, start_line, end_line, callback)
  callback = callback or function() end
  bufnr = bufnr or self.api.nvim_get_current_buf()
  start_line = start_line or 0
  end_line = end_line or self.api.nvim_buf_line_count(bufnr)
  local changedtick = self.api.nvim_buf_get_changedtick(bufnr)
  local code = table.concat(self.api.nvim_buf_get_lines(bufnr, start_line, end_line, false), '\n')
  local prompt = table.concat({
    'Edit the following ' .. self.get_filetype(bufnr) .. ' code.',
    'Return only valid JSON in exactly this shape: {"newText":"complete replacement text"}.',
    'Do not use Markdown fences or include commentary.',
    'File: ' .. self.api.nvim_buf_get_name(bufnr),
    '',
    code,
  }, '\n')

  self:request('prompt', { message = prompt }, function(_, err)
    if err then
      self.notify('Pi request failed: ' .. err, self.levels.ERROR)
      return callback(nil)
    end
    self.settled_callback = function()
      self:request('get_last_assistant_text', {}, function(data, get_err)
        if get_err then
          self.notify('Could not read Pi suggestion: ' .. get_err, self.levels.ERROR)
          return callback(nil)
        end
        if self.api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
          self.notify('Buffer changed while Pi was working; suggestion was not applied', self.levels.WARN)
          return callback(nil)
        end
        local replacement = self:_decode_replacement(data and data.text)
        if not replacement then
          self.notify('Pi did not return a valid JSON replacement', self.levels.WARN)
          return callback(nil)
        end
        self:_apply_suggested_edit(bufnr, {
          start_line = start_line,
          end_line = end_line,
          newText = replacement,
        }, callback)
      end)
    end
  end)
end

function PiAdapter:accept_suggestions()
  for _, suggestion in ipairs(self.suggestions) do
    if self.api.nvim_buf_is_valid(suggestion.bufnr) then
      self.api.nvim_buf_clear_namespace(suggestion.bufnr, self.suggestion_ns, 0, -1)
    end
  end
  self.suggestions = {}
  self.notify('All Pi suggestions accepted', self.levels.INFO)
end

function PiAdapter:discard_suggestions()
  for index = #self.suggestions, 1, -1 do
    local suggestion = self.suggestions[index]
    if self.api.nvim_buf_is_valid(suggestion.bufnr) then
      self.api.nvim_buf_set_lines(
        suggestion.bufnr,
        suggestion.start_line,
        suggestion.new_end_line,
        false,
        suggestion.original
      )
      self.api.nvim_buf_clear_namespace(suggestion.bufnr, self.suggestion_ns, 0, -1)
    end
  end
  self.suggestions = {}
  self.notify('Pi suggestions discarded', self.levels.INFO)
end

function PiAdapter:capabilities()
  return {
    provider = 'pi',
    protocol = 'rpc',
    prompt = true,
    suggestions = true,
  }
end

return PiAdapter
