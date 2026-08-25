#!/bin/sh
# Shared helpers for the prepare_*.sh scripts. Source, don't run directly.

# Override either by exporting it before calling a prepare_*.sh script.
SVN_ROOT="${SVN_ROOT:-${HOME}/opensource/httpd_svn}"
BASE_BUILD_DIR="${BASE_BUILD_DIR:-${HOME}/httpd_builds}"

# returns 0 if $1 <= $2
version_lte() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

pkg_version() {
    pkg-config --modversion "$1" 2>/dev/null || echo "n/a"
}

cmd_version() {
    cmd="$1"; pattern="$2"
    out="$(eval "$cmd" 2>&1)"
    echo "$out" | grep -oE "$pattern" | head -1
}

print_build_env() {
    echo ""
    echo "Build environment:"
    uname -a
    gcc --version 2>/dev/null | head -1
    printf "openssl:    %s\n" "$(openssl version 2>/dev/null | awk '{print $2}')"
    printf "apr:        %s\n" "$(apr-1-config --version 2>/dev/null)"
    printf "apr-util:   %s\n" "$(apu-1-config --version 2>/dev/null)"
    printf "brotli:     %s\n" "$(cmd_version 'brotli --version' '[0-9]+\.[0-9]+\.[0-9]+')"
    printf "jansson:    %s\n" "$(pkg_version jansson)"
    printf "nghttp2:    %s\n" "$(pkg_version libnghttp2)"
    printf "pcre2:      %s\n" "$(pkg_version libpcre2-8)"
    printf "lua:        %s\n" "$(cmd_version 'lua -v' '[0-9]+\.[0-9]+\.[0-9]+')"
    printf "systemd:    %s\n" "$(systemctl --version 2>/dev/null | awk '/systemd [0-9]/ {gsub(/[()]/,"",$3); print $3}')"
    printf "openldap:   %s\n" "$(pkg_version ldap)"
    printf "expat:      %s\n" "$(pkg_version expat)"
    printf "xml2:       %s\n" "$(pkg_version libxml-2.0)"
    printf "curl:       %s\n" "$(cmd_version 'curl --version' '^curl [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}')"
    printf "a2md:       %s\n" "$(cmd_version 'a2md --version' '[0-9]+\.[0-9]+\.[^ ]+')"
}

_svn_repo_base() {
    url="$(svn info "${SVN_ROOT}/trunk" 2>/dev/null \
           | awk -F': ' '/^URL:/{print $2}' \
           | sed 's|/trunk$||')"
    echo "${url:-https://svn.apache.org/repos/asf/httpd/httpd}"
}

# Sets SOURCE_DIR and IS_TAG. Checks out from SVN if not already local.
resolve_source_dir() {
    _branch="$1"
    IS_TAG=0

    if [ -d "${SVN_ROOT}/${_branch}" ]; then
        # Directly under SVN_ROOT: trunk, 2.4.x, or a manually checked-out branch
        SOURCE_DIR="${SVN_ROOT}/${_branch}"

    elif [ -d "${SVN_ROOT}/tags/${_branch}" ]; then
        # Already checked out under tags/
        SOURCE_DIR="${SVN_ROOT}/tags/${_branch}"
        IS_TAG=1

    else
        # Not local — probe SVN remote
        _repo="$(_svn_repo_base)"

        if svn ls "${_repo}/tags/${_branch}" >/dev/null 2>&1; then
            SOURCE_DIR="${SVN_ROOT}/tags/${_branch}"
            IS_TAG=1
            if [ ! -d "$SOURCE_DIR" ]; then
                echo "Tag '${_branch}' found in SVN. Checking out to ${SOURCE_DIR} …"
                mkdir -p "${SVN_ROOT}/tags"
                svn checkout "${_repo}/tags/${_branch}" "${SOURCE_DIR}" || exit 1
            fi

        elif svn ls "${_repo}/branches/${_branch}" >/dev/null 2>&1; then
            SOURCE_DIR="${SVN_ROOT}/${_branch}"
            if [ ! -d "$SOURCE_DIR" ]; then
                echo "Branch '${_branch}' found in SVN. Checking out to ${SOURCE_DIR} …"
                svn checkout "${_repo}/branches/${_branch}" "${SOURCE_DIR}" || exit 1
            fi

        else
            echo "Error: '${_branch}' not found as a local directory, SVN tag, or SVN branch."
            exit 1
        fi
    fi
}
