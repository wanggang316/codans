.PHONY: help bootstrap build-ghostty build-zmx generate build run-app format lint check check-rename test clean build-cli archive release bump-version regen-completions

# Use full Xcode.app when xcode-select points at Command Line Tools only.
# See DEC-10 in docs/exec-plans/0001-bootstrap-monorepo.md.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

help:
	@echo "apps/mac Makefile targets (usually invoked via top-level 'make mac-*'):"
	@echo "  bootstrap        - Init submodules + mise install"
	@echo "  build-ghostty    - Build GhosttyKit.xcframework (fingerprint-cached)"
	@echo "  build-zmx        - Build vendored zmx binary (fingerprint-cached)"
	@echo "  generate         - tuist install + tuist generate"
	@echo "  build            - Build touch-code app + tc CLI"
	@echo "  build-cli        - Build tc only"
	@echo "  run-app          - Build and launch touch-code.app"
	@echo "  archive          - Release archive + Developer ID export (needs Release.xcconfig)"
	@echo "  release          - archive + notarize + DMG + notarize DMG + staple"
	@echo "  bump-version     - Set MARKETING_VERSION (VERSION=x.y.z) and increment build number"
	@echo "  regen-completions - Regenerate tc/Resources/completions/{tc.zsh,tc.bash,tc.fish} from the built CLI"
	@echo "  format           - swift-format in-place"
	@echo "  lint             - swiftlint"
	@echo "  check            - format + lint"
	@echo "  test             - (placeholder)"
	@echo "  clean            - Remove workspace + project + Package.resolved"

bootstrap:
	cd ../.. && git submodule update --init --recursive && mise install

build-ghostty:
	./scripts/build-ghostty.sh

build-zmx:
	./scripts/build-zmx.sh

generate: bootstrap
	mise exec -- tuist install
	mise exec -- tuist generate --no-open

build: generate build-zmx
	xcodebuild -workspace touch-code.xcworkspace -scheme touch-code -configuration Debug build
	xcodebuild -workspace touch-code.xcworkspace -scheme tc -configuration Debug build

build-cli: generate
	xcodebuild -workspace touch-code.xcworkspace -scheme tc -configuration Debug build

# Refresh the bundled shell completion scripts from the live subcommand
# tree. Run after any change that adds/removes/renames a `tc` subcommand
# so tc/Resources/completions/{tc.zsh,tc.bash,tc.fish} (shipped inside
# the .app bundle) stay in sync. CI can `git diff --exit-code` after
# this target to fail loudly when contributors forget.
regen-completions: build-cli
	@TC=$$(xcodebuild -workspace touch-code.xcworkspace -scheme tc -configuration Debug -showBuildSettings 2>/dev/null | awk '$$1=="BUILT_PRODUCTS_DIR"{d=$$3} END{print d "/tc"}') && \
	  cd tc/Resources/completions && \
	  "$$TC" --generate-completion-script zsh  > tc.zsh  && \
	  "$$TC" --generate-completion-script bash > tc.bash && \
	  "$$TC" --generate-completion-script fish > tc.fish && \
	  echo "==> regenerated tc.zsh / tc.bash / tc.fish"

run-app: build
	@APP=$$(xcodebuild -workspace touch-code.xcworkspace -scheme touch-code -configuration Debug -showBuildSettings 2>/dev/null | awk '$$1=="BUILT_PRODUCTS_DIR"{d=$$3} $$1=="FULL_PRODUCT_NAME"{p=$$3} END{print d "/" p}') && open "$$APP"

archive: generate build-zmx
	./scripts/release.sh archive

release: generate build-zmx
	./scripts/release.sh release

bump-version:
	@if [ -z "$(VERSION)" ]; then \
	  echo "error: VERSION not set. Usage: make bump-version VERSION=0.2.0 [BUILD=N]" >&2; \
	  exit 1; \
	fi
	@if ! git -C $(CURDIR)/../.. diff --quiet HEAD -- apps/mac/Configurations; then \
	  echo "error: apps/mac/Configurations has uncommitted changes (staged or unstaged); refusing to bump" >&2; \
	  exit 1; \
	fi
	./scripts/bump-version.sh $(VERSION) $(BUILD)

format:
	swift format --in-place --recursive --configuration ./.swift-format.json touch-code tc TouchCodeCore TouchCodeIPC

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check-rename:
	../../scripts/check-rename-residue.sh apps/mac

check: format lint check-rename

test:
	@echo "no tests yet"

clean:
	rm -rf .build touch-code.xcworkspace touch-code.xcodeproj Tuist/Package.resolved
