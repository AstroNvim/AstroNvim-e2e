local MiniTest = require "mini.test"
local unit_helpers = require "unit_helpers"

local T = MiniTest.new_set()

local function call_index(calls, expected)
  for index, call in ipairs(calls) do
    if call == expected then return index end
  end
end

local function call_count(calls, expected)
  local count = 0
  for _, call in ipairs(calls) do
    if call == expected then count = count + 1 end
  end
  return count
end

local function assert_call_seen(calls, expected) assert.is_not_nil(call_index(calls, expected), expected) end

local function assert_call_absent(calls, expected) assert.is_nil(call_index(calls, expected), expected) end

local function assert_call_order(calls, first, second)
  local first_index = call_index(calls, first)
  local second_index = call_index(calls, second)
  assert.is_not_nil(first_index, first)
  assert.is_not_nil(second_index, second)
  assert.is_true(first_index < second_index)
end

local function with_mason_lspconfig(options, callback)
  options = options or {}
  local calls = {}
  local installed_call = 0
  local scheduled = {}
  local registry = { listeners = {} }

  function registry.get_installed_package_names()
    installed_call = installed_call + 1
    table.insert(calls, "registry:get_installed")
    return (options.installed_batches and options.installed_batches[installed_call]) or options.installed or {}
  end

  function registry.refresh(refresh_callback)
    table.insert(calls, "registry:refresh")
    if options.refresh then refresh_callback(options.refresh.success, options.refresh.updated_registries) end
  end

  function registry:off(event, handler)
    table.insert(calls, "registry:off:" .. event)
    assert.equals("function", type(handler))
    local listeners = self.listeners[event] or {}
    for index = #listeners, 1, -1 do
      if listeners[index] == handler then table.remove(listeners, index) end
    end
    self.listeners[event] = listeners
  end

  function registry:on(event, handler)
    table.insert(calls, "registry:on:" .. event)
    local listeners = self.listeners[event] or {}
    table.insert(listeners, handler)
    self.listeners[event] = listeners
  end

  function registry:emit(event, value)
    for _, handler in ipairs(self.listeners[event] or {}) do
      handler(value)
    end
  end

  function registry:listener_count(event) return #(self.listeners[event] or {}) end

  local loaded = {
    astrocore = {
      is_available = function(plugin)
        if plugin == "astrolsp" then return options.astrolsp_available ~= false end
        if plugin == "mason-tool-installer.nvim" then return options.tool_installer_available == true end
        return false
      end,
    },
    astrolsp = {
      lsp_setup = function(server) table.insert(calls, "setup:" .. server) end,
    },
    ["mason-core.functional"] = {
      each = function(callback_fn, values)
        for _, value in ipairs(values) do
          callback_fn(value)
        end
      end,
    },
    ["mason-registry"] = registry,
    ["mason-lspconfig.mappings"] = {
      get_mason_map = function() return { package_to_lspconfig = options.package_to_lspconfig or {} } end,
    },
    ["mason-lspconfig"] = {
      setup = function(opts)
        calls.setup_options = opts
        table.insert(calls, "mason-lspconfig:setup")
      end,
    },
  }

  for server, config in pairs(options.server_configs or {}) do
    loaded["mason-lspconfig.lsp." .. server] = config
  end

  return unit_helpers.with_module("astronvim.plugins.configs.mason-lspconfig", {
    loaded = loaded,
    preload = options.server_preloads,
    vim = {
      lsp = {
        config = function(server, config)
          table.insert(calls, "config:" .. server)
          calls.configurations = calls.configurations or {}
          calls.configurations[server] = config
        end,
      },
      schedule_wrap = function(callback_fn)
        return function(...)
          local arguments = { n = select("#", ...), ... }
          table.insert(scheduled, function() callback_fn(unpack(arguments, 1, arguments.n)) end)
        end
      end,
    },
  }, function(configure)
    local context = {
      drain_scheduled = function()
        while #scheduled > 0 do
          local callback_fn = table.remove(scheduled, 1)
          callback_fn()
        end
      end,
    }
    callback(configure, registry, calls, context)
  end)
end

T["MASON-01 appends the AstroNvim registry and selects enabled or ASCII icons"] = function()
  unit_helpers.with_module("astronvim.plugins.mason", {
    vim = { g = { icons_enabled = false } },
  }, function(spec)
    local options = { registries = { "custom:registry" } }
    spec.opts(nil, options)

    assert.same({ "custom:registry", "github:mason-org/mason-registry" }, options.registries)
    assert.same({ package_installed = "O", package_uninstalled = "X", package_pending = "0" }, options.ui.icons)
  end)

  unit_helpers.with_module("astronvim.plugins.mason", {
    vim = { g = { icons_enabled = true } },
  }, function(spec)
    local options = {}
    spec.opts(nil, options)

    assert.same({ package_installed = "✓", package_uninstalled = "✗", package_pending = "⟳" }, options.ui.icons)
  end)
end

T["MASON-02 dispatches the Mason UI mapping through the public module boundary"] = function()
  local calls = {}
  unit_helpers.with_module("astronvim.plugins.mason", {
    loaded = {
      ["mason.ui"] = { open = function() table.insert(calls, "open") end },
    },
  }, function(spec)
    local maps = { n = {} }
    spec.specs[1].opts(nil, { mappings = maps })

    assert.equals("Mason Installer", maps.n["<Leader>pm"].desc)
    maps.n["<Leader>pm"][1]()
    assert.equals("open", calls[#calls])
  end)
end

T["MASON-03 configures Tool Installer and handles startup states"] = function()
  local cases = {
    { name = "after VimEnter", did_enter = 1, run_on_start = nil, cleanup_error = true },
    { name = "before VimEnter", did_enter = 0, run_on_start = nil },
    { name = "disabled", did_enter = 1, run_on_start = false },
  }

  for _, case in ipairs(cases) do
    local calls = {}
    unit_helpers.with_module("astronvim.plugins.configs.mason-tool-installer", {
      replace_vim = { v = true },
      loaded = {
        ["mason-tool-installer"] = {
          setup = function(opts)
            calls.options = opts
            table.insert(calls, "setup")
          end,
          run_on_start = function() table.insert(calls, "run") end,
        },
      },
      vim = {
        v = { vim_did_enter = case.did_enter },
        api = {
          nvim_del_augroup_by_name = function(name)
            assert.equals("mti_start", name)
            table.insert(calls, "cleanup")
            if case.cleanup_error then error "missing augroup" end
          end,
        },
      },
    }, function(configure)
      local options = { run_on_start = case.run_on_start }
      configure(nil, options)
      assert.equals(options, calls.options)
    end)
    assert_call_seen(calls, "setup")
    if case.did_enter == 1 and case.run_on_start ~= false then
      assert_call_seen(calls, "cleanup")
      assert_call_seen(calls, "run")
      assert_call_order(calls, "cleanup", "run")
    else
      assert_call_absent(calls, "cleanup")
      assert_call_absent(calls, "run")
    end
  end
end

T["MASON-04 gives Tool Installer ownership of LSP installation requests"] = function()
  for _, case in ipairs {
    { available = true, expected = nil },
    { available = false, expected = { "lua-language-server" } },
  } do
    with_mason_lspconfig(
      { tool_installer_available = case.available, astrolsp_available = false },
      function(configure, _, calls)
        local options = { ensure_installed = { "lua-language-server" } }
        configure(nil, options)

        if case.available then
          assert.is_nil(options.ensure_installed)
        else
          assert.same(case.expected, options.ensure_installed)
        end
        assert.equals(options, calls.setup_options)
      end
    )
  end
end

T["MASON-05 maps package strings and objects without duplicate server setup"] = function()
  with_mason_lspconfig({
    installed = {},
    refresh = { success = true, updated_registries = {} },
    package_to_lspconfig = {
      ["lua-language-server"] = "lua_ls",
      ["typescript-language-server"] = "ts_ls",
    },
    server_configs = { lua_ls = { setting = "lua" }, ts_ls = { setting = "typescript" } },
  }, function(configure, registry, calls, context)
    local options = {}
    configure(nil, options)

    for _, expected in ipairs { "registry:get_installed", "registry:refresh", "mason-lspconfig:setup" } do
      assert_call_seen(calls, expected)
    end
    assert.equals(1, registry:listener_count "package:install:success")
    assert.equals(false, options.automatic_enable)
    context.drain_scheduled()

    for _, unexpected in ipairs { "config:lua_ls", "setup:lua_ls", "config:ts_ls", "setup:ts_ls" } do
      assert_call_absent(calls, unexpected)
    end

    configure(nil, {})
    assert.equals(1, registry:listener_count "package:install:success")
    context.drain_scheduled()

    for _, unexpected in ipairs { "config:lua_ls", "setup:lua_ls", "config:ts_ls", "setup:ts_ls" } do
      assert_call_absent(calls, unexpected)
    end

    registry:emit("package:install:success", { name = "typescript-language-server" })
    registry:emit("package:install:success", "lua-language-server")
    context.drain_scheduled()

    for _, expected in ipairs { "config:lua_ls", "setup:lua_ls", "config:ts_ls", "setup:ts_ls" } do
      assert_call_seen(calls, expected)
    end
    assert.equals(1, call_count(calls, "config:lua_ls"))
    assert.equals(1, call_count(calls, "setup:lua_ls"))
    assert.equals(1, call_count(calls, "config:ts_ls"))
    assert.equals(1, call_count(calls, "setup:ts_ls"))
  end)
end

T["MASON-06 handles unmapped and optional server configuration branches"] = function()
  with_mason_lspconfig({
    installed = { "unknown", "missing", "failing", "available" },
    refresh = { success = true, updated_registries = {} },
    package_to_lspconfig = {
      missing = "missing_server",
      failing = "failing_server",
      available = "available_server",
    },
    server_configs = { available_server = { setting = true } },
    server_preloads = {
      ["mason-lspconfig.lsp.failing_server"] = function() error "server configuration failed" end,
    },
  }, function(configure, registry, calls, context)
    configure(nil, {})

    for _, expected in ipairs { "registry:get_installed", "registry:refresh", "mason-lspconfig:setup" } do
      assert_call_seen(calls, expected)
    end
    assert_call_order(calls, "registry:off:package:install:success", "registry:on:package:install:success")
    assert.equals(1, registry:listener_count "package:install:success")

    context.drain_scheduled()
    for _, expected in ipairs {
      "setup:missing_server",
      "setup:failing_server",
      "config:available_server",
      "setup:available_server",
    } do
      assert_call_seen(calls, expected)
    end
    for _, unexpected in ipairs {
      "config:unknown",
      "setup:unknown",
      "config:missing_server",
      "config:failing_server",
    } do
      assert_call_absent(calls, unexpected)
    end
  end)
end

T["MASON-06 refreshes only successful nonempty registries and installs event packages after re-registration"] = function()
  local refresh_cases = {
    {
      refresh = { success = true, updated_registries = { "primary" } },
      installed_batches = { {}, { "after-refresh" } },
      refreshes_installed_packages = true,
    },
    {
      refresh = { success = true, updated_registries = {} },
      installed_batches = { {} },
      refreshes_installed_packages = false,
    },
    {
      refresh = { success = false, updated_registries = { "primary" } },
      installed_batches = { {} },
      refreshes_installed_packages = false,
    },
  }

  for _, case in ipairs(refresh_cases) do
    with_mason_lspconfig({
      refresh = case.refresh,
      installed_batches = case.installed_batches,
      package_to_lspconfig = { ["after-refresh"] = "after_refresh", ["event-package"] = "event_server" },
      server_configs = { after_refresh = {}, event_server = {} },
    }, function(configure, registry, calls, context)
      configure(nil, {})
      for _, expected in ipairs { "registry:get_installed", "registry:refresh", "mason-lspconfig:setup" } do
        assert_call_seen(calls, expected)
      end
      assert_call_order(calls, "registry:off:package:install:success", "registry:on:package:install:success")
      context.drain_scheduled()

      local expected_installed_calls = case.refreshes_installed_packages and 2 or 1
      assert.equals(expected_installed_calls, call_count(calls, "registry:get_installed"))
      if case.refreshes_installed_packages then
        assert_call_seen(calls, "config:after_refresh")
        assert_call_seen(calls, "setup:after_refresh")

        registry:emit("package:install:success", "event-package")
        context.drain_scheduled()
        assert_call_seen(calls, "config:event_server")
        assert_call_seen(calls, "setup:event_server")
      else
        assert_call_absent(calls, "config:after_refresh")
        assert_call_absent(calls, "setup:after_refresh")
      end
    end)
  end
end

T["MASON-06 delegates without AstroLSP and respects automatic_enable false"] = function()
  with_mason_lspconfig({ astrolsp_available = false }, function(configure, _, calls)
    local options = { automatic_enable = true }
    configure(nil, options)

    assert.equals(true, options.automatic_enable)
    assert_call_seen(calls, "mason-lspconfig:setup")
    assert_call_absent(calls, "registry:get_installed")
  end)

  with_mason_lspconfig({ automatic_enable = false }, function(configure, _, calls)
    local options = { automatic_enable = false }
    configure(nil, options)

    assert.equals(false, options.automatic_enable)
    assert_call_seen(calls, "mason-lspconfig:setup")
    assert_call_absent(calls, "registry:get_installed")
  end)
end

T["MASON-07 delegates null-ls and DAP setup while Tool Installer owns installation"] = function()
  local adapters = {
    { module = "astronvim.plugins.configs.mason-null-ls", dependency = "mason-null-ls" },
    { module = "astronvim.plugins.configs.mason-nvim-dap", dependency = "mason-nvim-dap" },
  }

  for _, adapter in ipairs(adapters) do
    for _, tool_installer_available in ipairs { false, true } do
      local calls = {}
      local availability_calls = {}
      unit_helpers.with_module(adapter.module, {
        loaded = {
          astrocore = {
            is_available = function(plugin)
              table.insert(availability_calls, plugin)
              return tool_installer_available
            end,
          },
          [adapter.dependency] = {
            setup = function(options) table.insert(calls, options) end,
          },
        },
      }, function(configure)
        local options = { ensure_installed = { "tool" }, handlers = {} }
        configure(nil, options)

        assert.same({ "mason-tool-installer.nvim" }, availability_calls)
        assert.equals(1, #calls)
        assert.equals(options, calls[1])
        if tool_installer_available then
          assert.is_nil(options.ensure_installed)
        else
          assert.same({ "tool" }, options.ensure_installed)
        end
      end)
    end
  end
end

T["MASON-08 declares none-ls trigger commands and attach ownership"] = function()
  unit_helpers.with_module("astronvim.plugins.none-ls", {}, function(spec)
    local dependency = spec.dependencies[1]

    assert.equals("null-ls", spec.main)
    assert.equals("User AstroFile", spec.event)
    assert.same({ "NullLsInstall", "NullLsUninstall" }, dependency.cmd)
    assert.is_nil(spec.opts.on_attach)
  end)
end

T["MASON-08 gates NullLsInfo on command availability"] = function()
  for _, exists in ipairs { 0, 2 } do
    unit_helpers.with_module("astronvim.plugins.none-ls", {
      vim = { fn = { exists = function(command) return command == ":NullLsInfo" and exists or 0 end } },
    }, function(spec)
      local maps = { n = {} }
      spec.specs[2].opts(nil, { mappings = maps })
      local mapping = maps.n["<Leader>lI"]

      assert.is_not_nil(mapping)
      assert.is_not_nil(mapping[1])
      assert.equals(exists > 0, mapping.cond())
    end)
  end
end

T["MASON-10 continues AstroLSP setup when an optional server config cannot load"] = function()
  with_mason_lspconfig({
    installed = { "lua-language-server" },
    package_to_lspconfig = { ["lua-language-server"] = "lua_ls" },
    server_preloads = {
      ["mason-lspconfig.lsp.lua_ls"] = function() error "optional config failed" end,
    },
  }, function(configure, _, calls, context)
    local options = { ensure_installed = { "lua-language-server" } }
    configure(nil, options)
    context.drain_scheduled()

    for _, expected in ipairs {
      "registry:get_installed",
      "registry:refresh",
      "mason-lspconfig:setup",
      "setup:lua_ls",
    } do
      assert_call_seen(calls, expected)
    end
    assert_call_order(calls, "registry:off:package:install:success", "registry:on:package:install:success")
    assert.equals(1, call_count(calls, "setup:lua_ls"))
    assert.is_false(options.automatic_enable)
  end)
end

T["MASON-08 merges NullLsInfo without disturbing caller mappings"] = function()
  unit_helpers.with_module("astronvim.plugins.none-ls", {
    vim = { fn = { exists = function() return 1 end } },
  }, function(spec)
    local mappings = {
      n = { ["<Leader>xx"] = { "<Cmd>Caller<CR>", desc = "Caller mapping" } },
      i = { ["<C-x>"] = { "caller" } },
    }
    local caller_normal = mappings.n["<Leader>xx"]
    local caller_insert = mappings.i["<C-x>"]
    local options = { mappings = mappings, features = { formatting = true } }

    spec.specs[2].opts(nil, options)
    spec.specs[2].opts(nil, options)

    assert.equals(caller_normal, mappings.n["<Leader>xx"])
    assert.equals(caller_insert, mappings.i["<C-x>"])
    assert.is_not_nil(mappings.n["<Leader>lI"])
    assert.is_not_nil(mappings.n["<Leader>lI"][1])
    assert.is_true(mappings.n["<Leader>lI"].cond())
    assert.equals(true, options.features.formatting)
  end)
end

T["MASON-09 preserves the existing AstroNvim registry and unrelated Mason options"] = function()
  local registry = "github:mason-org/mason-registry"
  unit_helpers.with_module("astronvim.plugins.mason", {
    vim = { g = { icons_enabled = false } },
  }, function(spec)
    local options = {
      registries = { "custom:first", registry, "custom:last" },
      ui = { border = "rounded", custom = { keep = true } },
      install_root_dir = "/tmp/mason",
    }

    spec.opts(nil, options)

    assert.same({ "custom:first", registry, "custom:last" }, options.registries)
    local registry_count = 0
    for _, configured_registry in ipairs(options.registries) do
      if configured_registry == registry then registry_count = registry_count + 1 end
    end
    assert.equals(1, registry_count)
    assert.equals("rounded", options.ui.border)
    assert.same({ keep = true }, options.ui.custom)
    assert.equals("/tmp/mason", options.install_root_dir)
    assert.same({ package_installed = "O", package_uninstalled = "X", package_pending = "0" }, options.ui.icons)
  end)
end

return T
