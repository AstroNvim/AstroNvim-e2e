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

T["BEHAVIOR-01 changes buffer, window, and layout state with production mappings"] = function()
  child = helpers.start_ready_child()

  child.lua 'vim.cmd.edit "plain.txt"'
  local initial_buffer = child.lua_get "vim.api.nvim_get_current_buf()"
  child.type_keys "<Space>n"
  helpers.wait_until(child, "vim.api.nvim_get_current_buf() ~= " .. initial_buffer, "new buffer mapping")

  child.type_keys "|"
  helpers.wait_until(child, "#vim.api.nvim_list_wins() == 2", "vertical split mapping")
  child.type_keys "\\"
  helpers.wait_until(child, "#vim.api.nvim_list_wins() == 3", "horizontal split mapping")

  local state = child.lua_get(([=[
    (function()
      local current_buffer = vim.api.nvim_get_current_buf()
      local rows, columns, current_buffer_in_all_windows = {}, {}, true
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local position = vim.api.nvim_win_get_position(winid)
        rows[position[1]] = true
        columns[position[2]] = true
        current_buffer_in_all_windows = current_buffer_in_all_windows
          and vim.api.nvim_win_get_buf(winid) == current_buffer
      end
      return {
        buffer_changed = current_buffer ~= %d,
        windows = #vim.api.nvim_list_wins(),
        has_horizontal_split = vim.tbl_count(rows) > 1,
        has_vertical_split = vim.tbl_count(columns) > 1,
        current_buffer_in_all_windows = current_buffer_in_all_windows,
      }
    end)()
  ]=]):format(initial_buffer))

  assert.is_true(state.buffer_changed)
  assert.equals(3, state.windows)
  assert.is_true(state.has_horizontal_split)
  assert.is_true(state.has_vertical_split)
  assert.is_true(state.current_buffer_in_all_windows)
end

T["BEHAVIOR-02 navigates tabs with production mappings"] = function()
  child = helpers.start_ready_child()

  child.lua "vim.cmd.tabnew()"
  child.lua "vim.cmd.tabnew()"
  local tabs = child.lua_get "vim.api.nvim_list_tabpages()"
  assert.equals(3, #tabs)
  assert.is_true(tabs[1] ~= tabs[2] and tabs[2] ~= tabs[3] and tabs[1] ~= tabs[3])

  child.lua "vim.cmd.tabfirst()"
  local first_tab = child.lua_get "vim.api.nvim_get_current_tabpage()"
  assert.equals(tabs[1], first_tab)

  child.type_keys "]t"
  helpers.wait_until(child, "vim.api.nvim_get_current_tabpage() == " .. tabs[2], "next tab mapping")
  assert.equals(tabs[2], child.lua_get "vim.api.nvim_get_current_tabpage()")

  child.type_keys "[t"
  helpers.wait_until(child, "vim.api.nvim_get_current_tabpage() == " .. first_tab, "previous tab mapping")
  assert.equals(first_tab, child.lua_get "vim.api.nvim_get_current_tabpage()")
end

T["BEHAVIOR-03 toggles live UI state with production mappings"] = function()
  child = helpers.start_ready_child()

  assert.is_false(child.lua_get "vim.wo.wrap")
  child.type_keys "<Space>uw"
  helpers.wait_until(child, "vim.wo.wrap == true", "wrap toggle")

  assert.equals(2, child.lua_get "vim.o.showtabline")
  child.type_keys "<Space>ut"
  helpers.wait_until(child, "vim.o.showtabline == 0", "tabline toggle")

  assert.equals(3, child.lua_get "vim.o.laststatus")
  child.type_keys "<Space>ul"
  helpers.wait_until(child, "vim.o.laststatus == 0", "statusline toggle")

  assert.equals("yes", child.lua_get "vim.wo.signcolumn")
  child.type_keys "<Space>ug"
  helpers.wait_until(child, "vim.wo.signcolumn == 'auto'", "signcolumn toggle")

  assert.same(
    { number = true, relativenumber = true },
    child.lua_get "{ number = vim.wo.number, relativenumber = vim.wo.relativenumber }"
  )
  child.type_keys "<Space>un"
  helpers.wait_until(child, "not vim.wo.number and vim.wo.relativenumber", "number mode toggle")

  assert.is_true(child.lua_get "vim.diagnostic.is_enabled()")
  child.type_keys "<Space>ud"
  helpers.wait_until(child, "not vim.diagnostic.is_enabled()", "diagnostics toggle")
end

return T
