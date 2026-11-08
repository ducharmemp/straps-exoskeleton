package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

it('setup accepts a table, warns on unknown options and preserves register', function()
  local plugin = require('straps_collab')
  assert.is_false(pcall(plugin.setup, false))
  local register, notify = plugin.register, vim.notify
  local called, messages = 0, {}
  plugin.register = function() called = called + 1; return plugin end
  vim.notify = function(msg) messages[#messages + 1] = msg end
  assert.equals(plugin, plugin.setup({ typo = true }))
  assert.equals(1, called)
  assert.is_truthy(messages[1]:find('unknown option typo', 1, true))
  plugin.register, vim.notify = register, notify
end)

it('health checks registration without creating notebooks', function()
  local saved, health = package.loaded['straps.registry'], vim.health
  local reports = {}
  vim.health = setmetatable({}, { __index = function(_, key) return function(msg) reports[#reports + 1] = key .. ':' .. msg end end })
  package.loaded['straps.registry'] = { get = function() return {} end }
  require('straps_collab.health').check()
  assert.is_truthy(table.concat(reports):find('ok:collaboration tools registered', 1, true))
  package.loaded['straps.registry'], vim.health = saved, health
end)
