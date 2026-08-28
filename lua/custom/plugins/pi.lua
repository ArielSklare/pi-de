-- Pi agent integration
local uv = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn

local M = {}

-- Job ID for pi agent
M.pi_job_id = nil
-- Buffer to store pending suggestions (as virtual text)
M.suggestions = {}
M.suggestion_ns = api.nvim_create_namespace('pi_suggestions')

-- Start pi agent in RPC mode
function M.start_pi()
  if M.pi_job_id then
    -- Already running
    return
  end
  local cmd = { 'pi', '--mode', 'rpc' }
  M.pi_job_id = uv.spawn(cmd, {
    stdio = { nil, uv.new_pipe(false), uv.new_pipe(false) },
  }, function(code, signal)
    M.pi_job_id = nil
    vim.notify('Pi agent exited with code ' .. code, vim.log.levels.INFO)
  end)
  if not M.pi_job_id then
    vim.notify('Failed to start pi agent', vim.log.levels.ERROR)
    return
  end
  -- Setup stdout reading
  local stdout = assert(M.pi_job_id.stdout)
  uv.read_start(stdout, function(err, data)
    assert(not err, err)
    if data then
      -- For simplicity, just print data (assuming it's JSON-RPC response)
      vim.schedule(function()
        vim.notify('Pi RPC: ' .. data, vim.log.levels.DEBUG)
        -- TODO: parse JSON-RPC and handle responses
      end)
    end
  end)
end

-- Stop pi agent
function M.stop_pi()
  if M.pi_job_id then
    uv.process_kill(M.pi_job_id, uv.SIGTERM)
    M.pi_job_id = nil
  end
end

-- Send a JSON-RPC request to pi agent
-- method: string, params: table, callback: function(result)
function M.pi_request(method, params, callback)
  if not M.pi_job_id then
    M.start_pi()
  end
  local request = {
    jsonrpc = "2.0",
    id = math.random(1, 10000),
    method = method,
    params = params,
  }
  local payload = vim.json.encode(request) .. "\n"
  -- Write to stdin of the job
  if M.pi_job_id and M.pi_job_id.stdin then
    uv.write(M.pi_job_id.stdin, payload, function(err)
      if err then
        vim.notify('Failed to write to pi agent: ' .. err, vim.log.levels.ERROR)
      end
    end)
  else
    vim.notify('Pi agent not available', vim.log.levels.ERROR)
  end
  -- TODO: implement response handling via stdout parsing
  -- For now, we just call callback with nil after a timeout
  vim.defer_fn(function()
    callback(nil)
  end, 1000)
end

-- Request pi to suggest edits for given code
function M.suggest_edits(bufnr, callback)
  bufnr = bufnr or api.nvim_get_current_buf()
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local code = table.concat(lines, "\n")
  M.pi_request("text_document/suggestEdits", {
    textDocument = {
      uri = vim.uri_from_bufnr(bufnr),
      languageId = vim.bo[bufnr].filetype,
      version = vim.treesitter and vim.treesitter.get_parser(bufnr) and 0 or 0, -- dummy
    },
    code = code,
  }, function(result)
    if result and result.edit then
      -- Apply edit with highlighting
      M.apply_suggested_edit(bufnr, result.edit, callback)
    else
      vim.notify('No edits suggested by pi', vim.log.levels.INFO)
      callback(nil)
    end
  end)
end

-- Apply suggested edit and highlight changed regions
function M.apply_suggested_edit(bufnr, edit, callback)
  -- For simplicity, we just highlight the changed lines with virtual text
  -- edit.range: {start: {line, character}, end: {line, character}}
  -- edit.newText: string
  local ns = M.suggestion_ns
  -- Clear previous suggestions in this buffer
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local start_line = edit.range.start.line
  local end_line = edit.range['end'].line
  local new_lines = vim.split(edit.newText or "\n", "\n", { plain = true })
  -- Replace the range with new text (actual edit)
  api.nvim_buf_set_text(bufnr, start_line, edit.range.start.character,
                        end_line, edit.range['end'].character,
                        new_lines)
  -- Highlight the changed region with virtual text (background)
  for i = start_line, end_line do
    api.nvim_buf_set_extmark(bufnr, ns, i, 0, {
      hl_group = 'PiSuggestion',
      end_line = i + 1,
      priority = 200,
      virt_text = { { '  ', 'PiSuggestion' } },
      virt_text_pos = 'overlay',
    })
  end
  -- Store suggestion for later acceptance
  table.insert(M.suggestions, { bufnr = bufnr, edit = edit })
  vim.notify('Pi suggestion applied (highlighted)', vim.log.levels.INFO)
  callback(true)
end

-- Accept all pending suggestions (make highlights permanent)
function M.accept_suggestions()
  for _, sug in ipairs(M.suggestions) do
    -- Clear highlights for this suggestion
    api.nvim_buf_clear_namespace(sug.bufnr, M.suggestion_ns, 0, -1)
  end
  M.suggestions = {}
  vim.notify('All pi suggestions accepted', vim.log.levels.INFO)
end

-- Discard pending suggestions and revert changes
function M.discard_suggestions()
  -- TODO: we would need to store original state to revert properly
  vim.notify('Discard not implemented', vim.log.levels.WARN)
end

-- Setup highlights
function M.setup_highlights()
  api.nvim_set_hl(0, 'PiSuggestion', { bg = '#3b4261', fg = '#ffffff' })
end

-- User commands
vim.api.nvim_create_user_command('PiStart', function() M.start_pi() end, {})
vim.api.nvim_create_user_command('PiStop', function() M.stop_pi() end, {})
vim.api.nvim_create_user_command('PiSuggest', function(opts)
  local bufnr = opts.bufnr
  M.suggest_edits(bufnr, function(success)
    if success then
      print('Pi suggestion applied')
    end
  end)
end, { range = true })
vim.api.nvim_create_user_command('PiAccept', function() M.accept_suggestions() end, {})
vim.api.nvim_create_user_command('PiDiscard', function() M.discard_suggestions() end, {})

-- Initialize highlights on load
M.setup_highlights()

return M