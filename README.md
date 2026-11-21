# maiden

self contained web based editor for norns

`maiden` consists of two parts - a backend http server and a frontend single page web app.

## setup

development can either be done directly on the device or on a linux/macos machine using the self-contained build environment.

### built-in toolchain

`maiden` includes a self-contained build environment in the `tool/` directory:

- **Go 1.16.15** - downloaded and cached automatically
- **Node.js 16.20.2** - installed via nvm and cached automatically

no manual installation of go, node, or yarn is required. the `tool/*/run.sh` scripts will download and cache the appropriate versions on first use.

## building

`maiden` uses the go module system to manage dependencies.

### building with make

the simplest way to build is using the included makefile:

```bash
make build       # build the backend
make release     # build release for linux arm and package in dist/maiden.tgz
make help        # show available targets
```

### manual build

if you prefer to build manually:

#### backend

from the `backend/` directory in the `maiden` source tree:

```bash
cd backend
../tool/go/run.sh go build -ldflags="-X github.com/monome/maiden/cmd.version=$(git describe --tags) -X github.com/monome/maiden/cmd.compileTime=$(date -u +%Y-%m-%dT%H:%M)" -o ../maiden
```

#### frontend (ui)

from the `web/` directory in the `maiden` source tree:

```bash
../tool/node/run.sh yarn install
../tool/node/run.sh yarn build
```

running `../tool/node/run.sh yarn build` will output static, bundled, and minified js, css, and html files suitable for release in the `build` directory. the built results are self contained and do not depend on node or any of the associated react toolchain.

**note:** the frontend must be built using `../tool/node/run.sh yarn` - do not use the system's node/yarn as they may have incompatible versions.

### cross-compiling

if developing on a linux or macos it is trivial to cross compile for arm (raspberry pi):

```bash
cd backend
GOOS=linux GOARCH=arm ../tool/go/run.sh go build -ldflags="${GO_LDFLAGS}" -o ../dist/maiden/maiden
```

**note:** the release target in `tool/release.sh` automatically builds for linux arm.

**tip:** install FUSE on your linux/macos machine and then mount the device filesystem using sshfs - the build results can then be written directly to the device.

## testing

```bash
./maiden server --debug --app web/build/ --data <norns_repo>/lua
```

## development

for development with the built-in toolchain:

```bash
# build backend
cd backend
../tool/go/run.sh go build -o ../maiden
cd ..

# build frontend
cd web
../tool/node/run.sh yarn install
../tool/node/run.sh yarn build
../tool/node/run.sh yarn start

# run backend in a separate shell
./maiden server --debug --app web/build/ --data ~/dust
```


## known compatible versions

tool | version
-----|---------
go   | 1.16.15 (with go1.12-compatible code)
node.js | 16.20.2 (npm 8.19.4, yarn 1.22.22)
yarn | 1.22.22 (compatible with react-scripts 1.0.17)
