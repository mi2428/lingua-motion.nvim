#!/bin/sh
set -eu

package=$1
test -f "$package/lua/lingua_motion/init.lua"
test -f "$package/doc/lingua-motion.txt"
test -f "$package/doc/tags"

LINGUA_MOTION_PACKAGE="$package" nvim --headless --clean -u NONE -i NONE \
  --cmd 'lua vim.opt.runtimepath:prepend(vim.env.LINGUA_MOTION_PACKAGE)' \
  -c 'lua local ok, err = pcall(function()
    local package = vim.env.LINGUA_MOTION_PACKAGE
    local found = false
    for _, line in ipairs(vim.fn.readfile(package .. "/doc/tags")) do
      if line:match("^lingua%-motion\t") then found = true end
    end
    assert(found, "installed lingua-motion help tag is missing")
    vim.cmd.help("lingua-motion")
    assert(vim.fn.resolve(vim.api.nvim_buf_get_name(0))
      == vim.fn.resolve(package .. "/doc/lingua-motion.txt"),
      "help resolved outside the installed package")
  end)
  if not ok then vim.api.nvim_err_writeln(tostring(err)); vim.cmd("cquit 1") end' \
  -c 'qa!'
