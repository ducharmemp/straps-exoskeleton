vim.api.nvim_create_user_command('StrapsCollab', function(opts)
  local target = vim.api.nvim_get_current_buf()
  if vim.b[target].straps_session ~= true then
    error('StrapsCollab: run this command from a straps session buffer')
  end
  require('straps_collab').register()
  local registry = require('straps.registry')
  local prior = registry.set_active_scope(target)
  local ok, result = pcall(require('straps_collab.collab').start,
    { name = opts.args ~= '' and opts.args or nil }, { bufnr = target })
  registry.set_active_scope(prior)
  if not ok then error(result, 0) end
  assert(vim.api.nvim_buf_is_valid(result.bufnr), 'StrapsCollab: start did not return a valid buffer')
  vim.cmd('vsplit')
  vim.api.nvim_win_set_buf(0, result.bufnr)
end, { nargs = '?' })
