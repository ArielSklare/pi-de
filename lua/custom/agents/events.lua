local M = {}

local supported_kinds = {
  started = true,
  text_delta = true,
  tool_started = true,
  tool_output = true,
  approval_required = true,
  completed = true,
  error = true,
}

function M.new(kind, payload)
  if not supported_kinds[kind] then error('Unsupported agent event kind: ' .. tostring(kind), 2) end
  if payload ~= nil and type(payload) ~= 'table' then error('Agent event payload must be a table', 2) end

  return {
    kind = kind,
    payload = payload or {},
  }
end

return M
