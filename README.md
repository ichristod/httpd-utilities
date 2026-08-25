# httpd-utilities

Scripts for building, testing, and debugging Apache httpd from source.

## Scripts

See [scripts/README.md](scripts/README.md) for full documentation.

| Script | Purpose |
|--------|---------|
| `prepare_pytest.sh` | Build an httpd SVN branch with debug symbols and wire up the Python test suite |
| `prepare_cdebug.sh` | Set up C-level debugging with CLion — experimental, works on my setup |
| `svn_branch.sh` | Shared helpers sourced by the other scripts |

## Quick start

```sh
./scripts/prepare_pytest.sh trunk
cd ~/opensource/httpd_svn/trunk && pytest test/modules
```

## Credits

Built with assistance from Claude, tested by ichristod.
