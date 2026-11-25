local MiniTest = require "mini.test"
local config = require "config"
local helpers = require "helpers"

local child
local lsp_client_ids
local T = MiniTest.new_set {
  hooks = {
    pre_case = function()
      child = nil
      lsp_client_ids = {}
    end,
    post_case = function()
      if child then
        pcall(
          child.lua,
          ([=[for _, client_id in ipairs(%s) do
            local client = vim.lsp.get_client_by_id(client_id)
            if client then client:stop() end
          end]=]):format(vim.inspect(lsp_client_ids))
        )
        pcall(
          helpers.wait_until,
          child,
          ([[(function()
            for _, client_id in ipairs(%s) do
              if vim.lsp.get_client_by_id(client_id) then return false end
            end
            return true
          end)()]]):format(vim.inspect(lsp_client_ids)),
          "AstroLSP fixture shutdown",
          1000
        )
      end
      helpers.stop_child(child)
      child = nil
    end,
  },
}

T["LSP-07 forwards Format options and applies format-on-save policy"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local project = helpers.fixture_project(child)
  local server = vim.fs.joinpath(config.harness_root, "tests", "fixtures", "lsp_server.lua")
  local format_client_id = child.lua_get(([=[(function()
    local project = %s
    local server = %s
    vim.cmd.edit(vim.fn.fnameescape(project .. "/plain.txt"))
    local nvim = vim.fn.exepath "nvim"
    if nvim == "" then nvim = vim.env.ASTRONVIM_TEST_NVIM or vim.v.progpath end
    vim.lsp.config("astronvim-e2e-format", {
      cmd = { nvim, "--headless", "--clean", "-u", "NONE", "-l", server },
      root_dir = project,
      filetypes = { "text" },
    })
    return vim.lsp.start(vim.lsp.config["astronvim-e2e-format"])
  end)()]=]):format(vim.inspect(project), vim.inspect(server)))
  table.insert(lsp_client_ids, format_client_id)
  helpers.wait_until(child, "vim.fn.exists(':Format') == 2", "registered Format command")

  local state = child.lua_get [[(function()
    local bufnr = vim.api.nvim_get_current_buf()
    local astrolsp = require "astrolsp"
    local calls = {}
    local format_opts = {
      async = true,
      timeout_ms = 87,
      filter = function(format_client) return format_client.name == "fake-formatter" end,
    }

    astrolsp.format_opts = format_opts
    vim.lsp.buf.format = function(options)
      table.insert(calls, {
        async = options.async,
        timeout_ms = options.timeout_ms,
        bufnr = options.bufnr,
        filter_is_forwarded = options.filter == format_opts.filter,
      })
    end
    vim.cmd "Format"

    local function format_on_save_state(buffer_autoformat, global_autoformat)
      vim.b[bufnr].autoformat = buffer_autoformat
      astrolsp.config.formatting.format_on_save.enabled = global_autoformat
      local before = #calls
      vim.api.nvim_exec_autocmds("BufWritePre", astronvim_test_autocmd_options(bufnr, { modeline = false }))
      return { called = #calls > before, options = calls[#calls] }
    end

    return {
      command_options = calls[1],
      buffer_disabled = format_on_save_state(false, true),
      buffer_enabled = format_on_save_state(true, false),
      global_disabled = format_on_save_state(nil, false),
      global_enabled = format_on_save_state(nil, true),
      command_registered = vim.fn.exists(":Format") == 2,
      buffer = bufnr,
    }
  end)()]]

  assert.is_true(state.command_registered)
  assert.same({ async = true, timeout_ms = 87, filter_is_forwarded = true }, state.command_options)
  assert.is_false(state.buffer_disabled.called)
  assert.is_true(state.buffer_enabled.called)
  assert.is_false(state.global_disabled.called)
  assert.is_true(state.global_enabled.called)
  assert.same(
    { async = true, timeout_ms = 87, bufnr = state.buffer, filter_is_forwarded = true },
    state.buffer_enabled.options
  )
  assert.same(
    { async = true, timeout_ms = 87, bufnr = state.buffer, filter_is_forwarded = true },
    state.global_enabled.options
  )
end

T["LSP-10 preserves user on_attach through the public LspAttach path"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local project = helpers.fixture_project(child)
  local server = vim.fs.joinpath(config.harness_root, "tests", "fixtures", "lsp_server.lua")
  local state = child.lua_get(([=[(function()
    local project = %s
    local server = %s
    vim.cmd.edit(vim.fn.fnameescape(project .. "/plain.txt"))
    local bufnr = vim.api.nvim_get_current_buf()
    local astrolsp = require "astrolsp"
    local user_on_attach_calls = {}
    astrolsp.config.on_attach = function(attached_client, attached_bufnr)
      table.insert(user_on_attach_calls, { client = attached_client.name, buffer = attached_bufnr })
    end

    local nvim = vim.fn.exepath "nvim"
    if nvim == "" then nvim = vim.env.ASTRONVIM_TEST_NVIM or vim.v.progpath end
    _G.astronvim_test_lsp_user_on_attach_calls = user_on_attach_calls
    vim.lsp.config("none-ls", {
      cmd = { nvim, "--headless", "--clean", "-u", "NONE", "-l", server },
      root_dir = project,
      filetypes = { "text" },
    })
    local client_id = vim.lsp.start(vim.lsp.config["none-ls"])
    return { client_id = client_id, buffer = bufnr }
  end)()]=]):format(vim.inspect(project), vim.inspect(server)))

  table.insert(lsp_client_ids, state.client_id)
  helpers.wait_until(
    child,
    ([[(function()
      local calls = _G.astronvim_test_lsp_user_on_attach_calls or {}
      return #vim.lsp.get_clients { name = "none-ls", bufnr = %d } == 1 and #calls == 1
    end)()]]):format(state.buffer),
    "none-ls client attachment",
    config.wait_timeout
  )
  state = child.lua_get(([=[(function()
    local bufnr = %d
    local calls = _G.astronvim_test_lsp_user_on_attach_calls or {}
    local clients = vim.lsp.get_clients { name = "none-ls", bufnr = bufnr }
    return {
      attached = #clients == 1 and #calls == 1,
      command_registered = vim.fn.exists(":Format") == 2,
      client_count = #clients,
      user_on_attach_calls = calls,
      buffer = bufnr,
    }
  end)()]=]):format(state.buffer))

  assert.is_true(state.attached)
  assert.is_true(state.command_registered)
  assert.equals(1, state.client_count)
  assert.same({ { client = "none-ls", buffer = state.buffer } }, state.user_on_attach_calls)
end

T["LSP-12 scopes live signature triggers across window and buffer switches"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local state = child.lua_get [[(function()
    local calls = {}
    local attached_buffers = {}
    local client = {
      id = 902,
      name = "signature-test",
      server_capabilities = {
        signatureHelpProvider = { triggerCharacters = { "(" }, retriggerCharacters = { "," } },
      },
      dynamic_capabilities = { get = function() return {} end },
      _get_registrations = function() return {} end,
      supports_method = function(_, method, bufnr)
        return method == "textDocument/signatureHelp" and attached_buffers[bufnr] == true
      end,
    }
    local original_get_client_by_id = vim.lsp.get_client_by_id
    local original_get_clients = vim.lsp.get_clients
    vim.lsp.get_client_by_id = function(id)
      return id == client.id and client or original_get_client_by_id(id)
    end
    vim.lsp.get_clients = function(filter)
      if filter and filter.bufnr then
        return attached_buffers[filter.bufnr] and { client } or {}
      end
      return original_get_clients(filter)
    end
    vim.lsp.buf.signature_help = function() table.insert(calls, vim.api.nvim_get_current_buf()) end

    local function attach(buffer)
      attached_buffers[buffer] = true
      vim.api.nvim_set_current_buf(buffer)
      vim.api.nvim_exec_autocmds(
        "LspAttach",
        astronvim_test_autocmd_options(buffer, { data = { client_id = client.id }, modeline = false })
      )
    end
    local function trigger(buffer, line)
      vim.api.nvim_set_current_buf(buffer)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { line })
      vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
      vim.api.nvim_exec_autocmds("TextChangedI", astronvim_test_autocmd_options(buffer, { modeline = false }))
    end
    local function trigger_buffer_event(event, buffer)
      vim.api.nvim_set_current_buf(buffer)
      vim.api.nvim_exec_autocmds(event, astronvim_test_autocmd_options(buffer, { modeline = false }))
    end
    local function count(buffer)
      local result = 0
      for _, called_buffer in ipairs(calls) do
        if called_buffer == buffer then result = result + 1 end
      end
      return result
    end

    local first = vim.api.nvim_create_buf(true, false)
    local second = vim.api.nvim_create_buf(true, false)
    for _, buffer in ipairs { first, second } do
      vim.b[buffer].signature_help = true
      attach(buffer)
      vim.b[buffer].signature_help_triggerCharacters = { ["("] = true }
      vim.b[buffer].signature_help_retriggerCharacters = { [","] = true }
    end

    trigger(first, "call(x")
    local first_initial = count(first)
    vim.b[second].signature_help = false
    trigger(second, "disabled(x")
    local second_disabled = count(second)
    trigger(first, "call( x")
    local first_retriggered = count(first)

    vim.b[second].signature_help = true
    trigger(second, "switch(x")
    local second_enabled = count(second)
    trigger_buffer_event("InsertLeave", first)
    trigger(second, "switch( x")
    local second_retriggered = count(second)
    trigger_buffer_event("BufDelete", first)
    trigger(second, "switch(  ")

    return {
      first_initial = first_initial,
      first_retriggered = first_retriggered,
      second_disabled = second_disabled,
      second_enabled = second_enabled,
      second_retriggered = second_retriggered,
      second_final = count(second),
    }
  end)()]]

  assert.is_true(state.first_initial > 0)
  assert.equals(0, state.second_disabled)
  assert.is_true(state.first_retriggered > state.first_initial)
  assert.is_true(state.second_enabled > state.second_disabled)
  assert.is_true(state.second_retriggered > state.second_enabled)
  assert.is_true(state.second_final > state.second_retriggered)
end

return T
