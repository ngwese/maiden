# api tests

black-box http tests for the maiden backend. they talk to a server that is already running and do not start `maiden` themselves.

## setup

```bash
cd api-tests
yarn install
```

known compatible versions:

tool | version
-----|--------
node.js | 22
yarn | 1.22.22

## running

default target is `http://127.0.0.1:5000`:

```bash
yarn test
```

point at any maiden endpoint with `MAIDEN_BASE_URL`:

```bash
MAIDEN_BASE_URL=http://norns.local yarn test
```

watch mode:

```bash
yarn test:watch
```

## notes

use a server whose dust directory can accept a temporary folder. the suite creates and deletes `code/__maiden_api_tests__/<id>/` through the api.

the suite does not start, stop, or restart systemd units, and it does not perform a successful project install or update.
