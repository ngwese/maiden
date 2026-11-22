# building

## frontend dependencies

building the web-based editor requires installing `node` and `yarn`.

known compatible versions:

tool | version
-----|--------
node.js | 22.23.2
yarn | 1.22.22


Using [`nvm`](https://www.nvmnode.com/) and `corepack enable` to manage toolchain dependencies is recommended.

```bash
nvm install 22.23
nvm use 22.23
corepack enable
```

you can also use your package manager if it supports version numbers or names:

- macOS Homebrew: `brew install node@22`
- Arch Linux: `pacman -Sy nodejs-lts-jod npm`
- Debian / Ubuntu: `apt install nodejs npm` *(warning: will only be version 22 on some systems)*

or install node manually from [nodejs.org](https://nodejs.org/)

note: using a different version of node or yarn may result in incompatible dependencies.

## testing the frontend in development mode

make sure your norns is running and connected to wifi, then run:

```bash
cd web
yarn install
yarn start
```

the development server runs on port 5001 and proxies to the maiden backend at `http://norns.local:80`. It will also connect to the norns/supercollider websockets at `ws://norns.local:5555` and `:5556`.

installing both the `reactjs` and `redux` devtools browser extensions is highly recommended.

## testing the frontend and backend in development mode

To test with development versions of both the frontend and backend, use this workflow:

* enable wifi on norns
* create a local copy of the norns home dir, or use `sshfs` to mount the `we` home directory locally - `sshfs we@norns.local: ~/norns`
* build the frontend with `cd web; yarn install; yarn build`
* start the backend locally with `make backend && ./maiden server --app web/build/ --data ~/norns/dust --doc ~/norns/norns/doc --debug`. The backend will serve the precompiled frontend at http://localhost:5000.
* (optional) start the hot-reload development server with `cd web; yarn start_local`. The development frontend will run at http://localhost:5001.
* (optional) if you want to also run the norns and supercollider processes locally, edit `web/public/repl-endpoints.js` to point to local addresses.
