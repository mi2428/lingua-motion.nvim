#!/bin/sh

set -eu

root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
output=${DEMO_OUTPUT:-$root/demo.gif}
plugin_ref=${PLUGIN_REF:-main}
fish_command=${FISH:-fish}
ffmpeg_command=${FFMPEG:-ffmpeg}
title=lingua-motion-demo-$$
window_x=${WINDOW_X:-240}
window_y=${WINDOW_Y:-120}
window_width=${WINDOW_WIDTH:-1940}
window_height=${WINDOW_HEIGHT:-1130}
content_inset_x=10
content_inset_top=40
content_inset_bottom=10
capture_x=$((window_x + content_inset_x))
capture_y=$((window_y + content_inset_top))
capture_width=$((window_width - content_inset_x * 2))
capture_height=$((window_height - content_inset_top - content_inset_bottom))
capture_region=$capture_x,$capture_y,$capture_width,$capture_height
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/lingua-motion-demo.XXXXXX")
plugin_root=$work_dir/plugin
socket=$work_dir/nvim.sock
start_gate=$work_dir/start
raw=$work_dir/demo.mov
gif=$work_dir/demo.gif
keycastr_defaults=$work_dir/keycastr.plist
input_source_tool=$work_dir/input-source
window_tool=$work_dir/place-window
input_source=
nvim=
demo_pid=
capture_pid=
keycastr_saved=false

require() {
	command -v "$1" >/dev/null 2>&1 || {
		printf '%s is required\n' "$1" >&2
		exit 1
	}
}

stop_keycastr() {
	osascript -e 'tell application "KeyCastr" to quit' >/dev/null 2>&1 || true
	i=0
	while pgrep -x KeyCastr >/dev/null 2>&1; do
		i=$((i + 1))
		[ "$i" -lt 50 ] || return 1
		sleep 0.1
	done
}

restore_keycastr() {
	[ "$keycastr_saved" = true ] || return
	stop_keycastr || printf 'Warning: KeyCastr did not quit cleanly\n' >&2
	if [ -s "$keycastr_defaults" ]; then
		defaults import io.github.keycastr "$keycastr_defaults" >/dev/null ||
			printf 'Warning: could not restore KeyCastr settings\n' >&2
	else
		defaults delete io.github.keycastr >/dev/null 2>&1 || true
	fi
}

cleanup() {
	trap - EXIT HUP INT TERM
	if [ -n "$capture_pid" ] && kill -0 "$capture_pid" >/dev/null 2>&1; then
		kill -INT "$capture_pid" >/dev/null 2>&1 || true
		wait "$capture_pid" >/dev/null 2>&1 || true
	fi
	if [ -n "$demo_pid" ]; then
		if [ -n "$nvim" ]; then
			"$nvim" --server "$socket" --remote-send '<Esc>:qa!<CR>' >/dev/null 2>&1 || true
		fi
		kill "$demo_pid" >/dev/null 2>&1 || true
	fi
	restore_keycastr
	if [ -n "$input_source" ] && [ -x "$input_source_tool" ]; then
		"$input_source_tool" "$input_source" >/dev/null 2>&1 ||
			printf 'Warning: could not restore input source\n' >&2
	fi
	rm -rf "$work_dir"
}

trap cleanup EXIT HUP INT TERM

for command in "$fish_command" "$ffmpeg_command" defaults git make mktemp open osascript pgrep screencapture swiftc tar; do
	require "$command"
done

fish=$(command -v "$fish_command")
ffmpeg=$(command -v "$ffmpeg_command")
ghostty=$("$fish" -lc 'command -v ghostty; or true')
nvim=$("$fish" -lc 'command -v nvim; or true')
[ -n "$ghostty" ] || {
	printf 'ghostty was not found in the fish login PATH\n' >&2
	exit 1
}
[ -n "$nvim" ] || {
	printf 'nvim was not found in the fish login PATH\n' >&2
	exit 1
}
open -Ra Ghostty || {
	printf 'Ghostty.app is required\n' >&2
	exit 1
}
open -Ra KeyCastr || {
	printf 'KeyCastr is required: brew install --cask keycastr\n' >&2
	exit 1
}

plugin_commit=$(git -C "$root" rev-parse --verify "$plugin_ref^{commit}") || {
	printf 'Could not resolve PLUGIN_REF: %s\n' "$plugin_ref" >&2
	exit 1
}
mkdir "$plugin_root"
git -C "$root" archive "$plugin_commit" | tar -x -C "$plugin_root"
[ -f "$plugin_root/lua/lingua_motion/init.lua" ] || {
	printf 'PLUGIN_REF does not identify a lingua-motion.nvim source tree: %s\n' "$plugin_ref" >&2
	exit 1
}
make -C "$plugin_root" lingua-motion-helper
swiftc "$root/input_source.swift" -o "$input_source_tool"
swiftc "$root/place_window.swift" -o "$window_tool"
printf 'Recording plugin %s\n' "$plugin_commit"

input_source=$("$input_source_tool")
"$input_source_tool" com.apple.keylayout.ABC
[ "$("$input_source_tool")" = com.apple.keylayout.ABC ] || {
	printf 'Could not select the ABC input source\n' >&2
	exit 1
}

stop_keycastr || {
	printf 'Timed out stopping KeyCastr\n' >&2
	exit 1
}
if defaults read io.github.keycastr >/dev/null 2>&1; then
	defaults export io.github.keycastr "$keycastr_defaults" >/dev/null || {
		printf 'Could not save KeyCastr settings\n' >&2
		exit 1
	}
fi
keycastr_saved=true

defaults write io.github.keycastr selectedVisualizer Default
defaults write io.github.keycastr default.commandKeysOnly -bool false
defaults write io.github.keycastr default.allModifiedKeys -bool false
defaults write io.github.keycastr default.allKeys -bool true
defaults write io.github.keycastr default.keystrokeDelay -float 0.65
defaults write io.github.keycastr default.fadeDelay -float 1.5
defaults write io.github.keycastr default.fadeDuration -float 0.15
defaults write io.github.keycastr default.fontSize -float 44
defaults write io.github.keycastr default_displayModifiedCharacters -bool true
open -gj -a KeyCastr

mkdir -p "$(dirname -- "$output")"
ln -s "$root" "$work_dir/demo"
ln -s "$fish" "$work_dir/fish"
ln -s "$nvim" "$work_dir/nvim"

open -na Ghostty --args \
	--title="$title" \
	--working-directory=/tmp \
	--window-save-state=never \
	--resize-overlay=never \
	--font-size=28 \
	--initial-command="direct:$work_dir/fish -l $work_dir/demo/start.fish $plugin_root $work_dir/demo $socket $start_gate $work_dir/nvim" \
	--background-opacity=1 \
	--background-blur=false

demo_pid=$(osascript "$root/prepare.applescript" "$title" "$((capture_x + 40))" "$((capture_y + capture_height - 120))")
"$window_tool" "$demo_pid" "$title" "$window_x" "$window_y" "$window_width" "$window_height"
: >"$start_gate"

i=0
while [ "$i" -lt 150 ]; do
	if ready=$("$nvim" --server "$socket" --remote-expr 'get(g:, "lingua_motion_demo_ready", 0)' 2>/dev/null) && [ "$ready" = 1 ]; then
		break
	fi
	i=$((i + 1))
	sleep 0.1
done
[ "$i" -lt 150 ] || {
	printf 'Timed out waiting for demo Neovim\n' >&2
	exit 1
}

osascript -e "tell application \"System Events\" to set frontmost of first application process whose unix id is $demo_pid to true"
front_pid=$(osascript -e 'tell application "System Events" to get unix id of first application process whose frontmost is true')
[ "$front_pid" = "$demo_pid" ] || {
	printf 'Could not focus the demo Ghostty process\n' >&2
	exit 1
}

screencapture -v -V 31 -R"$capture_region" -x "$raw" &
capture_pid=$!
sleep 1
kill -0 "$capture_pid" >/dev/null 2>&1 || {
	wait "$capture_pid" || true
	capture_pid=
	printf 'Screen recording failed. Allow the current terminal under System Settings > Privacy & Security > Screen & System Audio Recording.\n' >&2
	exit 1
}

osascript "$root/drive.applescript" "$demo_pid" "$nvim" "$socket"
wait "$capture_pid"
capture_pid=
[ -s "$raw" ] || {
	printf 'Screen recording was not written\n' >&2
	exit 1
}

"$ffmpeg" -loglevel error -y -i "$raw" \
	-vf 'fps=16,scale=1440:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192[p];[b][p]paletteuse=dither=bayer:bayer_scale=3' \
	-loop 0 "$gif"
[ -s "$gif" ] || {
	printf 'Demo GIF was not written\n' >&2
	exit 1
}
mv "$gif" "$output"
printf 'Wrote %s\n' "$output"
