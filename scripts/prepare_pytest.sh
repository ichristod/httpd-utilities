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
#   ./prepare_pytest.sh --test-revision 1935579 trunk
#   ./prepare_pytest.sh --test trunk --with-install 2.4.x --test-revision 1935579
#   ./prepare_pytest.sh --test trunk --with-install trunk --source-revision 1937392
#   ./prepare_pytest.sh --test trunk --test-revision 1937352 --with-install trunk --source-revision 1937392

FORCE=0
BRANCH=""
INSTALL_BRANCH=""
TEST_REVISION=""
SOURCE_REVISION=""

while [ $# -gt 0 ]; do
    case "$1" in
        --force)           FORCE=1; shift ;;
        --test)             BRANCH="$2"; shift 2 ;;
        --with-install)     INSTALL_BRANCH="$2"; shift 2 ;;
        --test-revision)    TEST_REVISION="$2"; shift 2 ;;
        --source-revision)  SOURCE_REVISION="$2"; shift 2 ;;
        *)                  BRANCH="$1"; shift ;;
    esac
done

if [ -z "$BRANCH" ]; then
    echo "Error: No branch or tag provided."
    echo "Usage: $0 [--force] [--test-revision <rev>] <branch-or-tag>"
    echo "       $0 --test <branch> --with-install <other> [--test-revision <rev>] [--source-revision <rev>]"
    echo "       branch: trunk | 2.4.x"
    echo "       tag:    2.4.68-rc1-candidate | ..."
    exit 1
fi

if [ -n "$SOURCE_REVISION" ] && [ -z "$INSTALL_BRANCH" ]; then
    echo "Error: --source-revision only applies together with --with-install."
    exit 1
fi

. "$(dirname "$0")/svn_branch.sh"

resolve_source_dir "$BRANCH"
BRANCH_SOURCE_DIR="$SOURCE_DIR"
BRANCH_IS_TAG="$IS_TAG"

if [ -n "$TEST_REVISION" ] && [ "$BRANCH_IS_TAG" = "1" ]; then
    echo "Error: --test-revision is not applicable to tag '${BRANCH}' (tags are already immutable)."
    exit 1
fi

# checkout_or_switch <canonical_source_dir> <revision> <target_dir>
checkout_or_switch() {
    _canonical="$1"; _rev="$2"; _target="$3"
    if [ -d "$_target" ]; then
        echo "Switching $(basename "$_target") to r${_rev}..."
        svn update -r "$_rev" "$_target" || exit 1
    else
        _url="$(svn info "$_canonical" | awk -F': ' '/^URL:/{print $2}')"
        echo "Checking out $(basename "$_target") at r${_rev}..."
        svn checkout -r "$_rev" "$_url" "$_target" || exit 1
    fi
}

# do_build_install <source_dir> <install_dir> <branch_name> <is_tag> <full_build> <revision>
do_build_install() {
    _src="$1"; _install="$2"; _name="$3"; _is_tag="$4"; _full="$5"; _rev="$6"

    export CFLAGS="-g -O0"
    cd "$_src" || exit 1

    if [ "$_full" = "1" ]; then
        make distclean 2>/dev/null || true
        ./buildconf --with-apr=apr-1-config || exit 1
        # The following logic is just a work around in order to build older versions of httpd
        # using Fedora 44, a cleaner approach is to execute these steps in an containized env
        # having the exact compatible versions of the OpenSSL and libxml, but that way would be
        # easy to execute one test again e.g. 2.4.49 and 2.4.67 using the same dev env.
        # For the moment its helpful but its not recommended and it has its limitations.
        if [ "$_is_tag" = "1" ] && version_lte "$_name" "2.4.52"; then
            # Old tags don't compile cleanly on modern Fedora 44 (OpenSSL 3, libxml2 2.12).
            # Inject a compat header via -include rather than patching the source tree.
            # ERR_GET_FUNC was dropped in OpenSSL 3; xmlstring.h needs an explicit include
            # in libxml2 2.12. Both are harmless stubs/includes for testing purposes.
            COMPAT_H="${_src}/.compat.h"
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
            if grep -q 'define lua_resume(a,b)' "${_src}/modules/lua/mod_lua.h" 2>/dev/null; then
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
                --prefix="$_install" \
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
                --prefix="$_install" \
                || exit 1
        fi
    else
        # httpd's Makefiles don't track header dependencies, so a header change
        # won't trigger a recompile of affected .c files. make clean forces it.
        make clean || true
    fi

    make -j"$(nproc)" || exit 1
    make install || exit 1

    echo "$_rev" > "${_install}/.built_revision"

    # port 80 needs root; switch to 8080
    sed -i 's/^Listen 80$/Listen 8080/' "${_install}/conf/httpd.conf"

    # a2md comes from the system mod_md package, not the httpd build.
    # Without it in bin/, the mod_md tests that use it are silently skipped.
    A2MD_SYSTEM="$(command -v a2md 2>/dev/null)"
    if [ -n "$A2MD_SYSTEM" ]; then
        ln -sf "$A2MD_SYSTEM" "${_install}/bin/a2md"
        echo "Linked a2md: ${_install}/bin/a2md -> ${A2MD_SYSTEM}"
    else
        echo "Warning: a2md not found on PATH — test_502/602 mod_md tests will be skipped."
        echo "         Install it with: sudo dnf install mod_md   (or equivalent)"
    fi

    print_build_env
}

# --with-install: reconfigure the --test branch's source to point at a different install prefix.
if [ -n "$INSTALL_BRANCH" ]; then
    if [ -n "$SOURCE_REVISION" ]; then
        resolve_source_dir "$INSTALL_BRANCH"
        if [ "$IS_TAG" = "1" ]; then
            echo "Error: --source-revision is not applicable to tag '${INSTALL_BRANCH}' (tags are already immutable)."
            exit 1
        fi
        INSTALL_SOURCE_DIR="${SVN_ROOT}/${INSTALL_BRANCH}-install-pinned"
        checkout_or_switch "$SOURCE_DIR" "$SOURCE_REVISION" "$INSTALL_SOURCE_DIR"
        INSTALL_DIR="${BASE_BUILD_DIR}/${INSTALL_BRANCH}-install-pinned"
        mkdir -p "$INSTALL_DIR" || exit 1
        echo "Building ${INSTALL_BRANCH} at r${SOURCE_REVISION} into ${INSTALL_DIR}..."
        do_build_install "$INSTALL_SOURCE_DIR" "$INSTALL_DIR" "$INSTALL_BRANCH" "$IS_TAG" 1 "$SOURCE_REVISION"
    else
        INSTALL_DIR="${BASE_BUILD_DIR}/${INSTALL_BRANCH}"
        if [ ! -f "${INSTALL_DIR}/bin/apachectl" ]; then
            echo "'${INSTALL_BRANCH}' is not installed yet. Building it first..."
            "$0" "${INSTALL_BRANCH}" || exit 1
        fi
    fi

    if [ -n "$TEST_REVISION" ]; then
        TEST_SOURCE_DIR="${SVN_ROOT}/${BRANCH}-pinned"
        checkout_or_switch "$BRANCH_SOURCE_DIR" "$TEST_REVISION" "$TEST_SOURCE_DIR"
    else
        TEST_SOURCE_DIR="$BRANCH_SOURCE_DIR"
        echo "Updating ${BRANCH} from SVN..."
        svn update "$TEST_SOURCE_DIR" || exit 1
    fi

    echo "Reconfiguring ${BRANCH} source to use ${INSTALL_BRANCH} installation (${INSTALL_DIR})..."
    export CFLAGS="-g -O0"
    cd "$TEST_SOURCE_DIR" || exit 1
    ./buildconf --with-apr=apr-1-config || exit 1
    if [ "$BRANCH_IS_TAG" = "1" ] && version_lte "$BRANCH" "2.4.52"; then
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
    echo "  cd ${TEST_SOURCE_DIR} && pytest test/modules"
    echo "  cd ${TEST_SOURCE_DIR} && pytest test/modules/http2"
    exit 0
fi

# --test-revision without --with-install: own install slot, always a full rebuild.
if [ -n "$TEST_REVISION" ]; then
    PINNED_SOURCE_DIR="${SVN_ROOT}/${BRANCH}-pinned"
    checkout_or_switch "$BRANCH_SOURCE_DIR" "$TEST_REVISION" "$PINNED_SOURCE_DIR"
    INSTALL_DIR="${BASE_BUILD_DIR}/${BRANCH}-pinned"
    mkdir -p "$INSTALL_DIR" || exit 1
    CURRENT_REV="$(svn info "$PINNED_SOURCE_DIR" | awk '/^Revision:/{print $2}')"
    echo "Pinned build of ${BRANCH} at r${CURRENT_REV}: forcing full rebuild."
    do_build_install "$PINNED_SOURCE_DIR" "$INSTALL_DIR" "$BRANCH" "$BRANCH_IS_TAG" 1 "$CURRENT_REV"
    echo ""
    echo "httpd (${BRANCH}) installed in ${INSTALL_DIR}"
    echo ""
    echo "Run tests with:"
    echo "  cd ${PINNED_SOURCE_DIR} && pytest test/modules"
    echo "  cd ${PINNED_SOURCE_DIR} && pytest test/modules/http2"
    exit 0
fi

# Plain form: build and install BRANCH itself, tracking HEAD.
INSTALL_DIR="${BASE_BUILD_DIR}/${BRANCH}"
BUILT_REVISION_FILE="${INSTALL_DIR}/.built_revision"
mkdir -p "$INSTALL_DIR" || exit 1

if [ "$FORCE" = "1" ] && [ -f "$BUILT_REVISION_FILE" ]; then
    echo "Forcing rebuild: removing build marker for '${BRANCH}'."
    rm -f "$BUILT_REVISION_FILE"
fi

FULL_BUILD=1

if [ "$BRANCH_IS_TAG" = "1" ]; then
    # Tags are immutable: build once and never again
    if [ -f "$BUILT_REVISION_FILE" ]; then
        echo "Tag '${BRANCH}' already built at r$(cat "$BUILT_REVISION_FILE"). Skipping build."
        echo ""
        echo "Run tests with:"
        echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules"
        echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules/http2"
        exit 0
    fi
    CURRENT_REV="$(svn info "$BRANCH_SOURCE_DIR" | awk '/^Revision:/{print $2}')"
else
    # Branch: update then compare revisions
    echo "Updating ${BRANCH} from SVN..."
    svn update "$BRANCH_SOURCE_DIR" || exit 1
    CURRENT_REV="$(svn info "$BRANCH_SOURCE_DIR" | awk '/^Revision:/{print $2}')"
    if [ -f "$BUILT_REVISION_FILE" ]; then
        LAST_BUILT_REV="$(cat "$BUILT_REVISION_FILE")"
        if [ "$CURRENT_REV" = "$LAST_BUILT_REV" ]; then
            echo "Branch '${BRANCH}' unchanged at r${CURRENT_REV}. Skipping build."
            echo ""
            echo "Run tests with:"
            echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules"
            echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules/http2"
            exit 0
        fi
        echo "Branch updated from r${LAST_BUILT_REV} to r${CURRENT_REV}. Rebuilding..."
        FULL_BUILD=0
    else
        echo "No previous build found. Building r${CURRENT_REV}..."
    fi
fi

do_build_install "$BRANCH_SOURCE_DIR" "$INSTALL_DIR" "$BRANCH" "$BRANCH_IS_TAG" "$FULL_BUILD" "$CURRENT_REV"

echo ""
echo "httpd (${BRANCH}) installed in ${INSTALL_DIR}"
echo ""
echo "Run tests with:"
echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules"
echo "  cd ${BRANCH_SOURCE_DIR} && pytest test/modules/http2"
