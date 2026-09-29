.PHONY: help test vet build build-linux run deploy clean

BUILD_DIR := .build
BIN       := $(BUILD_DIR)/codans-relay

DEPLOY_HOST := root@162.243.195.13
DEPLOY_KEY  := ~/.ssh/deploy
DEPLOY_ROOT := /opt/codans-relay
SSH         := ssh -i $(DEPLOY_KEY)
SCP         := scp -i $(DEPLOY_KEY)

help:
	@echo "apps/relay Makefile targets:"
	@echo "  test         - go vet + go test -race"
	@echo "  build        - Build codans-relay for this host into $(BUILD_DIR)/"
	@echo "  build-linux  - Build a static linux/amd64 binary at $(BIN)"
	@echo "  run          - Build and run locally on 127.0.0.1:3050 (data in ./data)"
	@echo "  deploy       - build-linux, upload a release to $(DEPLOY_HOST), activate it"
	@echo "  clean        - Remove $(BUILD_DIR)/"

test:
	go vet ./...
	go test -race ./...

build:
	go build -o $(BUILD_DIR)/host/codans-relay ./cmd/codans-relay

run: build
	$(BUILD_DIR)/host/codans-relay -listen 127.0.0.1:3050 -data ./data

build-linux:
	GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -ldflags "-s -w" -o $(BIN) ./cmd/codans-relay

# Release dir = <git short sha>-<UTC timestamp>. activate.sh swaps the
# `current` symlink and restarts the service. The Caddy snippet is installed
# separately (see README), since reloading Caddy touches every site on the VM.
deploy: build-linux
	@set -e; \
	release="$$(git rev-parse --short HEAD)-$$(date -u +%Y%m%d%H%M%S)"; \
	tarball="$(BUILD_DIR)/codans-relay-$$release.tar.gz"; \
	stage="$(BUILD_DIR)/stage"; \
	rm -rf "$$stage" && mkdir -p "$$stage"; \
	cp $(BIN) deploy/codans-relay.service deploy/codans-relay.caddy deploy/activate.sh "$$stage/"; \
	tar -czf "$$tarball" -C "$$stage" .; \
	echo "==> uploading release $$release"; \
	$(SSH) $(DEPLOY_HOST) "mkdir -p $(DEPLOY_ROOT)/releases/$$release"; \
	$(SCP) "$$tarball" $(DEPLOY_HOST):$(DEPLOY_ROOT)/releases/$$release/release.tar.gz; \
	$(SSH) $(DEPLOY_HOST) "cd $(DEPLOY_ROOT)/releases/$$release && tar -xzf release.tar.gz && rm release.tar.gz && NEW_RELEASE=$$release ./activate.sh"

clean:
	rm -rf $(BUILD_DIR)
