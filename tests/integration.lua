local helper_path = assert(vim.env.LINGUA_MOTION_HELPER, "LINGUA_MOTION_HELPER is required")
local lingua_motion = require("lingua_motion")

local function reset_buffer(source_lines, row, column)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, source_lines)
	vim.api.nvim_win_set_cursor(0, { row + 1, column })
	vim.cmd("normal! \27")
end

local function feed_keys(input_keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(input_keys, true, false, true), "xt", false)
	vim.wait(300, function()
		return false
	end, 1)
end

local function get_cursor_position()
	local cursor = vim.api.nvim_win_get_cursor(0)
	return cursor[1] - 1, cursor[2]
end

local function assert_cursor_position(expected_row, expected_column)
	local actual_row, actual_column = get_cursor_position()
	assert(
		actual_row == expected_row and actual_column == expected_column,
		("expected %d:%d, got %d:%d"):format(expected_row, expected_column, actual_row, actual_column)
	)
end

local function capture_unmodified_mode_mappings()
	local mappings_snapshot = {}
	for _, mapping_mode in ipairs({ "i", "c", "t" }) do
		for _, existing_mapping in ipairs(vim.api.nvim_get_keymap(mapping_mode)) do
			mappings_snapshot[#mappings_snapshot + 1] = {
				mode = mapping_mode,
				lhs = existing_mapping.lhs,
				rhs = existing_mapping.rhs,
				desc = existing_mapping.desc,
				expr = existing_mapping.expr,
				noremap = existing_mapping.noremap,
				callback = type(existing_mapping.callback),
			}
		end
	end
	table.sort(mappings_snapshot, function(first_mapping, second_mapping)
		return vim.json.encode(first_mapping) < vim.json.encode(second_mapping)
	end)
	return mappings_snapshot
end

local function capture_autocmd_snapshot()
	local autocmd_snapshot = {}
	for _, autocmd_entry in ipairs(vim.api.nvim_get_autocmds({})) do
		autocmd_snapshot[#autocmd_snapshot + 1] = {
			event = autocmd_entry.event,
			pattern = autocmd_entry.pattern,
			command = autocmd_entry.command,
			desc = autocmd_entry.desc,
			group_name = autocmd_entry.group_name,
		}
	end
	table.sort(autocmd_snapshot, function(first_autocmd, second_autocmd)
		return vim.json.encode(first_autocmd) < vim.json.encode(second_autocmd)
	end)
	return autocmd_snapshot
end

local maps_before_setup = capture_unmodified_mode_mappings()
local autocmds_before_setup = capture_autocmd_snapshot()
local restored_mapping_calls = 0
vim.keymap.set("n", "w", function()
	restored_mapping_calls = restored_mapping_calls + 1
end, { desc = "preexisting user mapping" })
lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500 })
assert(vim.deep_equal(maps_before_setup, capture_unmodified_mode_mappings()), "setup changed i/c/t maps")
assert(vim.deep_equal(autocmds_before_setup, capture_autocmd_snapshot()), "setup changed autocmds")
lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false })
feed_keys("w")
assert(restored_mapping_calls == 1, "setup did not restore a preexisting user mapping")
lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500 })

local health_errors = {}
local original_health_start, original_health_ok, original_health_error =
	vim.health.start, vim.health.ok, vim.health.error
rawset(vim.health, "start", function() end)
rawset(vim.health, "ok", function() end)
rawset(vim.health, "error", function(message)
	health_errors[#health_errors + 1] = message
end)
require("lingua-motion.health").check()
rawset(vim.health, "start", original_health_start)
rawset(vim.health, "ok", original_health_ok)
rawset(vim.health, "error", original_health_error)
assert(#health_errors == 0, "health check failed: " .. table.concat(health_errors, "; "))

local original_buffer_get_lines = vim.api.nvim_buf_get_lines
local accessed_ranges = {}
rawset(vim.api, "nvim_buf_get_lines", function(buffer_handle, start_row, end_row, strict_indexing)
	assert(end_row - start_row == 1, "word motion fetched more than one line")
	accessed_ranges[#accessed_ranges + 1] = { start_row, end_row }
	return original_buffer_get_lines(buffer_handle, start_row, end_row, strict_indexing)
end)
reset_buffer({ "lazy a b" }, 0, 0)
lingua_motion.motion("w")
rawset(vim.api, "nvim_buf_get_lines", original_buffer_get_lines)
assert(#accessed_ranges == 1 and accessed_ranges[1][1] == 0, "motion did not use a lazy line accessor")

reset_buffer({ "日本語です。", "", "ASCII, 日本語" }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, 6)
reset_buffer({ "日本語です。", "", "ASCII, 日本語" }, 0, 0)
lingua_motion.motion("e")
assert_cursor_position(0, 3)
reset_buffer({ "日本語です。", "", "ASCII, 日本語" }, 0, 6)
lingua_motion.motion("b")
assert_cursor_position(0, 0)
reset_buffer({ "日本語です。", "", "ASCII, 日本語" }, 0, 6)
lingua_motion.motion("ge")
assert_cursor_position(0, 3)
reset_buffer({ "日本語です。", "", "ASCII, 日本語" }, 0, 15)
lingua_motion.motion("w")
assert_cursor_position(2, 0)
local emoji_line = "東京→Shanghai→New York✈️ 世界一周旅行を计划中です🌏"
local plane_column = assert(emoji_line:find("✈", 1, true)) - 1
local world_column = assert(emoji_line:find("世界", 1, true)) - 1
reset_buffer({ emoji_line }, 0, plane_column)
lingua_motion.motion("w")
assert_cursor_position(0, world_column)

reset_buffer({ "One sentence. Next sentence!", "続く。" }, 0, 0)
lingua_motion.motion(")")
assert_cursor_position(0, 14)
lingua_motion.motion(")")
assert_cursor_position(1, 0)
reset_buffer({ "One sentence. Next sentence!", "続く。" }, 1, 0)
lingua_motion.motion("(")
assert_cursor_position(0, 14)
reset_buffer({ "One.", "", "Two." }, 0, 0)
lingua_motion.motion(")")
assert_cursor_position(2, 0)
reset_buffer({ "One.", "", "Two." }, 2, 0)
lingua_motion.motion("(")
assert_cursor_position(0, 0)
reset_buffer({ "One.", "　", "Two." }, 0, 0)
lingua_motion.motion(")")
assert_cursor_position(2, 0)
reset_buffer({ "One.", " ", "Two." }, 0, 0)
lingua_motion.motion(")")
assert_cursor_position(2, 0)

reset_buffer({ "a b c d" }, 0, 0)
feed_keys("2w")
assert_cursor_position(0, 4)
reset_buffer({ "a b c d" }, 0, 0)
feed_keys("2e")
assert_cursor_position(0, 4)
reset_buffer({ "a b c d" }, 0, 6)
feed_keys("2b")
assert_cursor_position(0, 2)
reset_buffer({ "a b c d e" }, 0, 0)
feed_keys("d2e")
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == " d e",
	"d2e inclusivity failed: " .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
)
reset_buffer({ "a b c d e" }, 0, 8)
feed_keys("d2ge")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "a b ", "d2ge inclusivity failed")

reset_buffer({ "日本語。次" }, 0, 0)
feed_keys("diw")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "語。次", "diw failed")
reset_buffer({ "日本語。次" }, 0, 0)
feed_keys("de")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "語。次", "de inclusivity failed")
reset_buffer({ "日本語。次" }, 0, 0)
feed_keys("ciwX\27")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "X語。次", "ciw failed")
reset_buffer({ "日本語。次" }, 0, 0)
feed_keys("yiw")
assert(vim.fn.getreg('"') == "日本", "yiw failed")
reset_buffer({ "a b" }, 0, 0)
feed_keys("daw")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "b", "daw failed")
reset_buffer({ "a b c" }, 0, 0)
feed_keys("d2aw")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "c", "d2aw whitespace failed")
reset_buffer({ "a b" }, 0, 0)
lingua_motion.textobject("iw")
feed_keys('"by')
assert(vim.fn.getreg("b") == "a", "normal textobject selection failed")
reset_buffer({ "a b" }, 0, 0)
vim.cmd("normal! v")
lingua_motion.textobject("iw")
feed_keys('"by')
assert(vim.fn.getreg("b") == "a", "visual textobject selection failed")
reset_buffer({ "a b", "c d" }, 0, 0)
vim.cmd("normal! V")
lingua_motion.textobject("iw")
feed_keys('"cy')
assert(vim.fn.getreg("c") == "a", "linewise visual textobject selection failed")
reset_buffer({ "a b", "c d" }, 0, 0)
vim.cmd("normal! \22")
lingua_motion.textobject("iw")
feed_keys('"dy')
assert(vim.fn.getreg("d") == "a", "blockwise visual textobject selection failed")

reset_buffer({ "One sentence. Next sentence!", "続く。" }, 0, 0)
feed_keys("dis")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == " Next sentence!", "dis failed")
reset_buffer({ "One sentence. Next sentence!", "続く。" }, 0, 0)
feed_keys("cisX\27")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "X Next sentence!", "cis failed")
reset_buffer({ "One sentence. Next sentence!", "続く。" }, 0, 0)
feed_keys("yas")
assert(vim.fn.getreg('"') == "One sentence. ", "yas failed")
reset_buffer({ "One.", "Next." }, 0, 0)
feed_keys("yas")
assert(vim.fn.getreg('"') == "One.\n", "multiline yas included the next sentence: " .. vim.inspect(vim.fn.getreg('"')))
local previous_virtualedit = vim.wo.virtualedit
reset_buffer({ "One.", "Next." }, 0, 0)
lingua_motion.textobject("as")
feed_keys('"ey')
assert(vim.fn.getreg("e") == "One.\n", "normal multiline as selection failed")
assert(vim.wo.virtualedit == previous_virtualedit, "normal multiline as changed virtualedit")
reset_buffer({ "One.", "Next." }, 0, 0)
vim.cmd("normal! v")
lingua_motion.textobject("as")
feed_keys('"fy')
assert(vim.fn.getreg("f") == "One.\n", "visual multiline as selection failed")
assert(vim.wo.virtualedit == previous_virtualedit, "visual multiline as changed virtualedit")
local previous_global_virtualedit = vim.go.virtualedit
local previous_window_virtualedit = vim.wo.virtualedit
vim.go.virtualedit = ""
vim.wo.virtualedit = "block"
reset_buffer({ "One.", "Next." }, 0, 0)
lingua_motion.textobject("as")
feed_keys('"gy')
assert(vim.fn.getreg("g") == "One.\n", "local virtualedit multiline as selection failed")
assert(vim.go.virtualedit == "", "multiline as changed global virtualedit")
assert(vim.wo.virtualedit == "block", "multiline as changed local virtualedit")
vim.go.virtualedit = previous_global_virtualedit
vim.wo.virtualedit = previous_window_virtualedit
reset_buffer({ "One.", "Next." }, 0, 0)
feed_keys("das")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "Next.", "multiline das removed the next sentence")
reset_buffer({ "One. Two. Three." }, 0, 0)
feed_keys("d2as")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "Three.", "d2as whitespace failed")

lingua_motion.setup({ helper_path = "/usr/bin/false", timeout_ms = 20, mappings = false })
reset_buffer({ "a b" }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, 2)
reset_buffer({ "a b" }, 0, 0)
feed_keys("dw")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "b", "native fallback failed")
reset_buffer({ "a b" }, 0, 0)
lingua_motion.setup({ helper_path = "/usr/bin/false", timeout_ms = 20, mappings = true })
reset_buffer({ "a b" }, 0, 0)
feed_keys("diw")
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == " b",
	"textobject fallback failed: " .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
)
reset_buffer({ "a b c" }, 0, 0)
feed_keys("diw")
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == " b c",
	"fallback register replay failed: " .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
)
assert(vim.fn.getreg('"') == "a", "fallback register was not preserved")
reset_buffer({ "a b c" }, 0, 0)
feed_keys('"adiw')
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == " b c",
	"named fallback register failed: " .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
)
assert(vim.fn.getreg("a") == "a", "named fallback register was not preserved")
reset_buffer({ "a b c" }, 0, 0)
feed_keys("d2iw")
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "b c",
	"fallback count replay failed: " .. vim.api.nvim_buf_get_lines(0, 0, -1, false)[1]
)

lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false, language = "ja" })
reset_buffer({ "日本語。次" }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, 6)

print("integration ok")
vim.cmd("qa!")
