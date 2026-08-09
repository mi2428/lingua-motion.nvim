# lingua-motion.nvim

Multilingual natural-language motions and text objects for Neovim, powered by Apple NLTokenizer. Japanese-first, macOS-only.

## Scope

The Swift helper uses Apple `NaturalLanguage` directly. Word tokens retain UTF-8 byte spans and numeric, symbolic, and emoji attributes. Sentence tokens preserve Apple's sentence boundaries without punctuation-specific splitting. Japanese, English, Chinese, and mixed text are supported through `language = "auto"` or an explicit NLLanguage raw code such as `ja`, `en`, or `zh-Hans`.

Published motions are `w`, `e`, `b`, `ge`, `(`, and `)`. Published text objects are `iw`, `aw`, `is`, and `as`. Counts work in Normal, Visual, and Operator-pending modes, including `diw`, `ciw`, `yiw`, `dis`, `cis`, and `yas`.

`iw` selects the current natural-language word, symbol, or emoji. `aw` prefers following whitespace, then preceding whitespace; consecutive Japanese tokens remain `iw`-sized. `is` selects one Apple sentence. `as` prefers trailing spaces/newlines, then leading whitespace. Sentence analysis joins only the current blank-line-delimited paragraph and accesses buffer lines lazily.

## Setup

Loading the plugin has no helper, keymap, autocmd, or IME side effects. Call `setup()` explicitly:

```lua
require("lingua_motion").setup({
  helper_path = "lingua-motion-helper",
  timeout_ms = 200,
  language = "auto",
  mappings = true,
})
```

`mappings = false` disables all mappings. A table can opt feature groups in or out, or override their lhs:

```lua
require("lingua_motion").setup({
  mappings = {
    word_motions = { w = "gw", e = "ge", b = false, ge = "gE" },
    word_textobjects = true,
    sentence_motions = false,
    sentence_textobjects = true,
  },
})
```

Only `n`, `x`, and `o` mappings are installed. `i`, `c`, and `t` maps, autocmds, input sources, and IME state are not touched. Helper timeout/crash/invalid responses use non-recursive native motions or text objects and retry the helper on a later request. Cache entries are bounded by `unit + language + text`.

## Install

Build the resident JSONL helper with Swift:

```sh
swiftc -swift-version 6 -warnings-as-errors -strict-concurrency=complete -O \
  -framework Foundation -framework NaturalLanguage \
  Sources/lingua-motion-helper/main.swift -o lingua-motion-helper
```

Nix provides the Darwin `aarch64` output:

```sh
nix build .#lingua-motion-helper
nix build .#lingua-motion
```

The plugin is macOS-only because Apple `NaturalLanguage` is the backend. It does not provide a Linux backend, paragraph/document motions, part-of-speech tagging, embeddings, or IME integration.

## Protocol

`lingua-motion-helper` is one long-lived JSONL process. stdout is protocol-only; diagnostics go to stderr. Each request has an id, text, unit, and language:

```json
{"id":1,"text":"日本語。English.","unit":"word","language":"auto"}
```

Responses contain UTF-8 byte `[start,end)` ranges and raw/decoded tokenizer attributes:

```json
{"id":1,"tokens":[{"start":0,"end":6,"attributes":0,"numeric":false,"symbolic":false,"emoji":false}]}
```

Unknown units return an id-matched error. The helper warms both tokenizer units, reuses tokenizers by unit/language, and wraps each request in `autoreleasepool`.

## Tests

```sh
tests/run.sh
```

The suite covers pure Lua UTF-8/span/offset mechanics, helper protocol and language cases, Neovim operator integration, lazy line/paragraph access, fallback/restart, and the host RSS plateau gate. Nix checks skip only RSS because sandbox process inspection is unavailable.

## Development Checks

Run all language-specific formatters, linters, strict type checks, and the Swift 6 compiler check with:

```sh
tests/lint.sh
```

Run the complete runtime suite, including the RSS soak, with:

```sh
tests/run.sh
```

The runtime helper is created under `${TMPDIR}` and removed by a trap; it does not create `.build/` in the repository.

The reproducible Nix checks run the static checks and the runtime suite without RSS:

```sh
nix flake check --all-systems
```

The host matrix is authoritative: `tests/lint.sh` uses Apple Swift 6 with strict concurrency and full SwiftLint. The locked nixpkgs compatibility matrix uses Swift 5.10.1 and keeps strict concurrency enabled; its SwiftLint package lacks `sourcekitdInProc.framework`, so only that Nix invocation uses `--disable-sourcekit` while retaining strict non-SourceKit rules.

## License

The [MIT](LICENSE).
