local MiniTest = require "mini.test"
local unit_helpers = require "unit_helpers"

local T = MiniTest.new_set()

local function assert_contains(value, expected) assert.is_true(tostring(value):find(expected, 1, true) ~= nil) end

local function assert_parent_environment_restored(state)
  for name, value in pairs(state.parent_environment) do
    assert.equals(value, state.environment[name])
  end
end

local function contains(values, expected)
  for _, value in ipairs(values) do
    if value == expected then return true end
  end
  return false
end

local function has_copy(copied_files, source, destination)
  for _, copy in ipairs(copied_files) do
    if copy[1] == source and copy[2] == destination then return true end
  end
  return false
end

local function with_helpers(options, callback)
  options = options or {}
  local state = {
    child_constructions = 0,
    copied_files = {},
    deleted_roots = {},
    jobs_alive = {},
    jobstop_ids = {},
    jobwait_ids = {},
    list_chans_calls = 0,
    lstat_paths = {},
    mkdir_paths = {},
    mkdtemp_template = nil,
    stop_attempts = 0,
    system_commands = {},
    scanned_paths = {},
    lua_get_calls = 0,
    lua_calls = {},
    wait_calls = 0,
    clock = 0,
  }
  local root = options.root or "/fixture-root"
  local parent_environment = {
    XDG_CONFIG_HOME = "/parent/config",
    XDG_DATA_HOME = "/parent/data",
    XDG_STATE_HOME = "/parent/state",
    XDG_CACHE_HOME = "/parent/cache",
    XDG_RUNTIME_DIR = "/parent/runtime",
    ASTRONVIM_TEST_ROOT = "/parent/test-root",
    ASTRONVIM_TEST_LAZY_PATH = "/parent/lazy.nvim",
    ASTRONVIM_TEST_PLUGIN_ROOT = "/parent/plugins",
    ASTRONVIM_TEST_LOCKFILE = "/parent/lazy-lock.json",
    ASTRONVIM_TEST_NVIM = "/parent/nvim",
  }
  for name, value in pairs(options.parent_environment or {}) do
    parent_environment[name] = value
  end
  local mock_environment = {}
  for name, value in pairs(parent_environment) do
    mock_environment[name] = value
  end
  state.parent_environment = parent_environment
  state.environment = mock_environment
  local fixture_entries = {
    ["/fixture-project"] = {
      { ".vscode", "directory" },
      { "git-tracked.txt", "file" },
      { "indentation.txt", "file" },
      { "plain.txt", "file" },
      { "session.json", "file" },
    },
    ["/fixture-project/.vscode"] = {
      { "launch.json", "file" },
    },
  }
  for path, entries in pairs(options.fixture_entries or {}) do
    fixture_entries[path] = entries
  end
  local function fixture_lstat(path)
    if path == "/fixture-project" then return { type = "directory" } end
    for parent, entries in pairs(fixture_entries) do
      for _, entry in ipairs(entries) do
        if vim.fs.joinpath(parent, entry[1]) == path then return { type = entry[2] } end
      end
    end
  end
  local function configured_lstat(path)
    local configured = options.fs_lstat_result
    if type(configured) == "function" then return configured(path) end
    if type(configured) == "table" then
      if configured[path] ~= nil then return configured[path] end
      if path == root and configured.type ~= nil then return configured end
    end
  end
  if options.job_id then state.jobs_alive[options.job_id] = options.job_alive ~= false end
  for _, channel in ipairs(options.channels or {}) do
    if options.channel_alive ~= false then state.jobs_alive[channel.id] = true end
  end

  local child = {
    job = options.job_id and { id = options.job_id } or nil,
    lua_get = function()
      state.lua_get_calls = state.lua_get_calls + 1
      local value = table.remove(options.wait_values or {}, 1)
      if value == "error" then error "child RPC failed" end
      return value == nil and false or value
    end,
    lua = function(expression)
      table.insert(state.lua_calls, expression)
      if options.lua_error then error(options.lua_error) end
    end,
    start = function()
      if options.start_error then error(options.start_error) end
    end,
    is_running = function()
      if options.is_running_error then error(options.is_running_error) end
      return options.child_running ~= false
    end,
    stop = function()
      state.stop_attempts = state.stop_attempts + 1
      if options.stop_error then error(options.stop_error) end
      if options.job_id and not options.stop_leaves_job_alive then state.jobs_alive[options.job_id] = false end
    end,
  }
  state.child = child

  return unit_helpers.with_module("helpers", {
    loaded = {
      config = {
        child_height = 30,
        child_width = 100,
        fixture_init = "/fixture-init.lua",
        fixture_project = "/fixture-project",
        lazy_path = "/lazy.nvim",
        lockfile = "/lazy-lock.json",
        plugin_root = "/plugins",
        root = "/astronvim",
        wait_timeout = 100,
      },
      ["mini.test"] = {
        new_child_neovim = function()
          state.child_constructions = state.child_constructions + 1
          if options.construction_error then error(options.construction_error) end
          return child
        end,
      },
    },
    replace_vim = { env = true },
    vim = {
      env = mock_environment,
      api = {
        nvim_list_chans = function()
          state.list_chans_calls = state.list_chans_calls + 1
          if state.list_chans_calls == 1 then return options.initial_channels or {} end
          return options.channels or {}
        end,
      },
      fn = {
        delete = function(path)
          table.insert(state.deleted_roots, path)
          if type(options.delete_result) == "function" then return options.delete_result(path, #state.deleted_roots) end
          return options.delete_result or 0
        end,
        fnameescape = function(path) return path end,
        isdirectory = function(path)
          if options.isdirectory_result then return options.isdirectory_result(path, #state.mkdir_paths) end
          return 1
        end,
        jobstop = function(job_id)
          table.insert(state.jobstop_ids, job_id)
          if not options.jobstop_survives then state.jobs_alive[job_id] = false end
        end,
        jobwait = function(job_ids)
          local result = {}
          for _, job_id in ipairs(job_ids) do
            table.insert(state.jobwait_ids, job_id)
            table.insert(result, state.jobs_alive[job_id] and -1 or 0)
          end
          return result
        end,
        mkdir = function(path)
          table.insert(state.mkdir_paths, path)
          if options.mkdir_result then return options.mkdir_result(path, #state.mkdir_paths) end
          return 1
        end,
        writefile = function() return options.writefile_result or 0 end,
      },
      system = function(command)
        table.insert(state.system_commands, command)
        return {
          wait = function()
            if options.system_result then
              local result = options.system_result(command, #state.system_commands)
              if result then return result end
            end
            return { code = 0, stderr = "" }
          end,
        }
      end,
      uv = {
        hrtime = function() return state.clock end,
        fs_copyfile = function(source, destination)
          if options.copy_error then return nil, options.copy_error end
          table.insert(state.copied_files, { source, destination })
          return true
        end,
        fs_lstat = function(path)
          table.insert(state.lstat_paths, path)
          local configured = configured_lstat(path)
          if configured ~= nil then return configured end
          return fixture_lstat(path)
        end,
        fs_mkdtemp = function(template)
          state.mkdtemp_template = template
          return root
        end,
        fs_scandir = function(path)
          table.insert(state.scanned_paths, path)
          return { path = path, index = 0 }
        end,
        fs_scandir_next = function(scanner)
          scanner.index = scanner.index + 1
          local entry = fixture_entries[scanner.path] and fixture_entries[scanner.path][scanner.index]
          if entry then return entry[1], entry[2] end
        end,
        os_getenv = function(name) return mock_environment[name] end,
        os_tmpdir = function() return "/portable-temp" end,
      },
      wait = function(timeout)
        state.wait_calls = state.wait_calls + 1
        state.clock = state.clock + timeout * 1000000
      end,
    },
  }, function(helpers) return callback(helpers, state, root) end)
end

T["WAIT-01 retries child RPC conditions after a false result"] = function()
  with_helpers({ wait_values = { false, true } }, function(helpers, state)
    local child = helpers.start_child()
    assert.is_true(helpers.wait_until(child, "ready", "child readiness", 100))
    assert.is_true(state.lua_get_calls > 1)
    assert.is_true(state.wait_calls > 0)
    helpers.stop_child(child)
  end)
end

T["WAIT-02 reports a dead child instead of masking the RPC error as a timeout"] = function()
  with_helpers({ wait_values = { "error" }, child_running = false }, function(helpers, state)
    local child = helpers.start_child()
    local ok, err = pcall(helpers.wait_until, child, "ready", "child readiness", 100)

    assert.is_false(ok)
    assert_contains(err, "Child Neovim exited while waiting for child readiness")
    assert_contains(err, "child RPC failed")
    assert.is_true(state.lua_get_calls >= 1)
    helpers.stop_child(child)
  end)
end

T["WAIT-03 retains the final RPC error when a live child never becomes ready"] = function()
  with_helpers({ wait_values = { "error" } }, function(helpers, state)
    local child = helpers.start_child()
    local ok, err = pcall(helpers.wait_until, child, "ready", "child readiness", 100)

    assert.is_false(ok)
    assert_contains(err, "Timed out waiting for child readiness")
    assert_contains(err, "child RPC failed")
    assert.is_true(state.lua_get_calls > 1)
    helpers.stop_child(child)
  end)
end

T["WAIT-04 detects a dead child job even when the child wrapper still reports running"] = function()
  with_helpers({ job_id = 42, job_alive = false, wait_values = { "error" } }, function(helpers, state)
    local child = helpers.start_child()
    local ok, err = pcall(helpers.wait_until, child, "ready", "child readiness", 100)

    assert.is_false(ok)
    assert_contains(err, "Child Neovim exited while waiting for child readiness")
    assert_contains(err, "child RPC failed")
    assert.is_true(#state.jobwait_ids >= 1)
    helpers.stop_child(child)
  end)
end

T["CHILD-01 starts a ready child and loads requested plugins"] = function()
  with_helpers({ wait_values = { true } }, function(helpers, state, root)
    local child = helpers.start_ready_child { "astrolsp" }

    assert.is_true(state.lua_get_calls >= 1)
    -- The exact load count guards against duplicate plugin loading.
    assert.equals(1, #state.lua_calls)
    assert_contains(state.lua_calls[1], "astrolsp")
    helpers.stop_child(child)
    assert.same({ root }, state.deleted_roots)
  end)
end

T["CHILD-02 cleans a child when readiness fails before the caller receives it"] = function()
  with_helpers({ wait_values = { false } }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_ready_child)
    local fixture_available = pcall(helpers.fixture_project, state.child)

    assert.is_false(ok)
    assert_contains(err, "Timed out waiting for VimEnter and LazyDone")
    assert.equals(1, state.stop_attempts)
    assert.same({ root }, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

T["CHILD-03 cleans a child when requested plugin loading fails"] = function()
  with_helpers({ wait_values = { true }, lua_error = "plugin loading failed" }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_ready_child, { "astrolsp" })
    local fixture_available = pcall(helpers.fixture_project, state.child)

    assert.is_false(ok)
    assert_contains(err, "plugin loading failed")
    assert.equals(1, state.stop_attempts)
    assert.same({ root }, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

T["PORT-01 creates fixtures under the platform temp directory and copies them through libuv"] = function()
  with_helpers({}, function(helpers, state, root)
    local child = helpers.start_child()
    assert.equals(root .. "/project", helpers.fixture_project(child))
    helpers.stop_child(child)

    assert.is_true(state.mkdtemp_template:sub(1, #"/portable-temp/") == "/portable-temp/")
    assert.is_true(contains(state.mkdir_paths, root .. "/project"))
    assert.is_true(contains(state.mkdir_paths, root .. "/project/.vscode"))
    for _, relative_path in ipairs {
      "git-tracked.txt",
      "indentation.txt",
      "plain.txt",
      "session.json",
      ".vscode/launch.json",
    } do
      assert.is_true(
        has_copy(state.copied_files, "/fixture-project/" .. relative_path, root .. "/project/" .. relative_path)
      )
    end
    for _, command in ipairs(state.system_commands) do
      assert.is_true(command[1] ~= "cp")
    end
    assert.same({ root }, state.deleted_roots)
  end)
end

T["TEST-05 removes the fixture root when directory creation fails"] = function()
  with_helpers({
    isdirectory_result = function() return 0 end,
    mkdir_result = function() return 0 end,
  }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)

    assert.is_false(ok)
    assert_contains(err, "Failed to create test fixture directory: " .. root .. "/config")
    assert.equals(0, state.child_constructions)
    assert.same({ root }, state.deleted_roots)
  end)
end

T["TEST-05 rejects a nested symbolic link before constructing the child"] = function()
  local link = "/fixture-project/.vscode/nested-link"
  with_helpers({
    fixture_entries = {
      ["/fixture-project/.vscode"] = {
        { "nested-link", "directory" },
        { "launch.json", "file" },
      },
      [link] = {
        { "escaped.txt", "file" },
      },
    },
    fs_lstat_result = {
      [link] = { type = "link" },
    },
  }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)

    assert.is_false(ok)
    assert_contains(err, "symbolic link")
    assert_contains(err, link)
    assert.equals(0, state.child_constructions)
    assert.is_true(contains(state.lstat_paths, link))
    assert.is_false(has_copy(state.copied_files, link, root .. "/project/.vscode/nested-link"))
    assert.is_false(
      has_copy(state.copied_files, link .. "/escaped.txt", root .. "/project/.vscode/nested-link/escaped.txt")
    )
    assert.is_false(contains(state.scanned_paths, link))
    assert.same({ root }, state.deleted_roots)
  end)
end

T["TEST-05 removes the fixture root when copying the fixture fails"] = function()
  with_helpers({ copy_error = "copy failed" }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)

    assert.is_false(ok)
    assert_contains(err, "Failed to copy fixture project: copy failed")
    assert.equals(0, state.child_constructions)
    assert.same({ root }, state.deleted_roots)
    assert_parent_environment_restored(state)
  end)
end

T["TEST-05 removes the fixture root when Git initialization fails"] = function()
  with_helpers({
    system_result = function(command)
      if command[1] == "git" and command[2] == "init" then return { code = 1, stderr = "Git initialization failed" } end
    end,
  }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)

    assert.is_false(ok)
    assert_contains(err, "Failed to initialize fixture Git repository: Git initialization failed")
    assert.equals(0, state.child_constructions)
    assert.same({ root }, state.deleted_roots)
  end)
end

T["TEST-05 removes the fixture root when child construction fails"] = function()
  with_helpers({ construction_error = "child construction failed" }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)

    assert.is_false(ok)
    assert_contains(err, "child construction failed")
    assert.equals(1, state.child_constructions)
    assert.same({ root }, state.deleted_roots)
  end)
end

T["TEST-05 stops a child and removes its fixture root after startup fails"] = function()
  with_helpers(
    { job_id = 42, start_error = "child startup failed", stop_leaves_job_alive = true },
    function(helpers, state, root)
      local ok, err = pcall(helpers.start_child)
      local fixture_available = pcall(helpers.fixture_project, state.child)

      assert.is_false(ok)
      assert_contains(err, "child startup failed")
      assert.equals(1, state.stop_attempts)
      assert.same({ 42 }, state.jobstop_ids)
      assert.is_true(#state.jobwait_ids >= 1)
      assert.is_false(state.jobs_alive[42])
      assert.same({ root }, state.deleted_roots)
      assert_parent_environment_restored(state)
      assert.is_false(fixture_available)
    end
  )
end

T["TEST-05 discovers and cleans a fixture channel when startup fails before assigning a child job"] = function()
  with_helpers({
    channels = { { id = 43, argv = { "nvim", "-u", "/fixture-init.lua" } } },
    jobstop_survives = true,
    start_error = "child startup failed",
    stop_error = { kind = "channel stop failure" },
  }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)
    local fixture_available = pcall(helpers.fixture_project, state.child)

    assert.is_false(ok)
    assert_contains(err, "child startup failed")
    assert_contains(err, 'kind = "channel stop failure"')
    assert_contains(err, "Child Neovim processes survived shutdown: 43")
    assert.same({ 43 }, state.jobstop_ids)
    assert.is_true(#state.jobwait_ids >= 2)
    assert.is_true(state.jobs_alive[43])
    assert.same({}, state.deleted_roots)
    assert_contains(err, "Fixture retained for surviving child cleanup: " .. root)
    assert.is_false(fixture_available)
  end)
end

T["TEST-05 preserves child stop errors while releasing the fixture"] = function()
  with_helpers({ job_id = 42, stop_error = "child stop failed" }, function(helpers, state, root)
    local child = helpers.start_child()
    local project = helpers.fixture_project(child)
    local ok, err = pcall(helpers.stop_child, child)
    local fixture_available = pcall(helpers.fixture_project, child)

    assert.equals(root .. "/project", project)
    assert.is_false(ok)
    assert_contains(err, "child stop failed")
    assert.equals(1, state.stop_attempts)
    assert.same({ 42 }, state.jobstop_ids)
    assert.is_false(state.jobs_alive[42])
    assert.same({ root }, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

T["TEST-05 reports surviving child jobs together with non-string stop errors"] = function()
  with_helpers({
    job_id = 42,
    jobstop_survives = true,
    stop_error = { kind = "stop failure" },
  }, function(helpers, state, root)
    local child = helpers.start_child()
    local ok, err = pcall(helpers.stop_child, child)
    local fixture_available = pcall(helpers.fixture_project, child)

    assert.is_false(ok)
    assert_contains(err, 'kind = "stop failure"')
    assert_contains(err, "Child Neovim process survived shutdown")
    assert_contains(err, "Fixture retained for surviving child cleanup: " .. root)
    assert.same({ 42 }, state.jobstop_ids)
    assert.is_true(#state.jobwait_ids >= 2)
    assert.is_true(state.jobs_alive[42])
    assert.same({}, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

T["TEST-05 reports root deletion failures after releasing child state"] = function()
  with_helpers({ delete_result = 1 }, function(helpers, state, root)
    local child = helpers.start_child()
    local ok, err = pcall(helpers.stop_child, child)
    local fixture_available = pcall(helpers.fixture_project, child)

    assert.is_false(ok)
    assert_contains(err, "Failed to delete test fixture root: " .. root)
    assert.same({ root }, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

T["TEST-05 retries fixture deletion while a Windows handle is released"] = function()
  with_helpers({
    fs_lstat_result = { type = "directory" },
    delete_result = function(_, attempt) return attempt < 3 and 1 or 0 end,
  }, function(helpers, state, root)
    local child = helpers.start_child()
    helpers.stop_child(child)

    assert.is_true(#state.deleted_roots > 1)
    assert.is_true(state.wait_calls > 0)
    for _, deleted_root in ipairs(state.deleted_roots) do
      assert.equals(root, deleted_root)
    end
  end)
end

T["TEST-05 aggregates startup and cleanup errors"] = function()
  with_helpers({
    delete_result = 1,
    job_id = 42,
    start_error = "child startup failed",
    stop_error = "child stop failed",
  }, function(helpers, state, root)
    local ok, err = pcall(helpers.start_child)
    local fixture_available = pcall(helpers.fixture_project, state.child)

    assert.is_false(ok)
    assert_contains(err, "child startup failed")
    assert_contains(err, "Failed child cleanup:")
    assert_contains(err, "child stop failed")
    assert_contains(err, "Failed to delete test fixture root: " .. root)
    assert.equals(1, state.stop_attempts)
    assert.same({ root }, state.deleted_roots)
    assert.is_false(fixture_available)
  end)
end

return T
