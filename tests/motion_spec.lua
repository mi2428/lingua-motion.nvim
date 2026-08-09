local motion_engine = require("lingua_motion.engine")

local validated_spans = motion_engine.validate_tokens({
	{ start = 0, ["end"] = 3, attributes = 0 },
	{ start = 4, ["end"] = 7, attributes = 2, symbolic = true },
	{ start = 8, ["end"] = 12, attributes = 4, emoji = true },
}, "abc def 😀!")
assert(validated_spans and #validated_spans == 3)
assert(validated_spans[2].symbolic and validated_spans[3].emoji)
-- Deliberately malformed input verifies runtime validation at the JSON boundary.
local malformed_candidates = vim.json.decode('[{"start":0,"finish":1,"emoji":"yes"}]')
assert(motion_engine.validate_tokens(malformed_candidates, "a") == nil)
assert(motion_engine.validate_tokens({ { start = 0, finish = 1 } }, "a") == nil)
assert(motion_engine.validate_tokens({ { start = 2, ["end"] = 1 } }, "abc") == nil)
assert(motion_engine.validate_tokens({ { start = 0, ["end"] = 4 } }, "abc") == nil)
assert(motion_engine.last_char_start("日本語", 9) == 6)
assert(motion_engine.last_char_start("😀", 4) == 0)
assert(motion_engine.is_whitespace("　"))
assert(motion_engine.is_whitespace(" "))
assert(not motion_engine.is_whitespace("a"))

local source_lines = { "日本語です。", "", "ASCII, 日本語" }
local token_spans_by_line = {
	{
		{ start = 0, finish = 6 },
		{ start = 6, finish = 15 },
		{ start = 15, finish = 18 },
	},
	{},
	{
		{ start = 0, finish = 5 },
		{ start = 5, finish = 6 },
		{ start = 7, finish = 16 },
	},
}

local function calculate_motion_position(row, column, motion_key, repetition_count)
	return motion_engine.move(
		#source_lines,
		function(line_index)
			return source_lines[line_index + 1]
		end,
		row,
		column,
		motion_key,
		function(line_index)
			return token_spans_by_line[line_index + 1]
		end,
		repetition_count
	)
end

local function assert_cursor_position(actual_row, actual_column, expected_row, expected_column)
	assert(
		actual_row == expected_row and actual_column == expected_column,
		("expected %d:%d, got %d:%d"):format(expected_row, expected_column, actual_row, actual_column)
	)
end

local function assert_motion_position(row, column, motion_key, expected_row, expected_column, repetition_count)
	local actual_row, actual_column = calculate_motion_position(row, column, motion_key, repetition_count)
	assert_cursor_position(actual_row, actual_column, expected_row, expected_column)
end

assert_motion_position(0, 0, "w", 0, 6)
assert_motion_position(0, 0, "e", 0, 3)
assert_motion_position(0, 6, "b", 0, 0)
assert_motion_position(0, 6, "ge", 0, 3)
assert_motion_position(0, 15, "w", 2, 0)
assert_motion_position(0, 15, "e", 2, 4)
assert_motion_position(2, 0, "b", 0, 15)
assert_motion_position(2, 0, "ge", 0, 15)
assert_motion_position(0, 0, "w", 0, 15, 2)

local word_token_spans = {
	{ start = 0, finish = 1 },
	{ start = 2, finish = 3 },
	{ start = 4, finish = 5 },
}
local start_byte, end_byte = motion_engine.word_range("a b c", word_token_spans, 2, "iw", 1)
assert(start_byte == 2 and end_byte == 3)
start_byte, end_byte = motion_engine.word_range("a b c", word_token_spans, 2, "aw", 1)
assert(start_byte == 2 and end_byte == 4)
start_byte, end_byte = motion_engine.word_range("a b c", word_token_spans, 0, "aw", 2)
assert(start_byte == 0 and end_byte == 4)
start_byte, end_byte = motion_engine.word_range(
	"abc",
	{ { start = 0, finish = 1 }, { start = 1, finish = 2 }, { start = 2, finish = 3 } },
	1,
	"aw",
	1
)
assert(start_byte == 1 and end_byte == 2)

local fullwidth_space_spans = { { start = 0, finish = 3 }, { start = 6, finish = 9 } }
start_byte, end_byte = motion_engine.word_range("前　後", fullwidth_space_spans, 0, "aw", 1)
assert(start_byte == 0 and end_byte == 6)
local no_break_space_spans = { { start = 0, finish = 3 }, { start = 5, finish = 8 } }
start_byte, end_byte = motion_engine.word_range("前 後", no_break_space_spans, 0, "aw", 1)
assert(start_byte == 0 and end_byte == 5)

local sentence_text = "One sentence. Next sentence!\n続く。"
local sentence_tokens = {
	{ start = 0, finish = 13 },
	{ start = 14, finish = 28 },
	{ start = 29, finish = 38 },
}
start_byte, end_byte = motion_engine.sentence_range(sentence_text, sentence_tokens, 2, "is", 1)
assert(start_byte == 0 and end_byte == 13)
start_byte, end_byte = motion_engine.sentence_range(sentence_text, sentence_tokens, 2, "as", 1)
assert(start_byte == 0 and end_byte == 14)
start_byte, end_byte = motion_engine.sentence_range(sentence_text, sentence_tokens, 15, "is", 2)
assert(start_byte == 14 and end_byte == 38)
start_byte, end_byte = motion_engine.sentence_range("One. Two. Three.", {
	{ start = 0, finish = 4 },
	{ start = 5, finish = 9 },
	{ start = 10, finish = 16 },
}, 0, "as", 2)
assert(start_byte == 0 and end_byte == 10)
local row, column = motion_engine.offset_to_position({ 0, 14, 29 }, 29)
assert(row == 2 and column == 0)

print("pure mechanics ok")
