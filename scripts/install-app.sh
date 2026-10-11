#!/bin/bash
# Usage: install-app.sh APP DESTINATION [PERMISSION_FALLBACK]
set -uo pipefail

app=$1
[[ "$app" == /* ]] || app="$PWD/$app"
destination=$2
fallback=${3:-}
diagnostics=$(mktemp) || exit 1
shutdown_state=$(mktemp) || { rm -f -- "$diagnostics"; exit 1; }
printf '[]' > "$shutdown_state"
lifecycle="$(dirname -- "${BASH_SOURCE[0]}")/tilde-lifecycle.js"
stage=
permission_denied=false
can_restart_previous=true

cleanup_stage() {
    if [[ -n "$stage" ]]; then
        # Never remove a previous app retained after a failed restore.
        rm -rf -- "$stage/tilde.app"
        rmdir -- "$stage" 2>/dev/null || true
    fi
}
trap 'cleanup_stage; rm -f -- "$diagnostics" "$shutdown_state"' EXIT

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
    # The build and staging copy must succeed before touching a running app.
    if ! osascript -l JavaScript "$lifecycle" stop "$shutdown_state"; then
        printf 'Could not stop tilde; installation was not replaced\n' >&2
        return 1
    fi
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
    if ! open -n "$target"; then
        printf 'Could not launch %s; attempting to restore the previous installation\n' "$target" >&2
        # A failed launch may still have started a process. Stop verified app
        # instances again before moving the new bundle out of the way.
        if ! osascript -l JavaScript "$lifecycle" stop-cleanup "$shutdown_state"; then
            can_restart_previous=false
            printf 'The new installation remains at %s\n' "$target" >&2
            if [[ -e "$previous" || -L "$previous" ]]; then printf 'Previous app retained at %s\n' "$previous" >&2; fi
            return 1
        fi
        if ! mv -- "$target" "$stage/tilde.app"; then
            can_restart_previous=false
            printf 'Could not remove the failed new installation at %s\n' "$target" >&2
            if [[ -e "$previous" || -L "$previous" ]]; then printf 'Previous app retained at %s\n' "$previous" >&2; fi
            return 1
        fi
        if [[ -e "$previous" || -L "$previous" ]]; then
            if ! mv -- "$previous" "$target"; then
                can_restart_previous=false
                printf 'Restore failed; previous app retained at %s\n' "$previous" >&2
            fi
        fi
        return 1
    fi
    rm -rf -- "$previous" || return 1
    printf 'Installed and launched tilde at %s\n' "$target"
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
if [[ "$can_restart_previous" == true ]]; then
    osascript -l JavaScript "$lifecycle" recover "$shutdown_state" || printf 'Could not restart every previous tilde instance\n' >&2
else
    printf 'Automatic restart skipped because rollback could not finish\n' >&2
fi
exit 1
