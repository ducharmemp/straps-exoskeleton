-- straps-collab: external collaboration layer for straps.nvim
-- Exposes register() so a plugin loader can call require('straps_collab').register().

local M = {}

function M.register()
  require('straps_collab.collab').register()
end

return M
