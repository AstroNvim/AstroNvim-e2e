local MiniTest = require "mini.test"
local config = require "config"

local T = MiniTest.new_set()

T["ROOT-01 separates AstroNvim source and e2e harness roots"] = function()
  assert.equals(config.source_root, config.root)
  assert.is_true(config.source_root ~= config.harness_root)
  assert.equals("directory", vim.uv.fs_stat(config.source_root).type)
  assert.equals("directory", vim.uv.fs_stat(config.harness_root).type)
  assert.equals("file", vim.uv.fs_stat(config.fixture_init).type)
  assert.equals("directory", vim.uv.fs_stat(config.fixture_project).type)
  assert.equals("directory", vim.uv.fs_stat(config.screenshots_dir).type)
end

return T
