local output = assert(vim.env.LVB_E2E_OUTPUT, "LVB_E2E_OUTPUT is required")
local timeout = tonumber(vim.env.LVB_E2E_TIMEOUT_MS) or 900000
local target = vim.env.LVB_E2E_MASON_TARGET or "auto"
local registry_source = assert(vim.env.LVB_E2E_MASON_REGISTRY, "LVB_E2E_MASON_REGISTRY is required")
local names = { "stylua", "shfmt", "lua-language-server", "tree-sitter-cli" }
local results = {}
local packages = {}
local started = {}
local remaining = #names
local fatal
local registry_sources = {}

require("mason").setup({ registries = { registry_source } })
local registry = require("mason-registry")

local function finish(name, package, success, err)
  if results[name] then
    return
  end
  local error_message
  if success ~= true and err ~= nil then
    error_message = tostring(err)
  end
  results[name] = {
    success = success == true,
    installed = package:is_installed(),
    elapsed_ms = (vim.uv.hrtime() - started[name]) / 1000000,
    error = error_message,
    source = package.spec.source,
  }
  remaining = remaining - 1
end

local ok_refresh, refresh_error = pcall(registry.refresh, function()
  for source in registry.sources:iterate({ include_uninstalled = true }) do
    registry_sources[#registry_sources + 1] = source:get_display_name()
  end
  for _, name in ipairs(names) do
    local ok_package, package = pcall(registry.get_package, name)
    if not ok_package then
      results[name] = { success = false, error = tostring(package) }
      remaining = remaining - 1
    else
      packages[name] = package
      started[name] = vim.uv.hrtime()
      package:on("install:success", vim.schedule_wrap(function()
        finish(name, package, true)
      end))
      package:on("install:failed", vim.schedule_wrap(function(err)
        finish(name, package, false, err)
      end))
      local ok_install, install_error = pcall(function()
        local opts = { force = true }
        if target ~= "auto" then
          opts.target = target
        end
        package:install(opts, vim.schedule_wrap(function(success, err)
          finish(name, package, success, err)
        end))
      end)
      if not ok_install then
        finish(name, package, false, install_error)
      end
    end
  end
end)

if not ok_refresh then
  fatal = tostring(refresh_error)
end

local completed = vim.wait(timeout, function()
  return fatal ~= nil or remaining == 0
end, 100)

for _, name in ipairs(names) do
  if not results[name] then
    local package = packages[name]
    results[name] = {
      success = false,
      installed = package and package:is_installed() or false,
      timed_out = not completed,
    }
  end
end

vim.fn.writefile({
  vim.json.encode({
    completed = completed,
    fatal = fatal,
    platform = vim.uv.os_uname(),
    registry = registry_source,
    registry_sources = registry_sources,
    results = results,
    target = target,
  }),
}, output)

local success = completed and fatal == nil
for _, result in pairs(results) do
  success = success and result.success == true and result.installed == true
end
vim.cmd(success and "qa!" or "cquit 20")
