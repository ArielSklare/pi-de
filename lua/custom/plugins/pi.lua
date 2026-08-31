-- Pi agent RPC integration
local uv = vim.uv or vim.loop
local api = vim.api
local setup = require('custom.plugins.setup')

local M = {
  process = nil,
  stdin = nil,
  stdout = nil,
  stderr = nil,
  next_request_id = 0,
  callbacks = {},
  suggestions = {},
  stopping = false,
}
M.suggestion_ns = api.nvim_create_namespace('pi_suggestions')

local stdout_buffer = ''
local stderr_buffer = ''
local settled_callback = nil

local function handle_message(message)
  if message.type == 'response' and message.id then
    local callback = M.callbacks[tostring(message.id)]
    if callback then
      M.callbacks[tostring(message.id)] = nil
      vim.schedule(function() callback(message.success and message.data or nil, message.error) end)
    end
  elseif message.type == 'agent_settled' and settled_callback then
    local callback = settled_callback
    settled_callback = nil
    vim.schedule(callback)
  end
end

local function consume_stdout(err, data)
  if err then
    vim.schedule(function() vim.notify('Pi RPC read failed: ' .. err, vim.log.levels.ERROR) end)
    return
  end
  if not data then return end
  stdout_buffer = stdout_buffer .. data
  while true do
    local newline = stdout_buffer:find('\n', 1, true)
    if not newline then break end
    local line = stdout_buffer:sub(1, newline - 1):gsub('\r$', '')
    stdout_buffer = stdout_buffer:sub(newline + 1)
    if line ~= '' then
      local ok, message = pcall(vim.json.decode, line)
      if ok then
        handle_message(message)
      else
        vim.schedule(function() vim.notify('Invalid Pi RPC response', vim.log.levels.WARN) end)
      end
    end
  end
end

function M.start_pi()
  if M.process and not M.process:is_closing() then return true end

  local command = setup.get_pi_command('rpc')
  local executable = table.remove(command, 1)
  M.stdin = uv.new_pipe(false)
  M.stdout = uv.new_pipe(false)
  M.stderr = uv.new_pipe(false)
  stderr_buffer = ''

  M.stopping = false
  local process
  process = uv.spawn(executable, {
    args = command,
    cwd = uv.cwd(),
    stdio = { M.stdin, M.stdout, M.stderr },
  }, function(code)
    if M.stdout and not M.stdout:is_closing() then M.stdout:close() end
    if M.stderr and not M.stderr:is_closing() then M.stderr:close() end
    if M.stdin and not M.stdin:is_closing() then M.stdin:close() end
    if process and not process:is_closing() then process:close() end
    M.process, M.stdin, M.stdout, M.stderr = nil, nil, nil, nil
    local was_stopping = M.stopping
    M.stopping = false
    vim.schedule(function()
      if code ~= 0 and not was_stopping then
        local detail = stderr_buffer ~= '' and (': ' .. vim.trim(stderr_buffer)) or ''
        vim.notify('Pi agent exited with code ' .. code .. detail, vim.log.levels.ERROR)
      end
    end)
  end)

  if not process then
    M.process, M.stdin, M.stdout, M.stderr = nil, nil, nil, nil
    vim.notify('Failed to start Pi agent: executable not found', vim.log.levels.ERROR)
    return false
  end

  M.process = process
  uv.read_start(M.stdout, consume_stdout)
  uv.read_start(M.stderr, function(_, data)
    if data then stderr_buffer = stderr_buffer .. data end
  end)
  return true
end

function M.stop_pi()
  if M.process and not M.process:is_closing() then
    M.stopping = true
    M.process:kill('sigterm')
  end
end

function M.pi_request(command_type, params, callback)
  if not M.start_pi() or not M.stdin then
    if callback then callback(nil, 'Pi agent is unavailable') end
    return
  end

  M.next_request_id = M.next_request_id + 1
  local id = tostring(M.next_request_id)
  local request = vim.tbl_extend('force', params or {}, { id = id, type = command_type })
  if callback then M.callbacks[id] = callback end
  M.stdin:write(vim.json.encode(request) .. '\n', function(err)
    if err and callback then
      M.callbacks[id] = nil
      vim.schedule(function() callback(nil, err) end)
    end
  end)
end

local function decode_replacement(text)
  if not text then return nil end
  text = text:gsub('^%s*```[%w_-]*%s*', ''):gsub('%s*```%s*$', '')
  local first, last = text:find('{', 1, true), text:match('.*()}')
  if first and last then text = text:sub(first, last) end
  local ok, value = pcall(vim.json.decode, text)
  if ok and type(value) == 'table' and type(value.newText) == 'string' then return value.newText end
  return nil
end

function M.apply_suggested_edit(bufnr, edit, callback)
  if not api.nvim_buf_is_valid(bufnr) then return callback(nil) end
  local original = api.nvim_buf_get_lines(bufnr, edit.start_line, edit.end_line, false)
  local new_lines = vim.split(edit.newText, '\n', { plain = true })
  if new_lines[#new_lines] == '' then table.remove(new_lines) end
  if #new_lines == 0 then new_lines = { '' } end

  api.nvim_buf_set_lines(bufnr, edit.start_line, edit.end_line, false, new_lines)
  api.nvim_buf_clear_namespace(bufnr, M.suggestion_ns, 0, -1)
  for line = edit.start_line, edit.start_line + #new_lines - 1 do
    api.nvim_buf_set_extmark(bufnr, M.suggestion_ns, line, 0, {
      line_hl_group = 'PiSuggestion',
      priority = 200,
    })
  end
  table.insert(M.suggestions, {
    bufnr = bufnr,
    start_line = edit.start_line,
    new_end_line = edit.start_line + #new_lines,
    original = original,
  })
  vim.notify('Pi suggestion applied and highlighted', vim.log.levels.INFO)
  callback(true)
end

function M.suggest_edits(bufnr, start_line, end_line, callback)
  bufnr = bufnr or api.nvim_get_current_buf()
  start_line = start_line or 0
  end_line = end_line or api.nvim_buf_line_count(bufnr)
  local changedtick = api.nvim_buf_get_changedtick(bufnr)
  local code = table.concat(api.nvim_buf_get_lines(bufnr, start_line, end_line, false), '\n')
  local prompt = table.concat({
    'Edit the following ' .. (vim.bo[bufnr].filetype or '') .. ' code.',
    'Return only valid JSON in exactly this shape: {"newText":"complete replacement text"}.',
    'Do not use Markdown fences or include commentary.',
    'File: ' .. api.nvim_buf_get_name(bufnr),
    '',
    code,
  }, '\n')

  M.pi_request('prompt', { message = prompt }, function(_, err)
    if err then
      vim.notify('Pi request failed: ' .. err, vim.log.levels.ERROR)
      return callback(nil)
    end
    settled_callback = function()
      M.pi_request('get_last_assistant_text', {}, function(data, get_err)
        if get_err then
          vim.notify('Could not read Pi suggestion: ' .. get_err, vim.log.levels.ERROR)
          return callback(nil)
        end
        if api.nvim_buf_get_changedtick(bufnr) ~= changedtick then
          vim.notify('Buffer changed while Pi was working; suggestion was not applied', vim.log.levels.WARN)
          return callback(nil)
        end
        local replacement = decode_replacement(data and data.text)
        if not replacement then
          vim.notify('Pi did not return a valid JSON replacement', vim.log.levels.WARN)
          return callback(nil)
        end
        M.apply_suggested_edit(bufnr, {
          start_line = start_line,
          end_line = end_line,
          newText = replacement,
        }, callback)
      end)
    end
  end)
end

function M.accept_suggestions()
  for _, suggestion in ipairs(M.suggestions) do
    if api.nvim_buf_is_valid(suggestion.bufnr) then
      api.nvim_buf_clear_namespace(suggestion.bufnr, M.suggestion_ns, 0, -1)
    end
  end
  M.suggestions = {}
  vim.notify('All Pi suggestions accepted', vim.log.levels.INFO)
end

function M.discard_suggestions()
  for index = #M.suggestions, 1, -1 do
    local suggestion = M.suggestions[index]
    if api.nvim_buf_is_valid(suggestion.bufnr) then
      api.nvim_buf_set_lines(suggestion.bufnr, suggestion.start_line, suggestion.new_end_line, false, suggestion.original)
      api.nvim_buf_clear_namespace(suggestion.bufnr, M.suggestion_ns, 0, -1)
    end
  end
  M.suggestions = {}
  vim.notify('Pi suggestions discarded', vim.log.levels.INFO)
end

api.nvim_set_hl(0, 'PiSuggestion', { bg = '#3b4261', fg = '#ffffff' })
api.nvim_create_user_command('PiStart', function() M.start_pi() end, {})
api.nvim_create_user_command('PiStop', function() M.stop_pi() end, {})
api.nvim_create_user_command('PiSuggest', function(opts)
  local start_line = opts.range > 0 and (opts.line1 - 1) or 0
  local end_line = opts.range > 0 and opts.line2 or api.nvim_buf_line_count(0)
  M.suggest_edits(opts.buf, start_line, end_line, function() end)
end, { range = true })
api.nvim_create_user_command('PiAccept', function() M.accept_suggestions() end, {})
api.nvim_create_user_command('PiDiscard', function() M.discard_suggestions() end, {})

return M
