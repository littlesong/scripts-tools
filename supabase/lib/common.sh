#!/bin/bash
# Shared plumbing for backup-supabase.sh and restore-supabase.sh. Sourced, not
# run. All of it exists to make the CLI act on exactly the project named by
# --ref, as the account behind the token you gave it:
#
#   * The token comes from --token-file or SUPABASE_ACCESS_TOKEN, nowhere else.
#     Nothing here runs `supabase login` or lets the CLI fall back to its stored
#     login, which on a machine with several Supabase accounts may belong to the
#     wrong one (and `supabase login` would overwrite it).
#   * Before anything else, the token's account must be able to see --ref.
#   * The CLI only ever sees a private link in a fresh temp directory. No
#     project checkout's supabase/.temp/project-ref is read or written, so a
#     deploy or another backup running at the same time cannot repoint us.
#
# Callers set REF, NAME, ENV, TOKEN_FILE and BACKUP_ROOT_OPT from their
# arguments first.

BACKUPS_DIR=""
LINK_DIR=""
PROJECT_NAME=""
TOKEN_SOURCE=""

die() { echo "$*" >&2; exit 1; }

# Print the calling script's header comment as its help text.
usage() {
    awk 'NR == 1 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
    exit "${1:-0}"
}

need_value() {  # <flag> [<value>]
    if [ $# -lt 2 ] || [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
        die "$1 needs a value."
    fi
}

# --ref, --name and <env> end up in paths and in CLI arguments; hold them to a
# shape that is harmless in both.
LABEL_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
REF_RE='^[a-z]{20}$'

check_label() {  # <what> <value>
    [ -n "$2" ] || die "Missing $1."
    [[ "$2" =~ $LABEL_RE ]] || die "$1 may only use letters, digits, '.', '_' and '-' (got '$2')."
}

check_target_args() {
    [ -n "$REF" ] || die "Missing --ref <project-ref>."
    [[ "$REF" =~ $REF_RE ]] || die "--ref must be a project ref (20 lowercase letters), not '$REF'."
    check_label --name "$NAME"
    check_label "<env>" "$ENV"
}

# Snapshots go to <root>/db-backups/<project>/<env>/<UTC timestamp>/, where
# <root> is --backup-root, else $SUPABASE_BACKUP_ROOT, else ~/supabase-backups.
# Deliberately not $BACKUP_ROOT: that name is generic enough that one project
# exporting it would send every other project's snapshots into its folder.
# Made absolute now, before anything cds into the temp link directory.
resolve_backups_dir() {
    local root="${BACKUP_ROOT_OPT:-${SUPABASE_BACKUP_ROOT:-$HOME/supabase-backups}}"
    case "$root" in
        /*) ;;
        *) root="$PWD/$root" ;;
    esac
    BACKUPS_DIR="$root/db-backups"
}

# libpq is keg-only, so pg_dump and psql are not on PATH by default.
use_libpq() {
    local d
    for d in /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin; do
        [ -x "$d/psql" ] && PATH="$d:$PATH"
    done
    export PATH
}

require_tools() {
    local tool
    for tool in "$@"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Missing required tool: $tool" >&2
            case "$tool" in
                pg_dump|psql) echo "  Install with: brew install libpq" >&2 ;;
            esac
            exit 1
        fi
    done
}

# ------------------------------------------------------------------ token --

# Accepts a dotenv-style line (SUPABASE_ACCESS_TOKEN=sbp_..., optionally with
# `export` and quotes) or a file holding nothing but the token. Parsed, never
# sourced: sourcing would run whatever else the file contains.
read_token_file() {  # <file>
    local token
    token=$(grep -E '^[[:space:]]*(export[[:space:]]+)?SUPABASE_ACCESS_TOKEN[[:space:]]*=' "$1" \
        | tail -n 1 | sed -E 's/^[^=]*=//; s/[[:space:]]+#.*$//' | tr -d "\"' \t\r" || true)
    if [ -z "$token" ] && [ "$(grep -cvE '^[[:space:]]*(#|$)' "$1" || true)" = 1 ]; then
        token=$(grep -vE '^[[:space:]]*(#|$)' "$1" | tr -d " \t\r")
        case "$token" in *=*) token="" ;; esac
    fi
    printf '%s' "$token"
}

load_token() {
    if [ -n "$TOKEN_FILE" ]; then
        [ -f "$TOKEN_FILE" ] || die "Token file not found: $TOKEN_FILE"
        case "$(ls -lnL "$TOKEN_FILE" | cut -c5-10)" in
            ------) ;;
            *) echo "warning: $TOKEN_FILE is readable by other users — chmod 600 it." >&2 ;;
        esac
        SUPABASE_ACCESS_TOKEN=$(read_token_file "$TOKEN_FILE")
        [ -n "$SUPABASE_ACCESS_TOKEN" ] ||
            die "No SUPABASE_ACCESS_TOKEN=... line (or bare token) in $TOKEN_FILE."
        TOKEN_SOURCE="--token-file $TOKEN_FILE"
    elif [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        TOKEN_SOURCE="SUPABASE_ACCESS_TOKEN"
    else
        cat >&2 <<EOF
No access token. Give one with --token-file <file> or SUPABASE_ACCESS_TOKEN.

This script never uses the CLI's stored login ('supabase login'): with more than
one Supabase account on a machine it can silently be the wrong one. Create a
personal access token while signed in to the account that owns $REF:

  https://supabase.com/dashboard/account/tokens

and keep it in a file only you can read, e.g.

  echo 'SUPABASE_ACCESS_TOKEN=sbp_...' > .env.local && chmod 600 .env.local
EOF
        exit 1
    fi
    export SUPABASE_ACCESS_TOKEN
}

# --------------------------------------------------------- project access --

init_link_dir() {
    LINK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/supabase-link.XXXXXX")
    # Run from inside it too, so even a CLI call that missed --workdir finds
    # this link and not some checkout's.
    cd "$LINK_DIR"
}

remove_link_dir() {
    if [ -n "$LINK_DIR" ]; then rm -rf "$LINK_DIR"; fi
}

# Does the token's account see the project? Parse the JSON rather than grep it,
# and surface the CLI's own error: a failed call must not read as "wrong
# account". Sets PROJECT_NAME to the project's name in Supabase.
check_project_access() {
    local rows row status
    if ! supabase projects list -o json </dev/null >"$LINK_DIR/projects.json" 2>"$LINK_DIR/projects.err"; then
        echo "\`supabase projects list\` failed (token from $TOKEN_SOURCE):" >&2
        sed 's/^/  /' "$LINK_DIR/projects.err" >&2
        exit 1
    fi
    # The CLI may print banner lines before the payload.
    if ! rows=$(sed -n '/^[[{]/,$p' "$LINK_DIR/projects.json" | jq -r '
            (if type == "array" then . else (.projects // .rows // []) end)[]
            | [(.ref // .id), (.name // ""), (.status // "")] | @tsv'); then
        die "Could not parse \`supabase projects list\` output."
    fi
    row=$(printf '%s\n' "$rows" | awk -F'\t' -v ref="$REF" '$1 == ref')
    if [ -z "$row" ]; then
        echo "The account behind $TOKEN_SOURCE cannot see project $REF." >&2
        echo "Projects it can see:" >&2
        printf '%s\n' "$rows" | awk -F'\t' 'NF { printf "  %s  %s\n", $1, $2 }' >&2
        echo "Check that the token was created on the account that owns $REF." >&2
        exit 1
    fi
    PROJECT_NAME=$(printf '%s\n' "$row" | cut -f2)
    status=$(printf '%s\n' "$row" | cut -f3)
    case "$status" in
        ACTIVE_*) ;;
        *) die "Project $REF ($PROJECT_NAME) is $status, not active — resume it in the dashboard first." ;;
    esac
}

# A <project>/<env> directory belongs to one project ref. If its latest snapshot
# came from a different ref, --ref is likely a typo or a prod ref under a test
# label; refuse rather than mix the two.
check_ref_binding() {  # <env>
    local manifest="$BACKUPS_DIR/$NAME/$1/latest/MANIFEST.txt" bound
    [ -f "$manifest" ] || return 0
    bound=$(sed -n 's/^project ref: *//p' "$manifest")
    if [ -n "$bound" ] && [ "$bound" != "$REF" ]; then
        die "Snapshots in $BACKUPS_DIR/$NAME/$1 are of project $bound, but --ref is $REF.
Check --ref, --name and <env>. If $NAME/$1 really moved to a new project,
move that directory aside first."
    fi
}

# The empty -p keeps link non-interactive. Nothing here needs the database
# password: dumps and psql use the short-lived login role from --dry-run.
link_project() {
    if ! supabase link --workdir "$LINK_DIR" --project-ref "$REF" -p "" --yes \
            </dev/null >"$LINK_DIR/link.log" 2>&1; then
        echo "supabase link --project-ref $REF failed:" >&2
        sed 's/^/  /' "$LINK_DIR/link.log" >&2
        exit 1
    fi
    if [ "$(cat "$LINK_DIR/supabase/.temp/project-ref" 2>/dev/null)" != "$REF" ]; then
        die "Linking $REF in $LINK_DIR did not take — aborting."
    fi
}

# Run a SQL file against the linked project and print the rows as a JSON array.
# --output json gives either a plain array or, when the CLI thinks it is talking
# to an agent, a { "rows": [...] } wrapper; normalise both.
query_json() {  # <sql-file>
    if ! supabase db query --linked --output json --workdir "$LINK_DIR" --file "$1" \
            </dev/null >"$LINK_DIR/query.out" 2>"$LINK_DIR/query.err"; then
        echo "Query failed ($(basename "$1")):" >&2
        sed 's/^/  /' "$LINK_DIR/query.err" >&2
        exit 1
    fi
    jq 'if type == "array" then . else .rows end' "$LINK_DIR/query.out"
}
