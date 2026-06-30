#!/bin/sh
# Build and install an httpd SVN branch with debug symbols.
# configure generates test/pyhttpd/config.ini pointing at the install prefix,
# so pytest picks it up automatically.
#
# Usage:
#   ./prepare_pytest.sh trunk
#   ./prepare_pytest.sh 2.4.x
#   ./prepare_pytest.sh --force trunk
#   ./prepare_pytest.sh --test trunk --with-install 2.4.x

FORCE=0
BRANCH=""
INSTALL_BRANCH=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force)        FORCE=1; shift ;;
        --test)         BRANCH="$2"; shift 2 ;;
        --with-install) INSTALL_BRANCH="$2"; shift 2 ;;
        *)              BRANCH="$1"; shift ;;
    esac
done

if [ -z "$BRANCH" ]; then
    echo "Error: No branch or tag provided."
    echo "Usage: $0 [--force] <branch-or-tag>"
    echo "       $0 --test <branch> --with-install <other>"
    echo "       branch: trunk | 2.4.x"
    echo "       tag:    2.4.68-rc1-candidate | ..."
    exit 1
fi

. "$(dirname "$0")/svn_branch.sh"

INSTALL_DIR="${BASE_BUILD_DIR}/${BRANCH}"
BUILT_REVISION_FILE="${INSTALL_DIR}/.built_revision"

resolve_source_dir "$BRANCH"

mkdir -p "$INSTALL_DIR" || exit 1

# --with-install: just reconfigure the source tree to point at a different install prefix.
if [ -n "$INSTALL_BRANCH" ]; then
    INSTALL_DIR="${BASE_BUILD_DIR}/${INSTALL_BRANCH}"
    if [ ! -f "${INSTALL_DIR}/bin/apachectl" ]; then
        echo "'${INSTALL_BRANCH}' is not installed yet. Building it first..."
        "$0" "${INSTALL_BRANCH}" || exit 1
    fi
    echo "Reconfiguring ${BRANCH} source to use ${INSTALL_BRANCH} installation (${INSTALL_DIR})..."
    export CFLAGS="-g -O0"
    cd "$SOURCE_DIR" || exit 1
    ./buildconf --with-apr=apr-1-config || exit 1
    if [ "$IS_TAG" = "1" ] && version_lte "$BRANCH" "2.4.52"; then
        ./configure \
            --enable-so \
            --with-nghttp2 \
            --enable-mods-shared=reallyall \
            --with-mpm=event \
            --enable-mpms-shared=all \
            --with-ssl=/usr \
            --with-apr=/usr \
            --with-apr-util=/usr \
            --with-pcre=/usr \
            --with-libxml2=/usr \
            --prefix="$INSTALL_DIR" \
            || exit 1
    else
        ./configure \
            --enable-so \
            --with-nghttp2 \
            --enable-mods-shared=reallyall \
            --with-mpm=event \
            --enable-mpms-shared=all \
            --with-ssl=/usr \
            --with-apr=/usr \
            --with-apr-util=/usr \
            --with-libxml2=/usr \
            --prefix="$INSTALL_DIR" \
            || exit 1
    fi
    print_build_env
    echo ""
    echo "Done. Run ${BRANCH} tests against ${INSTALL_BRANCH}:"
    echo "  cd ${SOURCE_DIR} && pytest test/modules"
    echo "  cd ${SOURCE_DIR} && pytest test/modules/http2"
    exit 0
fi

if [ "$FORCE" = "1" ] && [ -f "$BUILT_REVISION_FILE" ]; then
    echo "Forcing rebuild: removing build marker for '${BRANCH}'."
    rm -f "$BUILT_REVISION_FILE"
fi

FULL_BUILD=1

if [ "$IS_TAG" = "1" ]; then
    # Tags are immutable: build once and never again
    if [ -f "$BUILT_REVISION_FILE" ]; then
        echo "Tag '${BRANCH}' already built at r$(cat "$BUILT_REVISION_FILE"). Skipping build."
        echo ""
        echo "Run tests with:"
        echo "  cd ${SOURCE_DIR} && pytest test/modules"
        echo "  cd ${SOURCE_DIR} && pytest test/modules/http2"
        exit 0
    fi
    CURRENT_REV="$(svn info "$SOURCE_DIR" | awk '/^Revision:/{print $2}')"
else
    # Branch: update then compare revisions
    echo "Updating ${BRANCH} from SVN..."
    svn update "$SOURCE_DIR" || exit 1
    CURRENT_REV="$(svn info "$SOURCE_DIR" | awk '/^Revision:/{print $2}')"
    if [ -f "$BUILT_REVISION_FILE" ]; then
        LAST_BUILT_REV="$(cat "$BUILT_REVISION_FILE")"
        if [ "$CURRENT_REV" = "$LAST_BUILT_REV" ]; then
            echo "Branch '${BRANCH}' unchanged at r${CURRENT_REV}. Skipping build."
            echo ""
            echo "Run tests with:"
            echo "  cd ${SOURCE_DIR} && pytest test/modules"
            echo "  cd ${SOURCE_DIR} && pytest test/modules/http2"
            exit 0
        fi
        echo "Branch updated from r${LAST_BUILT_REV} to r${CURRENT_REV}. Rebuilding..."
        FULL_BUILD=0
    else
        echo "No previous build found. Building r${CURRENT_REV}..."
    fi
fi

export CFLAGS="-g -O0"

cd "$SOURCE_DIR" || exit 1

if [ "$FULL_BUILD" = "1" ]; then
    make distclean 2>/dev/null || true
    ./buildconf --with-apr=apr-1-config || exit 1
    # The following logic is just a work around in order to build older versions of httpd
    # using Fedora 44, a cleaner approach is to execute these steps in an containized env
    # having the exact compatible versions of the OpenSSL and libxml, but that way would be 
    # easy to execute one test again e.g. 2.4.49 and 2.4.67 using the same dev env.
    # For the moment its helpful but its not recommended and it has its limitations.
    if [ "$IS_TAG" = "1" ] && version_lte "$BRANCH" "2.4.52"; then
        # Old tags don't compile cleanly on modern Fedora 44 (OpenSSL 3, libxml2 2.12).
        # Inject a compat header via -include rather than patching the source tree.
        # ERR_GET_FUNC was dropped in OpenSSL 3; xmlstring.h needs an explicit include
        # in libxml2 2.12. Both are harmless stubs/includes for testing purposes.
        COMPAT_H="${SOURCE_DIR}/.compat.h"
        cat > "$COMPAT_H" <<'COMPAT'
#ifndef ERR_GET_FUNC
# define ERR_GET_FUNC(e) 0
#endif
#if defined(__has_include) && __has_include(<libxml/xmlstring.h>)
# include <libxml/xmlstring.h>
#endif
COMPAT
        export CFLAGS="-g -O0 -include ${COMPAT_H}"

        # Old mod_lua.h has a broken lua_resume shim that conflicts with Lua 5.4.
        # Can't fix it via -include (the macro gets redefined after), so just disable lua.
        DISABLE_LUA=""
        if grep -q 'define lua_resume(a,b)' "${SOURCE_DIR}/modules/lua/mod_lua.h" 2>/dev/null; then
            DISABLE_LUA="--disable-lua"
        fi
        ./configure \
            --enable-so \
            --with-nghttp2 \
            --enable-mods-shared=reallyall \
            --with-mpm=event \
            --enable-mpms-shared=all \
            --with-ssl=/usr \
            --with-apr=/usr \
            --with-apr-util=/usr \
            --with-pcre=/usr \
            --with-libxml2=/usr \
            ${DISABLE_LUA} \
            --prefix="$INSTALL_DIR" \
            || exit 1
    else
        ./configure \
            --enable-so \
            --with-nghttp2 \
            --enable-mods-shared=reallyall \
            --with-mpm=event \
            --enable-mpms-shared=all \
            --with-ssl=/usr \
            --with-apr=/usr \
            --with-apr-util=/usr \
            --with-libxml2=/usr \
            --prefix="$INSTALL_DIR" \
            || exit 1
    fi
else
    # httpd's Makefiles don't track header dependencies, so a header change
    # won't trigger a recompile of affected .c files. make clean forces it.
    make clean || true
fi

make -j"$(nproc)" || exit 1
make install || exit 1

echo "$CURRENT_REV" > "$BUILT_REVISION_FILE"

# port 80 needs root; switch to 8080
sed -i 's/^Listen 80$/Listen 8080/' "${INSTALL_DIR}/conf/httpd.conf"

# a2md comes from the system mod_md package, not the httpd build.
# Without it in bin/, the mod_md tests that use it are silently skipped.
A2MD_SYSTEM="$(command -v a2md 2>/dev/null)"
if [ -n "$A2MD_SYSTEM" ]; then
    ln -sf "$A2MD_SYSTEM" "${INSTALL_DIR}/bin/a2md"
    echo "Linked a2md: ${INSTALL_DIR}/bin/a2md -> ${A2MD_SYSTEM}"
else
    echo "Warning: a2md not found on PATH — test_502/602 mod_md tests will be skipped."
    echo "         Install it with: sudo dnf install mod_md   (or equivalent)"
fi


print_build_env
echo ""
echo "httpd (${BRANCH}) installed in ${INSTALL_DIR}"
echo ""
echo "Run tests with:"
echo "  cd ${SOURCE_DIR} && pytest test/modules"
echo "  cd ${SOURCE_DIR} && pytest test/modules/http2"
