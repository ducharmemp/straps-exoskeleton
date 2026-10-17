local count = 0
local function check(value, message)
  count = count + 1
  if tonumber(os.getenv('COLLAB_CF')) == count then value = not value end
  assert.is_true(value, message or ('assertion ' .. count))
end

local function drain()
  local done = false
  vim.schedule(function() done = true end)
  assert(vim.wait(1000, function() return done end))
end

local reg, tmp, original_stdpath, initial_buffers, original_notify, errors
local function registry()
  local r = { entries = {}, scope = nil, notices = {} }
  function r.define_default(spec)
    if not r.entries[spec.name] then
      spec.fn = assert(loadstring(spec.source))()
      r.entries[spec.name] = spec
    end
  end
  function r.get(name) return r.entries[name] end
  function r.active_scope() return r.scope end
  function r.set_active_scope(s) local old = r.scope; r.scope = s; return old end
  function r.call(name, ...) return assert(r.entries[name], name).fn(...) end
  r.entries['fn.session_notify'] = { fn = function(target, text)
    r.notices[#r.notices + 1] = { target = target, text = text, scope = r.scope }
  end }
  return r
end
local function target()
  local b = vim.api.nvim_create_buf(false, true)
  vim.b[b].straps_session = true
  return { bufnr = b }
end
local function call(name, input, ctx) return reg.call('tool.collab_' .. name, input or {}, ctx) end
local function opened(name, ctx)
  local out = call(ctx and 'start' or 'open', { name = name or 'example' }, ctx)
  return out:match('path: ([^\n]+)'), tonumber(out:match('bufnr: (%d+)'))
end
local function save(buf)
  vim.api.nvim_buf_call(buf, function() vim.cmd('silent write') end)
end
local function fails(fn, text)
  local ok, err = pcall(fn)
  check(not ok and (not text or tostring(err):find(text, 1, true) ~= nil))
end

before_each(function()
  tmp = vim.fn.tempname()
  vim.fn.mkdir(tmp, 'p')
  original_stdpath = vim.fn.stdpath
  vim.fn.stdpath = function(kind) return kind == 'data' and tmp or original_stdpath(kind) end
  original_notify = vim.notify
  errors = {}
  vim.notify = function(text) errors[#errors + 1] = text end
  initial_buffers = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do initial_buffers[b] = true end
  reg = registry()
  package.loaded['straps.registry'] = reg
  require('straps_collab').register()
end)

after_each(function()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not initial_buffers[b] then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  drain()
  vim.fn.stdpath = original_stdpath
  vim.notify = original_notify
  vim.fn.delete(tmp, 'rf')
end)

describe('collaboration behavior', function()
  it('registers executable entries without replacing custom definitions', function()
    local entry = reg.get('tool.collab_start')
    require('straps_collab').register()
    check(reg.get('tool.collab_start') == entry)
    check(reg.call('fn.system_prompt_layer.collab'):find('Both the human and agents', 1, true) ~= nil)
  end)

  it('creates unique files for repeated names and default timestamps', function()
    local ctx = target()
    local first, buf = opened('same.ORG', ctx)
    drain()
    check(#reg.notices == 0)
    local second = opened('same.ORG', ctx)
    check(first ~= second)
    check(first:match('/same%.org$') ~= nil)
    check(vim.bo[buf].filetype == 'org')
    check(vim.uv.fs_stat(first).type == 'file')
    check(vim.b[buf].straps_collab_watch[tostring(ctx.bufnr)] ~= nil)
    local date = os.date
    os.date = function() return 'constant' end
    local ok, a, b = pcall(function()
      local a = call('start', {}, ctx):match('path: ([^\n]+)')
      local b = call('start', {}, ctx):match('path: ([^\n]+)')
      return a, b
    end)
    os.date = date
    assert(ok, a)
    check(a ~= b)
  end)

  it('preserves existing content and unsaved named buffers', function()
    local path, buf = opened()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'human work' })
    local same, again = opened()
    check(path == same and again == buf)
    check(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == 'human work')
    local missing = tmp .. '/straps/collab/draft.org'
    local draft = vim.fn.bufadd(missing)
    vim.fn.bufload(draft)
    vim.api.nvim_buf_set_lines(draft, 0, -1, false, { 'unsaved draft' })
    local _, got = opened('draft')
    check(got == draft and vim.api.nvim_buf_get_lines(got, 0, -1, false)[1] == 'unsaved draft')
    check(vim.uv.fs_stat(missing) == nil)
  end)

  it('rejects invalid contexts before creating files', function()
    fails(function() call('start') end, 'session context')
    fails(function() call('start', {}, { bufnr = 0 }) end, 'session context')
    fails(function() call('start', {}, { bufnr = '1' }) end, 'session context')
    fails(function() call('start', {}, { bufnr = vim.api.nvim_get_current_buf() }) end, 'session context')
    check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
    reg.entries['fn.session_notify'] = nil
    fails(function() call('start', {}, target()) end, 'notification entry')
    check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
  end)

  it('confines directories and rejects leaf and intermediate symlinks', function()
    fails(function() call('open', { dir = tmp .. '/elsewhere' }) end, 'dir must be under')
    local path = opened('real')
    local dir = tmp .. '/straps/collab'
    assert(vim.uv.fs_symlink(path, dir .. '/link.org'))
    fails(function() opened('link') end, 'regular file')
    assert(vim.uv.fs_symlink(tmp, dir .. '/escape'))
    fails(function() call('open', { dir = dir .. '/escape', name = 'bad' }) end, 'symlink')
    fails(function() call('open', { dir = dir .. '/../outside' }) end, 'dir must be under')
    local nested = call('open', { dir = dir .. '/nested', name = 'safe' })
    check(nested:find('/nested/safe.org', 1, true) ~= nil)
  end)

  it('deduplicates subscriptions, scopes delivery, coalesces saves and follows renames', function()
    local ctx = target()
    local path, buf = opened('watch', ctx)
    local id = call('subscribe', { path = path }, ctx)
    check(id == call('subscribe', { path = path }, ctx))
    reg.scope = 777
    save(buf)
    save(buf)
    drain()
    check(#reg.notices == 1)
    check(reg.notices[1].target == ctx.bufnr and reg.notices[1].scope == ctx.bufnr)
    check(reg.scope == 777)
    check(reg.notices[1].text:find('[straps] collaboration saved:', 1, true) == 1)
    local renamed = path .. '.renamed'
    vim.api.nvim_buf_set_name(buf, renamed)
    save(buf)
    drain()
    check(#reg.notices == 2 and reg.notices[2].text:find(renamed, 1, true) ~= nil)
    check(call('unsubscribe', { path = renamed }, ctx) == 'removed: true')
  end)

  it('suppresses only current self stamps and preserves other subscribers', function()
    local ctx, other = target(), target()
    local path, buf = opened('stamped', ctx)
    call('subscribe', { path = path }, other)
    vim.b[buf].straps_last_writer = { session = ctx.bufnr, tick = vim.api.nvim_buf_get_changedtick(buf) }
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf })
    drain()
    check(#reg.notices == 1 and reg.notices[1].target == other.bufnr)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'human edit' })
    save(buf)
    drain()
    check(#reg.notices == 3)
    call('unsubscribe', { path = path }, ctx)
    save(buf)
    drain()
    check(#reg.notices == 4 and reg.notices[4].target == other.bufnr)
  end)

  it('cancels pending notices and removes autocmds on unsubscribe', function()
    local ctx = target()
    local path, buf = opened('pending', ctx)
    local group = vim.b[buf].straps_collab_watch[tostring(ctx.bufnr)]
    save(buf)
    check(call('unsubscribe', { path = path }, ctx) == 'removed: true')
    drain()
    check(#reg.notices == 0)
    check(vim.b[buf].straps_collab_watch[tostring(ctx.bufnr)] == nil)
    check(not pcall(vim.api.nvim_get_autocmds, { group = group }))
    check(call('unsubscribe', { path = path }, ctx) == 'removed: false')
  end)

  for _, which in ipairs({ 'session', 'notebook' }) do
    for _, unload in ipairs({ false, true }) do
      it('cleans up ' .. which .. (unload and ' unload' or ' wipe'), function()
        local ctx = target()
        local _, buf = opened('cleanup', ctx)
        local group = vim.b[buf].straps_collab_watch[tostring(ctx.bufnr)]
        save(buf)
        vim.api.nvim_buf_delete(which == 'session' and ctx.bufnr or buf, { force = true, unload = unload })
        drain()
        check(#reg.notices == 0)
        check(not pcall(vim.api.nvim_get_autocmds, { group = group }))
      end)
    end
  end

  it('reports hook errors and restores scope', function()
    local _, buf = opened('error', target())
    reg.entries['hook.collab_on_write'].fn = function() error('hook failure') end
    reg.scope = 333
    save(buf)
    drain()
    check(reg.scope == 333)
    check(#errors == 1 and errors[1]:find('hook failure', 1, true) ~= nil)
    check(#reg.notices == 0)
  end)

  it('lists without creating directories or loading files', function()
    check(call('list'):find('(empty)', 1, true) ~= nil)
    check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
    local path, buf = opened('listed')
    vim.api.nvim_buf_delete(buf, { force = true })
    local n = #vim.api.nvim_list_bufs()
    check(call('list'):find('listed.org', 1, true) ~= nil)
    check(#vim.api.nvim_list_bufs() == n)
    check(vim.fn.bufnr(path) == -1)
  end)

  it('opens the notebook for the user and returns its live buffer content', function()
    local current = vim.api.nvim_get_current_win()
    local wins = #vim.api.nvim_list_wins()
    local out = call('start', { name = 'shown' }, target())
    local buf = tonumber(out:match('bufnr: (%d+)'))
    check(#vim.fn.win_findbuf(buf) == 1)
    check(#vim.api.nvim_list_wins() == wins + 1)
    check(vim.fn.winlayout()[1] == 'row')
    check(vim.api.nvim_get_current_win() == current)
    check(out:find('     1\t#+TITLE: shown', 1, true) ~= nil)
    call('open', { name = 'shown' })
    check(#vim.api.nvim_list_wins() == wins + 1)
  end)

  it('reads unsaved notebook edits from the buffer by bufnr or name as a read capability', function()
    local path, buf = opened('live')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'unsaved human line' })
    local out = call('read', { bufnr = buf })
    check(out:find('     1\tunsaved human line', 1, true) ~= nil)
    check(out:find('modified: true', 1, true) ~= nil)
    check(vim.fn.readfile(path)[1] ~= 'unsaved human line')
    check(call('read', { name = 'live' }):find('     1\tunsaved human line', 1, true) ~= nil)
    check(reg.get('tool.collab_read').capability == 'read')
    check(reg.get('tool.collab_read').input_schema.properties.path == nil)
    fails(function() call('read', { bufnr = vim.api.nvim_create_buf(true, false) }) end, 'not a collaboration notebook')
    local outside = vim.fn.bufadd(tmp .. '/outside.org')
    fails(function() call('read', { bufnr = outside }) end, 'dir must be under')
  end)

  it('starts a run in an idle subscribed session on save and leaves running sessions to steering', function()
    local started, running = {}, false
    package.loaded['straps.loop'] = {
      running = function() return running end,
      start = function(b) started[#started + 1] = b end,
    }
    local ctx = target()
    local _, buf = opened('wake', ctx)
    reg.entries['fn.session_notify'].fn = function() return 'append' end
    save(buf)
    drain()
    drain()
    check(#started == 1 and started[1] == ctx.bufnr)
    running = true
    save(buf)
    drain()
    drain()
    check(#started == 1)
    running = false
    reg.entries['fn.session_notify'].fn = function() return 'steer' end
    save(buf)
    drain()
    drain()
    check(#started == 1)
    package.loaded['straps.loop'] = nil
  end)

  it('registers command with explicit context, opens a split, rejects other buffers', function()
    dofile('plugin/straps_collab.lua')
    reg.entries['tool.collab_start'].fn = function() error('no ctx to await on') end
    fails(function() vim.cmd('StrapsCollab refuse') end, 'session buffer')
    check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
    local ctx = target()
    vim.api.nvim_set_current_buf(ctx.bufnr)
    local win = vim.api.nvim_get_current_win()
    local wins = #vim.api.nvim_list_wins()
    vim.cmd('StrapsCollab command')
    local notebook = vim.api.nvim_get_current_buf()
    check(#vim.api.nvim_list_wins() == wins + 1)
    check(vim.fn.winlayout()[1] == 'row')
    check(vim.api.nvim_win_get_buf(win) == ctx.bufnr)
    check(vim.b[notebook].straps_collab_watch[tostring(ctx.bufnr)] ~= nil)
    vim.cmd('close')
  end)
end)

teardown(function() print('COLLAB_ASSERTIONS=' .. count) end)
