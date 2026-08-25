# Scripts

Helper scripts for building, testing, and debugging Apache httpd from source.

## Layout

| Path | Contents |
|------|----------|
| `~/opensource/httpd_svn/<branch>` | SVN source checkout — the test suite lives here too, under `test/modules/` |
| `~/httpd_builds/<branch>` | that branch, configured/built/installed |
| `~/opensource/httpd_svn/<branch>-pinned`, `~/httpd_builds/<branch>-pinned` | scratch checkout+install used by `--test-revision` |
| `~/opensource/httpd_svn/<branch>-install-pinned`, `~/httpd_builds/<branch>-install-pinned` | scratch checkout+install used by `--source-revision` |

One source checkout and one install per branch/tag name, normally in lockstep. The `-pinned` slots exist so pinning a revision never disturbs that lockstep pair — they're reused and fully rebuilt in place on every call, never accumulated. Both roots default to `$HOME` as shown above; override either by exporting `SVN_ROOT` / `BASE_BUILD_DIR` before calling a script.

## Getting started

On a machine with nothing checked out yet:

```sh
./scripts/prepare_pytest.sh trunk
```

That one command does everything: checks trunk out from the ASF SVN repo (no manual `svn checkout` needed), configures/builds/installs it, and generates `test/pyhttpd/config.ini` so pytest finds the install. Re-running it later just updates and rebuilds if the branch has moved on.

The only thing it doesn't set up is the Python side — do that once per checkout:

```sh
cd ~/opensource/httpd_svn/trunk
uv sync
pytest test/modules/http2
```

(`uv sync` is skippable if you run tests through `pyhttpd/runtests.sh`, which does it for you on first run.)

---

## prepare_pytest.sh

Builds an httpd branch from SVN with debug symbols and installs it locally so you can run the Python test suite against it.

| You want to... | Run |
|---|---|
| Build/update a branch to latest | `./prepare_pytest.sh trunk` |
| Build a release tag (built once, then cached) | `./prepare_pytest.sh 2.4.68-rc1-candidate` |
| Force a rebuild even if nothing changed | `./prepare_pytest.sh --force trunk` |
| Run one branch's tests against another branch's already-built binary | `./prepare_pytest.sh --test trunk --with-install 2.4.x` |
| Reproduce one exact revision (test suite + binary, same revision) | `./prepare_pytest.sh --test-revision 1935579 trunk` — then `cd` into `trunk-pinned` |
| Keep working from your normal `trunk` checkout, but test against a binary pinned to one revision | `./prepare_pytest.sh --test trunk --with-install trunk --source-revision 1937392` — `trunk`'s own `config.ini` gets pointed at it, no `cd` needed |
| Run an *old* test suite against a *separately pinned* binary (only when the two revisions differ) | `./prepare_pytest.sh --test trunk --with-install trunk --test-revision 1937352 --source-revision 1937392` |

`--test-revision` and `--source-revision` each build into their own `<branch>-pinned` / `<branch>-install-pinned` scratch slot — the branch's normal checkout/install is never touched, and pinned builds are always rebuilt fully (no skip, no incremental).

Handles compat failures on modern Fedora (OpenSSL 3, libxml2 2.12, Lua 5.4) for old tags automatically.

---

## prepare_cdebug.sh (experimental)

Sets up C-level debugging of httpd with CLion. Run this after `prepare_pytest.sh` has built the branch.

> Still rough around the edges — works on my setup but hasn't been tested broadly. CLion version differences and gdbserver port conflicts are the most common sources of friction.

```sh
./prepare_cdebug.sh trunk
```

After running, do **File → Reload Project** in CLion once to pick up the new configs.

### Workflow A — debug while pytest runs a test

```sh
cd ~/opensource/httpd_svn/trunk
PYHTTPD_CONFIG=test/pyhttpd/config_gdb.ini PYTHONPATH=test \
  pytest -p pyhttpd.conftest_cdebug test/modules/http2 -k your_test
```

When `=== GDB MODE ===` appears: **CLion → Debug → "GDB Remote (httpd-trunk)" → Resume (F9)**

### Workflow B — debug with curl, no pytest

**CLion → Debug → "Debug httpd (trunk)"** — httpd starts under CLion's debugger.  
Then `curl http://localhost:8080/` from another terminal.

To use a different port: `GDBSERVER_PORT=5678 ./prepare_cdebug.sh trunk`

---

## Debugging without CLion

### Attach GDB to a running httpd

The PID in `httpd.pid` is the parent process — it doesn't handle requests. Attach to a worker instead:

```sh
pgrep -P $(cat ~/httpd_builds/trunk/httpd.pid)   # list worker PIDs
gdb -p <worker-pid>
```

Note: httpd distributes requests across workers, so your breakpoint only fires if the right worker handles the request. Use `-X` (single process) to avoid this.

### Run httpd directly under GDB

```sh
INSTALL=$HOME/httpd_builds/trunk
gdb --args $INSTALL/bin/httpd -d $INSTALL -f $INSTALL/conf/httpd.conf -X
```

---

## Typical flow

```
prepare_pytest.sh trunk        # build once, rebuilds automatically on svn update
pytest test/modules            # run the test suite

prepare_cdebug.sh trunk        # sets up two CLion configs:
  "GDB Remote (httpd-trunk)"   # connect while pytest runs
  "Debug httpd (trunk)"        # click Debug, curl, breakpoints fire
```
