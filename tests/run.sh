#!/bin/sh
set -eu
export PYTHONDONTWRITEBYTECODE=1

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
helper=$(mktemp "${TMPDIR:-/tmp}/lingua-motion-helper.XXXXXX")
trap 'rm -f "$helper"' EXIT HUP INT TERM
swift_language_version=${LINGUA_MOTION_SWIFT_VERSION:-6}
export LINGUA_MOTION_TEST_REPO="$repo"
runtimepath_cmd='lua vim.opt.runtimepath:prepend(vim.fn.escape(vim.env.LINGUA_MOTION_TEST_REPO, "\\,"))'

python3 "$repo/tests/helper_transport.py"
python3 "$repo/tests/runner_path.py" "$runtimepath_cmd"

swiftc -swift-version "$swift_language_version" -warnings-as-errors -strict-concurrency=complete -O \
  -framework NaturalLanguage -framework Foundation \
  "$repo/Sources/lingua-motion-helper/main.swift" -o "$helper"

LINGUA_MOTION_HELPER="$helper" python3 "$repo/tests/helper_protocol.py"

if [ "${LINGUA_MOTION_SKIP_RSS:-0}" = "1" ]; then
  printf '%s\n' "helper RSS test skipped (LINGUA_MOTION_SKIP_RSS=1)"
else
  LINGUA_MOTION_HELPER="$helper" python3 "$repo/tests/helper_rss.py"
fi

nvim --headless --clean -u NONE \
  --cmd "$runtimepath_cmd" \
  -l "$repo/tests/motion_spec.lua"

LINGUA_MOTION_HELPER="$helper" nvim --headless --clean -u NONE \
  --cmd "$runtimepath_cmd" \
  -l "$repo/tests/integration.lua"

for cache_path in \
  "$repo/.build" \
  "$repo/.ruff_cache" \
  "$repo/__pycache__" \
  "$repo/tests/__pycache__"; do
  if [ -e "$cache_path" ]; then
    printf '%s\n' "runtime test left repo artifact: $cache_path" >&2
    exit 1
  fi
done
