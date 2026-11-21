default: build

GO_LDFLAGS += -X github.com/monome/maiden/cmd.version=$(shell git describe --tags)
GO_LDFLAGS += -X github.com/monome/maiden/cmd.compileTime=$(shell date -u +%Y-%m-%dT%H:%M)
export GO_LDFLAGS

build:
	cd backend && ../tool/go/run.sh go build -ldflags="${GO_LDFLAGS}" -o ../maiden

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
	rm -f maiden maiden.arm backend/maiden
	rm -rf web/build

clean-tools:
	./tool/go/clean.sh
	rm -rf .gopath 2>/dev/null || true

help:
	@echo "Available targets:"
	@echo "  build         - Build the project"
	@echo "  test          - Run Go tests"
	@echo "  release       - Build release for Linux ARM and package"
	@echo "  release-local - Build locally (no packaging)"
	@echo "  clean         - Remove build artifacts"
	@echo "  clean-tools   - Remove downloaded build tools"
	@echo "  help          - Show this help"

.PHONY: clean release build test default clean-tools help
