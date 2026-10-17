local core = os.getenv('STRAPS_TEST_RTP')
if not core or core == '' then
  describe('straps integration', function()
    pending('requires STRAPS_TEST_RTP pointing to a straps checkout')
  end)
  return
end

vim.opt.rtp:prepend(core)
package.path = core .. '/lua/?.lua;' .. core .. '/lua/?/init.lua;' .. package.path
require('straps').setup({ render = false })
require('straps_collab').register()
local registry = require('straps.registry')
local count = 0
local function check(value)
  count = count + 1
  if tonumber(os.getenv('COLLAB_CF')) == count then value = not value end
  assert.is_true(value, 'integration assertion ' .. count)
end
local function drain()
  local done = false
  vim.schedule(function() vim.schedule(function() done = true end) end)
  assert(vim.wait(1000, function() return done end))
end
local function text(buf) return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n') end

describe('actual straps registry and notification integration', function()
  it('delivers idle notices, restores scope and honors real writer stamps', function()
    local tmp = vim.fn.tempname()
    local original = vim.fn.stdpath
    vim.fn.stdpath = function(kind) return kind == 'data' and tmp or original(kind) end
    local ctx = { bufnr = vim.api.nvim_create_buf(false, true) }
    vim.b[ctx.bufnr].straps_session = true
    registry.ensure_scope(ctx.bufnr)
    local old = registry.set_active_scope(ctx.bufnr)
    local ok, err = pcall(function()
      local out = registry.call('tool.collab_start', { name = 'real-core' }, ctx)
      local buf = tonumber(out:match('bufnr: (%d+)'))
      local path = out:match('path: ([^\n]+)')
      registry.call('fn.mark_seen', ctx.bufnr, buf, true)
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = buf })
      drain()
      check(not text(ctx.bufnr):find('collaboration saved:', 1, true))
      vim.api.nvim_buf_set_lines(buf, 0, 0, false, { 'human edit' })
      vim.api.nvim_buf_call(buf, function() vim.cmd('silent write') end)
      drain()
      check(text(ctx.bufnr):find('collaboration saved: ' .. path, 1, true) ~= nil)
      check(not require('straps.loop').running(ctx.bufnr))
      check(registry.active_scope() == ctx.bufnr)
      registry.call('tool.collab_unsubscribe', { path = path }, ctx)
      vim.api.nvim_buf_delete(buf, { force = true })
    end)
    registry.set_active_scope(old)
    vim.api.nvim_buf_delete(ctx.bufnr, { force = true })
    vim.fn.stdpath = original
    vim.fn.delete(tmp, 'rf')
    assert(ok, err)
  end)
end)
