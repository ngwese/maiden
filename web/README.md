# building

## required tooling

building the editor requires installing `node` and `yarn`.

both `node` and `yarn` can be installed from your package manager:

- macOS Homebrew: `brew install node yarn`
- Arch Linux: `pacman -Sy nodejs npm yarn`
- Debian / Ubuntu: [repo for `node`][node-debian] and [repo for `yarn`][yarn-debian]
- You can also manually install `yarn` with `npm install -g yarn`

[node-debian]: https://nodejs.org/en/download/package-manager/#debian-and-ubuntu-based-linux-distributions
[yarn-debian]: https://yarnpkg.com/lang/en/docs/install/#debian-stable

known compatible versions:

tool | version
-----|--------
npm | 6.1.0
yarn | 1.7.0

## to build
from the `web/` directory within the `maiden` source tree:

```
yarn install
yarn build
```
running `yarn build` will output static, bundled, and minified js, css, and html
files suitable for release in the `build` directory. the built results are self
contained and do not depend on node or any of the associated react toolchain.

## development and testing

running `yarn start` starts a local development server which automatically
recompiles (and reloads) the application when a file is saved.

the development server runs on port 3000 and forwards any unhandled request to
the `"proxy"` defined in the `package.json` file. starting the `maiden` server
in a separate shell allows api calls to be handled during development.

installing both the `reactjs` and `redux` devtools browser extensions is highly
recommended.

## repl connection

the `maiden` repl uses websockets to directly connect to the `norns` (lua) and
`supercollider` consoles bypassing the http backend. in order to determine which
host/ip and socket to connect to `maiden` reads the `repl-endpoints.json` file
(`web/public/repl-endpoints.json`) from the http backend.

when running both the frontend and backend locally during development it is
still possible to make the repl work by locally editing `repl-endpoints.json`,
the default configuration looks like:

```
{
    "norns": "ws://maiden_app_location:5555",
    "supercollider": "ws://maiden_app_location:5556"
}
```

the `maiden_app_location` is a special value which causes the frontend to
attempt to connect to whichever host/ip `maiden` itself was loaded from. when
running the frontend/backend locally, change the config to point specifically a
the hostname or ip addr of the norns device. for example:

```
{
    "norns": "ws://norns.local:5555",
    "supercollider": "ws://norns.local:5556"
}
```

## typical workflow

a very quick/iterative development configuration can be achieved by:

* enabling wifi on norns
* using `sshfs` to mount the `we` home directory locally - `sshfs we@norns.local: ~/norns`
* editing `repl-endpoints.json` to point at the norns device
* starting the backend locally - `go build && ./maiden server --app web/build/ --data ~/norns/dust --doc ~/norns/norns/doc --debug`
* starting the yarns development server `cd web; yarn start`
