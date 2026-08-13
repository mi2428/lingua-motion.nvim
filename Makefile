.PHONY: record check

record:
	./record.sh

check:
	@tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/lingua-motion-demo-check.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	sh -n record.sh; \
	fish -n start.fish; \
	shellcheck record.sh; \
	shfmt -d record.sh; \
	osacompile -o "$$tmp/drive.scpt" drive.applescript; \
	osacompile -o "$$tmp/prepare.scpt" prepare.applescript; \
	swiftc -typecheck input_source.swift; \
	swiftc -typecheck place_window.swift; \
	host_pattern="/$$(printf Users)/|/$$(printf home)/[^ ]|opt/$$(printf homebrew)|usr/$$(printf local)|\\.$$(printf nix-profile)|nix/$$(printf store)"; \
	if rg -n "$$host_pattern" --glob '!demo.gif' .; then \
		echo 'host-specific path found' >&2; \
		exit 1; \
	fi
