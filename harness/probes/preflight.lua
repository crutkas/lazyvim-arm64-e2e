local output = assert(vim.env.LVB_E2E_OUTPUT, "LVB_E2E_OUTPUT is required")
local before = {
  CC = vim.env.CC or vim.NIL,
  CRATE_CC_NO_DEFAULTS = vim.env.CRATE_CC_NO_DEFAULTS or vim.NIL,
}
local preflight = LazyVim.treesitter.preflight({ apply = true })
local compiler = preflight.compiler

vim.fn.writefile({
  vim.json.encode({
    before = before,
    after = {
      CC = vim.env.CC,
      CRATE_CC_NO_DEFAULTS = vim.env.CRATE_CC_NO_DEFAULTS,
    },
    ok = preflight.ok,
    arch = preflight.arch,
    checks = preflight.checks,
    compiler = compiler and {
      arch = compiler.arch,
      command = compiler.command,
      explicit = compiler.explicit,
      host_arch = compiler.host_arch,
      kind = compiler.kind,
      machine = compiler.machine,
      path = compiler.path,
      target = compiler.target,
    } or nil,
    platform = vim.uv.os_uname(),
  }),
}, output)

vim.cmd(preflight.ok and "qa!" or "cquit 21")
