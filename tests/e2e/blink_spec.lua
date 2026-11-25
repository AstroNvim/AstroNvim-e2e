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

local function start_blink_child()
  child = helpers.start_ready_child()
  child.lua [[require("lazy").load { plugins = { "blink.cmp" } }]]
end

local function open_buffer_completion()
  child.lua [[
    vim.cmd.enew()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "astronvim", "" })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
  ]]
  child.type_keys "i"
  child.type_keys "astr"
  helpers.wait_until(
    child,
    [[
      vim.api.nvim_get_mode().mode == "i"
        and vim.api.nvim_get_current_line() == "astr"
        and next(vim.fn.maparg("<C-Space>", "i", false, true)) ~= nil
    ]],
    "Blink input and mapping"
  )
  child.type_keys "<C-Space>"
  helpers.wait_until(child, "require('blink.cmp').is_menu_visible()", "Blink completion menu")
  helpers.wait_until(child, "#require('blink.cmp').get_items() > 0", "Blink completion items")
end

T["BLINK-E2E-01 accepts a buffer completion through the configured mapping"] = function()
  start_blink_child()
  open_buffer_completion()

  child.type_keys "<C-n>"
  child.type_keys "<CR>"
  helpers.wait_until(
    child,
    "vim.api.nvim_get_current_line() == 'astronvim' and not require('blink.cmp').is_menu_visible()",
    "Blink completion acceptance"
  )
  assert.equals("astronvim", child.lua_get "vim.api.nvim_get_current_line()")
end

T["BLINK-E2E-02 hides a completion through the configured mapping"] = function()
  start_blink_child()
  open_buffer_completion()

  child.type_keys "<C-e>"
  helpers.wait_until(
    child,
    "vim.api.nvim_get_current_line() == 'astr' and not require('blink.cmp').is_menu_visible()",
    "Blink completion hide"
  )
end

return T
