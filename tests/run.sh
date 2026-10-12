#!/usr/bin/env sh
# tests/run.sh - automated tests for mysql-host-aliases.
#
# Runs under POSIX sh, bash and zsh. No real mysql binary is required: a fake
# tool (endpoints_echoargs) is placed on PATH that just prints the argv it receives,
# one argument per line, so we can assert exactly how the host flag was
# rewritten end-to-end through the wrapper.
#
# Usage:
#     ./tests/run.sh
#     sh tests/run.sh
#     bash tests/run.sh
#     zsh tests/run.sh
#
# Exit code 0 = all passed, 1 = at least one failure.

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_DIR=$(cd "$TESTS_DIR/.." && pwd)
SCRIPT="$REPO_DIR/mysql-host-aliases.sh"

# ---------------------------------------------------------------------------
# Scratch area + fake tool on PATH.
# ---------------------------------------------------------------------------
WORK=$(mktemp -d "${TMPDIR:-/tmp}/endpoints-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT INT TERM

BIN="$WORK/bin"
mkdir -p "$BIN"

# Fake tool: prints each argument on its own line, prefixed, so a caller can
# capture the exact rewritten argv.
cat > "$BIN/endpoints_echoargs" <<'EOF'
#!/usr/bin/env sh
for a in "$@"; do printf 'ARG:%s\n' "$a"; done
EOF
chmod +x "$BIN/endpoints_echoargs"
PATH="$BIN:$PATH"
export PATH

# ---------------------------------------------------------------------------
# Fixtures: a config file with a varied set of alias targets.
# ---------------------------------------------------------------------------
CFG="$WORK/test.cnf"
cat > "$CFG" <<'EOF'
[client]
user = someone
host = should-not-be-read

[endpoints]
# a comment line
dev     = dev.cluster-abc.eu-central-1.rds.amazonaws.com
prod    = prod.cluster-abc.eu-central-1.rds.amazonaws.com   # inline comment stripped
db1     = 10.20.30.40
tunnel  = 127.0.0.1
quoted  = "quoted.example.com"
sq      = 'single.example.com'
; semicolon comment
spaced  =    spaced.example.com

[other]
dev     = wrong.example.com
EOF

CFG_CUSTOM="$WORK/custom.cnf"
cat > "$CFG_CUSTOM" <<'EOF'
[aurora]
prod = aurora-prod.example.com
EOF

# ---------------------------------------------------------------------------
# Source the script. The config variables (ENDPOINTS_FILE/ENDPOINTS_GROUP/WRAPPED_TOOLS) are
# plain assignments at the top of the script, so they are reset to their
# defaults on every source — they are NOT meant to be overridden beforehand.
#
# For the end-to-end wrapper tests we therefore define a wrapper for our fake
# tool AFTER sourcing, using the exact same mechanism the script uses
# (__endpoints_run). ENDPOINTS_FILE / ENDPOINTS_GROUP are read at call time, so we point them at
# the fixtures after sourcing and that is honoured.
# ---------------------------------------------------------------------------
# shellcheck disable=SC1090
. "$SCRIPT"

ENDPOINTS_FILE="$CFG"
ENDPOINTS_GROUP="endpoints"

# Build the fake tool's wrapper exactly like the script's loop does.
eval 'endpoints_echoargs() { __endpoints_run "endpoints_echoargs" "$@"; }'

# ---------------------------------------------------------------------------
# Tiny assertion harness.
# ---------------------------------------------------------------------------
PASS=0
FAIL=0

check() {
    # $1 = description, $2 = expected, $3 = actual
    if [ "$2" = "$3" ]; then
        PASS=$((PASS + 1))
        printf 'ok   - %s\n' "$1"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL - %s\n' "$1"
        printf '        expected: [%s]\n' "$2"
        printf '        actual:   [%s]\n' "$3"
    fi
}

# Run the fake tool through its wrapper and collapse argv to a space-joined,
# ARG-prefixed string for easy comparison.
run_tool() {
    endpoints_echoargs "$@" | tr '\n' ' ' | sed 's/ *$//'
}

# =============================================================================
# 1. Config parsing: __endpoints_lookup
# =============================================================================
check "lookup: known RDS alias"        "dev.cluster-abc.eu-central-1.rds.amazonaws.com" "$(__endpoints_lookup dev)"
check "lookup: plain IP alias"         "10.20.30.40"                                 "$(__endpoints_lookup db1)"
check "lookup: tunnel alias"           "127.0.0.1"                                   "$(__endpoints_lookup tunnel)"
check "lookup: inline comment stripped" "prod.cluster-abc.eu-central-1.rds.amazonaws.com" "$(__endpoints_lookup prod)"
check "lookup: double quotes stripped" "quoted.example.com"                          "$(__endpoints_lookup quoted)"
check "lookup: single quotes stripped" "single.example.com"                          "$(__endpoints_lookup sq)"
check "lookup: surrounding spaces trimmed" "spaced.example.com"                      "$(__endpoints_lookup spaced)"
check "lookup: unknown key -> empty"   ""                                            "$(__endpoints_lookup nope)"
check "lookup: ignores other group"    "dev.cluster-abc.eu-central-1.rds.amazonaws.com" "$(__endpoints_lookup dev)"

# =============================================================================
# 2. __endpoints_resolve: known -> target, unknown -> passthrough
# =============================================================================
check "resolve: known alias"           "10.20.30.40"       "$(__endpoints_resolve db1)"
check "resolve: unknown passthrough"   "example.org"       "$(__endpoints_resolve example.org)"
check "resolve: IP passthrough"        "10.0.0.5"          "$(__endpoints_resolve 10.0.0.5)"
check "resolve: localhost passthrough" "localhost"         "$(__endpoints_resolve localhost)"

# =============================================================================
# 3. End-to-end rewriting through the wrapper (all four host forms)
# =============================================================================
check "form: -h VAL"      "ARG:-h ARG:10.20.30.40"               "$(run_tool -h db1)"
check "form: --host VAL"  "ARG:--host ARG:10.20.30.40"           "$(run_tool --host db1)"
check "form: --host=VAL"  "ARG:--host=10.20.30.40"               "$(run_tool --host=db1)"
check "form: -hVAL"       "ARG:-h10.20.30.40"                    "$(run_tool -hdb1)"

check "form: -h unknown passthrough"   "ARG:-h ARG:1.2.3.4"      "$(run_tool -h 1.2.3.4)"
check "form: --host=unknown passthrough" "ARG:--host=1.2.3.4"    "$(run_tool --host=1.2.3.4)"

# other flags preserved and order maintained
check "other flags preserved" "ARG:-u ARG:admin ARG:-h ARG:10.20.30.40 ARG:mydb" \
    "$(run_tool -u admin -h db1 mydb)"

# multiple hosts resolved independently
check "multiple hosts resolved" "ARG:-h ARG:10.20.30.40 ARG:--host=127.0.0.1" \
    "$(run_tool -h db1 --host=tunnel)"

# no host at all -> untouched
check "no host arg untouched" "ARG:--version" "$(run_tool --version)"

# =============================================================================
# 4. Missing config file -> everything passes through, nothing breaks
# =============================================================================
_save_file="$ENDPOINTS_FILE"
ENDPOINTS_FILE="$WORK/does-not-exist.cnf"
check "missing file: lookup empty"      ""                       "$(__endpoints_lookup db1)"
check "missing file: resolve passthrough" "db1"                  "$(__endpoints_resolve db1)"
check "missing file: wrapper passthrough" "ARG:-h ARG:db1"       "$(run_tool -h db1)"
ENDPOINTS_FILE="$_save_file"

# =============================================================================
# 5. Custom group / custom file
# =============================================================================
_save_file="$ENDPOINTS_FILE"; _save_group="$ENDPOINTS_GROUP"
ENDPOINTS_FILE="$CFG_CUSTOM"; ENDPOINTS_GROUP="aurora"
check "custom group+file: lookup"        "aurora-prod.example.com" "$(__endpoints_lookup prod)"
check "custom group+file: wrapper"       "ARG:-h ARG:aurora-prod.example.com" "$(run_tool -h prod)"
ENDPOINTS_FILE="$_save_file"; ENDPOINTS_GROUP="$_save_group"

# =============================================================================
# 6. Completion key listing
# =============================================================================
keys=$(__endpoints_keys | tr '\n' ' ' | sed 's/ *$//')
check "keys: lists all aliases in group" "dev prod db1 tunnel quoted sq spaced" "$keys"

# =============================================================================
# 7. Portability: sourcing with the DEFAULT tool list (which includes
#    hyphenated names like pt-online-schema-change) must not abort, and valid
#    tools must still be wrapped. Run in a fresh shell of each kind.
#
#    The WRAPPED_TOOLS list must be word-split into SEPARATE wrappers. zsh
#    does not word-split unquoted $var, so a naive loop builds a single bogus
#    function named with the whole string. We assert that TWO distinct tools
#    (mysql and mysqldump) each become their own function — this only holds
#    when the list was split correctly.
# =============================================================================
for _sh in sh bash zsh; do
    command -v "$_sh" >/dev/null 2>&1 || continue

    # Count how many of the first tools are individually defined as functions.
    _probe='. "'"$SCRIPT"'" >/dev/null 2>&1;
        for t in mysql mysqldump mysqladmin; do
            case "$(command -v "$t" 2>/dev/null; type "$t" 2>/dev/null)" in
                *function*) echo "FN:$t" ;;
            esac
        done'
    _out=$("$_sh" -c "$_probe" 2>/dev/null | tr "\n" " " | sed "s/ *$//")

    if [ "$_out" = "FN:mysql FN:mysqldump FN:mysqladmin" ]; then
        PASS=$((PASS + 1))
        printf 'ok   - portability: %s wraps each tool as its own function\n' "$_sh"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL - portability under %s (tools not individually wrapped): [%s]\n' "$_sh" "$_out"
    fi
done

# =============================================================================
# 8. Install CLI (executed mode). The script must behave as a CLI when run
#    directly, and must NOT run the CLI when sourced. All install actions use a
#    sandboxed HOME so real rc files are never touched.
# =============================================================================

# --version prints just the version number.
_ver=$("$SCRIPT" --version 2>/dev/null)
case "$_ver" in
    [0-9]*.[0-9]*.[0-9]*)
        PASS=$((PASS + 1)); printf 'ok   - cli: --version prints a semver (%s)\n' "$_ver" ;;
    *)
        FAIL=$((FAIL + 1)); printf 'FAIL - cli: --version unexpected output [%s]\n' "$_ver" ;;
esac

# --help mentions both usage modes.
_help=$("$SCRIPT" --help 2>/dev/null)
case "$_help" in
    *--install*--check*|*--check*--install*)
        PASS=$((PASS + 1)); printf 'ok   - cli: --help documents --check and --install\n' ;;
    *)
        FAIL=$((FAIL + 1)); printf 'FAIL - cli: --help missing --check/--install\n' ;;
esac

# Unknown argument exits non-zero.
"$SCRIPT" --nonsense >/dev/null 2>&1
if [ $? -ne 0 ]; then
    PASS=$((PASS + 1)); printf 'ok   - cli: unknown argument exits non-zero\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: unknown argument should have failed\n'
fi

# No action exits non-zero (neither --check nor --install given).
"$SCRIPT" --dest /tmp/whatever >/dev/null 2>&1
if [ $? -ne 0 ]; then
    PASS=$((PASS + 1)); printf 'ok   - cli: no action exits non-zero\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: no action should have failed\n'
fi

# --check is a true dry run: it must NOT create the dest or edit rc files.
_sb=$(mktemp -d "${TMPDIR:-/tmp}/mha-cli.XXXXXX")
: > "$_sb/.bashrc"; : > "$_sb/.zshrc"
HOME="$_sb" "$SCRIPT" --check >/dev/null 2>&1
if [ ! -e "$_sb/.mysql-host-aliases.sh" ] && [ ! -s "$_sb/.bashrc" ] && [ ! -s "$_sb/.zshrc" ]; then
    PASS=$((PASS + 1)); printf 'ok   - cli: --check writes nothing (dry run)\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: --check modified the filesystem\n'
fi

# --install actually installs: dest created + source line added to both rc files.
HOME="$_sb" "$SCRIPT" --install >/dev/null 2>&1
if [ -f "$_sb/.mysql-host-aliases.sh" ] \
   && grep -q "mysql-host-aliases.sh" "$_sb/.bashrc" \
   && grep -q "mysql-host-aliases.sh" "$_sb/.zshrc"; then
    PASS=$((PASS + 1)); printf 'ok   - cli: --install copies script and wires rc files\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: --install did not complete as expected\n'
fi

# --install is idempotent: a second run must not add a duplicate source line.
HOME="$_sb" "$SCRIPT" --install >/dev/null 2>&1
_count=$(grep -c "mysql-host-aliases.sh" "$_sb/.zshrc")
if [ "$_count" -eq 1 ]; then
    PASS=$((PASS + 1)); printf 'ok   - cli: --install is idempotent (no duplicate rc line)\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: --install added %s source lines (expected 1)\n' "$_count"
fi

# --install --dest creates a missing parent directory.
HOME="$_sb" "$SCRIPT" --install --dest "$_sb/nested/dir/mha.sh" >/dev/null 2>&1
if [ -f "$_sb/nested/dir/mha.sh" ]; then
    PASS=$((PASS + 1)); printf 'ok   - cli: --install --dest creates missing parent dir\n'
else
    FAIL=$((FAIL + 1)); printf 'FAIL - cli: --install --dest did not create dest\n'
fi
rm -rf "$_sb"

# Sourcing must NOT trigger the CLI (no install output, no exit). We source and
# then confirm a wrapper exists and HOME was untouched.
_sb2=$(mktemp -d "${TMPDIR:-/tmp}/mha-src.XXXXXX")
: > "$_sb2/.zshrc"
_srcout=$(HOME="$_sb2" sh -c '. "'"$SCRIPT"'" 2>&1; echo "WRAPPED:$(command -v mysql >/dev/null 2>&1 && type mysql 2>/dev/null | grep -c function)"')
case "$_srcout" in
    *Dry\ run*|*Installing*|*would\ update*)
        FAIL=$((FAIL + 1)); printf 'FAIL - sourcing triggered install output: [%s]\n' "$_srcout" ;;
    *WRAPPED:1*)
        if [ ! -e "$_sb2/.mysql-host-aliases.sh" ] && [ ! -s "$_sb2/.zshrc" ]; then
            PASS=$((PASS + 1)); printf 'ok   - sourcing defines wrappers and does NOT run the CLI\n'
        else
            FAIL=$((FAIL + 1)); printf 'FAIL - sourcing modified the filesystem\n'
        fi ;;
    *)
        FAIL=$((FAIL + 1)); printf 'FAIL - sourcing did not wrap mysql: [%s]\n' "$_srcout" ;;
esac
rm -rf "$_sb2"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "-------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"

[ "$FAIL" -eq 0 ]
