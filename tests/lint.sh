#!/bin/sh
set -eu

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_binary=$(mktemp "${TMPDIR:-/tmp}/lingua-motion-helper.XXXXXX")
trap 'rm -f "$temporary_binary"' EXIT HUP INT TERM
swift_language_version=${LINGUA_MOTION_SWIFT_VERSION:-6}
if [ -z "${VIMRUNTIME:-}" ]; then
  if ! command -v nvim >/dev/null 2>&1; then
    printf '%s\n' "VIMRUNTIME is unset and nvim is unavailable" >&2
    exit 1
  fi
  VIMRUNTIME=$(nvim --headless --clean -u NONE \
    -c 'lua io.write(vim.env.VIMRUNTIME or "")' -c 'qa!')
fi
if [ ! -d "$VIMRUNTIME" ]; then
  printf '%s\n' "VIMRUNTIME does not point to a directory: $VIMRUNTIME" >&2
  exit 1
fi
if [ -z "${LUA_LS_META:-}" ]; then
  lua_language_server=$(command -v lua-language-server)
  lua_language_server_root=$(python3 -c \
    'from pathlib import Path; import sys; print(Path(sys.argv[1]).resolve().parent.parent)' \
    "$lua_language_server")
  for lua_language_server_meta in \
    "$lua_language_server_root/libexec/meta" \
    "$lua_language_server_root/share/lua-language-server/meta"; do
    if [ -d "$lua_language_server_meta" ]; then
      LUA_LS_META=$lua_language_server_meta
      break
    fi
  done
fi
if [ ! -d "${LUA_LS_META:-}" ]; then
  printf '%s\n' "LuaLS meta directory was not found: ${LUA_LS_META:-unset}" >&2
  exit 1
fi
export LUA_LS_META VIMRUNTIME

sh -n "$repo/tests/run.sh" "$repo/tests/lint.sh"
ruff format --no-cache --check "$repo/tests"
ruff check --no-cache "$repo/tests"
pyright "$repo"
swift-format lint --strict --configuration "$repo/.swift-format" \
  "$repo/Sources/lingua-motion-helper/main.swift"
if [ "${LINGUA_MOTION_DISABLE_SOURCEKIT:-0}" = "1" ]; then
  # nixpkgs SwiftLint has no sourcekitdInProc.framework; keep all non-SourceKit rules strict.
  swiftlint lint --strict --no-cache --disable-sourcekit --config "$repo/.swiftlint.yml" "$repo/Sources"
else
  swiftlint lint --strict --no-cache --config "$repo/.swiftlint.yml" "$repo/Sources"
fi
swiftc -swift-version "$swift_language_version" -warnings-as-errors -strict-concurrency=complete \
  -framework NaturalLanguage -framework Foundation \
  "$repo/Sources/lingua-motion-helper/main.swift" -o "$temporary_binary"
stylua --check "$repo/lua" "$repo/tests"
lua-language-server --check="$repo" --checklevel=Warning --configpath="$repo/.luarc.json"
