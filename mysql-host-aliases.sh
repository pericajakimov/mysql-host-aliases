#!/usr/bin/env sh
# mysql-host-aliases.sh - short host-alias resolution for MySQL-style -h/--host.
#
# https://github.com/pericajakimov/mysql-host-aliases
#
# Maps short host aliases (defined in an INI group of a mysql config file) to
# real endpoints, transparently, for the mysql client & compatible tools.
#
# The real endpoint can be ANYTHING a tool would accept after -h/--host:
#   * a long Aurora/RDS cluster endpoint
#   * a plain hostname (internal DNS name, docker service, etc.)
#   * an IPv4/IPv6 address
#   * an SSH-tunnel / port-forward target (e.g. 127.0.0.1)
# Alias -> endpoint is a plain string substitution, so any host form works.
#
# Example: type `mysql -h prod` instead of
#          `mysql -h prod.cluster-abc123.eu-central-1.rds.amazonaws.com`,
#          or `mysql -h db1` instead of `mysql -h 10.20.30.40`.
#
# Works in BOTH bash and zsh. SOURCE this file (do not execute it):
#     source ~/.mysql-host-aliases.sh
#
# Config file format (an INI group inside a mysql config file):
#     [endpoints]
#     dev  = dev.cluster.xxxx.rds.amazonaws.com
#     db1  = 10.20.30.40
#     tun  = 127.0.0.1
#
# Behavior:
#   * Detects host in all forms: -h VAL, -hVAL, --host VAL, --host=VAL
#   * If VAL is a known alias -> substituted with the real endpoint.
#   * If VAL is not an alias  -> passed through unchanged.
#   * Alias always wins over a real host of the same name.
#   * If the config file is missing, nothing breaks: wrappers just pass through.
#
# This file is dual-mode:
#   * SOURCE it for normal use (defines the wrappers + completion).
#   * EXECUTE it to manage the install:
#         ./mysql-host-aliases.sh --help
#         ./mysql-host-aliases.sh --version
#         ./mysql-host-aliases.sh --check            # dry run
#         ./mysql-host-aliases.sh --check --dest P   # dry run to a custom path
#         ./mysql-host-aliases.sh --install          # install to ~/.mysql-host-aliases.sh
#         ./mysql-host-aliases.sh --install --dest P # install to a custom path

# Version of this script (single source of truth, printed by --version).
SCRIPT_VERSION="v1.0.0"

# ===========================================================================
# CONFIGURATION  --  edit these three values to customize.
# ===========================================================================

# Config file to read the aliases from.
ENDPOINTS_FILE="$HOME/.my.cnf"

# INI group inside that file that holds the alias = endpoint mapping.
ENDPOINTS_GROUP="endpoints"

# Whitespace-separated list of tools to wrap. Add any tool that uses the
# standard -h/--host form for its host. Remove tools you do not use.
# Newlines count as separators, so you can lay this out over several lines.
# NOTE: a '#' inside the quotes is NOT a comment — it would be read as a tool
# name — so keep any notes on these comment lines above the value.
WRAPPED_TOOLS="
    mysql mysqldump mysqladmin mysqlimport
    mysqlcheck mysqlshow mysqlsh mysqlpump
    pt-online-schema-change pt-table-checksum
    pt-table-sync pt-query-digest pt-archiver
    mysqlmig
"
#   mysqlmig - custom MySQL schema/data migration helper (takes -h/--host).
#              https://github.com/pericajakimov/mysqlmig


# ===========================================================================
# INTERNALS -- you normally do not need to edit below this line.
# ===========================================================================

# Resolve awk to an absolute path ONCE, at source time. When the wrappers run
# later, PATH or shell state may differ (and a bare `awk` sometimes failed to
# resolve in practice), so we pin the full path here. Fall back to the common
# system location if command -v can't find it.
ENDPOINTS_AWK=$(command -v awk 2>/dev/null)
[ -n "$ENDPOINTS_AWK" ] || ENDPOINTS_AWK="/usr/bin/awk"

# ---------------------------------------------------------------------------
# Parse one alias value out of the config file.
#   $1 = alias key to look up
# Prints the real endpoint on stdout, or nothing if not found / file missing.
# ---------------------------------------------------------------------------
__endpoints_lookup() {
    [ -f "$ENDPOINTS_FILE" ] || return 1
    "$ENDPOINTS_AWK" -v grp="$ENDPOINTS_GROUP" -v key="$1" '
        function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
        # strip surrounding quotes if present
        function unquote(s){
            if (s ~ /^".*"$/ || s ~ /^'"'"'.*'"'"'$/) s=substr(s,2,length(s)-2)
            return s
        }
        /^[ \t]*[#;]/ { next }                       # comment line
        /^[ \t]*\[/ {                                # group header
            g=$0; sub(/^[ \t]*\[/,"",g); sub(/\].*$/,"",g); g=trim(g)
            insect=(g==grp); next
        }
        insect {
            line=$0
            eq=index(line,"=")
            if (eq==0) next
            k=trim(substr(line,1,eq-1))
            v=substr(line,eq+1)
            # drop inline comment (unquoted # or ;) — simple heuristic
            sub(/[ \t]+[#;].*$/,"",v)
            v=trim(unquote(trim(v)))
            if (k==key) { print v; exit }
        }
    ' "$ENDPOINTS_FILE"
}

# ---------------------------------------------------------------------------
# List all alias keys (for completion). Prints one per line.
# ---------------------------------------------------------------------------
__endpoints_keys() {
    [ -f "$ENDPOINTS_FILE" ] || return 0
    "$ENDPOINTS_AWK" -v grp="$ENDPOINTS_GROUP" '
        function trim(s){ sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); return s }
        /^[ \t]*[#;]/ { next }
        /^[ \t]*\[/ { g=$0; sub(/^[ \t]*\[/,"",g); sub(/\].*$/,"",g); if(trim(g)==grp) insect=1; else insect=0; next }
        insect { eq=index($0,"="); if(eq){ print trim(substr($0,1,eq-1)) } }
    ' "$ENDPOINTS_FILE"
}

# ---------------------------------------------------------------------------
# Resolve a host value: echo alias target if known, else echo the value as-is.
# ---------------------------------------------------------------------------
__endpoints_resolve() {
    _val="$1"
    _real=$(__endpoints_lookup "$_val")
    if [ -n "$_real" ]; then
        printf '%s\n' "$_real"
    else
        printf '%s\n' "$_val"
    fi
}

# ---------------------------------------------------------------------------
# Generic runner: rewrite host args, then exec the real tool.
#   $1 = tool name, remaining = its args
# ---------------------------------------------------------------------------
__endpoints_run() {
    _tool="$1"; shift

    # Find the real binary (skip our own function/alias) via PATH.
    _bin=$(command -v "$_tool" 2>/dev/null)
    if [ -z "$_bin" ]; then
        printf 'mysql-host-aliases: %s: command not found\n' "$_tool" >&2
        return 127
    fi

    # Rebuild the argument list, rewriting the host where present.
    # POSIX-clean technique: iterate the ORIGINAL $# args exactly once by
    # counting them, re-appending each (possibly rewritten) arg to the end,
    # and shifting the original off the front. After the loop only the
    # rewritten args remain. Works in bash, zsh and POSIX sh (no arrays).
    _n=$#
    while [ "$_n" -gt 0 ]; do
        _n=$((_n - 1))
        case "$1" in
            -h|--host)
                if [ "$#" -ge 2 ]; then
                    _hv=$(__endpoints_resolve "$2")
                    set -- "$@" "$1" "$_hv"
                    shift 2
                    _n=$((_n - 1))      # we consumed the value arg too
                    continue
                else
                    set -- "$@" "$1"; shift; continue
                fi
                ;;
            --host=*)
                _hv=${1#--host=}
                set -- "$@" "--host=$(__endpoints_resolve "$_hv")"; shift; continue
                ;;
            -h?*)
                _hv=${1#-h}
                set -- "$@" "-h$(__endpoints_resolve "$_hv")"; shift; continue
                ;;
            *)
                set -- "$@" "$1"; shift; continue
                ;;
        esac
    done

    command "$_bin" "$@"
}

# ---------------------------------------------------------------------------
# Create a wrapper function for each tool in the list.
# Adding a tool = add its name to WRAPPED_TOOLS and re-source.
# ---------------------------------------------------------------------------
# Build the wrapper functions. This is done inside a function because zsh does
# NOT word-split unquoted parameter expansions the way bash/sh do — a plain
# `for t in $WRAPPED_TOOLS` would iterate ONCE with the whole string under
# zsh. Inside a zsh *function* we can enable `sh_word_split` with `localoptions`
# so the change is scoped to the function and never leaks into the user's
# interactive shell. In bash/sh the option is a harmless no-op.
#
# Some shells (interactive bash, zsh) allow hyphenated function names, so the
# Percona tools like pt-online-schema-change can be wrapped. Plain POSIX sh,
# dash, and bash-in-POSIX-mode (i.e. invoked as `sh`) reject them, and there a
# bad name is a hard syntax error. We can't infer this from version variables
# alone (bash sets BASH_VERSION even when run as `sh`), so we probe it directly.
__endpoints_build_wrappers() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt localoptions sh_word_split 2>/dev/null
    fi
    _relaxed=0
    if ( eval 'endpoints--probe() { :; }' ) 2>/dev/null; then
        _relaxed=1
    fi
    for _t in $WRAPPED_TOOLS; do
        if [ "$_relaxed" -eq 0 ]; then
            # POSIX sh: only names made of [A-Za-z0-9_] can be functions.
            case "$_t" in
                *[!A-Za-z0-9_]*) continue ;;
            esac
        fi
        # shellcheck disable=SC2139,SC2140
        eval "${_t}() { __endpoints_run \"${_t}\" \"\$@\"; }"
    done
    unset _relaxed _t
}

# ---------------------------------------------------------------------------
# Register tab-completion: offer alias names after -h / --host / --host= /
# -h<partial>. Shell-specific; eval-guarded so only the active shell parses it.
# ---------------------------------------------------------------------------
__endpoints_register_completion() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '
        __endpoints_zsh_complete() {
            local -a keys
            keys=(${(f)"$(__endpoints_keys)"})
            local cur=${words[CURRENT]}
            local prev=${words[CURRENT-1]}
            if [[ $prev == "-h" || $prev == "--host" ]]; then
                compadd -- $keys
            elif [[ $cur == --host=* ]]; then
                compadd -P "--host=" -- $keys
            elif [[ $cur == -h?* ]]; then
                compadd -P "-h" -- $keys
            else
                _default
            fi
        }
        # compdef is only available once the completion system (compinit) has
        # been initialized. Most zsh setups (oh-my-zsh, etc.) do this. If it is
        # NOT yet initialized AND we are in an interactive shell, bootstrap it
        # ourselves so completion works out of the box. We stay out of the way
        # of setups that already manage it (we only act when compdef is
        # missing), and use `compinit -i` to avoid the insecure-directory
        # prompt. This runs in-process (it must — a background job cannot
        # register completions in the current shell).
        if ! whence compdef >/dev/null 2>&1; then
            if [[ -o interactive ]]; then
                autoload -Uz compinit && compinit -i 2>/dev/null
            fi
        fi
        if whence compdef >/dev/null 2>&1; then
            # ${=var} forces zsh to word-split the tool list (zsh does not split
            # unquoted $var by default, which would register one bogus
            # completion for the whole string).
            for _t in ${=WRAPPED_TOOLS}; do
                compdef __endpoints_zsh_complete "$_t"
            done
            unset _t
        fi
        '
    elif [ -n "${BASH_VERSION:-}" ]; then
        eval '
        __endpoints_bash_complete() {
            local cur prev keys
            cur="${COMP_WORDS[COMP_CWORD]}"
            prev="${COMP_WORDS[COMP_CWORD-1]}"
            keys="$(__endpoints_keys)"
            if [ "$prev" = "-h" ] || [ "$prev" = "--host" ]; then
                COMPREPLY=( $(compgen -W "$keys" -- "$cur") )
                return 0
            fi
            case "$cur" in
                --host=*)
                    COMPREPLY=( $(compgen -P "--host=" -W "$keys" -- "${cur#--host=}") )
                    return 0
                    ;;
                -h?*)
                    COMPREPLY=( $(compgen -P "-h" -W "$keys" -- "${cur#-h}") )
                    return 0
                    ;;
            esac
            COMPREPLY=( $(compgen -f -- "$cur") )
            return 0
        }
        for _t in $WRAPPED_TOOLS; do
            complete -F __endpoints_bash_complete "$_t"
        done
        unset _t
        '
    fi
}

# ===========================================================================
# Install CLI -- only used when this file is EXECUTED, not sourced.
# ===========================================================================

# Default install destination.
ENDPOINTS_INSTALL_DEST="$HOME/.mysql-host-aliases.sh"

# Print the WRAPPED_TOOLS list as a single wrapped, space-separated line.
# Uses the same word-split guard as the wrapper builder (zsh needs it).
__endpoints_tools_oneline() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        setopt localoptions sh_word_split 2>/dev/null
    fi
    _list=""
    for _t in $WRAPPED_TOOLS; do
        _list="$_list $_t"
    done
    unset _t
    # Trim the single leading space.
    printf '%s\n' "${_list# }"
}

__endpoints_cli_usage() {
    cat <<EOF
mysql-host-aliases $SCRIPT_VERSION
Short host-alias resolution for the -h/--host flag of the mysql client and
other MySQL-compatible command-line tools (mysqldump, mysqlsh, the Percona
toolkit, your own scripts, ...). Define a short alias once and use it with
every wrapped tool.

NORMAL USE
    Source this file from your shell rc so the tool wrappers and tab-completion
    are defined in your interactive shell:

        [ -f "\$HOME/.mysql-host-aliases.sh" ] && . "\$HOME/.mysql-host-aliases.sh"

    Then type short aliases instead of long hosts, with any wrapped tool:

        mysql -h prod            # resolves 'prod' from the [endpoints] group
        mysqldump --host=db1     # works with every wrapped tool, not just mysql

    Define the aliases in an INI group of a mysql config file. The alias target
    can be anything you'd type after -h: an RDS/Aurora endpoint, a hostname, an
    IP address, or an SSH-tunnel target.

        [endpoints]
        prod = prod.cluster-abc123.eu-central-1.rds.amazonaws.com
        db1  = 10.20.30.40

WRAPPED TOOLS
$(__endpoints_tools_oneline | fold -s -w 70 | sed 's/^/    /')

    This list, the config file, and the INI group are all set near the top of
    the script and are meant to be edited:
        WRAPPED_TOOLS     tools to wrap        (add your own here)
        ENDPOINTS_FILE    config file to read  (default: ~/.my.cnf)
        ENDPOINTS_GROUP   INI group to read    (default: [endpoints])
    Edit them in $ENDPOINTS_INSTALL_DEST (the installed copy) and start a new
    shell, or re-source the file.

INSTALL (executing this file)
    ./mysql-host-aliases.sh --check             Dry run: show what install would do.
    ./mysql-host-aliases.sh --check --dest P    Dry run for a custom path P.
    ./mysql-host-aliases.sh --install           Install to $ENDPOINTS_INSTALL_DEST
                                                and add a source line to your
                                                ~/.bashrc and ~/.zshrc.
    ./mysql-host-aliases.sh --install --dest P  Install to a custom path P.
    ./mysql-host-aliases.sh --help              Show this help.
    ./mysql-host-aliases.sh --version           Print the version.

    Installing never edits your .my.cnf and only touches the destination file
    and your rc files (and only if the source line isn't already present).
EOF
}

# Perform (or, in dry-run, describe) the install.
#   $1 = mode: "check" (dry run) or "install" (apply)
#   $2 = destination path
__endpoints_do_install() {
    _mode="$1"
    _dest="$2"

    # Resolve the path of the running script (the source to copy from).
    _self="$ENDPOINTS_SELF"
    _marker="# mysql-host-aliases"
    _srcline="[ -f \"$_dest\" ] && . \"$_dest\""

    if [ "$_mode" = "check" ]; then
        echo "Dry run — no changes will be made."
    else
        echo "Installing mysql-host-aliases $SCRIPT_VERSION ..."
    fi
    echo

    # 1. Copy the script to the destination (unless it's the same file),
    #    creating the parent directory if needed.
    _destdir=$(dirname "$_dest")
    if [ "$_self" = "$_dest" ]; then
        echo "source is the destination already; skipping copy: $_dest"
    elif [ "$_mode" = "check" ]; then
        [ -d "$_destdir" ] || echo "would create directory: $_destdir"
        echo "would install script: $_self -> $_dest"
    else
        [ -d "$_destdir" ] || mkdir -p "$_destdir" || {
            echo "error: failed to create directory $_destdir" >&2; return 1; }
        cp "$_self" "$_dest" || { echo "error: failed to copy to $_dest" >&2; return 1; }
        echo "installed script: $_dest"
    fi
    unset _destdir
    echo

    echo "Source line:"
    echo "    $_srcline"
    echo

    # 2. Wire up the rc files that exist.
    for _rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
        [ -f "$_rc" ] || continue
        if grep -qF "$_dest" "$_rc" 2>/dev/null; then
            echo "already configured: $_rc"
        elif [ "$_mode" = "check" ]; then
            echo "would update: $_rc"
        else
            {
                printf '\n%s\n' "$_marker"
                printf '%s\n' "$_srcline"
            } >> "$_rc"
            echo "updated: $_rc"
        fi
    done
    unset _rc

    echo
    if [ "$_mode" = "check" ]; then
        echo "Run with --install to apply."
    else
        echo "Done. Open a new shell or run: exec \$SHELL"
    fi
}

# Argument parser / dispatcher for executed mode.
__endpoints_cli() {
    _action=""
    _dest="$ENDPOINTS_INSTALL_DEST"

    while [ $# -gt 0 ]; do
        case "$1" in
            --help)    __endpoints_cli_usage; return 0 ;;
            --version) echo "$SCRIPT_VERSION"; return 0 ;;
            --check)   _action="check"; shift ;;
            --install) _action="install"; shift ;;
            --dest)
                [ $# -ge 2 ] || { echo "error: --dest needs a path" >&2; return 2; }
                _dest="$2"; shift 2 ;;
            --dest=*)  _dest="${1#--dest=}"; shift ;;
            *)
                echo "unknown argument: $1" >&2
                echo "try: --help" >&2
                return 2 ;;
        esac
    done

    # Expand a leading ~ in --dest to $HOME.
    case "$_dest" in
        "~")   _dest="$HOME" ;;
        "~/"*) _dest="$HOME/${_dest#~/}" ;;
    esac

    if [ -z "$_action" ]; then
        echo "nothing to do. Try one of: --check, --install, --help, --version" >&2
        return 2
    fi

    __endpoints_do_install "$_action" "$_dest"
}

# ===========================================================================
# Mode detection: SOURCED vs EXECUTED.
#   * Sourced  -> define the wrappers + completion (the normal path).
#   * Executed -> run the install CLI, then exit.
# ===========================================================================
__endpoints_is_sourced() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        # In zsh, a sourced file's eval context contains ":file:".
        case "$ZSH_EVAL_CONTEXT" in *:file:*) return 0 ;; *) return 1 ;; esac
    elif [ -n "${BASH_VERSION:-}" ]; then
        # In bash, when sourced, ${BASH_SOURCE[0]} != $0.
        [ "${BASH_SOURCE[0]}" != "$0" ]
    else
        # POSIX sh fallback: no reliable detector. Assume executed only when $0
        # points at this script file; otherwise assume sourced.
        case "$0" in
            */mysql-host-aliases.sh|mysql-host-aliases.sh|*/mysql-host-aliases) return 1 ;;
            *) return 0 ;;
        esac
    fi
}

if __endpoints_is_sourced; then
    # Normal use: activate wrappers and completion in the current shell.
    __endpoints_build_wrappers
    __endpoints_register_completion
else
    # Executed directly: record our own path, then run the install CLI.
    # $0 is the path to this script when executed.
    ENDPOINTS_SELF=$0
    case "$ENDPOINTS_SELF" in
        /*) : ;;                                   # already absolute
        *)  ENDPOINTS_SELF="$(cd "$(dirname "$ENDPOINTS_SELF")" && pwd)/$(basename "$ENDPOINTS_SELF")" ;;
    esac
    __endpoints_cli "$@"
    exit $?
fi
