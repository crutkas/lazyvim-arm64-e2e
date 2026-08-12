local output = assert(vim.env.LVB_E2E_OUTPUT, "LVB_E2E_OUTPUT is required")
local timeout = tonumber(vim.env.LVB_E2E_TIMEOUT_MS) or 900000
local parsers = {
  "bash",
  "c",
  "diff",
  "html",
  "javascript",
  "jsdoc",
  "json",
  "lua",
  "luadoc",
  "luap",
  "markdown",
  "markdown_inline",
  "printf",
  "python",
  "query",
  "regex",
  "toml",
  "tsx",
  "typescript",
  "vim",
  "vimdoc",
  "xml",
  "yaml",
}
local started = vim.uv.hrtime()
local callback_finished = false
local task_started = false
local task_ok = false
local install_error
local check_ok
local health
local preflight
local before = {
  CC = vim.env.CC or vim.NIL,
  CRATE_CC_NO_DEFAULTS = vim.env.CRATE_CC_NO_DEFAULTS or vim.NIL,
}

local ok_build, build_error = pcall(function()
  LazyVim.treesitter.build(function()
    task_started = true
    check_ok, health, preflight = LazyVim.treesitter.check()
    local ok_wait, wait_result = pcall(function()
      return require("nvim-treesitter").install(parsers, { summary = true }):wait(timeout)
    end)
    task_ok = ok_wait and wait_result == true
    if not task_ok then
      install_error = ok_wait and "install task returned false" or tostring(wait_result)
    end
    callback_finished = true
  end)
end)
if not ok_build then
  install_error = tostring(build_error)
  callback_finished = true
end

local completed = vim.wait(timeout + 30000, function()
  return callback_finished
end, 100)
local TS = require("nvim-treesitter")
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/site")
local installed = TS.get_installed("parsers")
local results = {}
local success = completed and task_started and task_ok and install_error == nil

for _, parser in ipairs(parsers) do
  local files = vim.api.nvim_get_runtime_file("parser/" .. parser .. ".*", false)
  local load_ok, load_error = pcall(function()
    assert(#files > 0, "No runtime parser file was found.")
    vim.treesitter.language.add(parser)
    vim.treesitter.get_string_parser("", parser):parse()
  end)
  results[parser] = {
    files = files,
    installed = vim.tbl_contains(installed, parser),
    load_error = not load_ok and tostring(load_error) or nil,
    load_ok = load_ok,
  }
  success = success and results[parser].installed and load_ok
end

local dependencies = {}
for _, parser in ipairs(installed) do
  if not vim.tbl_contains(parsers, parser) then
    local files = vim.api.nvim_get_runtime_file("parser/" .. parser .. ".*", false)
    local load_ok, load_error = pcall(function()
      assert(#files > 0, "No runtime parser file was found.")
      vim.treesitter.language.add(parser)
      vim.treesitter.get_string_parser("", parser):parse()
    end)
    dependencies[parser] = {
      files = files,
      load_error = not load_ok and tostring(load_error) or nil,
      load_ok = load_ok,
    }
    success = success and load_ok
  end
end

vim.fn.writefile({
  vim.json.encode({
    after = {
      CC = vim.env.CC,
      CRATE_CC_NO_DEFAULTS = vim.env.CRATE_CC_NO_DEFAULTS,
    },
    before = before,
    completed = completed,
    check_ok = check_ok,
    dependencies = dependencies,
    elapsed_ms = (vim.uv.hrtime() - started) / 1000000,
    error = install_error,
    health = health,
    installed = installed,
    parsers = parsers,
    platform = vim.uv.os_uname(),
    preflight = preflight,
    results = results,
    task_ok = task_ok,
    task_started = task_started,
  }),
}, output)

vim.cmd(success and "qa!" or "cquit 22")
