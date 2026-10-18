# Builds loom-node for every system a device may be, into loom's priv/, where
# `GET /node/download/:target` serves it from. Pure Go, so cross-compiling
# needs nothing but the Go toolchain. rel/deploy.sh runs this.

VERSION := $(shell git describe --always --dirty 2>/dev/null || echo dev)
OUT     := ../priv/node
TARGETS := darwin-arm64 darwin-amd64 linux-arm64 linux-amd64
FLAGS   := -trimpath -ldflags "-s -w -X main.version=$(VERSION)"

all: $(TARGETS)

$(TARGETS):
	CGO_ENABLED=0 GOOS=$(word 1,$(subst -, ,$@)) GOARCH=$(word 2,$(subst -, ,$@)) \
		go build $(FLAGS) -o $(OUT)/loom-node-$@ .

test:
	go test ./...

.PHONY: all test $(TARGETS)
