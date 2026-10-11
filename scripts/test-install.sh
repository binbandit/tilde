#!/bin/bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "$0")/.." && pwd)
just=${JUST:-just}
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch/project/scripts" "$scratch/bin"
cp "$repo/justfile" "$scratch/project/justfile"
cp "$repo/scripts/install-app.sh" "$scratch/project/scripts/install-app.sh"
cp "$repo/scripts/tilde-lifecycle.js" "$scratch/project/scripts/tilde-lifecycle.js"
export TILDE_INSTALL_TEST_EVENTS="$scratch/events"
export TILDE_INSTALL_TEST_PROCESS="$scratch/process"
printf 'not-running' > "$TILDE_INSTALL_TEST_PROCESS"
: > "$TILDE_INSTALL_TEST_EVENTS"

source="$scratch/built \$artifact 'quoted'/tilde.app"
mkdir -p "$source/Contents/MacOS" "$source/Contents/Resources"
printf '#!/bin/sh\nexit 0\n' > "$source/Contents/MacOS/tilde"
chmod 755 "$source/Contents/MacOS/tilde"
printf 'new resource\n' > "$source/Contents/Resources/current.txt"
ln -s current.txt "$source/Contents/Resources/linked"

cat > "$scratch/bin/ditto" <<'SH'
#!/bin/bash
printf 'stage\n' >> "$TILDE_INSTALL_TEST_EVENTS"
if [[ ${TILDE_INSTALL_TEST_FAIL:-} == staging ]]; then
    mkdir -p -- "$2/Contents"
    printf 'partial copy\n' > "$2/Contents/partial.txt"
    printf 'ditto: source fixture: Permission denied\n' >&2
    exit 23
fi
exec /usr/bin/ditto "$@"
SH
cat > "$scratch/bin/mv" <<'SH'
#!/bin/bash
if [[ $2 == */.tilde-install.*/tilde.app ]]; then
    printf 'replace\n' >> "$TILDE_INSTALL_TEST_EVENTS"
elif [[ $2 == */.tilde-install.*/previous.app ]]; then
    printf 'restore\n' >> "$TILDE_INSTALL_TEST_EVENTS"
else
    printf 'backup\n' >> "$TILDE_INSTALL_TEST_EVENTS"
fi
if [[ ${TILDE_INSTALL_TEST_FAIL:-} == move && $2 == */.tilde-install.*/tilde.app ]]; then
    exit 23
fi
exec /bin/mv "$@"
SH
cat > "$scratch/bin/osascript" <<'SH'
#!/bin/bash
[[ $1 == -l && $2 == JavaScript && $3 == */tilde-lifecycle.js && $# == 5 ]] || exit 99
mode=$4
state=$5
if [[ $mode == stop ]]; then
    if [[ $(cat "$TILDE_INSTALL_TEST_PROCESS") == running ]]; then
        printf '["running"]' > "$state"
        printf 'stop-running\n' >> "$TILDE_INSTALL_TEST_EVENTS"
        [[ ${TILDE_INSTALL_TEST_FAIL:-} != shutdown ]] || exit 23
        printf 'stopped' > "$TILDE_INSTALL_TEST_PROCESS"
    else
        printf 'stop-none\n' >> "$TILDE_INSTALL_TEST_EVENTS"
    fi
elif [[ $mode == recover ]]; then
    if [[ $(cat "$state") != '[]' && $(cat "$TILDE_INSTALL_TEST_PROCESS") != running ]]; then
        printf 'recover-running\n' >> "$TILDE_INSTALL_TEST_EVENTS"
        printf 'running' > "$TILDE_INSTALL_TEST_PROCESS"
    fi
else
    exit 99
fi
SH
cat > "$scratch/bin/open" <<'SH'
#!/bin/bash
[[ $# == 2 && $1 == -n && -x $2/Contents/MacOS/tilde ]] || exit 99
printf 'launch|%s\n' "$2" >> "$TILDE_INSTALL_TEST_EVENTS"
[[ ${TILDE_INSTALL_TEST_FAIL:-} != launch ]] || exit 23
printf 'running' > "$TILDE_INSTALL_TEST_PROCESS"
SH
cat > "$scratch/bin/xcodegen" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$scratch/bin/xcodebuild" <<'SH'
#!/bin/sh
exit 23
SH
cat > "$scratch/bin/mktemp" <<'SH'
#!/bin/bash
if [[ ${TILDE_INSTALL_TEST_FAIL:-} == permission && ${*: -1} == "$TILDE_INSTALL_TEST_SYSTEM_DIR/"* ]]; then
    printf 'mktemp: %s: Permission denied\n' "${*: -1}" >&2
    exit 1
fi
if [[ ${TILDE_INSTALL_TEST_FAIL:-} == unrelated && ${*: -1} == "$TILDE_INSTALL_TEST_SYSTEM_DIR/"* ]]; then
    printf 'mktemp: %s: No space left on device\n' "${*: -1}" >&2
    exit 1
fi
exec /usr/bin/mktemp "$@"
SH
chmod 755 "$scratch/bin/"*
export PATH="$scratch/bin:$PATH"

install_fixture() {
    "$just" --justfile "$scratch/project/justfile" --no-deps "app=$source" install "$1"
}

assert_no_stage() {
    shopt -s nullglob
    local stages=("$1"/.tilde-install.*)
    [[ ${#stages[@]} == 0 ]]
}

assert_no_stop_or_launch() {
    if /usr/bin/grep -Eq '^(stop-|launch\|)' "$TILDE_INSTALL_TEST_EVENTS"; then
        printf 'App lifecycle must not run before staging succeeds\n' >&2
        exit 1
    fi
}

/usr/bin/osascript -l JavaScript "$repo/scripts/test-tilde-lifecycle.js" "$repo/scripts/tilde-lifecycle.js"

destination="$scratch/Applications \$TILDE_INSTALL_TEST_LITERAL \"double\" 'single' \$(touch SHOULD_NOT_RUN)"
export TILDE_INSTALL_TEST_LITERAL=EXPANDED
install_fixture "$destination"
[[ -x "$destination/tilde.app/Contents/MacOS/tilde" ]]
[[ -L "$destination/tilde.app/Contents/Resources/linked" ]]
[[ $(cat "$destination/tilde.app/Contents/Resources/linked") == 'new resource' ]]
[[ ! -e "$scratch/project/SHOULD_NOT_RUN" ]]
assert_no_stage "$destination"
[[ $(cat "$TILDE_INSTALL_TEST_EVENTS") == "stage
stop-none
replace
launch|$destination/tilde.app" ]]
printf 'PASS: literal source and destination, executable permissions, symlinks\n'

ln -s "$source" "$scratch/project/-built.app"
output=$(cd "$scratch/project" && bash "$repo/scripts/install-app.sh" '-built.app' '-literal')
[[ -f "$scratch/project/-literal/tilde.app/Contents/Resources/current.txt" ]]
[[ "$output" == "Installed and launched tilde at $scratch/project/-literal/tilde.app" ]]
assert_no_stage "$scratch/project/-literal"
printf 'PASS: relative source and destination beginning with a hyphen\n'

printf 'obsolete\n' > "$destination/tilde.app/Contents/Resources/obsolete.txt"
: > "$TILDE_INSTALL_TEST_EVENTS"
install_fixture "$destination"
[[ ! -e "$destination/tilde.app/Contents/Resources/obsolete.txt" ]]
[[ ! -e "$destination/tilde.app/tilde.app" ]]
assert_no_stage "$destination"
[[ $(cat "$TILDE_INSTALL_TEST_EVENTS") == "stage
stop-running
backup
replace
launch|$destination/tilde.app" ]]
printf 'PASS: running app stops after staging, replaces completely and launches exact path\n'

printf 'keep old installation\n' > "$destination/tilde.app/Contents/Resources/current.txt"
for failure in staging shutdown move launch; do
    : > "$TILDE_INSTALL_TEST_EVENTS"
    if TILDE_INSTALL_TEST_FAIL=$failure install_fixture "$destination"; then
        printf 'Expected %s failure\n' "$failure" >&2
        exit 1
    fi
    [[ $(cat "$destination/tilde.app/Contents/Resources/current.txt") == 'keep old installation' ]]
    [[ ! -e "$destination/tilde.app/Contents/partial.txt" ]]
    assert_no_stage "$destination"
    [[ $(cat "$TILDE_INSTALL_TEST_PROCESS") == running ]]
    if [[ $failure == staging ]]; then assert_no_stop_or_launch; fi
    if [[ $failure == shutdown ]]; then
        ! /usr/bin/grep -Eq '^(backup|replace|launch\|)' "$TILDE_INSTALL_TEST_EVENTS"
    fi
    if [[ $failure == move ]]; then
        ! /usr/bin/grep -q '^launch|' "$TILDE_INSTALL_TEST_EVENTS"
        /usr/bin/grep -q '^recover-running$' "$TILDE_INSTALL_TEST_EVENTS"
    fi
    printf 'PASS: %s failure preserves/restarts previous app\n' "$failure"
done

: > "$TILDE_INSTALL_TEST_EVENTS"
if "$just" --justfile "$scratch/project/justfile" "app=$source" install "$destination"; then
    printf 'Expected build failure\n' >&2
    exit 1
fi
[[ $(cat "$destination/tilde.app/Contents/Resources/current.txt") == 'keep old installation' ]]
assert_no_stage "$destination"
assert_no_stop_or_launch
printf 'PASS: build failure prevents installation\n'

# Adapt only the default directory arguments at the helper boundary. The actual
# just recipe still passes /Applications and $HOME/Applications; all writes stay
# in scratch directories, without changing HOME or either live Applications path.
export TILDE_INSTALL_TEST_SYSTEM_DIR="$scratch/default system Applications"
export TILDE_INSTALL_TEST_USER_DIR="$scratch/default user Applications"
export TILDE_INSTALL_TEST_HELPER="$repo/scripts/install-app.sh"
export TILDE_INSTALL_TEST_MARKER="$scratch/default-dispatch"
cat > "$scratch/project/scripts/install-app.sh" <<'SH'
#!/bin/bash
if [[ $# != 3 || $2 != /Applications || $3 != "$HOME/Applications" ]]; then
    printf 'Unexpected default install arguments\n' >&2
    exit 99
fi
touch "$TILDE_INSTALL_TEST_MARKER"
exec bash "$TILDE_INSTALL_TEST_HELPER" "$1" "$TILDE_INSTALL_TEST_SYSTEM_DIR" "$TILDE_INSTALL_TEST_USER_DIR"
SH

install_default() {
    "$just" --justfile "$scratch/project/justfile" --no-deps "app=$source" install
}

: > "$TILDE_INSTALL_TEST_EVENTS"
output=$(TILDE_INSTALL_TEST_FAIL=permission install_default)
[[ -f "$TILDE_INSTALL_TEST_USER_DIR/tilde.app/Contents/Resources/current.txt" ]]
[[ "$output" == "Installed and launched tilde at $TILDE_INSTALL_TEST_USER_DIR/tilde.app" ]]
/usr/bin/grep -Fxq "launch|$TILDE_INSTALL_TEST_USER_DIR/tilde.app" "$TILDE_INSTALL_TEST_EVENTS"
[[ $(/usr/bin/grep -c '^stop-' "$TILDE_INSTALL_TEST_EVENTS") == 1 ]]
assert_no_stage "$TILDE_INSTALL_TEST_USER_DIR"
rm -rf -- "$TILDE_INSTALL_TEST_USER_DIR"
printf 'PASS: default permission failure falls back and reports final destination\n'

: > "$TILDE_INSTALL_TEST_EVENTS"
if TILDE_INSTALL_TEST_FAIL=unrelated install_default; then
    printf 'Expected unrelated destination failure\n' >&2
    exit 1
fi
[[ ! -e "$TILDE_INSTALL_TEST_USER_DIR" ]]
if TILDE_INSTALL_TEST_FAIL=staging install_default; then
    printf 'Expected source-copy failure\n' >&2
    exit 1
fi
[[ ! -e "$TILDE_INSTALL_TEST_USER_DIR" ]]
assert_no_stage "$TILDE_INSTALL_TEST_SYSTEM_DIR"
assert_no_stop_or_launch
printf 'PASS: unrelated and source-copy failures never trigger fallback\n'

rm -f -- "$TILDE_INSTALL_TEST_MARKER"
: > "$TILDE_INSTALL_TEST_EVENTS"
if "$just" --justfile "$scratch/project/justfile" "app=$source" install; then
    printf 'Expected default build failure\n' >&2
    exit 1
fi
[[ ! -e "$TILDE_INSTALL_TEST_MARKER" ]]
[[ ! -e "$TILDE_INSTALL_TEST_USER_DIR" ]]
assert_no_stop_or_launch
printf 'PASS: default build failure never invokes installer or fallback\n'

cp "$repo/scripts/install-app.sh" "$scratch/project/scripts/install-app.sh"
if TILDE_INSTALL_TEST_FAIL=permission install_fixture "$TILDE_INSTALL_TEST_SYSTEM_DIR"; then
    printf 'Expected explicit destination failure\n' >&2
    exit 1
fi
[[ ! -e "$TILDE_INSTALL_TEST_USER_DIR" ]]
printf 'PASS: explicit destination never falls back\n'
