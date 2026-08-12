local output = assert(vim.env.LVB_E2E_OUTPUT, "LVB_E2E_OUTPUT is required")
local timeout = math.min(tonumber(vim.env.LVB_E2E_TIMEOUT_MS) or 900000, 120000)
vim.lsp.set_log_level("trace")
vim.bo.filetype = "lua"

local attached = vim.wait(timeout, function()
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
    if client.name == "lua_ls" then
      return true
    end
  end
  return false
end, 100)

local clients = {}
local hover_ok = false
local hover_result
local hover_error
for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
  clients[#clients + 1] = {
    cmd = client.config and client.config.cmd or nil,
    id = client.id,
    name = client.name,
    root_dir = client.root_dir,
  }
  if client.name == "lua_ls" then
    local params = vim.lsp.util.make_position_params(0, client.offset_encoding)
    local response = client:request_sync("textDocument/hover", params, 30000, 0)
    hover_result = response and response.result or nil
    hover_error = response and response.err or nil
    if not response then
      hover_error = "no response"
    end
    hover_ok = response ~= nil and response.err == nil
  end
end

local stop_requested = false
for _, client in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
  if client.name == "lua_ls" then
    client:stop(false)
    stop_requested = true
  end
end
local stopped_before_exit = vim.wait(5000, function()
  for _, client in ipairs(vim.lsp.get_clients()) do
    if client.name == "lua_ls" then
      return false
    end
  end
  return true
end, 100)

vim.fn.writefile({
  vim.json.encode({
    attached = attached,
    clients = clients,
    hover_error = hover_error,
    hover_ok = hover_ok,
    hover_result = hover_result,
    lsp_log = vim.lsp.log.get_filename(),
    stop_requested = stop_requested,
    stopped_before_exit = stopped_before_exit,
  }),
}, output)

vim.cmd(attached and hover_ok and stop_requested and "qa!" or "cquit 23")
