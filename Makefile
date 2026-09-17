PROJECT := MouseKy.xcodeproj
SCHEME := MouseKy
CONFIGURATION := Debug
DERIVED_DATA := .build
PRODUCT := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/MouseKy.app
INSTALL_DIR := $(HOME)/Applications
INSTALLED_APP := $(INSTALL_DIR)/MouseKy.app
BUNDLE_ID := io.github.stvn-pxl.MouseKy
APP_SUPPORT := $(HOME)/Library/Application Support/MouseKy
CACHE_DIR := $(HOME)/Library/Caches/$(BUNDLE_ID)
LOG_DIR := $(HOME)/Library/Logs/MouseKy
SAVED_STATE := $(HOME)/Library/Saved Application State/$(BUNDLE_ID).savedState
PREFERENCES := $(HOME)/Library/Preferences/$(BUNDLE_ID).plist

.PHONY: build reinstall run clean uninstall

build:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration "$(CONFIGURATION)" -derivedDataPath "$(DERIVED_DATA)" build
	@echo "Built: $(PRODUCT)"

reinstall: build
	@pkill -x MouseKy 2>/dev/null || true
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALLED_APP)"
	@ditto "$(PRODUCT)" "$(INSTALLED_APP)"
	@open "$(INSTALLED_APP)"
	@echo "Installed and launched: $(INSTALLED_APP)"

run: build
	@pkill -x MouseKy 2>/dev/null || true
	@open "$(PRODUCT)"

clean:
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -derivedDataPath "$(DERIVED_DATA)" clean

uninstall:
	@pkill -x MouseKy 2>/dev/null || true
	@rm -rf "$(INSTALLED_APP)" "$(APP_SUPPORT)" "$(CACHE_DIR)" "$(LOG_DIR)" "$(SAVED_STATE)" "$(PREFERENCES)"
	@tccutil reset Accessibility "$(BUNDLE_ID)" 2>/dev/null || true
	@tccutil reset ListenEvent "$(BUNDLE_ID)" 2>/dev/null || true
	@echo "MouseKy and its local data, caches, logs, saved state, preferences, and permissions were removed."
