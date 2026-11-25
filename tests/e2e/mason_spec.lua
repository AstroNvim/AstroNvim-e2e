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

T["MASON-E2E-01 exercises the public live Mason UI lifecycle"] = function()
  child = helpers.start_ready_child()

  child.lua [[vim.cmd "Mason"]]
  helpers.wait_until(child, "vim.bo.filetype == 'mason'", "Mason UI")

  assert.equals("mason", child.lua_get "vim.bo.filetype")
  child.type_keys "q"
  helpers.wait_until(child, "vim.bo.filetype ~= 'mason'", "Mason UI close")
end

return T
