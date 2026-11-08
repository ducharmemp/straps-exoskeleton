local M = {}

function M.register()
  require('straps_collab.collab').register()
  return M
end

function M.setup(opts)
  assert(opts == nil or type(opts) == 'table', 'straps_collab: setup options must be a table')
  for key in pairs(opts or {}) do
    vim.notify('straps_collab: unknown option ' .. tostring(key), vim.log.levels.WARN)
  end
  return M.register()
end

return M
