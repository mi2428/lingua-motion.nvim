local motion_engine = require("lingua_motion.engine")

---@class LinguaMotionMappingGroup
---@field [string] string|false

---@alias LinguaMotionMappingSelection boolean|LinguaMotionMappingGroup
---@alias LinguaMotionMappingConfig boolean|table<string, LinguaMotionMappingSelection>

---@class LinguaMotionConfig
---@field helper_path? string Executable path for the resident Swift helper.
---@field timeout_ms? number Maximum wait for one helper response.
---@field language? string NaturalLanguage raw language code or `auto`.
---@field mappings? LinguaMotionMappingConfig Mapping groups to install.

---@class ActiveLinguaMotionConfig
---@field helper_path string Executable path for the resident Swift helper.
---@field timeout_ms number Maximum wait for one helper response.
---@field language string NaturalLanguage raw language code or `auto`.
---@field mappings LinguaMotionMappingConfig Mapping groups to install.

---@class PendingTokenRequest
---@field done boolean
---@field failed? boolean
---@field tokens? TokenCandidate[]

---@class ParagraphContext
---@field first integer First buffer row in the paragraph.
---@field last integer Last buffer row in the paragraph.
---@field line_for fun(row: integer): string Lazy line accessor.
---@field starts integer[] UTF-8 byte offset for each paragraph row.
---@field text string Paragraph text joined by newlines.
---@field tokens TokenBoundary[]|nil Sentence token spans.

local module = {}
local plugin_configured = false

---@type ActiveLinguaMotionConfig
local current_config = {
	helper_path = "",
	timeout_ms = 200,
	language = "auto",
	mappings = true,
}
---@type integer|nil
local helper_job_id
local next_request_identifier = 1
---@type table<integer, PendingTokenRequest>
local pending_requests = {}
local helper_stdout_buffer = ""
---@type table<string, TokenSpan[]>
local token_cache = {}
---@type string[]
local token_cache_order = {}
local token_cache_limit = 128
---@class InstalledMapping
---@field mode string
---@field lhs string
---@field callback function
---@type InstalledMapping[]
local installed_mappings = {}

---@type table<string, LinguaMotionMappingGroup>
local default_mapping_groups = {
	word_motions = { w = "w", e = "e", b = "b", ge = "ge" },
	word_textobjects = { iw = "iw", aw = "aw" },
	sentence_motions = { ["("] = "(", [")"] = ")" },
	sentence_textobjects = { is = "is", as = "as" },
}

local function is_macos_platform()
	return vim.uv.os_uname().sysname == "Darwin"
end

local function make_token_cache_key(token_unit, source_text)
	return table.concat({ token_unit, current_config.language, source_text }, "\0")
end

local function clear_token_cache()
	token_cache = {}
	token_cache_order = {}
end

local function get_cached_tokens(token_unit, source_text)
	return token_cache[make_token_cache_key(token_unit, source_text)]
end

local function cache_tokens(token_unit, source_text, token_spans)
	local cache_key = make_token_cache_key(token_unit, source_text)
	if token_cache[cache_key] ~= nil then
		for order_index, cached_key in ipairs(token_cache_order) do
			if cached_key == cache_key then
				table.remove(token_cache_order, order_index)
				break
			end
		end
	end
	token_cache[cache_key] = token_spans
	token_cache_order[#token_cache_order + 1] = cache_key
	if #token_cache_order > token_cache_limit then
		token_cache[table.remove(token_cache_order, 1)] = nil
	end
end

local function handle_helper_response(response_line)
	if response_line == "" then
		return
	end
	local decoded_ok, response = pcall(vim.json.decode, response_line)
	if not decoded_ok or type(response) ~= "table" then
		return
	end
	local response_id = response.id
	if type(response_id) ~= "number" or response_id % 1 ~= 0 then
		return
	end
	local pending_request = pending_requests[response_id]
	if not pending_request then
		return
	end
	pending_request.done = true
	if response.error ~= nil then
		pending_request.failed = true
	else
		pending_request.tokens = response.tokens
	end
end

local function consume_helper_stdout(output_chunks)
	for chunk_index, output_chunk in ipairs(output_chunks) do
		helper_stdout_buffer = helper_stdout_buffer .. output_chunk
		while true do
			local newline_index = helper_stdout_buffer:find("\n", 1, true)
			if not newline_index then
				break
			end
			handle_helper_response(helper_stdout_buffer:sub(1, newline_index - 1))
			helper_stdout_buffer = helper_stdout_buffer:sub(newline_index + 1)
		end
		if chunk_index < #output_chunks and helper_stdout_buffer ~= "" then
			handle_helper_response(helper_stdout_buffer)
			helper_stdout_buffer = ""
		end
	end
end

local function mark_helper_job_failed(exited_job_id)
	if helper_job_id ~= exited_job_id then
		return
	end
	helper_job_id = nil
	helper_stdout_buffer = ""
	for _, pending_request in pairs(pending_requests) do
		pending_request.done = true
		pending_request.failed = true
	end
end

local function start_helper_job()
	if helper_job_id then
		return true
	end
	if not is_macos_platform() or vim.fn.executable(current_config.helper_path) ~= 1 then
		return false
	end
	local started_job_id
	started_job_id = vim.fn.jobstart({ current_config.helper_path }, {
		stdin = "pipe",
		stdout = "pipe",
		stderr = "pipe",
		on_stdout = function(_, output_chunks)
			consume_helper_stdout(output_chunks)
		end,
		on_stderr = function() end,
		on_exit = function()
			mark_helper_job_failed(started_job_id)
		end,
	})
	if started_job_id <= 0 then
		return false
	end
	helper_stdout_buffer = ""
	helper_job_id = started_job_id
	return true
end

local function stop_helper_job()
	local running_job_id = helper_job_id
	helper_job_id = nil
	if running_job_id then
		vim.fn.jobstop(running_job_id)
	end
	pending_requests = {}
	helper_stdout_buffer = ""
end

local function request_token_spans(token_unit, source_text)
	local cached_tokens = get_cached_tokens(token_unit, source_text)
	if cached_tokens ~= nil then
		return cached_tokens
	end
	if source_text == "" then
		local empty_spans = {}
		cache_tokens(token_unit, source_text, empty_spans)
		return empty_spans
	end
	if not start_helper_job() then
		return nil
	end
	local active_job_id = helper_job_id
	if not active_job_id then
		return nil
	end

	local request_identifier = next_request_identifier
	next_request_identifier = next_request_identifier + 1
	---@type PendingTokenRequest
	local pending_request = { done = false }
	pending_requests[request_identifier] = pending_request
	local encoded_request = vim.json.encode({
		id = request_identifier,
		text = source_text,
		unit = token_unit,
		language = current_config.language,
	}) .. string.char(10)
	local sent_bytes = vim.fn.chansend(active_job_id, encoded_request)
	if type(sent_bytes) ~= "number" or sent_bytes <= 0 then
		pending_requests[request_identifier] = nil
		stop_helper_job()
		return nil
	end
	vim.wait(current_config.timeout_ms, function()
		return pending_request.done or helper_job_id == nil
	end, 1)
	pending_requests[request_identifier] = nil
	if not pending_request.done or pending_request.failed then
		stop_helper_job()
		return nil
	end
	local token_spans = motion_engine.validate_tokens(pending_request.tokens, source_text)
	if not token_spans then
		stop_helper_job()
		return nil
	end
	cache_tokens(token_unit, source_text, token_spans)
	return token_spans
end

local function execute_native_motion(motion_keys)
	vim.cmd(("normal! %d%s"):format(vim.v.count1, motion_keys))
end

local function execute_native_textobject(textobject_keys)
	local current_mode = vim.fn.mode(1)
	local motion_count = vim.v.count1
	if current_mode:sub(1, 2) == "no" then
		vim.cmd("normal! v")
		vim.cmd(("normal! %d%s"):format(motion_count, textobject_keys))
		return
	end
	if current_mode == "n" then
		vim.cmd("normal! v")
	end
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(textobject_keys, true, false, true), "nx", false)
end

local function make_line_accessor(buffer_handle)
	local cached_lines = {}
	return function(row)
		if cached_lines[row] == nil then
			cached_lines[row] = vim.api.nvim_buf_get_lines(buffer_handle, row, row + 1, false)[1] or ""
		end
		return cached_lines[row]
	end
end

local function create_word_context(buffer_handle, current_row)
	local get_line = make_line_accessor(buffer_handle)
	local source_line = get_line(current_row)
	local token_spans = request_token_spans("word", source_line)
	return get_line, source_line, token_spans
end

local function create_paragraph_context(buffer_handle, current_row)
	local get_line = make_line_accessor(buffer_handle)
	local line_count = vim.api.nvim_buf_line_count(buffer_handle)
	local first_row = current_row
	local last_row = current_row
	if motion_engine.is_whitespace(get_line(current_row)) then
		return nil
	end
	while first_row > 0 do
		if motion_engine.is_whitespace(get_line(first_row - 1)) then
			break
		end
		first_row = first_row - 1
	end
	while last_row + 1 < line_count do
		if motion_engine.is_whitespace(get_line(last_row + 1)) then
			break
		end
		last_row = last_row + 1
	end
	local paragraph_lines = {}
	local line_start_bytes = {}
	local paragraph_byte_offset = 0
	for row = first_row, last_row do
		local source_line = get_line(row)
		paragraph_lines[#paragraph_lines + 1] = source_line
		line_start_bytes[#line_start_bytes + 1] = paragraph_byte_offset
		paragraph_byte_offset = paragraph_byte_offset + #source_line
		if row < last_row then
			paragraph_byte_offset = paragraph_byte_offset + 1
		end
	end
	local paragraph_text = table.concat(paragraph_lines, "\n")
	local sentence_spans = request_token_spans("sentence", paragraph_text)
	return {
		first = first_row,
		last = last_row,
		line_for = get_line,
		starts = line_start_bytes,
		text = paragraph_text,
		tokens = sentence_spans,
	}
end

local function find_adjacent_paragraph(buffer_handle, paragraph, sentence_motion_key)
	local line_count = vim.api.nvim_buf_line_count(buffer_handle)
	local row = sentence_motion_key == ")" and paragraph.last + 1 or paragraph.first - 1
	local get_line = paragraph.line_for
	local row_step = sentence_motion_key == ")" and 1 or -1
	while row >= 0 and row < line_count and motion_engine.is_whitespace(get_line(row)) do
		row = row + row_step
	end
	if row < 0 or row >= line_count then
		return nil
	end
	return create_paragraph_context(buffer_handle, row)
end

local function set_window_cursor(row, column)
	vim.api.nvim_win_set_cursor(0, { row + 1, column })
end

local function cursor_from_range(line_start_bytes, paragraph_text, end_byte)
	if end_byte <= 0 then
		return motion_engine.offset_to_position(line_start_bytes, 0)
	end
	for line_index = 2, #line_start_bytes do
		if end_byte == line_start_bytes[line_index] then
			local previous_line_length = line_start_bytes[line_index] - line_start_bytes[line_index - 1] - 1
			return line_index - 2, previous_line_length, true
		end
	end
	return motion_engine.offset_to_position(line_start_bytes, math.min(end_byte - 1, #paragraph_text))
end

local function select_visual_range(start_row, start_column, end_row, end_column, select_one_more)
	local previous_virtualedit = vim.wo.virtualedit
	local has_onemore = ("," .. previous_virtualedit .. ","):find(",onemore,", 1, true) ~= nil
	if select_one_more and not has_onemore then
		vim.wo.virtualedit = previous_virtualedit == "" and "onemore" or previous_virtualedit .. ",onemore"
	end
	local current_mode = vim.fn.mode(1)
	local is_visual_mode = current_mode:sub(1, 1) == "v" or current_mode == "V" or current_mode == "\22"
	if current_mode == "no" then
		set_window_cursor(start_row, start_column)
	elseif is_visual_mode then
		vim.cmd("normal! \27")
		set_window_cursor(start_row, start_column)
	else
		set_window_cursor(start_row, start_column)
	end
	vim.cmd("normal! v")
	set_window_cursor(end_row, end_column)
	if select_one_more then
		vim.wo.virtualedit = previous_virtualedit
	end
end

---Move the cursor with a NaturalLanguage-aware motion and native fallback.
---@param motion_key MotionKey|SentenceMotionKey
function module.motion(motion_key)
	if
		motion_key ~= "w"
		and motion_key ~= "e"
		and motion_key ~= "b"
		and motion_key ~= "ge"
		and motion_key ~= "("
		and motion_key ~= ")"
	then
		return
	end
	if not plugin_configured then
		execute_native_motion(motion_key)
		return
	end
	local window_id = 0
	local cursor_position = vim.api.nvim_win_get_cursor(window_id)
	local buffer_handle = vim.api.nvim_win_get_buf(window_id)
	local row, cursor_byte = cursor_position[1] - 1, cursor_position[2]
	local motion_count = vim.v.count1
	local operator_pending = vim.fn.mode(1):sub(1, 2) == "no"
	if motion_key == "(" or motion_key == ")" then
		local paragraph = create_paragraph_context(buffer_handle, row)
		if not paragraph or not paragraph.tokens then
			execute_native_motion(motion_key)
			return
		end
		local paragraph_byte_offset = paragraph.starts[row - paragraph.first + 1] + cursor_byte
		local target_paragraph = paragraph
		local did_move = false
		for _ = 1, motion_count do
			local target_byte = motion_engine.sentence_move(
				target_paragraph.tokens,
				paragraph_byte_offset,
				motion_key --[[@as SentenceMotionKey]],
				1
			)
			if target_byte ~= paragraph_byte_offset then
				paragraph_byte_offset = target_byte
				did_move = true
			else
				local adjacent_paragraph = find_adjacent_paragraph(buffer_handle, target_paragraph, motion_key)
				if not adjacent_paragraph or not adjacent_paragraph.tokens or #adjacent_paragraph.tokens == 0 then
					break
				end
				target_paragraph = adjacent_paragraph
				paragraph_byte_offset = motion_key == ")" and target_paragraph.tokens[1].start
					or target_paragraph.tokens[#target_paragraph.tokens].start
				did_move = true
			end
		end
		if not did_move then
			execute_native_motion(motion_key)
			return
		end
		local target_row, target_column =
			motion_engine.offset_to_position(target_paragraph.starts, paragraph_byte_offset)
		set_window_cursor(target_paragraph.first + target_row, target_column)
		return
	end

	local line_count = vim.api.nvim_buf_line_count(buffer_handle)
	local get_line = make_line_accessor(buffer_handle)
	local helper_unavailable = false
	local function get_word_spans(target_row)
		local token_spans = request_token_spans("word", get_line(target_row))
		if not token_spans then
			helper_unavailable = true
			return {}
		end
		return token_spans
	end
	local target_row, target_column = motion_engine.move(
		line_count,
		get_line,
		row,
		cursor_byte,
		motion_key --[[@as MotionKey]],
		get_word_spans,
		motion_count
	)
	if helper_unavailable then
		execute_native_motion(motion_key)
		return
	end
	if target_row == row and target_column == cursor_byte then
		execute_native_motion(motion_key)
		return
	end
	if operator_pending and (motion_key == "e" or motion_key == "ge") then
		vim.cmd("normal! v")
	end
	set_window_cursor(target_row, target_column)
end

---Select a NaturalLanguage-aware text object and preserve native fallback behavior.
---@param textobject_key TextObjectKind
function module.textobject(textobject_key)
	if textobject_key ~= "iw" and textobject_key ~= "aw" and textobject_key ~= "is" and textobject_key ~= "as" then
		return
	end
	if not plugin_configured then
		execute_native_textobject(textobject_key)
		return
	end
	local cursor_position = vim.api.nvim_win_get_cursor(0)
	local buffer_handle = vim.api.nvim_win_get_buf(0)
	local row, cursor_byte = cursor_position[1] - 1, cursor_position[2]
	local textobject_count = vim.v.count1
	local start_byte, end_byte
	local start_row, start_column, end_row, end_column, select_one_more
	if textobject_key == "iw" or textobject_key == "aw" then
		local get_line, source_line, token_spans = create_word_context(buffer_handle, row)
		if not token_spans then
			execute_native_textobject(textobject_key)
			return
		end
		start_byte, end_byte =
			motion_engine.word_range(source_line, token_spans, cursor_byte, textobject_key, textobject_count)
		if not start_byte or not end_byte then
			execute_native_textobject(textobject_key)
			return
		end
		start_row, start_column = row, start_byte
		end_row, end_column = row, motion_engine.last_char_start(source_line, end_byte)
	else
		local paragraph = create_paragraph_context(buffer_handle, row)
		if not paragraph or not paragraph.tokens then
			execute_native_textobject(textobject_key)
			return
		end
		local paragraph_byte_offset = paragraph.starts[row - paragraph.first + 1] + cursor_byte
		start_byte, end_byte = motion_engine.sentence_range(
			paragraph.text,
			paragraph.tokens,
			paragraph_byte_offset,
			textobject_key,
			textobject_count
		)
		if not start_byte or not end_byte then
			execute_native_textobject(textobject_key)
			return
		end
		local local_start_row, local_start_column = motion_engine.offset_to_position(paragraph.starts, start_byte)
		local local_end_row, local_end_column, local_select_one_more =
			cursor_from_range(paragraph.starts, paragraph.text, end_byte)
		start_row, start_column = paragraph.first + local_start_row, local_start_column
		end_row, end_column, select_one_more = paragraph.first + local_end_row, local_end_column, local_select_one_more
	end
	select_visual_range(start_row, start_column, end_row, end_column, select_one_more)
end

local function remove_installed_mappings()
	for _, mapping in ipairs(installed_mappings) do
		local existing_mapping = vim.fn.maparg(mapping.lhs, mapping.mode, false, true)
		if existing_mapping.callback == mapping.callback then
			pcall(vim.keymap.del, mapping.mode, mapping.lhs)
		end
	end
	installed_mappings = {}
end

local function select_mapping_group(group_name)
	if current_config.mappings == false then
		return nil
	end
	if current_config.mappings == true then
		return default_mapping_groups[group_name]
	end
	if type(current_config.mappings) ~= "table" then
		return nil
	end
	local selected_group = current_config.mappings[group_name]
	if selected_group == false then
		return nil
	end
	if selected_group == true or selected_group == nil then
		return default_mapping_groups[group_name]
	end
	return selected_group
end

local function install_mappings()
	remove_installed_mappings()
	for group_name, _ in pairs(default_mapping_groups) do
		local selected_group = select_mapping_group(group_name)
		if type(selected_group) == "table" then
			for source_key, left_hand_side in pairs(selected_group) do
				if type(left_hand_side) == "string" and left_hand_side ~= "" then
					local callback = function()
						if group_name:find("motions", 1, true) then
							module.motion(source_key --[[@as MotionKey|SentenceMotionKey]])
						else
							module.textobject(source_key --[[@as TextObjectKind]])
						end
					end
					for _, mapping_mode in ipairs({ "n", "x", "o" }) do
						vim.keymap.set(mapping_mode, left_hand_side, callback, {
							noremap = true,
							silent = true,
							desc = "Lingua motion " .. source_key,
						})
						installed_mappings[#installed_mappings + 1] = {
							mode = mapping_mode,
							lhs = left_hand_side,
							callback = callback,
						}
					end
				end
			end
		end
	end
end

---Configure the helper, cache, and optional normal/visual/operator mappings.
---@param options? LinguaMotionConfig
function module.setup(options)
	options = options or {}
	stop_helper_job()
	clear_token_cache()
	local selected_mappings = options.mappings
	if selected_mappings == nil then
		selected_mappings = true
	end
	current_config = {
		helper_path = options.helper_path or vim.fn.exepath("lingua-motion-helper"),
		timeout_ms = math.max(1, tonumber(options.timeout_ms) or 200),
		language = options.language or "auto",
		mappings = selected_mappings,
	}
	if current_config.helper_path == "" then
		current_config.helper_path = "lingua-motion-helper"
	end
	plugin_configured = true
	install_mappings()
end

return module
