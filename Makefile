APP_NAME := Sable
APP_BUNDLE := $(APP_NAME).app
BUILD_APP := $(CURDIR)/.build/$(APP_BUNDLE)
INSTALL_DIR ?= $(HOME)/Applications
INSTALL_APP := $(INSTALL_DIR)/$(APP_BUNDLE)

.PHONY: all build test run install uninstall clean print-app-path

all: build

build:
	@./scripts/build-app.sh

test:
	@swift test

run: build
	@open "$(BUILD_APP)"

install: build
	@mkdir -p "$(INSTALL_DIR)"
	@rm -rf "$(INSTALL_APP)"
	@ditto "$(BUILD_APP)" "$(INSTALL_APP)"
	@echo "Installed $(APP_NAME) to $(INSTALL_APP)"

uninstall:
	@rm -rf "$(INSTALL_APP)"
	@echo "Removed $(INSTALL_APP)"

clean:
	@swift package clean
	@rm -rf "$(BUILD_APP)"

print-app-path:
	@echo "$(BUILD_APP)"
