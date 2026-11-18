local tests_dir = vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))
package.path = tests_dir .. "/?.lua;" .. package.path
local config = require "config"
io.stdout:write(require("test_environment").compatibility_fingerprint(config.root) .. "\n")
