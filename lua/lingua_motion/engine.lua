---@alias MotionKey "w"|"e"|"b"|"ge"
---@alias TextObjectKind "iw"|"aw"|"is"|"as"
---@alias SentenceMotionKey "("|")"

---@class TokenCandidate
---@field start? number
---@field ["end"]? number
---@field attributes? number
---@field numeric? boolean
---@field symbolic? boolean
---@field emoji? boolean

---@class TokenBoundary
---@field start integer Inclusive UTF-8 byte offset.
---@field finish integer Exclusive UTF-8 byte offset.

---@class TokenSpan : TokenBoundary
---@field attributes integer Raw NaturalLanguage attributes.
---@field numeric boolean Whether the token is numeric.
---@field symbolic boolean Whether the token is symbolic.
---@field emoji boolean Whether the token is an emoji.

---@alias LineAccessor fun(row: integer): string
---@alias SpanProvider fun(row: integer): TokenBoundary[]

local module = {}

---@param source_text string
---@param byte_offset integer
---@return boolean
local function is_utf8_boundary(source_text, byte_offset)
	if byte_offset == 0 or byte_offset == #source_text then
		return true
	end
	local byte_value = source_text:byte(byte_offset + 1)
	return byte_value ~= nil and (byte_value < 128 or byte_value > 191)
end

---Validate helper token spans and normalize their protocol shape.
---@param candidate_tokens unknown
---@param source_text string
---@return TokenSpan[]|nil
function module.validate_tokens(candidate_tokens, source_text)
	if type(candidate_tokens) ~= "table" then
		return nil
	end
	local normalized_spans = {}
	local source_byte_length = #source_text
	local previous_end_byte = 0
	for _, candidate_token in ipairs(candidate_tokens) do
		if type(candidate_token) ~= "table" then
			return nil
		end
		local start_byte = candidate_token.start
		local end_byte = candidate_token["end"]
		local raw_attributes = candidate_token.attributes
		if candidate_token.numeric ~= nil and type(candidate_token.numeric) ~= "boolean" then
			return nil
		end
		if candidate_token.symbolic ~= nil and type(candidate_token.symbolic) ~= "boolean" then
			return nil
		end
		if candidate_token.emoji ~= nil and type(candidate_token.emoji) ~= "boolean" then
			return nil
		end
		if
			raw_attributes ~= nil
			and (type(raw_attributes) ~= "number" or raw_attributes % 1 ~= 0 or raw_attributes < 0)
		then
			return nil
		end
		if
			type(start_byte) ~= "number"
			or type(end_byte) ~= "number"
			or start_byte % 1 ~= 0
			or end_byte % 1 ~= 0
			or start_byte < previous_end_byte
			or start_byte < 0
			or start_byte >= end_byte
			or end_byte > source_byte_length
			or not is_utf8_boundary(source_text, start_byte)
			or not is_utf8_boundary(source_text, end_byte)
		then
			return nil
		end
		normalized_spans[#normalized_spans + 1] = {
			start = start_byte,
			finish = end_byte,
			attributes = raw_attributes or 0,
			numeric = candidate_token.numeric == true,
			symbolic = candidate_token.symbolic == true,
			emoji = candidate_token.emoji == true,
		}
		previous_end_byte = end_byte
	end
	return normalized_spans
end

---Return the zero-based byte offset of the final UTF-8 character in a span.
---@param source_line string
---@param end_byte integer Exclusive UTF-8 byte offset.
---@return integer
function module.last_char_start(source_line, end_byte)
	local byte_index = end_byte
	while byte_index > 1 do
		local byte_value = source_line:byte(byte_index)
		if not byte_value or byte_value < 128 or byte_value > 191 then
			break
		end
		byte_index = byte_index - 1
	end
	return byte_index - 1
end

---Find the token containing a zero-based byte cursor.
---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@return integer|nil
function module.containing(token_spans, cursor_byte)
	for token_index, token_span in ipairs(token_spans) do
		if cursor_byte >= token_span.start and cursor_byte < token_span.finish then
			return token_index
		end
	end
	return nil
end

---Return whether every codepoint in text is Unicode whitespace.
---@param source_text string
---@return boolean
function module.is_whitespace(source_text)
	for character_index = 0, vim.fn.strchars(source_text) - 1 do
		local character = vim.fn.strcharpart(source_text, character_index, 1)
		if character ~= "\n" and vim.fn.charclass(character) ~= 0 then
			return false
		end
	end
	return true
end

---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@return integer|nil
local function find_next_token_index(token_spans, cursor_byte)
	for token_index, token_span in ipairs(token_spans) do
		if token_span.start > cursor_byte then
			return token_index
		end
	end
	return nil
end

---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@return integer|nil
local function find_previous_token_index(token_spans, cursor_byte)
	for token_index = #token_spans, 1, -1 do
		if token_spans[token_index].finish <= cursor_byte then
			return token_index
		end
	end
	return nil
end

---Move once using NaturalLanguage spans, falling back to another line when needed.
---@param line_count integer
---@param line_for LineAccessor
---@param row integer
---@param cursor_byte integer
---@param motion_key MotionKey
---@param spans_for SpanProvider
---@return integer row, integer cursor_byte
function module.move_once(line_count, line_for, row, cursor_byte, motion_key, spans_for)
	local current_spans = spans_for(row)
	if motion_key == "w" then
		local next_token_index = find_next_token_index(current_spans, cursor_byte)
		if next_token_index then
			return row, current_spans[next_token_index].start
		end
		for next_row = row + 1, line_count - 1 do
			local next_line_spans = spans_for(next_row)
			if #next_line_spans > 0 then
				return next_row, next_line_spans[1].start
			end
		end
	elseif motion_key == "e" then
		local containing_index = module.containing(current_spans, cursor_byte)
		local next_token_index = containing_index or find_next_token_index(current_spans, cursor_byte)
		if next_token_index then
			local current_token = current_spans[next_token_index]
			local final_character_start = module.last_char_start(line_for(row), current_token.finish)
			if cursor_byte < final_character_start then
				return row, final_character_start
			end
			local following_token = current_spans[next_token_index + 1]
			if following_token then
				return row, module.last_char_start(line_for(row), following_token.finish)
			end
		end
		for next_row = row + 1, line_count - 1 do
			local next_line_spans = spans_for(next_row)
			if #next_line_spans > 0 then
				return next_row, module.last_char_start(line_for(next_row), next_line_spans[1].finish)
			end
		end
	elseif motion_key == "b" then
		local containing_index = module.containing(current_spans, cursor_byte)
		if containing_index and cursor_byte > current_spans[containing_index].start then
			return row, current_spans[containing_index].start
		end
		local previous_token_index = find_previous_token_index(current_spans, cursor_byte)
		if previous_token_index then
			return row, current_spans[previous_token_index].start
		end
		for previous_row = row - 1, 0, -1 do
			local previous_line_spans = spans_for(previous_row)
			if #previous_line_spans > 0 then
				return previous_row, previous_line_spans[#previous_line_spans].start
			end
		end
	elseif motion_key == "ge" then
		local previous_token_index = find_previous_token_index(current_spans, cursor_byte)
		if previous_token_index then
			return row, module.last_char_start(line_for(row), current_spans[previous_token_index].finish)
		end
		for previous_row = row - 1, 0, -1 do
			local previous_line_spans = spans_for(previous_row)
			if #previous_line_spans > 0 then
				local previous_token = previous_line_spans[#previous_line_spans]
				return previous_row, module.last_char_start(line_for(previous_row), previous_token.finish)
			end
		end
	end
	return row, cursor_byte
end

---Apply a motion repeatedly until its target stops changing.
---@param line_count integer
---@param line_for LineAccessor
---@param row integer
---@param cursor_byte integer
---@param motion_key MotionKey
---@param spans_for SpanProvider
---@param repetition_count? integer
---@return integer row, integer cursor_byte
function module.move(line_count, line_for, row, cursor_byte, motion_key, spans_for, repetition_count)
	for _ = 1, repetition_count or 1 do
		local next_row, next_cursor_byte =
			module.move_once(line_count, line_for, row, cursor_byte, motion_key, spans_for)
		if next_row == row and next_cursor_byte == cursor_byte then
			break
		end
		row, cursor_byte = next_row, next_cursor_byte
	end
	return row, cursor_byte
end

---@param source_text string
---@param start_byte integer
---@param end_byte integer
---@return boolean
local function is_whitespace_range(source_text, start_byte, end_byte)
	if start_byte >= end_byte then
		return true
	end
	return module.is_whitespace(source_text:sub(start_byte + 1, end_byte))
end

---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@return integer|nil
local function find_object_token_index(token_spans, cursor_byte)
	return module.containing(token_spans, cursor_byte)
		or find_next_token_index(token_spans, cursor_byte)
		or find_previous_token_index(token_spans, cursor_byte)
end

---Return the word range selected by `iw` or `aw`.
---@param source_line string
---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@param object_kind TextObjectKind
---@param repetition_count? integer
---@return integer|nil start_byte, integer|nil end_byte
function module.word_range(source_line, token_spans, cursor_byte, object_kind, repetition_count)
	local first_token_index = find_object_token_index(token_spans, cursor_byte)
	if not first_token_index then
		return nil
	end
	local last_token_index = math.min(#token_spans, first_token_index + (repetition_count or 1) - 1)
	local first_token = token_spans[first_token_index]
	local last_token = token_spans[last_token_index]
	local start_byte, end_byte = first_token.start, last_token.finish
	if object_kind == "aw" then
		local following_token = token_spans[last_token_index + 1]
		local trailing_end_byte = following_token and following_token.start or #source_line
		if trailing_end_byte > end_byte and is_whitespace_range(source_line, end_byte, trailing_end_byte) then
			end_byte = trailing_end_byte
		else
			local preceding_token = token_spans[first_token_index - 1]
			local leading_start_byte = preceding_token and preceding_token.finish or 0
			if start_byte > leading_start_byte and is_whitespace_range(source_line, leading_start_byte, start_byte) then
				start_byte = leading_start_byte
			end
		end
	end
	return start_byte, end_byte
end

---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@return integer|nil
local function find_sentence_index(token_spans, cursor_byte)
	return module.containing(token_spans, cursor_byte)
		or find_next_token_index(token_spans, cursor_byte)
		or find_previous_token_index(token_spans, cursor_byte)
end

---Return the sentence range selected by `is` or `as`.
---@param source_text string
---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@param object_kind TextObjectKind
---@param repetition_count? integer
---@return integer|nil start_byte, integer|nil end_byte
function module.sentence_range(source_text, token_spans, cursor_byte, object_kind, repetition_count)
	local first_sentence_index = find_sentence_index(token_spans, cursor_byte)
	if not first_sentence_index then
		return nil
	end
	local last_sentence_index = math.min(#token_spans, first_sentence_index + (repetition_count or 1) - 1)
	local first_sentence = token_spans[first_sentence_index]
	local last_sentence = token_spans[last_sentence_index]
	local start_byte, end_byte = first_sentence.start, last_sentence.finish
	if object_kind == "as" then
		local following_sentence = token_spans[last_sentence_index + 1]
		local trailing_end_byte = following_sentence and following_sentence.start or #source_text
		if trailing_end_byte > end_byte and is_whitespace_range(source_text, end_byte, trailing_end_byte) then
			end_byte = trailing_end_byte
		else
			local preceding_sentence = token_spans[first_sentence_index - 1]
			local leading_start_byte = preceding_sentence and preceding_sentence.finish or 0
			if start_byte > leading_start_byte and is_whitespace_range(source_text, leading_start_byte, start_byte) then
				start_byte = leading_start_byte
			end
		end
	end
	return start_byte, end_byte
end

---Move to an adjacent sentence start.
---@param token_spans TokenBoundary[]
---@param cursor_byte integer
---@param motion_key SentenceMotionKey
---@param repetition_count? integer
---@return integer cursor_byte
function module.sentence_move(token_spans, cursor_byte, motion_key, repetition_count)
	for _ = 1, repetition_count or 1 do
		local target_byte
		if motion_key == ")" then
			for _, sentence_span in ipairs(token_spans) do
				if sentence_span.start > cursor_byte then
					target_byte = sentence_span.start
					break
				end
			end
		else
			for sentence_index = #token_spans, 1, -1 do
				if token_spans[sentence_index].start < cursor_byte then
					target_byte = token_spans[sentence_index].start
					break
				end
			end
		end
		if not target_byte or target_byte == cursor_byte then
			break
		end
		cursor_byte = target_byte
	end
	return cursor_byte
end

---Convert a paragraph byte offset into a zero-based row and byte column.
---@param line_starts integer[]
---@param byte_offset integer
---@return integer row, integer column
function module.offset_to_position(line_starts, byte_offset)
	for line_index = #line_starts, 1, -1 do
		if byte_offset >= line_starts[line_index] then
			return line_index - 1, byte_offset - line_starts[line_index]
		end
	end
	return 0, byte_offset
end

return module
