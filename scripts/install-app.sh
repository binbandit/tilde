#!/bin/bash
# Usage: install-app.sh APP DESTINATION [PERMISSION_FALLBACK]
set -uo pipefail

app=$1
[[ "$app" == /* ]] || app="$PWD/$app"
destination=$2
fallback=${3:-}
diagnostics=$(mktemp) || exit 1
stage=
permission_denied=false

cleanup_stage() {
    if [[ -n "$stage" ]]; then
        # Never remove a previous app retained after a failed restore.
        rm -rf -- "$stage/tilde.app"
        rmdir -- "$stage" 2>/dev/null || true
    fi
}
trap 'cleanup_stage; rm -f -- "$diagnostics"' EXIT

destination_error() {
    local message
    message=$(< "$diagnostics")
    printf '%s\n' "$message" >&2
    case "$message" in
        *'Permission denied'*|*'Operation not permitted'*|*'Read-only file system'*)
            permission_denied=true
            ;;
    esac
}

install_to() {
    local directory=$1 target previous
    [[ "$directory" == /* ]] || directory="$PWD/$directory"
    if ! LC_ALL=C mkdir -p -- "$directory" 2>"$diagnostics"; then
        destination_error
        return 1
    fi
    if ! stage=$(LC_ALL=C mktemp -d -- "$directory/.tilde-install.XXXXXX" 2>"$diagnostics"); then
        destination_error
        return 1
    fi
    # Copy errors may come from the source, so they never trigger fallback.
    ditto "$app" "$stage/tilde.app" || return 1
    target="$directory/tilde.app"
    previous="$stage/previous.app"
    if [[ -e "$target" || -L "$target" ]]; then
        if ! LC_ALL=C mv -- "$target" "$previous" 2>"$diagnostics"; then
            destination_error
            return 1
        fi
    fi
    if ! LC_ALL=C mv -- "$stage/tilde.app" "$target" 2>"$diagnostics"; then
        destination_error
        if [[ -e "$previous" || -L "$previous" ]]; then
            if ! mv -- "$previous" "$target"; then
                permission_denied=false
                printf 'Previous app retained at %s\n' "$previous" >&2
            fi
        fi
        return 1
    fi
    rm -rf -- "$previous" || return 1
    printf 'Installed tilde to %s\n' "$target"
}

if install_to "$destination"; then
    exit 0
fi
cleanup_stage
stage=
if [[ -n "$fallback" && "$permission_denied" == true ]]; then
    printf 'Cannot write to %s; trying %s\n' "$destination" "$fallback" >&2
    permission_denied=false
    install_to "$fallback" && exit 0
fi
exit 1
