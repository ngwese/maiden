# tool build environment

this directory contains self-contained build tools:

- go: golang 1.12.17

## setup

no manual setup needed. the `tool/*/run.sh` scripts will:

1. detect your build host os/architecture
2. download the appropriate toolchain (cached locally)
3. execute the command

## usage

### go

```bash
cd backend
../tool/go/run.sh go build -o ../maiden
../tool/go/run.sh go test
```


### make

```bash
make build
make release      # build for linux arm (raspberry pi)
make clean-tools  # remove downloaded tools
```

## cache location

tools are cached in:

- `tool/go/` - golang binary

both are gitignored. delete to force refresh.
