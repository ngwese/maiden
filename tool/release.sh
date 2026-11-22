#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# quick and dirty release script for Linux ARM

REL_DIR=./dist/maiden

rm -rf ./dist
mkdir -pv $REL_DIR

# maiden
echo -e "building maiden"
echo "====================="
make build-arm
# for compatibility with old systemd unit setup
cp -v tool/start.sh $REL_DIR
cp -v tool/project-setup.sh $REL_DIR
cp -v maiden.yaml $REL_DIR

# sources
mkdir -pv $REL_DIR/dist/sources/
cp -v sources/*.json $REL_DIR/dist/sources/

# app
echo -e "\nbuilding app"
echo "====================="
cd web
yarn install
yarn build
cd ..

mkdir -pv ${REL_DIR}/app
cp -rv ./web/build ${REL_DIR}/app

# tarball
echo -e "\nmaking release"
echo "====================="
(cd ./dist; tar czvf maiden.tgz maiden)

# version manifest
echo -e "creating version manifest"
echo "====================="
cat > ${REL_DIR}/VERSIONS.json << VERSION_EOF
{
  "zig": "$(zig version)",
  "node": "$(node --version)",
  "yarn": "$(yarn --version)"
}
VERSION_EOF

echo "Release created: dist/maiden.tgz"
