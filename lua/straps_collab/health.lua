local M = {}

function M.check()
  vim.health.start("straps_collab")
  local ok, registry = pcall(require, "straps.registry")
  if not ok then
    vim.health.error("Straps is missing from runtimepath")
    return
  end
  if registry.get("tool.collab_start") then vim.health.ok("collaboration tools registered")
  else vim.health.warn("collaboration tools are not registered; run setup()") end
  vim.health.info("notebook directory: " .. vim.fn.stdpath("data") .. "/straps/collab")
  vim.health.info("orgmode.nvim is optional")
end

return M
