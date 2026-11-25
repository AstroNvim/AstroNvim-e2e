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

T["GIT-04 loads Gitsigns from AstroGitFile without changing editor state"] = function()
  child = helpers.start_ready_child()

  local state = child.lua_get [[(function()
    local buffer = vim.api.nvim_get_current_buf()
    local windows = #vim.api.nvim_list_wins()
    vim.api.nvim_exec_autocmds("User", { pattern = "AstroGitFile", modeline = false })
    local loaded = vim.wait(3000, function() return vim.fn.exists(":Gitsigns") == 2 end, 20)
    return {
      loaded = loaded,
      buffer = buffer,
      current_buffer = vim.api.nvim_get_current_buf(),
      buffer_valid = vim.api.nvim_buf_is_valid(buffer),
      windows = windows,
      current_windows = #vim.api.nvim_list_wins(),
    }
  end)()]]

  assert.is_true(state.loaded)
  assert.is_true(state.buffer_valid)
  assert.equals(state.buffer, state.current_buffer)
  assert.equals(state.windows, state.current_windows)
end

T["SESSION-04 hands the AstroNvim session mapping to Resession without persistence"] = function()
  child = helpers.start_ready_child()

  child.lua [[
    _G.astronvim_test_resession_loads = {}
    package.loaded.resession = {
      load = function(name) table.insert(_G.astronvim_test_resession_loads, name) end,
    }
  ]]
  child.type_keys "<Space>Sl"
  helpers.wait_until(child, "#_G.astronvim_test_resession_loads == 1", "Resession load request")

  assert.same({ "Last Session" }, child.lua_get "_G.astronvim_test_resession_loads")
end

T["TERM-05 maps a float terminal with local options and hides it through user input"] = function()
  child = helpers.start_ready_child()

  local original_buffer = child.lua_get "vim.api.nvim_get_current_buf()"
  child.lua [[vim.api.nvim_feedkeys(" tf", "mx", false)]]
  helpers.wait_until(
    child,
    [[(function()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal" then return true end
      end
      return false
    end)()]],
    "float terminal mapping"
  )
  local opened = child.lua_get [[(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].buftype == "terminal" then
        for _, winid in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_get_buf(winid) == bufnr then
            return {
              buffer = bufnr,
              window = winid,
              current_buffer = vim.api.nvim_get_current_buf(),
              buftype = vim.bo[bufnr].buftype,
              buflisted = vim.bo[bufnr].buflisted,
              filetype = vim.bo[bufnr].filetype,
              foldcolumn = vim.wo[winid].foldcolumn,
              signcolumn = vim.wo[winid].signcolumn,
            }
          end
        end
      end
    end
  end)()]]

  child.lua [[
    vim.cmd.stopinsert()
    vim.api.nvim_feedkeys(vim.keycode "<F7>", "mx", false)
  ]]
  helpers.wait_until(
    child,
    ([[(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(winid) == %d then return false end
      end
      return true
    end)()]]):format(opened.buffer),
    "float terminal hide mapping"
  )
  local hidden = child.lua_get(([[(function()
    local visible = false
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(winid) == %d then visible = true end
    end
    return {
      visible = visible,
      current_buffer = vim.api.nvim_get_current_buf(),
      buffer_valid = vim.api.nvim_buf_is_valid(%d),
      buftype = vim.bo[%d].buftype,
    }
  end)()]]):format(opened.buffer, opened.buffer, opened.buffer))

  local terminal_job = child.lua_get(("vim.b[%d].terminal_job_id"):format(opened.buffer))
  if terminal_job then
    child.lua(([=[vim.fn.jobstop(%d); vim.fn.jobwait({ %d }, 1000)]=]):format(terminal_job, terminal_job))
  end

  assert.equals("terminal", opened.buftype)
  assert.is_false(opened.buflisted)
  assert.equals("toggleterm", opened.filetype)
  assert.same({ foldcolumn = "0", signcolumn = "no" }, {
    foldcolumn = opened.foldcolumn,
    signcolumn = opened.signcolumn,
  })
  assert.equals(original_buffer, hidden.current_buffer)
  assert.is_true(hidden.buffer_valid)
  assert.equals("terminal", hidden.buftype)
  assert.is_false(hidden.visible)
end

T["INDENT-02 hands real file events to the matching buffer only"] = function()
  child = helpers.start_ready_child()

  local state = child.lua_get [[(function()
    local calls = {}
    package.loaded["guess-indent"] = {
      set_from_buffer = function(bufnr, use_defaults, notify)
        table.insert(calls, { buffer = bufnr, use_defaults = use_defaults, notify = notify })
      end,
    }
    local function named_buffer(name)
      local bufnr = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_name(bufnr, vim.fs.joinpath(vim.uv.cwd(), name))
      vim.bo[bufnr].buftype = ""
      return bufnr
    end
    local read_buffer = named_buffer("guess-indent-read.txt")
    local new_file_buffer = named_buffer("guess-indent-new.txt")
    local other_buffer = named_buffer("guess-indent-other.txt")

    vim.api.nvim_exec_autocmds("BufReadPost", astronvim_test_autocmd_options(read_buffer, { modeline = false }))
    local after_read = #calls
    vim.api.nvim_exec_autocmds("BufNewFile", astronvim_test_autocmd_options(new_file_buffer, { modeline = false }))
    local after_registration = #calls
    vim.api.nvim_exec_autocmds("BufWritePost", astronvim_test_autocmd_options(other_buffer, { modeline = false }))
    local after_other_write = #calls
    vim.api.nvim_exec_autocmds("BufWritePost", astronvim_test_autocmd_options(new_file_buffer, { modeline = false }))
    local after_first_write = #calls
    vim.api.nvim_exec_autocmds("BufWritePost", astronvim_test_autocmd_options(new_file_buffer, { modeline = false }))
    local after_second_write = #calls
    return {
      calls = calls,
      read_buffer = read_buffer,
      new_file_buffer = new_file_buffer,
      counts = {
        after_read = after_read,
        after_registration = after_registration,
        after_other_write = after_other_write,
        after_first_write = after_first_write,
        after_second_write = after_second_write,
      },
    }
  end)()]]

  assert.same({
    after_read = 1,
    after_registration = 1,
    after_other_write = 1,
    after_first_write = 2,
    after_second_write = 2,
  }, state.counts)
  assert.equals(2, #state.calls)
  assert.same({ use_defaults = true, notify = true }, {
    use_defaults = state.calls[1].use_defaults,
    notify = state.calls[1].notify,
  })
  assert.same({ use_defaults = true, notify = true }, {
    use_defaults = state.calls[2].use_defaults,
    notify = state.calls[2].notify,
  })
  assert.equals(state.read_buffer, state.calls[1].buffer)
  assert.equals(state.new_file_buffer, state.calls[2].buffer)
end

return T
