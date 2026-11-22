# maiden

web based script editor and cli tools for norns.

`maiden` consists of two parts - a backend http server and a frontend single
page web app.

## setup

development can either be done directly on the device or on a linux/macos
machine.

### requirements

- **Zig 0.17.1** - for the backend
- **Node.js** - for the frontend (see `web/package.json` / `.nvmrc`)

## building

### building with make

the simplest way to build is using the included makefile:

```bash
make backend       # build the backend (native)
make backend-arm   # cross-compile for linux arm (norns)
make frontend      # release-build the web frontend
make release       # build release for linux arm and package in dist/maiden.tgz
make help          # show available targets
```


### manual build

if you prefer to build manually:

#### backend

from the `backend/` directory in the `maiden` source tree:

```bash
cd backend
zig build
# binary at zig-out/bin/maiden
```

or from the repo root:

```bash
make backend
# binary at ./maiden
```

#### frontend (ui)

from the repo root:

```bash
make frontend
```

or from the `web/` directory:

```bash
yarn install
yarn build
```

running `yarn build` will output static, bundled, and minified js, css, and html
files suitable for release in the `build` directory. the built results are self
contained and do not depend on node or any of the associated react toolchain.


### cross-compiling

if developing on a linux or macos it is trivial to cross compile for arm
(raspberry pi):

```bash
make backend-arm
# or:
cd backend
zig build -Dtarget=arm-linux-gnueabihf.2.31 -Doptimize=ReleaseSafe
```


**note:** the release target in `tool/release.sh` automatically builds for linux
arm.

**tip:** install FUSE on your linux/macos machine and then mount the device
filesystem using sshfs - the build results can then be written directly to the
device.

## testing

```bash
./maiden server --debug --app web/build/ --data <norns_repo>/lua
```

api tests against a running server:

```bash
MAIDEN_BASE_URL=http://127.0.0.1:5000 yarn --cwd api-tests test
```

## development

```bash
# build backend and frontend
make backend
make frontend

# optional: hot-reload frontend
cd web && yarn start

# run backend in a separate shell
./maiden server --debug --app web/build/ --data ~/dust
```


## known compatible versions

tool | version
-----|---------
zig  | 0.17.1
node.js | see `web/package.json` / `.nvmrc`
yarn | 1.x (compatible with react-scripts 1.0.17)
