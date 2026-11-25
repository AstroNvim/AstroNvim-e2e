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

T["LSP-07 forwards Format options and applies format-on-save policy"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local state = child.lua_get [[(function()
    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    local astrolsp = require "astrolsp"
    local astrolsp_autocmds = require "astronvim.plugins._astrolsp_autocmds"
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
    astrolsp_autocmds.opts.commands.Format[1]()

    local format_on_save = astrolsp_autocmds.opts.autocmds.lsp_auto_format[1].callback
    local function format_on_save_state(buffer_autoformat, global_autoformat)
      vim.b[bufnr].autoformat = buffer_autoformat
      astrolsp.config.formatting.format_on_save.enabled = global_autoformat
      local before = #calls
      format_on_save(nil, nil, bufnr)
      return { called = #calls > before, options = calls[#calls] }
    end

    return {
      command_options = calls[1],
      buffer_disabled = format_on_save_state(false, true),
      buffer_enabled = format_on_save_state(true, false),
      global_disabled = format_on_save_state(nil, false),
      global_enabled = format_on_save_state(nil, true),
      buffer = bufnr,
    }
  end)()]]

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

T["LSP-10 gives a fake none-ls client one AstroLSP attach path"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local state = child.lua_get [[(function()
    vim.cmd.enew()
    local bufnr = vim.api.nvim_get_current_buf()
    local astrolsp = require "astrolsp"
    local client = {
      id = 902,
      name = "none-ls",
      server_capabilities = {},
      supports_method = function() return false end,
    }
    local user_on_attach_calls = {}
    local configured_on_attach = astrolsp.config.on_attach
    local user_on_attach = function(attached_client, attached_bufnr)
      table.insert(user_on_attach_calls, { client = attached_client.name, buffer = attached_bufnr })
    end
    local none_ls_spec = require "astronvim.plugins.none-ls"
    local none_ls_astrolsp
    for _, spec in ipairs(none_ls_spec.specs) do
      if spec[1] == "AstroNvim/astrolsp" then
        none_ls_astrolsp = spec
        break
      end
    end
    local integration_options = { mappings = { n = {} }, on_attach = user_on_attach }
    none_ls_astrolsp.opts(nil, integration_options)

    vim.lsp.get_client_by_id = function(id) return id == client.id and client or nil end
    vim.lsp.get_clients = function() return {} end
    astrolsp.config.on_attach = integration_options.on_attach
    vim.api.nvim_exec_autocmds(
      "LspAttach",
      astronvim_test_autocmd_options(bufnr, { data = { client_id = client.id } })
    )

    return {
      configured_on_attach_is_nil = configured_on_attach == nil,
      integration_preserved_on_attach = integration_options.on_attach == user_on_attach,
      null_ls_mapping = integration_options.mappings.n["<Leader>lI"][1],
      user_on_attach_calls = user_on_attach_calls,
      attached_client = astrolsp.attached_clients[client.id] == client,
      astro_attach_handlers = #vim.api.nvim_get_autocmds { group = "astrolsp_on_attach", event = "LspAttach" },
      buffer = bufnr,
    }
  end)()]]

  assert.is_true(state.configured_on_attach_is_nil)
  assert.is_true(state.integration_preserved_on_attach)
  assert.equals("<Cmd>NullLsInfo<CR>", state.null_ls_mapping)
  assert.same({ { client = "none-ls", buffer = state.buffer } }, state.user_on_attach_calls)
  assert.is_true(state.attached_client)
  assert.equals(1, state.astro_attach_handlers)
end

T["LSP-12 scopes live signature triggers across window and buffer switches"] = function()
  child = helpers.start_ready_child { "astrolsp" }

  local state = child.lua_get [[(function()
    local calls = {}
    local astrolsp_autocmds = require "astronvim.plugins._astrolsp_autocmds"
    local signature_help = astrolsp_autocmds.opts.autocmds.lsp_auto_signature_help
    local changed = signature_help[1].callback
    local insert_leave = signature_help[2].callback
    local buffer_delete = signature_help[3].callback
    vim.lsp.buf.signature_help = function() table.insert(calls, vim.api.nvim_get_current_buf()) end

    local function trigger(buffer, line)
      vim.api.nvim_set_current_buf(buffer)
      vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { line })
      vim.api.nvim_win_set_cursor(0, { 1, #line - 1 })
      changed { buf = buffer }
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
    insert_leave { buf = first }
    trigger(second, "switch( x")
    local second_retriggered = count(second)
    buffer_delete { buf = first }
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
