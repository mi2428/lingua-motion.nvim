SWIFTC ?= swiftc

lingua-motion-helper: Sources/lingua-motion-helper/main.swift
	$(SWIFTC) -swift-version 6 -warnings-as-errors -strict-concurrency=complete -O \
		-framework Foundation -framework NaturalLanguage $< -o $@
