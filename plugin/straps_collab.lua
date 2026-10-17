local function session_buffer(command)
  local target = vim.api.nvim_get_current_buf()
  if vim.b[target].straps_session ~= true then
    error(command .. ': run this command from a straps session buffer')
  end
  return target
end

local function in_scope(target, fn, ...)
  local registry = require('straps.registry')
  local prior = registry.set_active_scope(target)
  local ok, result = pcall(fn, ...)
  registry.set_active_scope(prior)
  if not ok then error(result, 0) end
  return result
end

local function window_showing(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then return win end
  end
end

vim.api.nvim_create_user_command('StrapsCollab', function(opts)
  local target = session_buffer('StrapsCollab')
  require('straps_collab').register()
  local result = in_scope(target, require('straps_collab.collab').start,
    { name = opts.args ~= '' and opts.args or nil }, { bufnr = target })
  assert(vim.api.nvim_buf_is_valid(result.bufnr), 'StrapsCollab: start did not return a valid buffer')
  vim.cmd('vsplit')
  vim.api.nvim_win_set_buf(0, result.bufnr)
end, { nargs = '?' })

local function open(target, name)
  require('straps_collab').register()
  local result = in_scope(target, require('straps_collab.collab').resume, { name = name }, { bufnr = target })
  assert(vim.api.nvim_buf_is_valid(result.bufnr), 'StrapsCollabOpen: resume did not return a valid buffer')
  local win = window_showing(result.bufnr)
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd('vsplit')
    vim.api.nvim_win_set_buf(0, result.bufnr)
  end
end

local function choose(target, choice)
  if not choice then return end
  if not vim.api.nvim_buf_is_valid(target) or vim.b[target].straps_session ~= true then
    vim.notify('StrapsCollabOpen: session buffer ' .. target .. ' is gone', vim.log.levels.ERROR)
    return
  end
  local win = window_showing(target)
  if win then vim.api.nvim_set_current_win(win) end
  local ok, err = pcall(open, target, choice.name)
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR) end
end

vim.api.nvim_create_user_command('StrapsCollabOpen', function(opts)
  local target = session_buffer('StrapsCollabOpen')
  if opts.args ~= '' then return open(target, opts.args) end
  local collab = require('straps_collab.collab')
  local items = collab.notebooks()
  if #items == 0 then
    vim.notify('StrapsCollabOpen: no notebooks in ' .. collab.root())
    return
  end
  require('straps.ui').pick(items, { prompt = 'straps: open collab notebook', format_item = collab.label }, function(choice)
    vim.schedule(function() choose(target, choice) end)
  end)
end, {
  nargs = '?',
  complete = function(arglead) return require('straps_collab.collab').complete(arglead) end,
})
