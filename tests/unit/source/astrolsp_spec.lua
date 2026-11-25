local MiniTest = require "mini.test"
local unit_helpers = require "unit_helpers"

local T = MiniTest.new_set()

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then return true end
  end
  return false
end

local function assert_file_operation(calls, index, operation, argument)
  local call = calls[index]
  assert.is_not_nil(call)
  assert.equals(operation, call.operation)
  assert.same(argument, call.argument)
end

local function operation_arguments(calls, operation)
  local arguments = {}
  for _, call in ipairs(calls) do
    if call.operation == operation then table.insert(arguments, call.argument) end
  end
  return arguments
end

local function assert_operation_arguments(calls, operation, expected)
  assert.same(expected, operation_arguments(calls, operation))
end

local function with_astrolsp_spec(options, callback)
  options = options or {}
  local calls = {}
  local metadata = {
    capabilities = options.capabilities or { sentinel = "generated capabilities" },
  }
  local buffers = options.buffers or {}
  local valid_buffers = options.valid_buffers or {}
  local names = options.names or {}
  local operations = options.operations or {}
  local file_operations = {}
  for _, name in ipairs {
    "willCreateFiles",
    "didCreateFiles",
    "willDeleteFiles",
    "didDeleteFiles",
    "willRenameFiles",
    "didRenameFiles",
  } do
    file_operations[name] = function(argument)
      table.insert(calls, { operation = name, argument = argument })
      if operations[name] then return operations[name](argument) end
    end
  end

  return unit_helpers.with_module("astronvim.plugins._astrolsp", {
    loaded = {
      ["astrocore.buffer"] = {
        is_valid = function(bufnr) return valid_buffers[bufnr] == true end,
      },
      ["astrolsp.file_operations"] = file_operations,
      ["neo-tree.events"] = options.neo_tree_events or {
        BEFORE_FILE_ADD = "before_file_add",
        FILE_ADDED = "file_added",
        BEFORE_FILE_DELETE = "before_file_delete",
        FILE_DELETED = "file_deleted",
        BEFORE_FILE_MOVE = "before_file_move",
        BEFORE_FILE_RENAME = "before_file_rename",
        FILE_MOVED = "file_moved",
        FILE_RENAMED = "file_renamed",
      },
    },
    replace_vim = { b = true },
    vim = {
      api = {
        nvim_buf_get_name = function(bufnr) return names[bufnr] end,
      },
      b = buffers,
      lsp = {
        protocol = {
          make_client_capabilities = function() return metadata.capabilities end,
        },
      },
      uv = {
        fs_stat = options.fs_stat or function() return nil end,
      },
    },
  }, function(spec) return callback(spec, calls, buffers, metadata) end)
end

local function file_events(spec) return spec.specs[1].opts.autocmds.astrolsp_createfiles_events end

T["LSP-02 reports valid new and URI buffers around a write"] = function()
  with_astrolsp_spec({
    buffers = { [1] = {}, [2] = {}, [3] = {} },
    valid_buffers = { [1] = true, [2] = false, [3] = true },
    names = {
      [1] = "/workspace/new.lua",
      [2] = "/workspace/invalid.lua",
      [3] = "zipfile:///workspace/archive.zip::new.lua",
    },
    fs_stat = function() return nil end,
  }, function(spec, calls, buffers)
    local will_create, did_create = unpack(file_events(spec))

    will_create.callback { buf = 1 }
    assert.equals("/workspace/new.lua", buffers[1].new_file)
    did_create.callback { buf = 1 }
    assert.equals(false, buffers[1].new_file)

    buffers[2].new_file = "stale"
    will_create.callback { buf = 2 }
    did_create.callback { buf = 2 }
    assert.equals(false, buffers[2].new_file)

    will_create.callback { buf = 3 }
    did_create.callback { buf = 3 }
    assert.equals(false, buffers[3].new_file)

    assert_file_operation(calls, 1, "willCreateFiles", "/workspace/new.lua")
    assert_file_operation(calls, 2, "didCreateFiles", "/workspace/new.lua")
    assert_file_operation(calls, 3, "willCreateFiles", "zipfile:///workspace/archive.zip::new.lua")
    assert_file_operation(calls, 4, "didCreateFiles", "zipfile:///workspace/archive.zip::new.lua")
  end)
end

T["LSP-02 skips existing buffers and preserves fs_stat failure behavior"] = function()
  with_astrolsp_spec({
    buffers = { [1] = {}, [2] = { new_file = "stale" } },
    valid_buffers = { [1] = true, [2] = true },
    names = { [1] = "/workspace/existing.lua", [2] = "/workspace/stat-error.lua" },
    fs_stat = function(path)
      if path == "/workspace/existing.lua" then return { type = "file" } end
      error "fs_stat failed"
    end,
  }, function(spec, calls, buffers)
    local will_create = file_events(spec)[1]

    will_create.callback { buf = 1 }
    assert.equals(false, buffers[1].new_file)
    assert.same({}, calls)

    local ok, err = pcall(will_create.callback, { buf = 2 })
    assert.is_false(ok)
    assert.is_true(tostring(err):find("fs_stat failed", 1, true) ~= nil)
    assert.equals(false, buffers[2].new_file)
    assert.same({}, calls)
  end)
end

T["LSP-03 clears state before a didCreateFiles callback error"] = function()
  with_astrolsp_spec({
    buffers = { [1] = {} },
    valid_buffers = { [1] = true },
    names = { [1] = "/workspace/did-error.lua" },
    operations = {
      didCreateFiles = function() error "didCreateFiles failed" end,
    },
  }, function(spec, _, buffers)
    local will_create, did_create = unpack(file_events(spec))
    will_create.callback { buf = 1 }

    local ok, err = pcall(did_create.callback, { buf = 1 })
    assert.is_false(ok)
    assert.is_true(tostring(err):find("didCreateFiles failed", 1, true) ~= nil)
    assert.equals(false, buffers[1].new_file)
  end)
end

local function neo_tree_handler_entries(options)
  local handlers = {}
  for _, handler in ipairs(options.event_handlers) do
    assert.is_nil(handlers[handler.event], "Duplicate Neo-tree event: " .. handler.event)
    handlers[handler.event] = handler
  end
  return handlers
end

local function neo_tree_handlers_for_event(options, event)
  local handlers = {}
  for _, handler in ipairs(options.event_handlers) do
    if handler.event == event then table.insert(handlers, handler) end
  end
  return handlers
end

local function neo_tree_handler(options, event, excluded)
  for _, handler in ipairs(neo_tree_handlers_for_event(options, event)) do
    if handler ~= excluded then return handler end
  end
  error("Missing Neo-tree event handler: " .. event)
end

local function neo_tree_handlers(spec, options)
  options = options or { event_handlers = {} }
  spec.specs[2].opts(nil, options)
  return neo_tree_handler_entries(options)
end

T["LSP-04 adapts Neo-tree create delete move and rename state"] = function()
  local deleted = true
  with_astrolsp_spec({
    fs_stat = function(path)
      if path == "/workspace/deleted-directory" and not deleted then return { type = "directory" } end
      if path == "/workspace/source-directory" then return { type = "directory" } end
      if path == "/workspace/destination-directory" then return { type = "directory" } end
      return nil
    end,
  }, function(spec, calls)
    local handlers = neo_tree_handlers(spec)

    handlers.before_file_add.handler "/workspace/created.lua"
    handlers.file_added.handler "/workspace/created.lua"

    deleted = false
    handlers.before_file_delete.handler "/workspace/deleted-directory"
    deleted = true
    handlers.file_deleted.handler "/workspace/deleted-directory"
    handlers.file_deleted.handler "/workspace/deleted-directory"

    handlers.before_file_move.handler {
      source = "/workspace/source-directory",
      destination = "/workspace/destination-file",
    }
    handlers.before_file_rename.handler {
      source = "/workspace/missing-source",
      destination = "/workspace/destination-directory",
    }
    handlers.file_moved.handler {
      source = "/workspace/missing-source",
      destination = "/workspace/destination-file",
    }
    handlers.file_renamed.handler {
      source = "/workspace/missing-source",
      destination = "/workspace/destination-directory",
    }

    assert_operation_arguments(calls, "willCreateFiles", { "/workspace/created.lua" })
    assert_operation_arguments(calls, "didCreateFiles", { "/workspace/created.lua" })
    assert_operation_arguments(calls, "willDeleteFiles", {
      { path = "/workspace/deleted-directory", kind = "folder" },
    })
    assert_operation_arguments(calls, "didDeleteFiles", {
      { path = "/workspace/deleted-directory", kind = "folder" },
      { path = "/workspace/deleted-directory", kind = "file" },
    })
    assert_operation_arguments(calls, "willRenameFiles", {
      { from = "/workspace/source-directory", to = "/workspace/destination-file", kind = "folder" },
      { from = "/workspace/missing-source", to = "/workspace/destination-directory", kind = "folder" },
    })
    assert_operation_arguments(calls, "didRenameFiles", {
      { from = "/workspace/missing-source", to = "/workspace/destination-file", kind = "file" },
      { from = "/workspace/missing-source", to = "/workspace/destination-directory", kind = "folder" },
    })
  end)
end

T["LSP-06 permits formatting only for supported enabled clients"] = function()
  local config = { formatting = { disabled = {} } }
  unit_helpers.with_module("astronvim.plugins._astrolsp_autocmds", {
    loaded = {
      astrolsp = {
        config = config,
        format_opts = {},
      },
    },
  }, function(spec)
    local command = spec.opts.commands.Format
    local autoformat = spec.opts.autocmds.lsp_auto_format
    local function client(name, supported)
      return {
        name = name,
        supports_method = function(_, method, bufnr)
          return supported and method == "textDocument/formatting" and bufnr == 12
        end,
      }
    end

    assert.is_true(command.cond(client("formatter", true), 12))
    assert.is_true(autoformat.cond(client("formatter", true), 12))
    assert.is_false(command.cond(client("formatter", false), 12))

    config.formatting.disabled = true
    assert.is_false(command.cond(client("formatter", true), 12))
    assert.is_false(autoformat.cond(client("formatter", true), 12))

    config.formatting.disabled = { "formatter" }
    assert.is_false(command.cond(client("formatter", true), 12))
    assert.is_true(command.cond(client("other", true), 12))
  end)
end

T["LSP-01 declares AstroLSP feature, file operation, and wildcard capability defaults"] = function()
  with_astrolsp_spec({}, function(spec, _, _, metadata)
    local options = spec.opts

    assert.same({ codelens = true, inlay_hints = false, semantic_tokens = true }, options.features)
    assert.equals(10000, options.file_operations.timeout)
    assert.same({
      dynamicRegistration = true,
      didCreate = true,
      didDelete = true,
      didRename = true,
      willCreate = true,
      willDelete = true,
      willRename = true,
    }, options.file_operations.operations)
    assert.is_true(options.config["*"].capabilities == metadata.capabilities)
  end)
end

local function with_astrolsp_autocmd_spec(options, callback)
  options = options or {}
  local codelens = options.codelens or {}
  return unit_helpers.with_module("astronvim.plugins._astrolsp_autocmds", {
    loaded = {
      astrolsp = options.astrolsp or {
        config = { features = { codelens = true }, formatting = { disabled = {} } },
        format_opts = {},
      },
    },
    vim = {
      lsp = { codelens = codelens, buf = options.lsp_buf or {} },
    },
    replace_vim = { lsp = true },
  }, callback)
end

T["LSP-09 leaves CodeLens refresh ownership with AstroLSP"] = function()
  with_astrolsp_autocmd_spec({}, function(spec) assert.is_nil(spec.opts.autocmds.lsp_codelens_refresh) end)
end

local function with_astrolsp_mappings(options, callback)
  options = options or {}
  local calls = {}
  local maps
  local function record(name)
    return function(...)
      local arguments = { n = select("#", ...), ... }
      table.insert(calls, { name = name, arguments = arguments })
    end
  end
  local function empty_map_table() return { n = {}, v = {}, x = {} } end

  return unit_helpers.with_module("astronvim.plugins._astrolsp_mappings", {
    loaded = {
      astrocore = {
        empty_map_table = empty_map_table,
        extend_tbl = function(_, additions)
          maps = additions
          return additions
        end,
      },
      astroui = { get_icon = function() return "LSP" end },
      astrolsp = { format_opts = options.format_opts or { async = true } },
      ["astrolsp.toggles"] = {
        codelens = record "toggle_codelens",
        buffer_autoformat = record "toggle_buffer_autoformat",
        autoformat = record "toggle_autoformat",
        signature_help = record "toggle_signature_help",
        buffer_inlay_hints = record "toggle_buffer_inlay_hints",
        inlay_hints = record "toggle_inlay_hints",
        buffer_semantic_tokens = record "toggle_buffer_semantic_tokens",
      },
    },
    vim = {
      tbl_contains = function(values, value)
        for _, candidate in ipairs(values) do
          if candidate == value then return true end
        end
        return false
      end,
      lsp = {
        buf = {
          code_action = record "code_action",
          declaration = record "declaration",
          definition = record "definition",
          format = record "format",
          references = record "references",
          rename = record "rename",
          signature_help = record "signature_help",
          type_definition = record "type_definition",
          workspace_symbol = record "workspace_symbol",
          workspace_diagnostics = options.workspace_diagnostics and record "workspace_diagnostics" or nil,
        },
        codelens = {
          enable = options.native_codelens and record "codelens_enable" or nil,
          refresh = record "codelens_refresh",
          run = record "codelens_run",
        },
      },
    },
    replace_vim = { lsp = true },
  }, function(spec)
    local mapping_options = options.mapping_options
      or { formatting = { disabled = options.disabled or {} }, mappings = {} }
    spec.opts(nil, mapping_options)
    callback(maps, calls, mapping_options)
  end)
end

local function assert_mapping_condition(maps, mode, lhs, expected) assert.equals(expected, maps[mode][lhs].cond) end

local function assert_supported_method(supported, mapping, client, bufnr, expected_method)
  assert.is_true(mapping.cond(client, bufnr))
  local request = supported[#supported]
  assert.equals(expected_method, request.method)
  assert.equals(bufnr, request.bufnr)
end

T["LSPMAP-01 exposes representative capability gates"] = function()
  with_astrolsp_mappings({ workspace_diagnostics = true }, function(maps)
    for _, gate in ipairs {
      { "n", "<Leader>la", "textDocument/codeAction" },
      { "x", "<Leader>la", "textDocument/codeAction" },
      { "n", "<Leader>lA", "textDocument/codeAction" },
      { "n", "<Leader>lL", "textDocument/codeLens" },
      { "n", "<Leader>uL", "textDocument/codeLens" },
      { "n", "<Leader>u?", "textDocument/signatureHelp" },
      { "n", "<Leader>lR", "textDocument/references" },
      { "n", "<Leader>lr", "textDocument/rename" },
      { "n", "<Leader>lw", "workspace/diagnostic" },
    } do
      assert_mapping_condition(maps, gate[1], gate[2], gate[3])
    end

    local supported = {}
    local client = {
      name = "formatter",
      supports_method = function(_, method, bufnr)
        table.insert(supported, { method = method, bufnr = bufnr })
        return true
      end,
    }
    assert_supported_method(supported, maps.n["<Leader>lf"], client, 31, "textDocument/formatting")
    assert_supported_method(supported, maps.v["<Leader>lf"], client, 32, "textDocument/rangeFormatting")
    assert_supported_method(supported, maps.n["<Leader>uY"], client, 33, "textDocument/semanticTokens/full")
    assert_supported_method(supported, maps.n["<Leader>uf"], client, 34, "textDocument/formatting")
    assert_supported_method(supported, maps.n["<Leader>uF"], client, 35, "textDocument/formatting")
  end)

  for _, disabled in ipairs { true, { "formatter" } } do
    with_astrolsp_mappings({ disabled = disabled }, function(maps)
      local client = {
        name = "formatter",
        supports_method = function() return true end,
      }
      assert.is_false(maps.n["<Leader>lf"].cond(client, 40))
      assert.is_false(maps.v["<Leader>lf"].cond(client, 40))
      assert.is_false(maps.n["<Leader>uf"].cond(client, 41))
      assert.is_false(maps.n["<Leader>uF"].cond(client, 42))
    end)
  end
end

local function assert_mapping_dispatch(maps, calls, mode, lhs, name, ...)
  maps[mode][lhs][1](...)
  local call = calls[#calls]
  assert.equals(name, call.name)
  assert.same({ n = select("#", ...), ... }, call.arguments)
end

T["LSPMAP-02 dispatches each public mapping operation"] = function()
  with_astrolsp_mappings({ native_codelens = true, workspace_diagnostics = true }, function(maps, calls)
    assert_mapping_dispatch(maps, calls, "n", "<Leader>la", "code_action")
    assert_mapping_dispatch(maps, calls, "x", "<Leader>la", "code_action")
    assert_mapping_dispatch(
      maps,
      calls,
      "n",
      "<Leader>lA",
      "code_action",
      { context = { only = { "source" }, diagnostics = {} } }
    )
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lf", "format", { async = true })
    assert_mapping_dispatch(maps, calls, "v", "<Leader>lf", "format", { async = true })
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lL", "codelens_run")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uL", "toggle_codelens")
    assert_mapping_dispatch(maps, calls, "n", "gD", "declaration")
    assert_mapping_dispatch(maps, calls, "n", "gd", "definition")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uf", "toggle_buffer_autoformat")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uF", "toggle_autoformat")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>u?", "toggle_signature_help")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uh", "toggle_buffer_inlay_hints")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uH", "toggle_inlay_hints")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lR", "references")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lr", "rename")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lh", "signature_help")
    assert_mapping_dispatch(maps, calls, "n", "gK", "signature_help")
    assert_mapping_dispatch(maps, calls, "n", "gy", "type_definition")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lG", "workspace_symbol")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lw", "workspace_diagnostics")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>uY", "toggle_buffer_semantic_tokens")
  end)

  with_astrolsp_mappings({}, function(maps, calls)
    assert_mapping_condition(maps, "n", "<Leader>lw", "workspace/diagnostic")
    assert_mapping_dispatch(maps, calls, "n", "<Leader>lL", "codelens_run")
  end)
end

T["LSP-13 preserves valid format options for enabled formatting clients"] = function()
  local format_calls = {}
  local format_opts = { async = true, timeout_ms = 1000 }
  local format_opts_snapshot = { async = true, timeout_ms = 1000 }
  local client = {
    name = "formatter",
    supports_method = function(_, method, bufnr) return method == "textDocument/formatting" and bufnr == 14 end,
  }

  with_astrolsp_autocmd_spec({
    astrolsp = { config = { features = {}, formatting = { disabled = {} } }, format_opts = format_opts },
    lsp_buf = { format = function(options) table.insert(format_calls, options) end },
  }, function(spec)
    local command = spec.opts.commands.Format
    local autoformat = spec.opts.autocmds.lsp_auto_format

    assert.is_true(command.cond(client, 14))
    assert.is_true(autoformat.cond(client, 14))
    command[1]()
  end)

  assert.same(format_opts_snapshot, format_opts)
  assert.same(format_opts_snapshot, format_calls[1])
end

T["LSPMAP-04 keeps range formatting limited to range-capable clients"] = function()
  with_astrolsp_mappings({}, function(maps)
    local methods = {}
    local client = {
      name = "range-only",
      supports_method = function(_, method, bufnr)
        table.insert(methods, { method = method, bufnr = bufnr })
        return method == "textDocument/rangeFormatting"
      end,
    }
    assert.is_false(maps.n["<Leader>lf"].cond(client, 28))
    assert.is_true(maps.v["<Leader>lf"].cond(client, 28))
    assert.equals("textDocument/formatting", methods[1].method)
    assert.equals(28, methods[1].bufnr)
    assert.equals("textDocument/rangeFormatting", methods[2].method)
    assert.equals(28, methods[2].bufnr)
  end)
end

T["LSPCONFIG-01 preserves command compatibility metadata without owning options"] = function()
  for _, case in ipairs {
    { exists = 0, command = { "LspInfo", "LspLog", "LspStart" } },
    { exists = 1, command = { "LspInfo", "LspLog", "LspStart" } },
    { exists = 2, command = nil },
    { exists = 3, command = { "LspInfo", "LspLog", "LspStart" } },
  } do
    unit_helpers.with_module("astronvim.plugins.lspconfig", {
      vim = { fn = { exists = function() return case.exists end } },
    }, function(spec)
      assert.equals("neovim/nvim-lspconfig", spec[1])
      assert.equals("User AstroFile", spec.event)
      assert.same(case.command, spec.cmd)
      assert.is_nil(spec.opts)
      assert.is_nil(spec.config)
    end)
  end
end

T["LSPMAP-03 exposes legacy LSP commands only without native :lsp"] = function()
  for _, case in ipairs {
    { native = false, expected = { "LspInfo", "LspLog", "LspStart" } },
    { native = true, expected = nil },
  } do
    local exists_calls = {}
    unit_helpers.with_module("astronvim.plugins.lspconfig", {
      vim = {
        fn = {
          exists = function(command)
            table.insert(exists_calls, command)
            return case.native and 2 or 0
          end,
        },
      },
    }, function(spec)
      assert.same(case.expected, spec.cmd)
      assert.same({ ":lsp" }, exists_calls)
    end)
  end
end

T["LSP-03 repeats new writes and clears state after failed write callbacks"] = function()
  with_astrolsp_spec({
    buffers = { [1] = {}, [2] = {}, [3] = {} },
    valid_buffers = { [1] = true, [2] = true, [3] = true },
    names = {
      [1] = "/workspace/repeated.lua",
      [2] = "/workspace/failed-write.lua",
      [3] = "/workspace/will-error.lua",
    },
    operations = {
      willCreateFiles = function(path)
        if path == "/workspace/will-error.lua" then error "willCreateFiles failed" end
      end,
    },
  }, function(spec, calls, buffers)
    local will_create, did_create = unpack(file_events(spec))

    for _ = 1, 2 do
      will_create.callback { buf = 1 }
      did_create.callback { buf = 1 }
    end
    assert.equals(false, buffers[1].new_file)

    will_create.callback { buf = 2 }
    assert.equals("/workspace/failed-write.lua", buffers[2].new_file)

    local ok, err = pcall(will_create.callback, { buf = 3 })
    assert.is_false(ok)
    assert.is_true(tostring(err):find("willCreateFiles failed", 1, true) ~= nil)
    assert.equals(false, buffers[3].new_file)

    did_create.callback { buf = 3 }

    assert_file_operation(calls, 1, "willCreateFiles", "/workspace/repeated.lua")
    assert_file_operation(calls, 2, "didCreateFiles", "/workspace/repeated.lua")
    assert_file_operation(calls, 3, "willCreateFiles", "/workspace/repeated.lua")
    assert_file_operation(calls, 4, "didCreateFiles", "/workspace/repeated.lua")
    assert_file_operation(calls, 5, "willCreateFiles", "/workspace/failed-write.lua")
    assert_file_operation(calls, 6, "willCreateFiles", "/workspace/will-error.lua")
  end)
end

T["LSP-11 keeps Neo-tree ownership stable"] = function()
  local stats = {
    ["/workspace/first"] = { type = "directory" },
    ["/workspace/second"] = { type = "file" },
  }
  with_astrolsp_spec({ fs_stat = function(path) return stats[path] end }, function(spec, calls)
    local neo_tree = spec.specs[2]
    local caller_handler = {
      event = "before_file_delete",
      id = "caller-owned",
      handler = function() end,
    }
    local options = { event_handlers = { caller_handler } }
    neo_tree.opts(nil, options)
    neo_tree.opts(nil, options)

    local caller_instances = 0
    for _, handler in ipairs(options.event_handlers) do
      if handler == caller_handler then caller_instances = caller_instances + 1 end
    end
    assert.equals(1, caller_instances)

    for _, event in ipairs {
      "before_file_add",
      "file_added",
      "before_file_delete",
      "file_deleted",
      "before_file_move",
      "before_file_rename",
      "file_moved",
      "file_renamed",
    } do
      local astrolsp_instances = 0
      for _, handler in ipairs(neo_tree_handlers_for_event(options, event)) do
        if handler ~= caller_handler then astrolsp_instances = astrolsp_instances + 1 end
      end
      assert.equals(1, astrolsp_instances)
    end

    local before_delete = neo_tree_handler(options, "before_file_delete", caller_handler)
    local file_deleted = neo_tree_handler(options, "file_deleted")
    before_delete.handler "/workspace/first"
    before_delete.handler "/workspace/second"

    file_deleted.handler "/workspace/second"
    stats["/workspace/first"] = nil
    file_deleted.handler "/workspace/first"

    assert_file_operation(calls, 1, "willDeleteFiles", { path = "/workspace/first", kind = "folder" })
    assert_file_operation(calls, 2, "willDeleteFiles", { path = "/workspace/second", kind = "file" })
    assert_file_operation(calls, 3, "didDeleteFiles", { path = "/workspace/second", kind = "file" })
    assert_file_operation(calls, 4, "didDeleteFiles", { path = "/workspace/first", kind = "folder" })
  end)
end

T["LSP-12 keeps signature-help state scoped to its buffer lifecycle"] = function()
  local current = { buffer = 1, line = "" }
  local buffer_vars = {
    [1] = {
      signature_help = true,
      signature_help_triggerCharacters = { ["("] = true },
      signature_help_retriggerCharacters = { [","] = true },
    },
    [2] = {
      signature_help = true,
      signature_help_triggerCharacters = { ["("] = true },
      signature_help_retriggerCharacters = { [","] = true },
    },
  }
  local signature_requests = {}

  unit_helpers.with_module("astronvim.plugins._astrolsp_autocmds", {
    loaded = {
      astrolsp = {
        config = { features = { codelens = true, signature_help = true }, formatting = { disabled = {} } },
        format_opts = {},
      },
    },
    replace_vim = { b = true, lsp = true },
    vim = {
      b = buffer_vars,
      api = {
        nvim_win_get_cursor = function() return { 1, #current.line } end,
        nvim_get_current_line = function() return current.line end,
      },
      lsp = {
        codelens = { enable = function() end },
        buf = {
          signature_help = function()
            if current.buffer == 1 and current.line == "error(" then error "signature callback failure" end
            table.insert(signature_requests, current.buffer)
          end,
        },
      },
    },
  }, function(spec)
    local signature_help = spec.opts.autocmds.lsp_auto_signature_help
    local changed = signature_help[1].callback
    local function cleanup_callback(event)
      for _, autocmd in ipairs(signature_help) do
        local events = type(autocmd.event) == "table" and autocmd.event or { autocmd.event }
        if contains(events, event) then return autocmd.callback end
      end
    end
    local insert_leave = assert(cleanup_callback "InsertLeave")
    local buffer_delete = assert(cleanup_callback "BufDelete")
    local function change(buffer, line)
      current.buffer = buffer
      current.line = line
      changed { buf = buffer }
    end
    local function request_count(buffer)
      local count = 0
      for _, request_buffer in ipairs(signature_requests) do
        if request_buffer == buffer then count = count + 1 end
      end
      return count
    end

    change(1, "call(")
    local after_trigger = request_count(1)
    assert.is_true(after_trigger > 0)
    insert_leave { buf = 1 }
    change(1, ",")
    assert.equals(after_trigger, request_count(1))

    change(1, "call(")
    local before_buffer_delete = request_count(1)
    assert.is_true(before_buffer_delete > after_trigger)
    buffer_delete { buf = 1 }
    change(1, ",")
    assert.equals(before_buffer_delete, request_count(1))

    buffer_vars[2].signature_help = false
    change(2, "disabled(")
    assert.equals(0, request_count(2))
    buffer_vars[2].signature_help = true
    change(2, "switch(")
    local buffer_two_trigger = request_count(2)
    assert.is_true(buffer_two_trigger > 0)
    change(2, ",")
    assert.is_true(request_count(2) > buffer_two_trigger)

    local ok, error_message = pcall(change, 1, "error(")
    assert.is_false(ok)
    assert.is_true(tostring(error_message):find("signature callback failure", 1, true) ~= nil)
  end)
end

return T
