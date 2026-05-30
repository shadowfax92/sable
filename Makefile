APP_NAME := Sable
APP_BUNDLE := $(APP_NAME).app
BUNDLE_ID := ai.browseros.sable
BUNDLE_VERSION := 1
CONFIG ?= release
INSTALL_DIR ?= /Applications
MIN_MACOS := 13.0
SHORT_VERSION := 0.1.0
BIN_PATH := .build/$(CONFIG)/$(APP_NAME)
INSTALL_APP := $(INSTALL_DIR)/$(APP_BUNDLE)
INSTALL_STAGING_DIR := .build/install-staging
INSTALL_STAGING_APP := $(INSTALL_STAGING_DIR)/$(APP_BUNDLE)
SHELL := /bin/bash

.PHONY: all build app test run open install reinstall uninstall clean print-app-path

all: build

build: app

app:
	@set -euo pipefail; \
	echo "-> swift build -c $(CONFIG) --product $(APP_NAME)"; \
	swift build -c "$(CONFIG)" --product "$(APP_NAME)"; \
	if [[ ! -x "$(BIN_PATH)" ]]; then \
		echo "Expected binary not found at $(BIN_PATH)" >&2; \
		exit 1; \
	fi; \
	echo "-> assembling $(APP_BUNDLE)"; \
	rm -rf "$(APP_BUNDLE)"; \
	mkdir -p "$(APP_BUNDLE)/Contents/MacOS" "$(APP_BUNDLE)/Contents/Resources"; \
	cp "$(BIN_PATH)" "$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)"; \
	if [[ -f "Resources/AppIcon.icns" ]]; then \
		cp "Resources/AppIcon.icns" "$(APP_BUNDLE)/Contents/Resources/AppIcon.icns"; \
	fi; \
	{ \
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'; \
		printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'; \
		printf '%s\n' '<plist version="1.0">'; \
		printf '%s\n' '<dict>'; \
		printf '%s\n' '    <key>CFBundleDevelopmentRegion</key>'; \
		printf '%s\n' '    <string>en</string>'; \
		printf '%s\n' '    <key>CFBundleExecutable</key>'; \
		printf '%s\n' '    <string>$(APP_NAME)</string>'; \
		printf '%s\n' '    <key>CFBundleIconFile</key>'; \
		printf '%s\n' '    <string>AppIcon</string>'; \
		printf '%s\n' '    <key>CFBundleIconName</key>'; \
		printf '%s\n' '    <string>AppIcon</string>'; \
		printf '%s\n' '    <key>CFBundleIdentifier</key>'; \
		printf '%s\n' '    <string>$(BUNDLE_ID)</string>'; \
		printf '%s\n' '    <key>CFBundleInfoDictionaryVersion</key>'; \
		printf '%s\n' '    <string>6.0</string>'; \
		printf '%s\n' '    <key>CFBundleName</key>'; \
		printf '%s\n' '    <string>$(APP_NAME)</string>'; \
		printf '%s\n' '    <key>CFBundleDisplayName</key>'; \
		printf '%s\n' '    <string>$(APP_NAME)</string>'; \
		printf '%s\n' '    <key>CFBundlePackageType</key>'; \
		printf '%s\n' '    <string>APPL</string>'; \
		printf '%s\n' '    <key>CFBundleShortVersionString</key>'; \
		printf '%s\n' '    <string>$(SHORT_VERSION)</string>'; \
		printf '%s\n' '    <key>CFBundleVersion</key>'; \
		printf '%s\n' '    <string>$(BUNDLE_VERSION)</string>'; \
		printf '%s\n' '    <key>LSMinimumSystemVersion</key>'; \
		printf '%s\n' '    <string>$(MIN_MACOS)</string>'; \
		printf '%s\n' '    <key>NSHighResolutionCapable</key>'; \
		printf '%s\n' '    <true/>'; \
		printf '%s\n' '    <key>NSHumanReadableCopyright</key>'; \
		printf '%s\n' '    <string>Copyright 2026</string>'; \
		printf '%s\n' '    <key>NSPrincipalClass</key>'; \
		printf '%s\n' '    <string>NSApplication</string>'; \
		printf '%s\n' '</dict>'; \
		printf '%s\n' '</plist>'; \
	} > "$(APP_BUNDLE)/Contents/Info.plist"; \
	codesign --force --deep --sign - --identifier "$(BUNDLE_ID)" "$(APP_BUNDLE)" >/dev/null; \
	echo "OK $(CURDIR)/$(APP_BUNDLE)"; \
	echo "  open $(CURDIR)/$(APP_BUNDLE)"

test:
	swift test

run: open

open: app
	open "$(APP_BUNDLE)"

install: app
	@set -euo pipefail; \
	echo "-> installing $(INSTALL_APP)"; \
	rm -rf "$(INSTALL_STAGING_DIR)"; \
	mkdir -p "$(INSTALL_STAGING_DIR)" "$(INSTALL_DIR)"; \
	ditto "$(APP_BUNDLE)" "$(INSTALL_STAGING_APP)"; \
	codesign --force --deep --sign - --identifier "$(BUNDLE_ID)" "$(INSTALL_STAGING_APP)" >/dev/null; \
	rm -rf "$(INSTALL_APP)"; \
	ditto "$(INSTALL_STAGING_APP)" "$(INSTALL_APP)"; \
	codesign --verify --deep --strict "$(INSTALL_APP)" >/dev/null; \
	rm -rf "$(INSTALL_STAGING_DIR)"; \
	echo "OK Installed $(INSTALL_APP)"; \
	echo "  open \"$(INSTALL_APP)\""

reinstall:
	@rm -rf "$(INSTALL_APP)"
	@$(MAKE) install INSTALL_DIR="$(INSTALL_DIR)" CONFIG="$(CONFIG)"

uninstall:
	@rm -rf "$(INSTALL_APP)"
	@echo "OK Removed $(INSTALL_APP)"

clean:
	rm -rf .build "$(APP_BUNDLE)"

print-app-path:
	@echo "$(CURDIR)/$(APP_BUNDLE)"
