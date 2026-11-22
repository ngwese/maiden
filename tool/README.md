# tool scripts

scripts used for packaging and device setup:

- `release.sh` - build linux arm release tarball (`make release`)
- `project-setup.sh` - copy sources/catalogs into `~/dust` on device


## usage

```bash
make backend       # native zig backend → ./maiden
make backend-arm   # cross-compile for norns
make frontend      # release-build the web frontend
make release       # build for linux arm and package dist/maiden.tgz
```

