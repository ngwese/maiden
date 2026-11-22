default: backend

ZIG_VERSION := $(shell git describe --tags 2>/dev/null || echo development)
ZIG_COMPILE_TIME := $(shell date -u +%Y-%m-%dT%H:%M)

backend:
	cd backend && zig build -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	cp -f backend/zig-out/bin/maiden ./maiden

backend-arm:
	cd backend && zig build -Dtarget=arm-linux-gnueabihf.2.31 -Doptimize=ReleaseSafe -Dversion="$(ZIG_VERSION)" -Dcompile-time="$(ZIG_COMPILE_TIME)"
	mkdir -pv dist/maiden
	cp -f backend/zig-out/bin/maiden dist/maiden/maiden

frontend:
	cd web && yarn install && yarn build

release:
	./tool/release.sh

clean:
	rm -f maiden
	rm -rf dist
	rm -rf web/build
	rm -rf backend/zig-out backend/.zig-cache

help:
	@echo "Available targets:"
	@echo "  backend       - Build the Zig backend (native)"
	@echo "  backend-arm   - Cross-compile Zig backend for linux arm glibc 2.31"
	@echo "  frontend      - Release-build the web frontend"
	@echo "  release       - Build release for Linux ARM and package"
	@echo "  clean         - Remove build artifacts"
	@echo "  help          - Show this help"
	@echo ""
	@echo "API tests (manual): start the server, then:"
	@echo "  MAIDEN_BASE_URL=http://127.0.0.1:5000 yarn --cwd api-tests test"

.PHONY: clean release backend backend-arm frontend release-local default help
