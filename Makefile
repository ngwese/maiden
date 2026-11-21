default: build

GO_LDFLAGS += -X github.com/monome/maiden/cmd.version=$(shell git describe --tags)
GO_LDFLAGS += -X github.com/monome/maiden/cmd.compileTime=$(shell date -u +%Y-%m-%dT%H:%M)
export GO_LDFLAGS

ZIG_VERSION := $(shell git describe --tags 2>/dev/null || echo development)
ZIG_COMPILE_TIME := $(shell date -u +%Y-%m-%dT%H:%M)

build:
	cd backend && ../tool/go/run.sh go build -ldflags="${GO_LDFLAGS}" -o ../maiden

build-next:
	cd backend-next && zig build -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	cp -f backend-next/zig-out/bin/maiden ./maiden-next

build-next-arm:
	cd backend-next && zig build -Dtarget=arm-linux-gnueabihf.2.31 -Doptimize=ReleaseSafe -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	mkdir -pv dist/maiden
	cp -f backend-next/zig-out/bin/maiden dist/maiden/maiden

test:
	cd backend && ../tool/go/run.sh go test .
	cd backend && ../tool/go/run.sh go test ./cmd/...
	cd backend/pkg/catalog && ../../../tool/go/run.sh go test ./...
	cd backend/pkg/dust && ../../../tool/go/run.sh go test ./...

release:
	./tool/release.sh

release-local:
	cd backend && ../tool/go/run.sh go build -ldflags="${GO_LDFLAGS}" -o ../maiden

clean:
	rm -rf dist
	rm -f maiden maiden.arm maiden-next backend/maiden
	rm -rf web/build backend-next/zig-out backend-next/.zig-cache

clean-tools:
	./tool/go/clean.sh
	rm -rf .gopath 2>/dev/null || true

help:
	@echo "Available targets:"
	@echo "  build          - Build the Go backend"
	@echo "  build-next     - Build the Zig backend (native)"
	@echo "  build-next-arm - Cross-compile Zig backend for linux arm glibc 2.31"
	@echo "  test           - Run Go tests"
	@echo "  release        - Build release for Linux ARM and package"
	@echo "  release-local  - Build locally (no packaging)"
	@echo "  clean          - Remove build artifacts"
	@echo "  clean-tools    - Remove downloaded build tools"
	@echo "  help           - Show this help"

.PHONY: clean release build build-next build-next-arm test default clean-tools help
