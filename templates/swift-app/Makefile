SHELL := /bin/bash
.DEFAULT_GOAL := ipa

ROOT := ../..
APP := SwiftExample
BUNDLE_ID := com.example.swiftexample
MIN_IOS := 16.0
BUILD := build
APP_DIR := $(BUILD)/Payload/$(APP).app
IPA := $(BUILD)/$(APP).ipa

include $(ROOT)/mk/ios-toolchain.mk

.PHONY: ipa app project clean verify

$(APP_DIR)/$(APP): Sources/main.swift
	@mkdir -p $(@D) $(MODULE_CACHE)
	$(SWIFTC) $(IOS_SWIFT_LDFLAGS) -module-name $(APP) $< -o $@
	chmod 755 $@

$(APP_DIR)/Info.plist: Info.plist
	@mkdir -p $(@D)
	$(PYTHON) $(ROOT)/tools/plisttool.py plist -i $< -o $@ 	  --var EXECUTABLE_NAME=$(APP) --var PRODUCT_BUNDLE_IDENTIFIER=$(BUNDLE_ID) 	  --set MinimumOSVersion=$(MIN_IOS)

$(APP_DIR)/PkgInfo:
	@mkdir -p $(@D)
	@printf 'APPL????' > $@

app: toolchain-check $(APP_DIR)/$(APP) $(APP_DIR)/Info.plist $(APP_DIR)/PkgInfo $(LDID)
	$(LDID) -SEntitlements.plist -I$(BUNDLE_ID) $(APP_DIR)/$(APP)

ipa: app
	@rm -f $(IPA)
	@cd $(BUILD) && $(ZIP) -qry $(notdir $(IPA)) Payload
	@unzip -tq $(IPA)
	@$(PYTHON) $(ROOT)/tools/verify_ipa.py $(IPA) --bundle-id $(BUNDLE_ID)

verify:
	@$(PYTHON) $(ROOT)/tools/verify_ipa.py $(IPA) --bundle-id $(BUNDLE_ID)

project:
	@$(PYTHON) $(ROOT)/tools/pbxprojgen.py project.json

clean:
	rm -rf $(BUILD) $(APP).xcodeproj
