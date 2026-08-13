local root = assert(vim.env.LINGUA_MOTION_PLUGIN_ROOT)

vim.opt.runtimepath:prepend(root)

require("lingua_motion").setup({
	helper_path = root .. "/lingua-motion-helper",
})

local function prepare_buffer()
	if not vim.api.nvim_buf_is_valid(0) or vim.api.nvim_buf_line_count(0) < 20 then
		vim.schedule(prepare_buffer)
		return
	end
	vim.bo.bufhidden = "wipe"
	vim.bo.swapfile = false
	vim.bo.modified = false
	vim.bo.filetype = "lingua-motion-demo"
	vim.bo.syntax = "markdown"
	vim.api.nvim_buf_set_name(0, "multilingual-demo.md")
	pcall(vim.treesitter.start, 0, "markdown")
	local ok, lazy = pcall(require, "lazy")
	if ok then
		pcall(lazy.load, { plugins = { "mini.map" } })
	end
	vim.api.nvim_win_set_cursor(0, { 5, 0 })
	vim.cmd("normal! zz")
	vim.defer_fn(function()
		vim.cmd("redraw!")
		vim.g.lingua_motion_demo_ready = 1
	end, 300)
end

vim.schedule(prepare_buffer)
