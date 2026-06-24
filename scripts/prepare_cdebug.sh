#!/bin/sh
# Set up C-level debugging of httpd with CLion.
# Run after prepare_pytest.sh has built the branch.
#
# Usage: ./prepare_cdebug.sh trunk
#
# Two workflows after running this:
#
#   A) debug while pytest runs a test:
#      PYHTTPD_CONFIG=test/pyhttpd/config_gdb.ini PYTHONPATH=test \
#        pytest -p pyhttpd.conftest_cdebug test/modules/http2 -k your_test
#      When "=== GDB MODE ===" appears: CLion → Debug → "GDB Remote (httpd-<branch>)" → F9
#
#   B) debug with curl, no pytest:
#      CLion → Debug → "Debug httpd (<branch>)"
#      curl http://localhost:8080/ from another terminal

BRANCH="$1"
GDBSERVER_PORT="${GDBSERVER_PORT:-1234}"

if [ -z "$BRANCH" ]; then
    echo "Usage: $0 <branch>   (e.g. trunk, 2.4.x)"
    exit 1
fi

. "$(dirname "$0")/svn_branch.sh"

INSTALL_DIR="${BASE_BUILD_DIR}/${BRANCH}"

if [ ! -f "${INSTALL_DIR}/bin/apachectl" ]; then
    echo "Error: '${BRANCH}' is not built. Run prepare_pytest.sh ${BRANCH} first."
    exit 1
fi

resolve_source_dir "$BRANCH"

# 1. apachectl_gdb — drop-in replacement that starts httpd under gdbserver

WRAPPER="${INSTALL_DIR}/bin/apachectl_gdb"
cat > "$WRAPPER" <<'WRAPPER_EOF'
#!/bin/sh
GDBSERVER_PORT="${GDBSERVER_PORT:-1234}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_APACHECTL="${SCRIPT_DIR}/apachectl"
HTTPD="${SCRIPT_DIR}/httpd"

# pyhttpd calls: apachectl -d <serverroot> -f <conf> -k <cmd>
CMD=""
DOPT=""
FOPT=""
i=1
while [ "$i" -le "$#" ]; do
    eval "arg=\$$i"
    i=$((i+1))
    case "$arg" in
        -k) eval "CMD=\$$i"; i=$((i+1)) ;;
        -d) eval "DOPT=\$$i"; i=$((i+1)) ;;
        -f) eval "FOPT=\$$i"; i=$((i+1)) ;;
    esac
done

PID_FILE="${DOPT}/httpd.pid"

case "$CMD" in
    start)
        echo "" >&2
        echo "=== GDB MODE: httpd starting under gdbserver on port ${GDBSERVER_PORT} ===" >&2
        echo "    CLion → Debug → 'GDB Remote (httpd)' → Resume (F9)" >&2
        echo "    You have 2 minutes before pytest times out." >&2
        echo "" >&2
        gdbserver ":${GDBSERVER_PORT}" "$HTTPD" -d "$DOPT" -f "$FOPT" -X &
        sleep 0.3
        exit 0
        ;;
    stop|graceful-stop)
        [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"
        pkill -f "gdbserver :${GDBSERVER_PORT}" 2>/dev/null || true
        exit 0
        ;;
    graceful)
        [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null; rm -f "$PID_FILE"
        pkill -f "gdbserver :${GDBSERVER_PORT}" 2>/dev/null || true
        sleep 0.2
        exec "$0" -d "$DOPT" -f "$FOPT" -k start
        ;;
    *)
        exec "$REAL_APACHECTL" "$@"
        ;;
esac
WRAPPER_EOF
chmod +x "$WRAPPER"
echo "Created: $WRAPPER"

# 2. config_gdb.ini — pyhttpd config using apachectl_gdb instead of apachectl

CONFIG_INI_SRC="${SOURCE_DIR}/test/pyhttpd/config.ini"
CONFIG_INI_GDB="${SOURCE_DIR}/test/pyhttpd/config_gdb.ini"

if [ ! -f "$CONFIG_INI_SRC" ]; then
    echo "Warning: ${CONFIG_INI_SRC} not found (run prepare_pytest.sh ${BRANCH} first)."
else
    sed "s|apachectl = .*|apachectl = ${INSTALL_DIR}/bin/apachectl_gdb|" \
        "$CONFIG_INI_SRC" > "$CONFIG_INI_GDB"
    echo "Created: $CONFIG_INI_GDB"
fi

# 3. conftest_cdebug.py — extends pyhttpd startup timeout for gdbserver

CONFTEST="${SOURCE_DIR}/test/pyhttpd/conftest_cdebug.py"
cat > "$CONFTEST" <<'CONFTEST_EOF'
from datetime import timedelta
from pyhttpd.env import HttpdTestEnv

_LIVE_TIMEOUT = timedelta(seconds=120)


def _apache_restart(self):
    self.apache_stop()
    r = self._run_apachectl("start")
    if r.exit_code == 0:
        return 0 if self.is_live(self._http_base, timeout=_LIVE_TIMEOUT) else -1
    return r.exit_code


def _apache_reload(self):
    r = self._run_apachectl("graceful")
    if r.exit_code == 0:
        return 0 if self.is_live(self._http_base, timeout=_LIVE_TIMEOUT) else -1
    return r.exit_code


def pytest_configure(config):
    HttpdTestEnv.apache_restart = _apache_restart
    HttpdTestEnv.apache_reload = _apache_reload
CONFTEST_EOF
echo "Created: $CONFTEST"

# 4. .idea/customTargets.xml — CLion needs this to activate the Debug button for external binaries.

IDEA_DIR="${SOURCE_DIR}/.idea"
mkdir -p "$IDEA_DIR"
python3 - "$BRANCH" "${IDEA_DIR}/customTargets.xml" <<'PYEOF'
import sys, uuid
branch, out_file = sys.argv[1], sys.argv[2]
# Stable UUIDs per branch so re-running doesn't change the file
target_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"httpd-target-{branch}"))
config_id = str(uuid.uuid5(uuid.NAMESPACE_DNS, f"httpd-config-{branch}"))
with open(out_file, 'w') as f:
    f.write(f'''<?xml version="1.0" encoding="UTF-8"?>
<project version="4">
  <component name="CLionExternalBuildManager">
    <target id="{target_id}" name="httpd" defaultType="TOOL">
      <configuration id="{config_id}" name="httpd" toolchainName="Default" />
    </target>
  </component>
</project>
''')
PYEOF
echo "Created: ${IDEA_DIR}/customTargets.xml"

# 5. compile_commands.json — lets CLion index the C sources.
#    Flags are extracted from buildmark.c (always rebuilt) and applied to all .c files.
#    Per-module flags like OpenSSL defines won't be captured, so some warnings are expected.

COMPILE_COMMANDS="${SOURCE_DIR}/compile_commands.json"
python3 - "$SOURCE_DIR" "$COMPILE_COMMANDS" <<'PYEOF'
import subprocess, json, re, sys, os, glob

src_dir = sys.argv[1]
out_file = sys.argv[2]

# Target a specific file so make -n always emits a command even when up to date.
# httpd uses libtool, so the line looks like:
#   /path/libtool ... gcc <flags> -c server/buildmark.c -o server/buildmark.lo
result = subprocess.run(
    ["make", "-n", "server/buildmark.lo"],
    capture_output=True, text=True, cwd=src_dir
)
sample_cmd = ""
for line in result.stdout.splitlines():
    if "libtool" in line and "gcc" in line and " -c " in line:
        m = re.search(r'\bgcc\b.*', line)
        if m:
            cmd = re.sub(r'\s+-(?:prefer-non-pic|static)\b', '', m.group(0))
            cmd = re.sub(r'\s+-c\s+\S+\s+-o\s+\S+\s*$', '', cmd).strip()
            sample_cmd = cmd
            break

entries = []
if sample_cmd:
    for lo in glob.glob(os.path.join(src_dir, "**", "*.lo"), recursive=True):
        c_file = lo[:-3] + ".c"
        if os.path.exists(c_file):
            entries.append({"directory": src_dir, "command": f"{sample_cmd} -c {c_file}", "file": c_file})

with open(out_file, "w") as f:
    json.dump(entries, f, indent=2)
print(f"compile_commands.json: {len(entries)} entries")
PYEOF
echo "Created: $COMPILE_COMMANDS"

# 6. CLion run configs

RUN_DIR="${SOURCE_DIR}/.run"
mkdir -p "$RUN_DIR"

cat > "${RUN_DIR}/GDB Remote (httpd-${BRANCH}).run.xml" <<EOF
<component name="ProjectRunConfigurationManager">
  <configuration name="GDB Remote (httpd-${BRANCH})"
    type="CLionRemoteGDBRunConfiguration"
    factoryName="Remote GDB Debug"
    GDB_PATH="gdb"
    SYMBOL_FILE="${INSTALL_DIR}/bin/httpd"
    REMOTE_TARGET="tcp:localhost:${GDBSERVER_PORT}">
    <method v="2" />
  </configuration>
</component>
EOF
echo "Created CLion config: ${RUN_DIR}/GDB Remote (httpd-${BRANCH}).run.xml"

cat > "${RUN_DIR}/Debug httpd (${BRANCH}).run.xml" <<EOF
<component name="ProjectRunConfigurationManager">
  <configuration name="Debug httpd (${BRANCH})"
    type="CLionExternalRunConfiguration"
    factoryName="Application"
    PROGRAM_PARAMS="-d ${INSTALL_DIR} -f ${INSTALL_DIR}/conf/httpd.conf -X"
    WORKING_DIR="file://${INSTALL_DIR}"
    PASS_PARENT_ENVS_2="true"
    PROJECT_NAME="httpd"
    TARGET_NAME="httpd"
    CONFIG_NAME="httpd"
    RUN_PATH="${INSTALL_DIR}/bin/httpd">
    <method v="2" />
  </configuration>
</component>
EOF
echo "Created CLion config: ${RUN_DIR}/Debug httpd (${BRANCH}).run.xml"

echo ""
echo "=== C debug setup ready for httpd (${BRANCH}) ==="
echo ""
echo "Workflow A — debug a pytest test:"
echo "  cd ${SOURCE_DIR}"
echo "  PYHTTPD_CONFIG=test/pyhttpd/config_gdb.ini PYTHONPATH=test \\"
echo "    pytest -p pyhttpd.conftest_cdebug test/modules/http2 -k your_test"
echo "  When '=== GDB MODE ===' appears:"
echo "    CLion → Debug → 'GDB Remote (httpd-${BRANCH})' → Resume (F9)"
echo ""
echo "Workflow B — debug with curl:"
echo "  CLion → Debug → 'Debug httpd (${BRANCH})'"
echo "  curl http://localhost:8080/"
