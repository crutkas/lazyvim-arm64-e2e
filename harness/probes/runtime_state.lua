local output = assert(vim.env.LVB_E2E_OUTPUT, "LVB_E2E_OUTPUT is required")
local lazy = require("lazy")
local config = require("lazy.core.config")
local pending = {}

for name, plugin in pairs(config.plugins) do
  if plugin._ and plugin._.tasks and #plugin._.tasks > 0 then
    pending[#pending + 1] = name
  end
end
table.sort(pending)

vim.fn.writefile({
  vim.json.encode({
    lazy_stats = lazy.stats(),
    pending_plugin_tasks = pending,
    runtime = vim.api.nvim_list_runtime_paths(),
  }),
}, output)
vim.cmd(#pending == 0 and "qa!" or "cquit 24")
