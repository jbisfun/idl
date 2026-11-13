SHELL := /bin/bash
CONFIG ?= release
SWIFTLY_ENV := $(HOME)/.local/share/swiftly/env.sh
XTOOL := [ ! -f $(SWIFTLY_ENV) ] || . $(SWIFTLY_ENV); xtool

.DEFAULT_GOAL := ipa
.PHONY: ipa app signed install setup clean

ipa:
	$(XTOOL) dev build -c $(CONFIG) --ipa

app:
	$(XTOOL) dev build -c $(CONFIG)

signed:
	$(XTOOL) dev build -c $(CONFIG) --sign --ipa

install: signed
	$(XTOOL) install xtool/XtoolExample.ipa

setup:
	$(XTOOL) setup

clean:
	rm -rf .build .bsp xtool
