local module = {}

function module.check()
	vim.health.start("lingua-motion.nvim")
	if vim.uv.os_uname().sysname ~= "Darwin" then
		vim.health.error("Apple NaturalLanguage requires macOS")
		return
	end
	vim.health.ok("Running on macOS")

	local configured, helper_path, timeout_ms, language = require("lingua_motion")._health_config()
	if not configured then
		vim.health.error("setup() has not been called")
		return
	end
	if vim.fn.executable(helper_path) ~= 1 then
		vim.health.error("Helper is not executable: " .. helper_path)
		return
	end
	local resolved_path = vim.fn.exepath(helper_path)
	vim.health.ok("Helper is executable: " .. (resolved_path ~= "" and resolved_path or helper_path))

	local source_text = "日本語 health check"
	local ran_ok, result = pcall(function()
		return vim.system({ helper_path }, {
			stdin = vim.json.encode({ id = 1, text = source_text, unit = "word", language = language }) .. "\n",
			text = true,
		}):wait(timeout_ms)
	end)
	if not ran_ok then
		vim.health.error("Failed to run helper: " .. tostring(result))
		return
	end
	if result.code == 124 then
		vim.health.error(("Helper timed out after %d ms"):format(timeout_ms))
		return
	end
	if result.code ~= 0 then
		vim.health.error(("Helper exited with code %d: %s"):format(result.code, vim.trim(result.stderr or "")))
		return
	end
	local decoded_ok, response = pcall(vim.json.decode, result.stdout or "")
	if
		not decoded_ok
		or type(response) ~= "table"
		or response.id ~= 1
		or response.error ~= nil
		or not require("lingua_motion.engine").validate_tokens(response.tokens, source_text)
	then
		vim.health.error("Helper returned an invalid response")
		return
	end
	vim.health.ok("Helper tokenization succeeded")
end

return module
