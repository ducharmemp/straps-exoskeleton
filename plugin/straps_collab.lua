if vim.g.loaded_straps_collab then return end
vim.g.loaded_straps_collab = true

local function report(err)
  local text = tostring(err):gsub('^straps_collab: ', '')
  vim.notify('straps_collab: ' .. text, vim.log.levels.ERROR)
end

local function session_buffer()
  local target = vim.api.nvim_get_current_buf()
  if vim.b[target].straps_session ~= true then
    report('run this command from a straps session buffer')
    return nil
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
  local target = session_buffer()
  if not target then return end
  local ok, err = pcall(function()
    require('straps_collab').register()
    local result = in_scope(target, require('straps_collab.collab').start,
      { name = opts.args ~= '' and opts.args or nil }, { bufnr = target })
    assert(vim.api.nvim_buf_is_valid(result.bufnr), 'start did not return a valid buffer')
    vim.cmd('vsplit')
    vim.api.nvim_win_set_buf(0, result.bufnr)
  end)
  if not ok then report(err) end
end, { nargs = '?', desc = 'Create a straps collaboration notebook and subscribe this session' })

local function open(target, name)
  require('straps_collab').register()
  local result = in_scope(target, require('straps_collab.collab').resume, { name = name }, { bufnr = target })
  assert(vim.api.nvim_buf_is_valid(result.bufnr), 'resume did not return a valid buffer')
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
    report('session buffer ' .. target .. ' is gone')
    return
  end
  local win = window_showing(target)
  if win then vim.api.nvim_set_current_win(win) end
  local ok, err = pcall(open, target, choice.name)
  if not ok then report(err) end
end

vim.api.nvim_create_user_command('StrapsCollabOpen', function(opts)
  local target = session_buffer()
  if not target then return end
  if opts.args ~= '' then
    local ok, err = pcall(open, target, opts.args)
    if not ok then report(err) end
    return
  end
  local collab = require('straps_collab.collab')
  local ok, items = pcall(collab.notebooks)
  if not ok then return report(items) end
  if #items == 0 then
    vim.notify('straps_collab: no notebooks in ' .. collab.root(), vim.log.levels.INFO)
    return
  end
  require('straps.ui').pick(items, { prompt = 'straps: open collab notebook', format_item = collab.label }, function(choice)
    vim.schedule(function() choose(target, choice) end)
  end)
end, {
  nargs = '?',
  desc = 'Reopen a straps collaboration notebook and subscribe this session',
  complete = function(arglead) return require('straps_collab.collab').complete(arglead) end,
})
