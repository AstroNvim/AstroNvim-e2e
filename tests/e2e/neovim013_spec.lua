local MiniTest = require "mini.test"
local helpers = require "helpers"

local child

local T = MiniTest.new_set {
  hooks = {
    pre_case = function() child = nil end,
    post_case = function()
      helpers.stop_child(child)
      child = nil
    end,
  },
}

T["NVIM-FS-01 exercises native autoread on Neovim 0.13"] = function()
  child = helpers.start_ready_child()

  if child.lua_get "vim.fn.has('nvim-0.13') ~= 1" then
    MiniTest.skip "Neovim 0.12 cannot exercise AstroNvim's checktime fallback through a synthetic public FocusGained event"
  end

  local options = child.lua_get [[{
    autoread = vim.o.autoread,
    diff_algorithm = vim.opt.diffopt:get().algorithm,
    diff_linematch = vim.opt.diffopt:get().linematch,
  }]]
  assert.is_true(options.autoread)
  assert.equals("histogram", options.diff_algorithm)
  assert.equals("60", options.diff_linematch)

  local path = helpers.canonical_path(helpers.fixture_project(child) .. "/native-autoread.txt")
  vim.fn.writefile({ "before" }, path)
  child.lua(([[vim.cmd.edit(%s)]]):format(vim.inspect(path)))
  helpers.wait_until(child, "vim.api.nvim_get_current_line() == 'before'", "native autoread fixture")
  assert.equals("native-autoread.txt", child.lua_get "vim.fn.expand('%:t')")

  vim.fn.writefile({ "after" }, path)
  helpers.wait_until(child, "vim.api.nvim_get_current_line() == 'after'", "native autoread file change")

  if child.lua_get "vim.fn.has('win32') == 1" then
    vim.fn.writefile({ "replaced" }, path)
  else
    local replacement = path .. ".replacement"
    vim.fn.writefile({ "replaced" }, replacement)
    assert.equals(0, vim.fn.rename(replacement, path))
  end
  helpers.wait_until(child, "vim.api.nvim_get_current_line() == 'replaced'", "native autoread replacement")
end

return T
