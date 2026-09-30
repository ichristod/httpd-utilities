#!/bin/sh
# Shared VCS-agnostic helpers for the prepare_*.sh scripts. Source, don't run directly.

BASE_BUILD_DIR="${BASE_BUILD_DIR:-${HOME}/httpd_builds}"

version_lte() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" = "$1" ]
}

pkg_version() {
    PKG_CONFIG_PATH="${PKG_CONFIG_PATH:+${PKG_CONFIG_PATH}:}/usr/local/lib/pkgconfig" \
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

    _httpd="${INSTALL_DIR:-${BASE_BUILD_DIR}/${BRANCH}}/bin/httpd"
    if [ -x "$_httpd" ]; then
        echo ""
        echo "Linked libraries:"
        ldd "$_httpd" 2>/dev/null | grep -v 'linux-vdso\|ld-linux' | sort
    fi
}
