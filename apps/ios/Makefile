.PHONY: help generate build build-iphone build-ipad test lint format clean

# Use full Xcode.app when xcode-select points at CLT only.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

# Simulator destinations. `OS=latest` avoids ambiguity when an older
# runtime ships a device with the same name.
IPHONE_DESTINATION ?= platform=iOS Simulator,name=iPhone 17 Pro,OS=latest
IPAD_DESTINATION   ?= platform=iOS Simulator,name=iPad Pro 13-inch (M4),OS=latest
TEST_DESTINATION   ?= $(IPHONE_DESTINATION)

XCODEBUILD := xcodebuild -workspace CodansMobile.xcworkspace -configuration Debug

help:
	@echo "apps/ios Makefile targets (usually invoked via top-level 'make ios-*'):"
	@echo "  generate      - tuist install + tuist generate (also loads ../mac for the shared targets)"
	@echo "  build         - Build CodansMobile for the iPhone and iPad simulators"
	@echo "  build-iphone  - Build for $(IPHONE_DESTINATION)"
	@echo "  build-ipad    - Build for $(IPAD_DESTINATION)"
	@echo "  test          - Run CodansMobileTests on $(TEST_DESTINATION)"
	@echo "  lint          - swiftlint (apps/mac config)"
	@echo "  clean         - Remove workspace + project + Tuist build dir"

# A cross-project reference makes Tuist resolve the referenced project's
# external dependencies from this project's manifest, so apps/ios must list
# and pin exactly what apps/mac does. Tuist/Package.swift is a symlink to
# apps/mac's; Package.resolved is a copy refreshed here, because Tuist
# re-links it under .build and a symlinked lockfile breaks the second
# `tuist install`.
generate:
	cp ../mac/Tuist/Package.resolved Tuist/Package.resolved
	mise exec -- tuist install
	mise exec -- tuist generate --no-open

build: build-iphone build-ipad

build-iphone: generate
	$(XCODEBUILD) -scheme CodansMobile -destination '$(IPHONE_DESTINATION)' build

build-ipad: generate
	$(XCODEBUILD) -scheme CodansMobile -destination '$(IPAD_DESTINATION)' build

test: generate
	@set -o pipefail; \
	$(XCODEBUILD) -scheme CodansMobile -destination '$(TEST_DESTINATION)' test | mise exec -- xcbeautify

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

format:
	swift format --in-place --recursive --configuration ../mac/.swift-format.json CodansMobile CodansMobileTests

clean:
	rm -rf CodansMobile.xcworkspace CodansMobile.xcodeproj Derived Tuist/.build
