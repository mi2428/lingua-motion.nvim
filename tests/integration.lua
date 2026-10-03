local helper_path = assert(vim.env.LINGUA_MOTION_HELPER, "LINGUA_MOTION_HELPER is required")
local lingua_motion = require("lingua_motion")

local function reset_buffer(source_lines, row, column)
	vim.api.nvim_buf_set_lines(0, 0, -1, false, source_lines)
	vim.api.nvim_win_set_cursor(0, { row + 1, column })
	vim.cmd("normal! \27")
end

local function feed_keys(input_keys, native)
	vim.api.nvim_feedkeys(
		vim.api.nvim_replace_termcodes(input_keys, true, false, true),
		native and "nxt" or "xt",
		false
	)
	vim.wait(300, function()
		return false
	end, 1)
end

local function assert_native_keys(source_lines, row, column, native_keys, mapped_keys)
	local function capture_result(input_keys, native)
		reset_buffer(source_lines, row, column)
		vim.fn.setreg('"', "")
		vim.fn.setreg("z", "")
		feed_keys(input_keys, native)
		return {
			lines = vim.api.nvim_buf_get_lines(0, 0, -1, false),
			cursor = vim.api.nvim_win_get_cursor(0),
			mode = vim.fn.mode(1),
			unnamed = vim.fn.getreg('"'),
			register = vim.fn.getreg("z"),
			register_type = vim.fn.getregtype("z"),
		}
	end
	local expected = capture_result(native_keys, true)
	local actual = capture_result(mapped_keys or native_keys, false)
	assert(
		vim.deep_equal(expected, actual),
		("native mismatch for %s: expected %s, got %s"):format(
			mapped_keys or native_keys,
			vim.inspect(expected),
			vim.inspect(actual)
		)
	)
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

do
	local mapping_modes = { "n", "x", "o" }
	local overlapping_configs = {
		{
			word_motions = { w = "Q", e = "Q" },
			word_textobjects = false,
			sentence_motions = false,
			sentence_textobjects = false,
		},
		{
			word_motions = { w = "Q" },
			word_textobjects = { iw = "Q" },
			sentence_motions = { [")"] = "Q" },
			sentence_textobjects = { is = "Q" },
		},
	}
	for _, mapping_config in ipairs(overlapping_configs) do
		local original_mappings = {}
		local original_callback = function()
			return ""
		end
		for _, mapping_mode in ipairs(mapping_modes) do
			vim.keymap.set(mapping_mode, "Q", original_callback, {
				desc = "original user mapping",
				expr = true,
				nowait = true,
				remap = true,
			})
			original_mappings[mapping_mode] = vim.fn.maparg("Q", mapping_mode, false, true)
		end
		lingua_motion.setup({ mappings = mapping_config })
		lingua_motion.setup({ mappings = false })
		for _, mapping_mode in ipairs(mapping_modes) do
			assert(
				vim.deep_equal(vim.fn.maparg("Q", mapping_mode, false, true), original_mappings[mapping_mode]),
				"overlapping mappings did not restore original callback/metadata: " .. mapping_mode
			)
		end

		lingua_motion.setup({ mappings = mapping_config })
		lingua_motion.setup({
			mappings = {
				word_motions = { w = "R" },
				word_textobjects = false,
				sentence_motions = false,
				sentence_textobjects = false,
			},
		})
		lingua_motion.setup({ mappings = false })
		for _, mapping_mode in ipairs(mapping_modes) do
			assert(
				vim.deep_equal(vim.fn.maparg("Q", mapping_mode, false, true), original_mappings[mapping_mode]),
				"reconfiguration left an overlapping plugin mapping: " .. mapping_mode
			)
			assert(vim.tbl_isempty(vim.fn.maparg("R", mapping_mode, false, true)), "new mapping was not removed")
		end

		lingua_motion.setup({ mappings = mapping_config })
		local newer_mappings = {}
		for _, mapping_mode in ipairs(mapping_modes) do
			vim.keymap.set(mapping_mode, "Q", function() end, { desc = "newer user mapping", silent = true })
			newer_mappings[mapping_mode] = vim.fn.maparg("Q", mapping_mode, false, true)
		end
		lingua_motion.setup({ mappings = false })
		for _, mapping_mode in ipairs(mapping_modes) do
			assert(
				vim.deep_equal(vim.fn.maparg("Q", mapping_mode, false, true), newer_mappings[mapping_mode]),
				"cleanup overwrote a newer user mapping: " .. mapping_mode
			)
			vim.keymap.del(mapping_mode, "Q")
		end
		lingua_motion.setup({ mappings = mapping_config })
		lingua_motion.setup({ mappings = false })
		for _, mapping_mode in ipairs(mapping_modes) do
			assert(
				vim.tbl_isempty(vim.fn.maparg("Q", mapping_mode, false, true)),
				"plugin callback remained without original"
			)
		end
	end
	assert(
		vim.deep_equal(maps_before_setup, capture_unmodified_mode_mappings()),
		"overlapping setup changed i/c/t maps"
	)
	assert(vim.deep_equal(autocmds_before_setup, capture_autocmd_snapshot()), "overlapping setup changed autocmds")
end

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
local korean_line = "아침 햇살을 받으며 조용한 골목을 걷습니다."
local korean_haze_column = assert(korean_line:find("햇살", 1, true)) - 1
reset_buffer({ korean_line }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, korean_haze_column)
reset_buffer({ korean_line }, 0, korean_haze_column)
feed_keys("ciw빛\27")
assert(
	vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "아침 빛 받으며 조용한 골목을 걷습니다.",
	"Korean ciw failed"
)

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

for _, input_keys in ipairs({ "cwX\27", "c2wX\27", "2c2wX\27", '"zcwX\27', "cwX\27w.", "c2wX\27w." }) do
	assert_native_keys({ "a bee chocolate fancy gold honey" }, 0, 0, input_keys)
end
for _, column in ipairs({ 1, 2, 3, 4 }) do
	for _, input_keys in ipairs({ "cwX\27", "c2wX\27" }) do
		assert_native_keys({ "bee   chocolate fancy" }, 0, column, input_keys)
	end
end
for _, input_keys in ipairs({ "cwX\27", "c2wX\27", "c3wX\27" }) do
	assert_native_keys({ "one", "two three four" }, 0, 0, input_keys)
	assert_native_keys({ "one", "two three four" }, 0, 2, input_keys)
end
for _, input_keys in ipairs({ "cwX\27", "c2wX\27", "2c2wX\27" }) do
	assert_native_keys({ "日本 語 次 の 文" }, 0, 0, input_keys)
	assert_native_keys({ "아침 햇살을 받으며 조용한 골목을 걷습니다" }, 0, 0, input_keys)
end
reset_buffer({ "日本語。次" }, 0, 0)
feed_keys("cwX\27")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "X語。次", "cw lost natural-language boundaries")
for _, input_keys in ipairs({ "dw", "d2w", '"zyw', "w", "vwy" }) do
	assert_native_keys({ "a bee chocolate fancy" }, 0, 0, input_keys)
end

do
	local previous_selection = vim.o.selection
	local saved_global_virtualedit = vim.go.virtualedit
	local saved_local_virtualedit = vim.api.nvim_get_option_value("virtualedit", { scope = "local" })
	lingua_motion.setup({ helper_path = helper_path, timeout_ms = 2000 })
	local selection_cases = {
		{ "iw", { "One. Two. Three." }, "One" },
		{ "aw", { "One Two." }, "One " },
		{ "is", { "One. Two. Three." }, "One." },
		{ "as", { "One. Two. Three." }, "One. " },
		{ "iw", { "a" }, "a" },
		{ "iw", { "日本語。次" }, "日本" },
		{ "iw", { "Café" }, "Café" },
		{ "iw", { "✈️" }, "✈️" },
		{ "iw", { "👩🏽‍💻" }, "👩🏽‍💻" },
		{ "aw", { "One a" }, " a", 4 },
		{ "is", { "猫。" }, "猫。" },
		{ "as", { "One.", "Next." }, "One.\n" },
		{ "as", { "One.", "  Next." }, "One.\n  " },
		{ "2as", { "One.", "Next." }, "One.\nNext." },
		{ "2is", { "日本語。", "続く。" }, "日本語。\n続く。" },
	}
	for _, selection in ipairs({ "exclusive", "inclusive" }) do
		vim.o.selection = selection
		vim.go.virtualedit = "all"
		vim.wo.virtualedit = "block"
		reset_buffer({ "日本語。次" }, 0, 0)
		vim.cmd('normal! "zyiw')
		assert(vim.fn.getreg("z") == "日本語", "native control did not bypass the helper")
		for _, case in ipairs(selection_cases) do
			local object, lines, expected_text, column = case[1], case[2], case[3], case[4] or 0
			for _, keys in ipairs({
				object .. '"zy',
				"v" .. object .. '"zy',
				"V" .. object .. '"zy',
				"\22" .. object .. '"zy',
				'"zy' .. object,
			}) do
				reset_buffer(lines, 0, column)
				feed_keys(keys)
				assert(
					vim.fn.getreg("z") == expected_text and vim.fn.getregtype("z") == "v",
					selection .. " " .. keys .. " selected " .. vim.inspect(vim.fn.getreg("z"))
				)
				assert(vim.o.selection == selection, "textobject changed selection")
				assert(vim.go.virtualedit == "all" and vim.wo.virtualedit == "block", "textobject changed virtualedit")
			end
		end
		for _, object in ipairs({ "iw", "aw", "is", "as" }) do
			local source = object == "aw" and "One Two. Three." or "One. Two. Three."
			local remaining = ({ iw = ". Two. Three.", aw = "Two. Three.", is = " Two. Three.", as = "Two. Three." })[object]
			for _, operator in ipairs({ "d", "c" }) do
				reset_buffer({ source }, 0, 0)
				feed_keys(operator .. object .. (operator == "c" and "X\27" or ""))
				assert(
					vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == (operator == "c" and "X" or "") .. remaining,
					selection .. " " .. operator .. object .. " truncated the edit"
				)
			end
		end
		for _, operator in ipairs({ "d", "c" }) do
			reset_buffer({ "One.", "Next." }, 0, 0)
			feed_keys(operator .. "as" .. (operator == "c" and "X\27" or ""))
			assert(
				vim.deep_equal(
					vim.api.nvim_buf_get_lines(0, 0, -1, false),
					{ (operator == "c" and "X" or "") .. "Next." }
				),
				selection .. " multiline " .. operator .. "as truncated the edit"
			)
		end
		local virtualedit_cases = { { "", "" }, { "", "block" }, { "", "onemore" }, { "onemore", "" } }
		if selection == "exclusive" then
			vim.list_extend(virtualedit_cases, { { "all", "" }, { "all", "all" } })
		end
		for _, options in ipairs(virtualedit_cases) do
			vim.go.virtualedit = options[1]
			vim.wo.virtualedit = options[2]
			for _, case in ipairs({ selection_cases[5], selection_cases[9], selection_cases[12] }) do
				reset_buffer(case[2], 0, 0)
				feed_keys(case[1] .. '"zy')
				assert(
					vim.fn.getreg("z") == case[3],
					selection
						.. " virtualedit="
						.. vim.inspect(options)
						.. " selected "
						.. vim.inspect(vim.fn.getreg("z"))
				)
				assert(vim.go.virtualedit == options[1], "textobject changed global virtualedit")
				assert(
					vim.api.nvim_get_option_value("virtualedit", { scope = "local" }) == options[2],
					"textobject changed local virtualedit"
				)
				assert(vim.o.selection == selection, "textobject changed selection")
			end
		end
	end
	vim.o.selection = previous_selection
	vim.go.virtualedit = saved_global_virtualedit
	vim.wo.virtualedit = saved_local_virtualedit
end

lingua_motion.setup({ helper_path = "/usr/bin/false", timeout_ms = 20, mappings = false })
reset_buffer({ "a b" }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, 2)
reset_buffer({ "a b" }, 0, 0)
feed_keys("dw")
assert(vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "b", "native fallback failed")
reset_buffer({ "a b" }, 0, 0)
lingua_motion.setup({ helper_path = "/usr/bin/false", timeout_ms = 20, mappings = true })
-- Failed-helper edit boundaries are tracked separately; a nil provider must not throw.
reset_buffer({ "a b" }, 0, 0)
vim.v.errmsg = ""
feed_keys("cwX\27")
assert(vim.v.errmsg == "", "change-word helper failure raised an error: " .. vim.v.errmsg)
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

for _, visual_keys in ipairs({ "v", "V", "\22" }) do
	for _, object_keys in ipairs({ "iw", "aw", "is", "as" }) do
		assert_native_keys(
			{ "a b c d e f.", "Next sentence." },
			0,
			0,
			(visual_keys == "\22" and "v" or visual_keys) .. "2" .. object_keys .. '"zy',
			visual_keys .. "2" .. object_keys .. '"zy'
		)
	end
end
for _, object_keys in ipairs({ "iw", "aw", "is", "as" }) do
	assert_native_keys(
		{ "a b c d e f.", "Next sentence." },
		0,
		0,
		"v2" .. object_keys .. '"zy',
		"2" .. object_keys .. '"zy'
	)
end

do
	local original_jobstart = vim.fn.jobstart
	local helper_launches = 0
	local tokens_json = "[]"
	local failure_text = ""
	local fake_helper_script = [[
import json, re, sys, time
for line in sys.stdin:
    request = json.loads(line)
    if sys.argv[2] == "*" or request["text"] == sys.argv[2]:
        time.sleep(1)
        continue
    tokens = json.loads(sys.argv[1]) if request["text"] == "a b" else [{"start": match.start(), "end": match.end()} for match in re.finditer(r"\S+", request["text"])]
    print(json.dumps({"id": request["id"], "tokens": tokens}), flush=True)
]]
	rawset(vim.fn, "jobstart", function(command, options)
		assert(command[1] == helper_path)
		helper_launches = helper_launches + 1
		return original_jobstart(
			{ vim.fn.exepath("python3"), "-u", "-c", fake_helper_script, tokens_json, failure_text },
			options
		)
	end)
	for _, malformed_json in ipairs({ "{}", '{"oops":true}', '{"1":{"start":0,"end":1}}' }) do
		tokens_json = malformed_json
		lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false })
		reset_buffer({ "a b" }, 0, 0)
		lingua_motion.motion("w")
		assert_cursor_position(0, 2)
		local launches_after_failure = helper_launches
		tokens_json = '[{"start":0,"end":1},{"start":1,"end":3}]'
		reset_buffer({ "a b" }, 0, 0)
		lingua_motion.motion("w")
		assert_cursor_position(0, 1)
		assert(helper_launches == launches_after_failure + 1, "invalid tokens were cached or helper was not retried")
		reset_buffer({ "a b" }, 0, 0)
		lingua_motion.motion("w")
		assert_cursor_position(0, 1)
		assert(helper_launches == launches_after_failure + 1, "valid tokens were not cached")
	end
	tokens_json = '{"oops":true}'
	lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false })
	reset_buffer({ "a b", "c d" }, 0, 0)
	lingua_motion.motion("w")
	assert_cursor_position(0, 2)

	for _, motion_key in ipairs({ "w", "e", "b", "ge" }) do
		local forward = motion_key == "w" or motion_key == "e"
		for _, count in ipairs({ 1, 3 }) do
			for _, fail_immediately in ipairs({ true, false }) do
				local source_lines = { "aa bb", "cc dd", "ee ff", "gg hh", "ii jj", "kk ll", "mm nn", "oo pp" }
				local row = forward and 0 or #source_lines - 1
				local column = forward and 0 or 4
				if not fail_immediately then
					source_lines[forward and 2 or #source_lines - 1] = "fail"
					if count == 1 then
						column = forward and 4 or 0
					end
				end
				reset_buffer(source_lines, row, column)
				vim.cmd(("normal! %d%s"):format(count, motion_key))
				local native_row, native_column = get_cursor_position()
				failure_text = fail_immediately and "*" or "fail"
				lingua_motion.setup({
					helper_path = helper_path,
					timeout_ms = fail_immediately and 20 or 200,
				})
				local launches_before = helper_launches
				reset_buffer(source_lines, row, column)
				feed_keys(tostring(count) .. motion_key)
				assert_cursor_position(native_row, native_column)
				assert(
					helper_launches == launches_before + 1,
					("word scan restarted helper after failure: %s (launches=%d)"):format(
						motion_key,
						helper_launches - launches_before
					)
				)
			end
		end
	end

	-- A failed cross-line operation must not prevent a later request from recovering.
	failure_text = "fail"
	lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false })
	reset_buffer({ "aa bb", "fail", "cc dd" }, 0, 4)
	lingua_motion.motion("w")
	assert_cursor_position(1, 0)
	local launches_after_failure = helper_launches
	failure_text = ""
	tokens_json = '[{"start":0,"end":1},{"start":1,"end":3}]'
	reset_buffer({ "a b" }, 0, 0)
	lingua_motion.motion("w")
	assert_cursor_position(0, 1)
	assert(helper_launches == launches_after_failure + 1, "later operation did not retry helper")
	reset_buffer({ "a b" }, 0, 0)
	lingua_motion.motion("w")
	assert_cursor_position(0, 1)
	assert(helper_launches == launches_after_failure + 1, "recovered result was not cached")
	reset_buffer({ "aa bb", "", "   ", "cc dd" }, 0, 4)
	lingua_motion.motion("w")
	assert_cursor_position(3, 0)
	assert(helper_launches == launches_after_failure + 1, "empty result or cache hit restarted helper")
	lingua_motion.setup({ mappings = false })
	rawset(vim.fn, "jobstart", original_jobstart)
end

lingua_motion.setup({ helper_path = helper_path, timeout_ms = 500, mappings = false, language = "ja" })
reset_buffer({ "日本語。次" }, 0, 0)
lingua_motion.motion("w")
assert_cursor_position(0, 6)

print("integration ok")
vim.cmd("qa!")
