.PHONY: help bootstrap mac-bootstrap mac-build-ghostty mac-build-zmx mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-release mac-bump-version mac-format mac-lint mac-check mac-test mac-clean

MAC_APP_DIR := apps/mac

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
	@echo "  mac-test          - (placeholder)"
	@echo "  mac-clean         - Remove workspace + project + Package.resolved"

bootstrap:
	git submodule update --init --recursive
	mise install

mac-bootstrap mac-build-ghostty mac-build-zmx mac-generate mac-build mac-build-cli mac-run-app mac-archive mac-release mac-format mac-lint mac-check mac-test mac-clean:
	$(MAKE) -C $(MAC_APP_DIR) $(subst mac-,,$@)

mac-bump-version:
	$(MAKE) -C $(MAC_APP_DIR) bump-version VERSION=$(VERSION)
