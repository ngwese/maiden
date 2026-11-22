# tool scripts

scripts used for packaging and device setup:

- `release.sh` - build linux arm release tarball (`make release`)
- `start.sh` - systemd-compatible launcher copied into the release
- `project-setup.sh` - copy sources/catalogs into `~/dust` on device

## usage

```bash
make build        # native zig backend → ./maiden
make build-arm    # cross-compile for norns
make release      # build for linux arm and package dist/maiden.tgz
```
