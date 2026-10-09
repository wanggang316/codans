.PHONY: help bootstrap ios-generate ios-build ios-build-iphone ios-build-ipad ios-test ios-lint ios-clean mac-bootstrap mac-build-ghostty mac-build-zmx mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-release mac-bump-version mac-format mac-lint mac-check mac-test mac-clean web-install web-dev web-build web-preview web-typecheck

MAC_APP_DIR := apps/mac
IOS_APP_DIR := apps/ios
WEB_DIR     := apps/website

help:
	@echo "codans top-level Makefile (delegates to $(MAC_APP_DIR)/Makefile):"
	@echo "  bootstrap         - Init submodules + mise install"
	@echo "  mac-generate      - Generate codans.xcworkspace from Tuist"
	@echo "  mac-build         - Build mac app + codans CLI"
	@echo "  mac-build-cli     - Build codans CLI only"
	@echo "  mac-run-app       - Build and launch codans.app"
	@echo "  mac-archive       - Release archive + Developer ID export"
	@echo "  mac-release       - Full release pipeline: archive → notarize → DMG → staple"
	@echo "  mac-bump-version  - VERSION=x.y.z; updates MARKETING_VERSION + build number"
	@echo "  mac-build-ghostty - Build GhosttyKit.xcframework"
	@echo "  mac-build-zmx     - Build vendored zmx binary"
	@echo "  mac-format        - swift-format in-place"
	@echo "  mac-lint          - swiftlint"
	@echo "  mac-check         - format + lint"
	@echo "  mac-test          - Run Swift unit tests (xcodebuild test, non-zero on failure)"
	@echo "  mac-clean         - Remove workspace + project + Package.resolved"
	@echo ""
	@echo "iOS companion ($(IOS_APP_DIR)):"
	@echo "  ios-generate      - Generate CodansMobile.xcworkspace from Tuist (loads $(MAC_APP_DIR) shared targets)"
	@echo "  ios-build         - Build CodansMobile for the iPhone and iPad simulators"
	@echo "  ios-build-iphone  - Build for the iPhone simulator only"
	@echo "  ios-build-ipad    - Build for the iPad simulator only"
	@echo "  ios-test          - Run CodansMobileTests on the iPhone simulator"
	@echo "  ios-lint          - swiftlint"
	@echo "  ios-clean         - Remove workspace + project + Tuist build dir"
	@echo ""
	@echo "website ($(WEB_DIR)):"
	@echo "  web-install       - pnpm install"
	@echo "  web-dev           - pnpm dev   (Vite at http://localhost:5173)"
	@echo "  web-build         - pnpm build (production output in $(WEB_DIR)/dist)"
	@echo "  web-preview       - pnpm preview"
	@echo "  web-typecheck     - tsc -b --noEmit"

bootstrap:
	git submodule update --init --recursive
	mise install

mac-bootstrap mac-build-ghostty mac-build-zmx mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-release mac-format mac-lint mac-check mac-test mac-clean:
	$(MAKE) -C $(MAC_APP_DIR) $(subst mac-,,$@)

ios-generate ios-build ios-build-iphone ios-build-ipad ios-test ios-lint ios-clean:
	$(MAKE) -C $(IOS_APP_DIR) $(subst ios-,,$@)

mac-bump-version:
	$(MAKE) -C $(MAC_APP_DIR) bump-version VERSION=$(VERSION)

web-install:
	cd $(WEB_DIR) && pnpm install

web-dev:
	cd $(WEB_DIR) && pnpm dev

web-build:
	cd $(WEB_DIR) && pnpm build

web-preview:
	cd $(WEB_DIR) && pnpm preview

web-typecheck:
	cd $(WEB_DIR) && pnpm typecheck
