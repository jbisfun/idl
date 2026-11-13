SHELL := /bin/bash
.DEFAULT_GOAL := help

.PHONY: help check test objc swift xtool examples clean

help:
	@printf '%s\n' \
	  'make check     verify the Linux iOS toolchain' \
	  'make test      run host-side utility tests' \
	  'make objc      build the Objective-C example IPA' \
	  'make swift     build the Swift example IPA' \
	  'make xtool     build the xtool/SwiftPM example IPA' \
	  'make examples  build and validate all example IPAs' \
	  'make clean     remove generated files'

check:
	@$(MAKE) -f mk/ios-toolchain.mk toolchain-check

test:
	python3 -m unittest discover -s tests -v

objc:
	@$(MAKE) -C templates/objc-app ipa

swift:
	@$(MAKE) -C templates/swift-app ipa

xtool:
	@$(MAKE) -C templates/xtool-swiftpm ipa
	@python3 tools/verify_ipa.py templates/xtool-swiftpm/xtool/XtoolExample.ipa \
	  --bundle-id com.example.xtoolapp --allow-unsigned

examples: check test objc swift xtool

clean:
	@$(MAKE) -C templates/objc-app clean
	@$(MAKE) -C templates/swift-app clean
	@$(MAKE) -C templates/xtool-swiftpm clean
