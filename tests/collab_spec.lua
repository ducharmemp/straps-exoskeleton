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

local reg, tmp, original_stdpath, initial_buffers, original_notify, errors, original_ui
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
  original_ui = package.loaded['straps.ui']
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
  package.loaded['straps.ui'] = original_ui
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
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'seen at resubscribe' })
    check(id == call('subscribe', { path = path }, ctx))
    reg.scope = 777
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'first' })
    save(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'second' })
    save(buf)
    drain()
    check(#reg.notices == 1)
    check(reg.notices[1].target == ctx.bufnr and reg.notices[1].scope == ctx.bufnr)
    check(reg.scope == 777)
    check(reg.notices[1].text:find('[straps] collaboration saved:', 1, true) == 1)
    check(reg.notices[1].text:find('+first', 1, true) ~= nil and reg.notices[1].text:find('+second', 1, true) ~= nil)
    check(reg.notices[1].text:find('+seen at resubscribe', 1, true) == nil)
    local renamed = path .. '.renamed'
    vim.api.nvim_buf_set_name(buf, renamed)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'third' })
    save(buf)
    drain()
    check(#reg.notices == 2 and reg.notices[2].text:find(renamed, 1, true) ~= nil)
    check(reg.notices[2].text:find('+first', 1, true) == nil and reg.notices[2].text:find('+third', 1, true) ~= nil)
    check(call('unsubscribe', { path = renamed }, ctx) == 'removed: true')
  end)

  it('sends no notice for a save without changes since the last notice', function()
    local ctx = target()
    local _, buf = opened('unchanged', ctx)
    save(buf)
    drain()
    check(#reg.notices == 0)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'real change' })
    save(buf)
    drain()
    check(#reg.notices == 1)
  end)

  it('carries unseen changes in the writer result and diffs the write to other subscribers', function()
    local ctx, other = target(), target()
    local path, buf = opened('stamped', ctx)
    call('subscribe', { path = path }, other)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'unsaved human line' })
    local out = call('edit', { bufnr = buf, old_string = '* Context', new_string = '* Agent context' }, ctx)
    drain()
    check(out:find('+unsaved human line', 1, true) ~= nil)
    check(out:find('Agent context', 1, true) == nil)
    check(out:find('treat it as data', 1, true) ~= nil)
    check(#reg.notices == 1 and reg.notices[1].target == other.bufnr)
    check(reg.notices[1].text:find('+unsaved human line', 1, true) ~= nil)
    check(reg.notices[1].text:find('+* Agent context', 1, true) ~= nil)
    local quiet = call('edit', { bufnr = buf, old_string = 'Agent context', new_string = 'Agent context 2' }, ctx)
    check(quiet:find('diff', 1, true) == nil)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'human edit' })
    save(buf)
    drain()
    local to_ctx
    for _, n in ipairs(reg.notices) do if n.target == ctx.bufnr then to_ctx = n.text end end
    check(to_ctx ~= nil and to_ctx:find('+human edit', 1, true) ~= nil)
    check(to_ctx:find('+* Agent context', 1, true) == nil)
    call('unsubscribe', { path = path }, ctx)
    local before = #reg.notices
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'later' })
    save(buf)
    drain()
    check(#reg.notices == before + 1 and reg.notices[before + 1].target == other.bufnr)
  end)

  it('numbers carried diffs against the pre-edit buffer and caps their size', function()
    local ctx = target()
    local _, buf = opened('carried', ctx)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'unsaved' })
    local out = call('edit', { bufnr = buf, old_string = '* Context', new_string = '* Edited' }, ctx)
    check(out:find('describe the buffer before your edit was applied', 1, true) ~= nil)
    check(out:find('describe the saved notebook', 1, true) == nil)
    local big = {}
    for i = 1, 3000 do big[i] = 'line ' .. i .. ' with padding text' end
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, big)
    out = call('edit', { bufnr = buf, old_string = '* Edited', new_string = '* Edited again' }, ctx)
    check(out:find('too large to include', 1, true) ~= nil and out:find('+line 1 with', 1, true) == nil)
  end)

  it('drops a captured save when the session reads before delivery', function()
    local ctx = target()
    local _, buf = opened('race', ctx)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'saved line' })
    save(buf)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'unsaved line' })
    call('read', { bufnr = buf }, ctx)
    drain()
    check(#reg.notices == 0)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'after race' })
    save(buf)
    drain()
    local t = reg.notices[1] and reg.notices[1].text or ''
    check(#reg.notices == 1 and t:find('+after race', 1, true) ~= nil)
    check(t:find('+saved line', 1, true) == nil and t:find('+unsaved line', 1, true) == nil)
  end)

  it('resets the baseline on read and open so notices diff against what the session last saw', function()
    local ctx = target()
    local _, buf = opened('rebase', ctx)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'seen by read' })
    call('read', { bufnr = buf }, ctx)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'after read' })
    save(buf)
    drain()
    check(#reg.notices == 1 and reg.notices[1].text:find('+seen by read', 1, true) == nil)
    check(reg.notices[1].text:find('+after read', 1, true) ~= nil)
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'seen by open' })
    call('open', { name = 'rebase' }, ctx)
    save(buf)
    drain()
    check(#reg.notices == 1)
  end)

  it('replaces an oversized diff with a collab_read instruction', function()
    local ctx = target()
    local _, buf = opened('large', ctx)
    local big = {}
    for i = 1, 3000 do big[i] = 'line ' .. i .. ' with padding text' end
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, big)
    save(buf)
    drain()
    check(#reg.notices == 1 and reg.notices[1].text:find('too large to include', 1, true) ~= nil)
    check(reg.notices[1].text:find('+line 1 with', 1, true) == nil)
  end)

  it('cancels pending notices and removes autocmds on unsubscribe', function()
    local ctx = target()
    local path, buf = opened('pending', ctx)
    local group = vim.b[buf].straps_collab_watch[tostring(ctx.bufnr)]
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'pending' })
    save(buf)
    check(call('unsubscribe', { path = path }, ctx) == 'removed: true')
    drain()
    check(#reg.notices == 0)
    check(require('straps_collab.collab')._subs[buf] == nil)
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
        vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'pending change' })
        save(buf)
        vim.api.nvim_buf_delete(which == 'session' and ctx.bufnr or buf, { force = true, unload = unload })
        drain()
        check(#reg.notices == 0)
        check(require('straps_collab.collab')._subs[buf] == nil)
        check(not pcall(vim.api.nvim_get_autocmds, { group = group }))
      end)
    end
  end

  it('reports hook errors and restores scope', function()
    local _, buf = opened('error', target())
    local hook = reg.entries['hook.collab_on_write'].fn
    reg.entries['hook.collab_on_write'].fn = function() error('hook failure') end
    reg.scope = 333
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'missed change' })
    save(buf)
    drain()
    check(reg.scope == 333)
    check(#errors == 1 and errors[1]:find('hook failure', 1, true) ~= nil)
    check(#reg.notices == 0)
    reg.entries['hook.collab_on_write'].fn = hook
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'next change' })
    save(buf)
    drain()
    check(#reg.notices == 1 and reg.notices[1].text:find('+missed change', 1, true) ~= nil)
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

  it('edits and patches the live notebook buffer by bufnr as one undo step', function()
    local writer, other = target(), target()
    local path, buf = opened('changes', writer)
    call('subscribe', { path = path }, other)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'alpha', 'beta', 'gamma' })
    local out = call('edit', { bufnr = buf, old_string = 'beta', new_string = 'BETA' }, writer)
    check(out:find('1 replacement', 1, true) ~= nil)
    check(vim.fn.readfile(path)[2] == 'BETA')
    check(not vim.bo[buf].modified)
    vim.api.nvim_buf_call(buf, function() vim.cmd('silent undo') end)
    check(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[2] == 'beta')
    vim.api.nvim_buf_call(buf, function() vim.cmd('silent redo') end)
    fails(function() call('edit', { bufnr = buf, old_string = 'missing', new_string = 'x' }, writer) end, 'not found')
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'a', 'a' })
    fails(function() call('edit', { bufnr = buf, old_string = 'a', new_string = 'b' }, writer) end, 'matches 2 times')
    check(call('edit', { name = 'changes', old_string = 'a', new_string = 'b', replace_all = true }, writer):find('2 replacements', 1, true) ~= nil)
    check(table.concat(vim.fn.readfile(path), ',') == 'b,b')
    call('patch', { bufnr = buf, hunks = {
      { start_line = 2, end_line = 2, new_text = 'two\nlines', expected_old_text = 'b' },
      { start_line = 1, end_line = 0, new_text = 'first' },
    } }, writer)
    check(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ',') == 'first,b,two,lines')
    check(table.concat(vim.fn.readfile(path), ',') == 'first,b,two,lines')
    fails(function() call('patch', { bufnr = buf, hunks = { { start_line = 1, end_line = 1, new_text = 'x', expected_old_text = 'nope' } } }, writer) end, 'mismatch')
    fails(function() call('patch', { bufnr = buf, hunks = { { start_line = 1, end_line = 2, new_text = 'x' }, { start_line = 2, end_line = 3, new_text = 'y' } } }, writer) end, 'overlap')
    check(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), ',') == 'first,b,two,lines')
    fails(function() call('edit', { bufnr = vim.api.nvim_create_buf(true, false), old_string = 'a', new_string = 'b' }, writer) end, 'not a collaboration notebook')
    check(reg.get('tool.collab_edit').capability == 'edit' and reg.get('tool.collab_patch').capability == 'edit')
    check(reg.get('tool.collab_edit').input_schema.properties.path == nil)
    check(reg.get('tool.collab_patch').input_schema.properties.path == nil)
    drain()
    local to_other = 0
    for _, n in ipairs(reg.notices) do if n.target == other.bufnr then to_other = to_other + 1 end end
    check(to_other >= 1)
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
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'wake 1' })
    save(buf)
    drain()
    drain()
    check(#started == 1 and started[1] == ctx.bufnr)
    running = true
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'wake 2' })
    save(buf)
    drain()
    drain()
    check(#started == 1)
    running = false
    reg.entries['fn.session_notify'].fn = function() return 'steer' end
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'wake 3' })
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

  describe('StrapsCollabOpen', function()
    local collab
    local function notebook(name, lines)
      local result = collab.open({ name = name })
      if lines then
        vim.api.nvim_buf_set_lines(result.bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(result.bufnr, function() vim.cmd('silent noautocmd write') end)
      end
      return result.path, result.bufnr
    end
    local function unload(buf) vim.api.nvim_buf_delete(buf, { force = true }) end
    local function in_session()
      local ctx = target()
      vim.api.nvim_set_current_buf(ctx.bufnr)
      return ctx, vim.api.nvim_get_current_win()
    end
    local function watch(buf, ctx) return (vim.b[buf].straps_collab_watch or {})[tostring(ctx.bufnr)] end
    local function stub_picker(choose)
      local seen = {}
      package.loaded['straps.ui'] = { pick = function(items, opts, cb)
        seen.items, seen.opts = items, opts
        seen.calls = (seen.calls or 0) + 1
        cb(choose and choose(items) or nil)
      end }
      return seen
    end

    before_each(function()
      collab = require('straps_collab.collab')
      dofile('plugin/straps_collab.lua')
    end)

    local function stub_tools()
      for _, name in ipairs({ 'open', 'subscribe', 'start' }) do
        reg.entries['tool.collab_' .. name].fn = function() error('tool called') end
      end
    end

    it('validates context, name and notification entry when resuming directly', function()
      fails(function() collab.resume({ name = 'x' }, { bufnr = 0 }) end, 'session context')
      fails(function() collab.resume({}, target()) end, 'name is required')
      reg.entries['fn.session_notify'] = nil
      fails(function() collab.resume({ name = 'missing' }, target()) end, 'notification entry')
    end)

    it('refuses outside a session buffer without subscribing', function()
      local _, buf = notebook('outside')
      local ctx = target()
      vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
      fails(function() vim.cmd('StrapsCollabOpen outside') end, 'session buffer')
      check(watch(buf, ctx) == nil and next(vim.b[buf].straps_collab_watch or {}) == nil)
    end)

    it('reports a missing notebook without creating the root', function()
      in_session()
      fails(function() vim.cmd('StrapsCollabOpen missing') end, 'no notebook')
      check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
      check(reg.scope == nil)
    end)

    it('runs resume in the session scope and restores the prior scope', function()
      notebook('scoped')
      local ctx = in_session()
      local resume, during = collab.resume, nil
      collab.resume = function(...) during = reg.scope; return resume(...) end
      reg.scope = 'prior'
      vim.cmd('StrapsCollabOpen scoped')
      collab.resume = resume
      check(during == ctx.bufnr)
      check(reg.scope == 'prior')
      vim.cmd('close')
    end)

    it('reopens an unloaded notebook, subscribes the session and opens a split', function()
      local path, buf = notebook('existing', { '#+TITLE: existing', 'kept line' })
      unload(buf)
      stub_tools()
      local ctx, win = in_session()
      local wins = #vim.api.nvim_list_wins()
      vim.cmd('StrapsCollabOpen existing')
      local nb = vim.api.nvim_get_current_buf()
      check(vim.fs.normalize(vim.api.nvim_buf_get_name(nb)) == path)
      check(vim.api.nvim_buf_get_lines(nb, 0, -1, false)[2] == 'kept line')
      check(vim.bo[nb].filetype == 'org')
      check(watch(nb, ctx) ~= nil)
      check(vim.uv.fs_stat(tmp .. '/straps/collab/existing-1.org') == nil)
      check(#vim.api.nvim_list_wins() == wins + 1)
      check(vim.fn.winlayout()[1] == 'row')
      check(vim.api.nvim_win_get_buf(win) == ctx.bufnr)
      local result = collab.resume({ name = 'existing' }, ctx)
      check(result.path == path and result.bufnr == nb and result.created == false)
      check(result.autocmd == watch(nb, ctx))
      vim.cmd('close')
    end)

    it('reuses the subscription and the notebook window on a second resume', function()
      notebook('again')
      local ctx, win = in_session()
      vim.cmd('StrapsCollabOpen again')
      local nb_win = vim.api.nvim_get_current_win()
      local nb = vim.api.nvim_get_current_buf()
      local group = watch(nb, ctx)
      local wins = #vim.api.nvim_list_wins()
      vim.api.nvim_set_current_win(win)
      vim.cmd('StrapsCollabOpen again')
      check(watch(nb, ctx) == group)
      check(#vim.api.nvim_list_wins() == wins)
      check(vim.api.nvim_get_current_win() == nb_win)
      vim.api.nvim_buf_set_lines(nb, -1, -1, false, { 'seen by reopening' })
      vim.api.nvim_buf_call(nb, function() vim.cmd('silent noautocmd write') end)
      vim.api.nvim_set_current_win(win)
      vim.cmd('StrapsCollabOpen again')
      vim.api.nvim_buf_set_lines(nb, -1, -1, false, { 'after reopening' })
      save(nb)
      drain()
      local text = reg.notices[#reg.notices] and reg.notices[#reg.notices].text or ''
      check(text:find('+after reopening', 1, true) ~= nil)
      check(text:find('+seen by reopening', 1, true) == nil)
      vim.cmd('close')
    end)

    it('splits in the current tab when only another tab shows the notebook', function()
      local _, buf = notebook('tabbed')
      local ctx = in_session()
      local home = vim.api.nvim_get_current_tabpage()
      vim.cmd('tabnew')
      local other = vim.api.nvim_get_current_tabpage()
      finally(function()
        if vim.api.nvim_tabpage_is_valid(other) then
          vim.cmd('tabclose ' .. vim.api.nvim_tabpage_get_number(other))
        end
      end)
      vim.api.nvim_win_set_buf(0, buf)
      vim.api.nvim_set_current_tabpage(home)
      local wins = #vim.api.nvim_tabpage_list_wins(home)
      vim.cmd('StrapsCollabOpen tabbed')
      check(vim.api.nvim_get_current_tabpage() == home)
      check(#vim.api.nvim_tabpage_list_wins(home) == wins + 1)
      check(watch(buf, ctx) ~= nil)
      vim.cmd('close')
    end)

    it('keeps unsaved edits and diffs later saves against them', function()
      local _, buf = notebook('unsaved', { 'saved' })
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'unsaved line' })
      local ctx = in_session()
      vim.cmd('StrapsCollabOpen unsaved')
      check(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[2] == 'unsaved line')
      vim.api.nvim_buf_set_lines(buf, -1, -1, false, { 'after resume' })
      save(buf)
      drain()
      check(#reg.notices == 1 and reg.notices[1].target == ctx.bufnr)
      local text = reg.notices[1] and reg.notices[1].text or ''
      check(text:find('+after resume', 1, true) ~= nil)
      check(text:find('+unsaved line', 1, true) == nil)
      vim.cmd('close')
    end)

    it('refuses a loaded notebook whose file is gone', function()
      local path = notebook('deleted')
      vim.uv.fs_unlink(path)
      in_session()
      fails(function() vim.cmd('StrapsCollabOpen deleted') end, 'no file on disk')
    end)

    it('matches loaded buffers by exact name', function()
      vim.fn.mkdir(tmp .. '/straps/collab', 'p')
      vim.fn.bufload(vim.fn.bufadd(tmp .. '/straps/collab/x.org.bak'))
      in_session()
      fails(function() vim.cmd('StrapsCollabOpen x') end, 'no notebook')
    end)

    it('completes resumable notebook names by prefix without creating the root', function()
      check(#collab.complete('') == 0)
      check(vim.uv.fs_stat(tmp .. '/straps/collab') == nil)
      local dir = tmp .. '/straps/collab'
      vim.fn.mkdir(dir, 'p')
      for _, name in ipairs({ 'alpha.org', 'alps.org', 'beta.org', 'a b.org', '..org' }) do vim.fn.writefile({}, dir .. '/' .. name) end
      check(vim.deep_equal(collab.complete('al'), { 'alpha', 'alps' }))
      check(vim.deep_equal(collab.complete(''), { 'alpha', 'alps', 'beta' }))
      check(vim.deep_equal(vim.fn.getcompletion('StrapsCollabOpen al', 'cmdline'), { 'alpha', 'alps' }))
    end)

    it('lists notebooks newest first with titles, dates and subscribers', function()
      local old = notebook('old', { '#+title: Older notes' })
      local new = notebook('new', { 'no title here' })
      vim.uv.fs_utime(old, 1000, 1000)
      vim.uv.fs_utime(new, 2000000000, 2000000000)
      local ctx = target()
      collab.subscribe(old, ctx)
      local items = collab.notebooks()
      check(#items == 2 and items[1].name == 'new' and items[2].name == 'old')
      check(items[2].title == 'Older notes' and items[1].title == '')
      local label = collab.label(items[2])
      check(label:find('Older notes', 1, true) ~= nil)
      check(label:find(os.date('%Y-%m-%d', 1000), 1, true) ~= nil)
      check(label:find('sessions: ' .. ctx.bufnr, 1, true) ~= nil)
      check(collab.label(items[1]):find('sessions', 1, true) == nil)
      check(collab.label({ name = 'same', title = 'same', mtime = 0, sessions = {} }):find('same  ·  same', 1, true) == nil)
    end)

    it('opens the picked notebook for the session captured before the picker', function()
      local _, buf = notebook('picked')
      local ctx, win = in_session()
      vim.cmd('split')
      local elsewhere = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(elsewhere, vim.api.nvim_create_buf(false, true))
      vim.api.nvim_set_current_win(win)
      local seen = stub_picker(function(items)
        vim.api.nvim_set_current_win(elsewhere)
        return items[1]
      end)
      local wins = #vim.api.nvim_list_wins()
      vim.cmd('StrapsCollabOpen')
      drain()
      check(seen.calls == 1 and seen.opts.format_item == collab.label)
      check(watch(buf, ctx) ~= nil)
      check(vim.api.nvim_get_current_buf() == buf)
      check(#vim.api.nvim_list_wins() == wins + 1)
      check(vim.api.nvim_win_get_buf(win) == ctx.bufnr)
      check(vim.fn.win_screenpos(vim.api.nvim_get_current_win())[1] == vim.fn.win_screenpos(win)[1])
      vim.cmd('close')
      vim.api.nvim_win_close(elsewhere, true)
    end)

    it('does nothing when the picker is cancelled', function()
      local _, buf = notebook('cancelled')
      in_session()
      local seen = stub_picker(nil)
      local wins = #vim.api.nvim_list_wins()
      vim.v.errmsg = ''
      vim.cmd('StrapsCollabOpen')
      drain()
      check(seen.calls == 1)
      check(#errors == 0 and vim.v.errmsg == '')
      check(next(vim.b[buf].straps_collab_watch or {}) == nil)
      check(#vim.api.nvim_list_wins() == wins)
    end)

    for _, case in ipairs({ { 'a missing', false }, { 'an unaddressable-only', true } }) do
      it('reports ' .. case[1] .. ' collaboration directory without opening the picker', function()
        if case[2] then
          vim.fn.mkdir(tmp .. '/straps/collab', 'p')
          vim.fn.writefile({}, tmp .. '/straps/collab/a b.org')
        end
        in_session()
        local seen = stub_picker(nil)
        vim.cmd('StrapsCollabOpen')
        check(seen.calls == nil)
        check(errors[#errors] and errors[#errors]:find('no notebooks', 1, true) ~= nil)
      end)
    end

    it('reports a picked notebook that disappeared before the choice', function()
      local path, buf = notebook('vanished')
      unload(buf)
      in_session()
      stub_picker(function(items)
        vim.uv.fs_unlink(path)
        return items[1]
      end)
      vim.cmd('StrapsCollabOpen')
      drain()
      check(errors[#errors] and errors[#errors]:find('no notebook', 1, true) ~= nil)
      check(vim.fn.bufnr(path) == -1 or next(vim.b[vim.fn.bufnr(path)].straps_collab_watch or {}) == nil)
    end)

    it('reports a session buffer wiped before the choice arrives', function()
      local _, buf = notebook('orphan')
      local ctx = in_session()
      stub_picker(function(items)
        vim.api.nvim_set_current_buf(vim.api.nvim_create_buf(false, true))
        vim.api.nvim_buf_delete(ctx.bufnr, { force = true })
        return items[1]
      end)
      vim.cmd('StrapsCollabOpen')
      drain()
      check(errors[#errors] and errors[#errors]:find('is gone', 1, true) ~= nil)
      check(next(vim.b[buf].straps_collab_watch or {}) == nil)
    end)
  end)
end)

teardown(function() print('COLLAB_ASSERTIONS=' .. count) end)
