SHELL := /bin/bash
.DEFAULT_GOAL := ipa

ROOT := ../..
APP := ObjCExample
BUNDLE_ID := com.example.objcexample
MIN_IOS := 16.0
BUILD := build
APP_DIR := $(BUILD)/Payload/$(APP).app
IPA := $(BUILD)/$(APP).ipa
OBJ := $(BUILD)/obj/main.o

include $(ROOT)/mk/ios-toolchain.mk

.PHONY: ipa app project clean verify

$(OBJ): Sources/main.m
	@mkdir -p $(@D) $(MODULE_CACHE)
	$(CC) $(IOS_OBJCFLAGS) -c $< -o $@

$(APP_DIR)/$(APP): $(OBJ)
	@mkdir -p $(@D)
	$(CC) $(IOS_LDFLAGS) $^ -o $@ -framework UIKit -framework Foundation
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
