# Scripts

Helper scripts for building, testing, and debugging Apache httpd from source.

## Layout

| SVN (default) | Git (`--git`) | Contents |
|------|------|----------|
| `~/opensource/httpd_svn/<branch>` | `~/opensource/httpd_git/<ref>/` | source — test suite lives under `test/modules/` |
| | `~/opensource/httpd_git/.clone/` | shared git clone (managed automatically) |
| `~/httpd_builds/<branch>` | `~/httpd_builds/<ref>/` | configured/built/installed |
| `…/<branch>-pinned` | `…/<ref>-pinned` | scratch slot for `--test-revision` / `--test-ref` |
| `…/<branch>-install-pinned` | `…/<ref>-install-pinned` | scratch slot for `--source-revision` / `--source-ref` |

One source checkout and one install per branch/tag name, normally in lockstep. The `-pinned` slots exist so pinning a revision never disturbs that lockstep pair — they're reused and fully rebuilt in place on every call, never accumulated.

Override roots via env: `SVN_ROOT` / `GIT_ROOT` / `BASE_BUILD_DIR`. Git mode also accepts `GIT_REMOTE` (defaults to `https://github.com/apache/httpd.git`).

## Getting started

On a machine with nothing checked out yet:

```sh
# SVN (default)
./scripts/prepare_pytest.sh trunk

# Git
./scripts/prepare_pytest.sh --git main
```

That one command does everything: checks out/clones the source (no manual `svn checkout` or `git clone` needed), configures/builds/installs it, and generates `test/pyhttpd/config.ini` so pytest finds the install. Re-running it later just updates and rebuilds if the branch has moved on.

The only thing it doesn't set up is the Python side — do that once per checkout:

```sh
# SVN
cd ~/opensource/httpd_svn/trunk
# Git
cd ~/opensource/httpd_git/main

uv sync
pytest test/modules/http2
```

(`uv sync` is skippable if you run tests through `pyhttpd/runtests.sh`, which does it for you on first run.)

---

## prepare_pytest.sh

Builds an httpd branch from SVN or git with debug symbols and installs it locally so you can run the Python test suite against it. Pass `--git` to use git instead of SVN. `--test-ref` / `--source-ref` are aliases for `--test-revision` / `--source-revision` — in git mode these accept any git ref (branch, tag, or commit SHA).

| You want to... | SVN | Git |
|---|---|---|
| Build/update a branch to latest | `./prepare_pytest.sh trunk` | `./prepare_pytest.sh --git main` |
| Build a release tag (built once, then cached) | `… 2.4.68-rc1-candidate` | `… --git 2.4.62` |
| Force a rebuild even if nothing changed | `… --force trunk` | `… --git --force main` |
| Run one branch's tests against another's binary | `… --test trunk --with-install 2.4.x` | `… --git --test main --with-install 2.4.x` |
| Pin to an exact revision/commit | `… --test-revision 1935579 trunk` | `… --git --test-ref abc1234 main` |
| Test against a separately pinned binary | `… --test trunk --with-install trunk --source-revision 1937392` | `… --git --test main --with-install main --source-ref 2.4.62` |

Pinned builds (`--test-revision`/`--test-ref`, `--source-revision`/`--source-ref`) each use their own `-pinned` / `-install-pinned` scratch slot — the branch's normal checkout/install is never touched, and pinned builds are always rebuilt fully.

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
