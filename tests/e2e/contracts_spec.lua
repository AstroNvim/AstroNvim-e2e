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

T["CONTRACT-02 preserves intentional global options and comment behavior"] = function()
  child = helpers.start_ready_child()

  local options = child.lua_get [[{
    clipboard = vim.o.clipboard,
    cmdheight = vim.o.cmdheight,
    confirm = vim.o.confirm,
    cursorline = vim.o.cursorline,
    termguicolors = vim.o.termguicolors,
  }]]
  assert.same({
    clipboard = "unnamedplus",
    cmdheight = 0,
    confirm = true,
    cursorline = true,
    termguicolors = true,
  }, options)

  child.lua [[
    vim.cmd "enew!"
    vim.bo.filetype = "lua"
    vim.bo.commentstring = "-- %s"
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
  ]]
  child.type_keys "<Space>/"
  helpers.wait_until(child, "vim.api.nvim_get_current_line() ~= 'local value = 1'", "comment mapping")

  local line = child.lua_get "vim.api.nvim_get_current_line()"
  assert.is_true(line:sub(1, 2) == "--")
  assert.is_true(line:find("local value = 1", 1, true) ~= nil)
end

T["CONTRACT-03 exercises representative public autocmd effects"] = function()
  child = helpers.start_ready_child()

  local yank_highlighted = child.lua_get [[(function()
    local buffer = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_set_current_buf(buffer)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "copied text" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd "normal! yy"
    return #vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, {}) > 0
  end)()]]
  assert.is_true(yank_highlighted)

  child.type_keys "<Space>e"
  helpers.wait_until(
    child,
    [[(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.bo[vim.api.nvim_win_get_buf(winid)].filetype == "neo-tree" then return true end
      end
      return false
    end)()]],
    "Neo-tree for lazygit refresh"
  )

  local project = helpers.fixture_project(child)
  local refreshed_name = "refresh.txt"
  local refreshed_path = vim.fs.joinpath(project, refreshed_name)
  assert.equals(0, vim.fn.writefile({ "refreshed" }, refreshed_path))
  child.lua(([=[
    local terminal = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(terminal, %s)
    vim.api.nvim_exec_autocmds("TermClose", astronvim_test_autocmd_options(terminal, { data = {} }))
  ]=]):format(vim.inspect(vim.fs.joinpath(project, "lazygit"))))

  helpers.wait_until(
    child,
    ([[(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "neo-tree" then
          for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
            if line:find(%s, 1, true) then return true end
          end
        end
      end
      return false
    end)()]]):format(vim.inspect(refreshed_name)),
    "lazygit close refresh"
  )
end

return T
