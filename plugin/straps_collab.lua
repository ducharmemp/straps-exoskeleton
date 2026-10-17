vim.api.nvim_create_user_command('StrapsCollab', function(opts)
  local target = vim.api.nvim_get_current_buf()
  if vim.b[target].straps_session ~= true then
    error('StrapsCollab: run this command from a straps session buffer')
  end
  require('straps_collab').register()
  local registry = require('straps.registry')
  local prior = registry.set_active_scope(target)
  local ok, result = pcall(registry.call, 'tool.collab_start',
    { name = opts.args ~= '' and opts.args or nil }, { bufnr = target })
  registry.set_active_scope(prior)
  if not ok then error(result, 0) end
  local buf = tonumber(result:match('\nbufnr: (%d+)'))
  assert(buf and vim.api.nvim_buf_is_valid(buf), 'StrapsCollab: start did not return a valid buffer')
  vim.cmd('split')
  vim.api.nvim_win_set_buf(0, buf)
end, { nargs = '?' })
