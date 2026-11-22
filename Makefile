default: build

ZIG_VERSION := $(shell git describe --tags 2>/dev/null || echo development)
ZIG_COMPILE_TIME := $(shell date -u +%Y-%m-%dT%H:%M)

build:
	cd backend && zig build -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	cp -f backend/zig-out/bin/maiden ./maiden

build-arm:
	cd backend && zig build -Dtarget=arm-linux-gnueabihf.2.31 -Doptimize=ReleaseSafe -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	mkdir -pv dist/maiden
	cp -f backend/zig-out/bin/maiden dist/maiden/maiden

release:
	./tool/release.sh

release-local: build

clean:
	rm -rf dist
	rm -f maiden maiden.arm
	rm -rf web/build backend/zig-out backend/.zig-cache

help:
	@echo "Available targets:"
	@echo "  build         - Build the Zig backend (native)"
	@echo "  build-arm     - Cross-compile Zig backend for linux arm glibc 2.31"
	@echo "  release       - Build release for Linux ARM and package"
	@echo "  release-local - Build locally (no packaging)"
	@echo "  clean         - Remove build artifacts"
	@echo "  help          - Show this help"
	@echo ""
	@echo "API tests (manual): start the server, then:"
	@echo "  MAIDEN_BASE_URL=http://127.0.0.1:5000 yarn --cwd api-tests test"

.PHONY: clean release build build-arm release-local default help
