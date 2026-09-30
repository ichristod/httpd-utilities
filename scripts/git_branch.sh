#!/bin/sh
# Git helpers for the prepare_*.sh scripts. Source, don't run directly.
# Parallel to svn_branch.sh: provides the same interface for git repos.
#
# Layout:
#   GIT_ROOT/.clone/                       — shared clone (internal)
#   GIT_ROOT/<ref>/                        — one git worktree per branch/tag
#   GIT_ROOT/<ref>-pinned/                 — scratch worktree for --test-ref
#   GIT_ROOT/<ref>-install-pinned/         — scratch worktree for --source-ref
#   BASE_BUILD_DIR/<ref>/                  — installed build (same as SVN mode)

GIT_ROOT="${GIT_ROOT:-${HOME}/opensource/httpd_git}"
GIT_REMOTE="${GIT_REMOTE:-https://github.com/apache/httpd.git}"

. "$(dirname "$0")/common.sh"

VCS_TYPE="git"
VCS_SOURCE_ROOT="$GIT_ROOT"

_GIT_CLONE="${GIT_ROOT}/.clone"
_CLONE_READY=0

_ensure_clone() {
    [ "$_CLONE_READY" = "1" ] && return 0
    if [ ! -d "${_GIT_CLONE}/.git" ]; then
        echo "Cloning httpd git repo into ${_GIT_CLONE} ..."
        mkdir -p "$GIT_ROOT"
        git clone "$GIT_REMOTE" "$_GIT_CLONE" || exit 1
    fi
    echo "Fetching latest refs..."
    git -C "$_GIT_CLONE" fetch --all --tags --prune || exit 1
    git -C "$_GIT_CLONE" worktree prune 2>/dev/null
    _CLONE_READY=1
}

_is_git_tag() {
    git -C "$_GIT_CLONE" tag -l "$1" | grep -qx "$1"
}

_is_git_branch() {
    git -C "$_GIT_CLONE" branch -r --list "origin/$1" | grep -q "origin/$1"
}

# Resolve a user-supplied ref to the checkout target.
# Branches → origin/<branch> (remote-tracking); tags/SHAs → as-is.
_resolve_ref() {
    if _is_git_branch "$1"; then
        echo "origin/${1}"
    else
        echo "$1"
    fi
}

# Sets SOURCE_DIR and IS_TAG. Creates a worktree if not already present.
resolve_source_dir() {
    _ref="$1"
    IS_TAG=0
    _ensure_clone

    if _is_git_tag "$_ref"; then
        IS_TAG=1
    elif ! _is_git_branch "$_ref"; then
        if ! git -C "$_GIT_CLONE" rev-parse --verify "$_ref" >/dev/null 2>&1; then
            echo "Error: '${_ref}' not found as a git tag, branch, or commit."
            exit 1
        fi
    fi

    SOURCE_DIR="${GIT_ROOT}/${_ref}"
    if [ ! -d "$SOURCE_DIR" ]; then
        _resolved="$(_resolve_ref "$_ref")"
        echo "Creating worktree for '${_ref}' at ${SOURCE_DIR} ..."
        git -C "$_GIT_CLONE" worktree add --detach "$SOURCE_DIR" "$_resolved" || exit 1
    fi
}

# --- VCS interface (called by prepare_pytest.sh) ---

vcs_update() {
    _dir="$1"
    _ref="$(basename "$_dir")"
    _ensure_clone
    if _is_git_branch "$_ref"; then
        git -C "$_dir" checkout --detach "origin/${_ref}" || exit 1
    fi
}

vcs_get_rev() {
    git -C "$1" rev-parse HEAD
}

vcs_rev_label() {
    echo "$(echo "$1" | cut -c1-10)"
}

# vcs_checkout_at_ref <source_dir> <ref> <target_dir>
vcs_checkout_at_ref() {
    _source_dir="$1"; _ref="$2"; _target="$3"
    _ensure_clone
    _resolved="$(_resolve_ref "$_ref")"
    if [ -d "$_target" ]; then
        echo "Switching $(basename "$_target") to ${_ref}..."
        git -C "$_target" checkout --detach "$_resolved" || exit 1
    else
        echo "Creating worktree for $(basename "$_target") at ${_ref}..."
        git -C "$_GIT_CLONE" worktree add --detach "$_target" "$_resolved" || exit 1
    fi
}
