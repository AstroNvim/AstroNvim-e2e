local environment = require "test_environment"

local M = {}

local function normalize(path) return vim.fs.normalize(path):gsub("/$", "") end

local function canonical(path)
  local resolved = vim.uv.fs_realpath(path)
  if not resolved then error("Failed to resolve test path: " .. path, 0) end
  return normalize(resolved)
end

local tests_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
local default_harness_root = vim.fs.dirname(tests_dir)
local default_source_root = vim.fs.joinpath(vim.fs.dirname(default_harness_root), "AstroNvim")
local harness_root = canonical(vim.env.ASTRONVIM_E2E_ROOT or default_harness_root)
local source_root = canonical(vim.env.ASTRONVIM_SOURCE_ROOT or default_source_root)

local function require_entry(path, expected_type, message)
  local entry = vim.uv.fs_lstat(path)
  if not entry or entry.type ~= expected_type then error(message .. ": " .. path, 0) end
end

require_entry(source_root .. "/lua/astronvim", "directory", "ASTRONVIM_SOURCE_ROOT is not an AstroNvim checkout")
require_entry(source_root .. "/version.txt", "file", "ASTRONVIM_SOURCE_ROOT is not an AstroNvim checkout")
require_entry(harness_root .. "/tests/fixtures/init.lua", "file", "ASTRONVIM_E2E_ROOT is not an e2e checkout")
require_entry(harness_root .. "/tests/e2e", "directory", "ASTRONVIM_E2E_ROOT is not an e2e checkout")

M.root = source_root
M.source_root = source_root
M.harness_root = harness_root
M.environment_schema = environment.schema
M.fixture_init = harness_root .. "/tests/fixtures/init.lua"
M.fixture_project = harness_root .. "/tests/fixtures/project"
M.screenshots_dir = harness_root .. "/tests/screenshots"
M.highlights_dir = harness_root .. "/tests/highlights"
M.golden_nvim_version = "0.12.4"
M.child_width = 100
M.child_height = 30
M.wait_timeout = 15000

function M.paths_for_test_root(test_root)
  local paths = environment.paths_for_test_root(normalize(test_root))
  paths.root = paths.test_root
  return paths
end

function M.paths_for(root) return environment.paths(normalize(root)) end

local paths = M.paths_for(M.root)
for name, value in pairs(paths) do
  M[name] = value
end

local function lstat(path) return vim.uv.fs_lstat(path) end

local function read_json(path)
  local file, open_error = io.open(path, "rb")
  if not file then return nil, open_error end
  local contents = file:read "*a"
  file:close()
  local ok, decoded = pcall(vim.json.decode, contents)
  if not ok then return nil, decoded end
  return decoded
end

function M.classify_environment() return environment.classify(paths, lstat) end

local function run_read_only_git(arguments)
  return vim
    .system(vim.list_extend({ "git" }, arguments), {
      text = true,
      env = { GIT_OPTIONAL_LOCKS = "0" },
    })
    :wait()
end

local function verify_repository(relative_path, expected_commit)
  if not environment.is_safe_relative_path(relative_path) then return false end
  local path = M.test_root .. "/" .. relative_path
  if not environment.has_safe_path_type(M.root, path, "directory", lstat) then return false end

  local revision = run_read_only_git { "-C", path, "rev-parse", "HEAD" }
  if revision.code ~= 0 or vim.trim(revision.stdout) ~= expected_commit then return false end
  local status = run_read_only_git { "-C", path, "status", "--porcelain", "--untracked-files=no" }
  return status.code == 0 and status.stdout == ""
end

function M.validate_ready_environment()
  for _, file in ipairs { M.ready, M.manifest, M.lockfile } do
    if not environment.has_safe_path_type(M.root, file, "file", lstat) then
      return false, "required lifecycle file is missing or unsafe: " .. file
    end
  end

  local marker, marker_error = read_json(M.ready)
  if not marker then return false, "cannot read .ready: " .. tostring(marker_error) end
  local manifest, manifest_error = read_json(M.manifest)
  if not manifest then return false, "cannot read manifest.json: " .. tostring(manifest_error) end
  local lock, lock_error = read_json(M.lockfile)
  if not lock then return false, "cannot read lazy-lock.json: " .. tostring(lock_error) end

  local fingerprint = environment.compatibility_fingerprint(M.root)
  local valid, result = environment.validate_ready(marker, manifest, lock, function(relative_path, expected_type)
    if not environment.is_safe_relative_path(relative_path) then return false end
    return environment.has_safe_path_type(M.root, M.test_root .. "/" .. relative_path, expected_type, lstat)
  end, fingerprint)
  if not valid then return false, result end
  if not verify_repository(result.lazy.path, result.lazy.commit) then
    return false, "lazy.nvim is missing, changed, or has tracked modifications"
  end
  for name, plugin in pairs(result.plugins) do
    if not verify_repository(plugin.path, plugin.commit) then
      return false, "managed plugin is missing, changed, or has tracked modifications: " .. name
    end
  end
  return true
end

function M.assert_ready_environment()
  local ok, message = M.validate_ready_environment()
  if not ok then
    error(("Test environment is incomplete or incompatible. Run `make test-clear` then retry: %s"):format(message), 0)
  end
end

function M.assert_staging_path(path)
  if not environment.is_staging_target(M.root, normalize(path)) then
    error("Refusing to modify a non-canonical test staging path", 0)
  end
end

return M
