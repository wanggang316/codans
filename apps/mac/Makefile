.PHONY: help bootstrap build-ghostty build-zmx generate build run-app format lint check check-rename test clean build-cli archive release bump-version regen-completions

# Use full Xcode.app when xcode-select points at CLT only.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer

help:
	@echo "apps/mac Makefile targets (usually invoked via top-level 'make mac-*'):"
	@echo "  bootstrap        - Init submodules + mise install"
	@echo "  build-ghostty    - Build GhosttyKit.xcframework (fingerprint-cached)"
	@echo "  build-zmx        - Build vendored zmx binary (fingerprint-cached)"
	@echo "  generate         - tuist install + tuist generate"
	@echo "  build            - Build codans app + codans CLI"
	@echo "  build-cli        - Build codans CLI only"
	@echo "  run-app          - Build and launch Codans.app"
	@echo "  archive          - Release archive + Developer ID export (needs Release.xcconfig)"
	@echo "  release          - archive + notarize + DMG + notarize DMG + staple"
	@echo "  bump-version     - Set MARKETING_VERSION (VERSION=x.y.z) and increment build number"
	@echo "  regen-completions - Regenerate codans-cli/Resources/completions/{codans.zsh,codans.bash,codans.fish} from the built CLI"
	@echo "  format           - swift-format in-place"
	@echo "  lint             - swiftlint"
	@echo "  check            - format + lint"
	@echo "  test             - Run Swift unit-test schemes (Codans/CodansCore/CodansKit)"
	@echo "  clean            - Remove workspace + project + Package.resolved"

bootstrap:
	cd ../.. && git submodule update --init --recursive && mise install

build-ghostty:
	./scripts/build-ghostty.sh

build-zmx:
	./scripts/build-zmx.sh

generate: bootstrap
	# --disable-experimental-prebuilts: tuist install shells out to
	# `swift package resolve`, whose prebuilt swift-syntax is default-on in
	# the Xcode 26 toolchain. The prebuilt MacroSupport breaks the Release
	# archive's module scan (CasePathsMacrosSupport.framework's modulemap
	# references a -Swift.h that isn't there -> "could not build module").
	# Building swift-syntax from source — as before the CI runner image
	# started serving the prebuilt — sidesteps it. tuist forwards the flag
	# through to swift package.
	mise exec -- tuist install --disable-experimental-prebuilts
	mise exec -- tuist generate --no-open

build: generate build-zmx
	xcodebuild -workspace codans.xcworkspace -scheme Codans -configuration Debug build
	xcodebuild -workspace codans.xcworkspace -scheme codans-cli -configuration Debug build

build-cli: generate
	xcodebuild -workspace codans.xcworkspace -scheme codans-cli -configuration Debug build

# Refresh the bundled shell completion scripts from the live subcommand
# tree. Run after any change that adds/removes/renames a `codans` subcommand
# so codans-cli/Resources/completions/{codans.zsh,codans.bash,codans.fish}
# (shipped inside the .app bundle) stay in sync. CI can `git diff --exit-code`
# after this target to fail loudly when contributors forget.
regen-completions: build-cli
	@CODANS=$$(xcodebuild -workspace codans.xcworkspace -scheme codans-cli -configuration Debug -showBuildSettings 2>/dev/null | awk '$$1=="BUILT_PRODUCTS_DIR"{d=$$3} END{print d "/codans"}') && \
	  cd codans-cli/Resources/completions && \
	  "$$CODANS" --generate-completion-script zsh  > codans.zsh  && \
	  "$$CODANS" --generate-completion-script bash > codans.bash && \
	  "$$CODANS" --generate-completion-script fish > codans.fish && \
	  echo "==> regenerated codans.zsh / codans.bash / codans.fish"

run-app: build
	@APP=$$(xcodebuild -workspace codans.xcworkspace -scheme Codans -configuration Debug -showBuildSettings 2>/dev/null | awk '$$1=="BUILT_PRODUCTS_DIR"{d=$$3} $$1=="FULL_PRODUCT_NAME"{p=$$3} END{print d "/" p}') && open "$$APP"

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
	swift format --in-place --recursive --configuration ./.swift-format.json codans codans-cli CodansCore CodansIPC

lint:
	mise exec -- swiftlint lint --quiet --config .swiftlint.yml

check-rename:
	../../scripts/check-rename-residue.sh apps/mac

check: format lint check-rename

# Run the Swift unit-test schemes. The `Codans` scheme hosts CodansTests
# (app/runtime tests); CodansCore / CodansKit host the framework tests.
# Each xcodebuild test is piped through xcbeautify for readable output;
# `set -o pipefail` is required so a pipe does NOT mask xcodebuild's exit
# code (a naive `... | xcbeautify` always reports success). The loop aborts
# via `|| exit $$?` on the first scheme that fails so the target exits non-zero.
test: generate
	@set -o pipefail; \
	for scheme in Codans CodansCore CodansKit; do \
	  echo "==> testing $$scheme"; \
	  xcodebuild test -workspace codans.xcworkspace -scheme "$$scheme" -configuration Debug \
	    | mise exec -- xcbeautify || exit $$?; \
	done

clean:
	rm -rf .build codans.xcworkspace codans.xcodeproj Tuist/Package.resolved
