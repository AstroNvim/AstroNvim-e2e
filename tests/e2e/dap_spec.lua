local MiniTest = require "mini.test"
local config = require "config"
local helpers = require "helpers"

local child
local T = MiniTest.new_set {
  hooks = {
    pre_case = function() child = nil end,
    post_case = function()
      if child then
        pcall(
          child.lua,
          [[
            local dap = require "dap"
            if dap.session() then dap.terminate { all = true } end
          ]]
        )
        pcall(helpers.wait_until, child, "require('dap').session() == nil", "DAP fixture shutdown", 1000)
      end
      helpers.stop_child(child)
      child = nil
    end,
  },
}

T["DAP-E2E-01 loads fixture launch configuration through nvim-dap"] = function()
  child = helpers.start_ready_child { "nvim-dap" }
  local project = helpers.fixture_project(child)
  local state = child.lua_get(([=[(function()
    local configure = require "astronvim.plugins.configs.nvim-dap"
    configure()
    local vscode = require "dap.ext.vscode"
    local configurations = vscode.getconfigs(vim.fs.joinpath(%s, ".vscode", "launch.json"))
    return {
      count = #configurations,
      name = configurations[1] and configurations[1].name,
      request = configurations[1] and configurations[1].request,
      type = configurations[1] and configurations[1].type,
    }
  end)()]=]):format(vim.inspect(project)))

  assert.same({ count = 1, name = "Fixture", request = "launch", type = "lua" }, state)
end

T["DAP-E2E-02 reports malformed launch configuration without breaking the child"] = function()
  child = helpers.start_ready_child { "nvim-dap" }
  local project = helpers.fixture_project(child)
  local state = child.lua_get(([=[(function()
    local configure = require "astronvim.plugins.configs.nvim-dap"
    configure()
    local vscode = require "dap.ext.vscode"
    local path = vim.fs.joinpath(%s, ".vscode", "launch.json")
    local history_boundary = #Snacks.notifier.get_history()
    vim.fn.writefile({ "{ malformed" }, path)
    local configurations = vscode.getconfigs(path)
    return { configurations = configurations, history_boundary = history_boundary }
  end)()]=]):format(vim.inspect(project)))

  helpers.wait_until(
    child,
    ([[(function()
      local history = Snacks.notifier.get_history()
      for index = %d + 1, #history do
        if history[index].level == "error" then return true end
      end
      return false
    end)()]]):format(state.history_boundary),
    "DAP parse error notification"
  )

  local parse_error = child.lua_get(([[(function()
    local history = Snacks.notifier.get_history()
    for index = %d + 1, #history do
      local notification = history[index]
      if notification.level == "error" and type(notification.msg) == "string" and notification.msg ~= "" then
        local message = notification.msg:lower()
        if message:find("parse", 1, true) or message:find("json", 1, true) or message:find("decode", 1, true) then
          return { level = notification.level, message = notification.msg }
        end
      end
    end
  end)()]]):format(state.history_boundary))
  assert.same({}, state.configurations)
  assert.is_not_nil(parse_error, "Expected a non-empty parse-related DAP error")
  assert.equals("error", parse_error.level)
  assert.is_true(parse_error.message ~= "")
  assert.is_true(child.is_running())
end

T["DAP-E2E-03 runs and terminates a hermetic adapter through AstroNvim mappings"] = function()
  child = helpers.start_ready_child { "nvim-dap", "nvim-dap-ui" }
  local project = helpers.fixture_project(child)
  local adapter = vim.fs.joinpath(config.harness_root, "tests", "fixtures", "dap_adapter.lua")
  local source = vim.fs.joinpath(project, "dap-source.lua")
  local log = vim.fs.joinpath(project, "dap-events.jsonl")
  local adapter_exit_marker = vim.fs.joinpath(project, "dap-adapter-exited")

  child.lua(
    ([=[
    local dap = require "dap"
    vim.env.ASTRONVIM_E2E_DAP_LOG = %s
    vim.env.ASTRONVIM_E2E_DAP_EXIT_MARKER = %s
    vim.env.ASTRONVIM_E2E_DAP_SOURCE = %s
    local nvim = vim.fn.exepath "nvim"
    if nvim == "" then nvim = vim.env.ASTRONVIM_TEST_NVIM or vim.v.progpath end
    dap.adapters.astronvim_fixture = {
      type = "executable",
      command = nvim,
      args = { "--headless", "--clean", "-u", "NONE", "-l", %s },
      options = { detached = false },
    }
    local source = %s
    local launch_path = vim.fs.joinpath(vim.fs.dirname(source), ".vscode", "launch.json")
    vim.fn.writefile({ vim.json.encode {
      version = "0.2.0",
      configurations = {
        {
          type = "astronvim_fixture",
          request = "launch",
          name = "AstroNvim fixture",
          program = source,
        },
      },
    } }, launch_path)
    vim.fn.writefile({ "return 1" }, source)
    vim.cmd.edit(vim.fn.fnameescape(source))
  ]=]):format(
      vim.inspect(log),
      vim.inspect(adapter_exit_marker),
      vim.inspect(source),
      vim.inspect(adapter),
      vim.inspect(source)
    )
  )

  local function assert_no_unexpected(commands)
    for _, command in ipairs(commands) do
      assert.is_true(command:sub(1, #"unexpected:") ~= "unexpected:", vim.inspect(commands))
    end
  end

  local setup = child.lua_get [[{
    filetype = vim.bo.filetype,
    adapter = type(require("dap").adapters.astronvim_fixture),
    launch_file = vim.fn.filereadable(vim.fs.joinpath(vim.fn.getcwd(), ".vscode", "launch.json")),
  }]]
  assert.equals("lua", setup.filetype)
  assert.equals("table", setup.adapter)
  assert.equals(1, setup.launch_file)
  child.type_keys "<Space>dc"

  helpers.wait_until(child, "require('dap').session() ~= nil", "DAP adapter session")
  helpers.wait_until(
    child,
    ([[(function()
      if vim.fn.filereadable(%s) == 0 then return false end
      local commands = {}
      for _, line in ipairs(vim.fn.readfile(%s)) do
        table.insert(commands, vim.json.decode(line).command)
      end
      return vim.tbl_contains(commands, "initialize")
        and vim.tbl_contains(commands, "launch")
        and vim.tbl_contains(commands, "configurationDone")
    end)()]]):format(vim.inspect(log), vim.inspect(log)),
    "DAP adapter initialization"
  )
  helpers.wait_until(child, "#vim.api.nvim_list_wins() > 1", "DAP UI open")

  local commands = child.lua_get(([[(function()
    local commands = {}
    if vim.fn.filereadable(%s) == 1 then
      for _, line in ipairs(vim.fn.readfile(%s)) do
        table.insert(commands, vim.json.decode(line).command)
      end
    end
    return commands
  end)()]]):format(vim.inspect(log), vim.inspect(log)))
  local expected_commands = { "initialize", "launch", "configurationDone" }
  local expected_index = 1
  for _, command in ipairs(commands) do
    if command == expected_commands[expected_index] then expected_index = expected_index + 1 end
  end
  assert.equals(#expected_commands + 1, expected_index, vim.inspect(commands))

  child.type_keys "<Space>dQ"
  helpers.wait_until(
    child,
    ("vim.fn.filereadable(%s) == 1"):format(vim.inspect(adapter_exit_marker)),
    "DAP adapter exit"
  )
  helpers.wait_until(child, "require('dap').session() == nil", "DAP session termination")
  helpers.wait_until(child, "#vim.api.nvim_list_wins() == 1", "DAP UI close")

  commands = child.lua_get(([[(function()
    local commands = {}
    for _, line in ipairs(vim.fn.readfile(%s)) do
      table.insert(commands, vim.json.decode(line).command)
    end
    return commands
  end)()]]):format(vim.inspect(log)))
  assert_no_unexpected(commands)
end

return T
