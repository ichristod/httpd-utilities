#!/bin/sh
# SVN helpers for the prepare_*.sh scripts. Source, don't run directly.

SVN_ROOT="${SVN_ROOT:-${HOME}/opensource/httpd_svn}"

. "$(dirname "$0")/common.sh"

VCS_TYPE="svn"
VCS_SOURCE_ROOT="$SVN_ROOT"

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
        SOURCE_DIR="${SVN_ROOT}/${_branch}"

    elif [ -d "${SVN_ROOT}/tags/${_branch}" ]; then
        SOURCE_DIR="${SVN_ROOT}/tags/${_branch}"
        IS_TAG=1

    else
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

# --- VCS interface (called by prepare_pytest.sh) ---

vcs_update() {
    svn update "$1" || exit 1
}

vcs_get_rev() {
    svn info "$1" | awk '/^Revision:/{print $2}'
}

vcs_rev_label() {
    echo "r${1}"
}

# vcs_checkout_at_ref <canonical_source_dir> <ref> <target_dir>
vcs_checkout_at_ref() {
    _canonical="$1"; _ref="$2"; _target="$3"
    if [ -d "$_target" ]; then
        echo "Switching $(basename "$_target") to r${_ref}..."
        svn update -r "$_ref" "$_target" || exit 1
    else
        _url="$(svn info "$_canonical" | awk -F': ' '/^URL:/{print $2}')"
        echo "Checking out $(basename "$_target") at r${_ref}..."
        svn checkout -r "$_ref" "$_url" "$_target" || exit 1
    fi
}
