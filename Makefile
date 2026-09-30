# Thin wrappers around xcodebuild / swift. Only Xcode is required.
# `make help` lists targets.

PROJECT      := Splicewright.xcodeproj
SCHEME       := Splicewright
PACKAGE      := Packages/SplicewrightKit
BUILD_DIR    := build
DERIVED      := $(BUILD_DIR)/DerivedData
DEBUG_APP    := $(DERIVED)/Build/Products/Debug/Splicewright.app
RELEASE_APP  := $(DERIVED)/Build/Products/Release/Splicewright.app
DMG          := $(BUILD_DIR)/Splicewright.dmg
XCODEGEN_VERSION := 2.46.0
XCODEGEN     := $(BUILD_DIR)/tools/xcodegen/bin/xcodegen

XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=macOS' \
             -derivedDataPath $(DERIVED) -skipPackagePluginValidation

.DEFAULT_GOAL := help
.PHONY: help doctor build run test release dmg fixtures lint generate check-project clean

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  make %-14s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

doctor: ## Check that this Mac has what's needed to build
	@scripts/doctor.sh

build: ## Build the Debug app
	$(XCODEBUILD) -configuration Debug -quiet build

run: build ## Build and launch the Debug app
	open "$(DEBUG_APP)"

test: ## Run all unit tests (SWCore, SWMedia)
	swift test --package-path $(PACKAGE)

release: ## Build the Release app
	$(XCODEBUILD) -configuration Release -quiet build
	@echo "Built $(RELEASE_APP)"

dmg: release ## Package the Release app as a .dmg
	rm -rf $(BUILD_DIR)/dmg $(DMG)
	mkdir -p $(BUILD_DIR)/dmg
	cp -R "$(RELEASE_APP)" $(BUILD_DIR)/dmg/
	ln -s /Applications $(BUILD_DIR)/dmg/Applications
	hdiutil create -volname Splicewright -srcfolder $(BUILD_DIR)/dmg -ov -format UDZO $(DMG)
	@echo "Created $(DMG)"

fixtures: ## Generate sample SDR/HDR clips in TestMedia/ (needs ffmpeg)
	@scripts/make-fixtures.sh

lint: ## Run SwiftLint (optional; CI runs it)
	@command -v swiftlint >/dev/null || { echo "SwiftLint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --quiet

$(XCODEGEN):
	mkdir -p $(BUILD_DIR)/tools
	curl -sSfL -o $(BUILD_DIR)/tools/xcodegen.zip \
	  https://github.com/yonaskolb/XcodeGen/releases/download/$(XCODEGEN_VERSION)/xcodegen.zip
	unzip -q -o $(BUILD_DIR)/tools/xcodegen.zip -d $(BUILD_DIR)/tools

generate: $(XCODEGEN) ## Regenerate Splicewright.xcodeproj from project.yml (maintainers)
	$(XCODEGEN) generate --spec project.yml

check-project: generate ## Fail if the committed Xcode project doesn't match project.yml
	@git diff --exit-code -- $(PROJECT) App/Info.plist \
	  || { echo "Splicewright.xcodeproj is out of date. Run 'make generate' and commit."; exit 1; }

clean: ## Remove build products
	rm -rf $(BUILD_DIR)
