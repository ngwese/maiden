# backend-next

zig reimplementation of the maiden backend aimed to be a drop-in replacement for
the go binary in `backend/`.

## requirements

zig 0.17.1

## building

native:

```bash
cd backend-next
zig build
# binary at zig-out/bin/maiden
```

or from the repo root:

```bash
make build-next
```

cross-compile for norns (linux arm hard-float, glibc 2.31):

```bash
make build-next-arm
# or:
cd backend-next
zig build -Dtarget=arm-linux-gnueabihf.2.31 -Doptimize=ReleaseSafe
```

## running

same cli as the go backend:

```bash
./zig-out/bin/maiden server --debug --app ../web/build --data ~/dust
```

built-in TUI REPL (replaces the external `maiden-repl` binary). Websocket
endpoints are loaded from `{--api}/maiden/repl-endpoints.json` (`maiden_app_location`
is replaced with the API host):

```bash
./zig-out/bin/maiden repl
# optional: override discovered websocket URLs, and/or --api for the maiden server
./zig-out/bin/maiden repl ws://127.0.0.1:5555/ ws://127.0.0.1:5556/ --api http://127.0.0.1/
```

## testing

point the api test suite at a running server:

```bash
MAIDEN_BASE_URL=http://127.0.0.1:5000 yarn --cwd ../api-tests test
```
