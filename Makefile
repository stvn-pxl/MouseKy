PROJECT := MouseKy.xcodeproj
SCHEME := MouseKy
CONFIGURATION := Debug
DEV_APP_NAME := MouseKy Dev
DEV_BUNDLE_ID := io.github.stvn-pxl.MouseKy.Dev
DEV_SIGNING_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F '"' '/Apple Development/ { print $$2; exit }')
DEV_CODE_SIGN_IDENTITY := $(if $(DEV_SIGNING_IDENTITY),$(DEV_SIGNING_IDENTITY),-)
DERIVED_DATA := .build
BUILD_ARTIFACTS := $(DERIVED_DATA) .build-current .build-tests .build-ci .build-release DerivedData
XCODE_DERIVED_DATA_ROOT := $(HOME)/Library/Developer/Xcode/DerivedData
PRODUCT := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(DEV_APP_NAME).app
INSTALL_DIR := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/$(DEV_APP_NAME).app
APP_SUPPORT := $(HOME)/Library/Application Support/$(DEV_APP_NAME)
CACHE_DIR := $(HOME)/Library/Caches/$(DEV_BUNDLE_ID)
LOG_DIR := $(HOME)/Library/Logs/$(DEV_APP_NAME)
SAVED_STATE := $(HOME)/Library/Saved Application State/$(DEV_BUNDLE_ID).savedState
PREFERENCES := $(HOME)/Library/Preferences/$(DEV_BUNDLE_ID).plist
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DEV_BUILD_SETTINGS := PRODUCT_NAME="$(DEV_APP_NAME)" PRODUCT_BUNDLE_IDENTIFIER="$(DEV_BUNDLE_ID)" CODE_SIGN_IDENTITY="$(DEV_CODE_SIGN_IDENTITY)" CODE_SIGN_STYLE=Manual

.PHONY: build reinstall run clean uninstall

build:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA)" $(DEV_BUILD_SETTINGS) build
	@echo "Built: $(PRODUCT)"

reinstall: build
	@pkill -x "$(DEV_APP_NAME)" 2>/dev/null || true
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALLED_APP)"
	@ditto "$(PRODUCT)" "$(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"
	@echo "Installed and launched: $(INSTALLED_APP)"

run: build
	@pkill -x "$(DEV_APP_NAME)" 2>/dev/null || true
	@open "$(PRODUCT)"

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)" $(DEV_BUILD_SETTINGS) clean

uninstall:
	@pkill -x "$(DEV_APP_NAME)" 2>/dev/null || true
	@if [ -d "$(INSTALLED_APP)" ]; then \
		"$(LSREGISTER)" -f "$(INSTALLED_APP)"; \
	elif [ -d "$(PRODUCT)" ]; then \
		"$(LSREGISTER)" -f "$(PRODUCT)"; \
	fi
	@tccutil reset Accessibility "$(DEV_BUNDLE_ID)"
	@tccutil reset ListenEvent "$(DEV_BUNDLE_ID)"
	@rm -rf "$(INSTALLED_APP)" "$(APP_SUPPORT)" "$(CACHE_DIR)" "$(LOG_DIR)" "$(SAVED_STATE)" "$(PREFERENCES)" $(BUILD_ARTIFACTS) "$(XCODE_DERIVED_DATA_ROOT)"/MouseKy-*
	@echo "$(DEV_APP_NAME), its local data, permissions, and local build artifacts were removed."
