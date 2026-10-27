#!/bin/bash
# Shared plumbing for backup-supabase.sh and restore-supabase.sh. Sourced, not
# run. All of it exists to make the CLI act on exactly the intended project, as
# the account behind the token you gave it:
#
#   * The target is either looked up in projects.ini (short form:
#     <project> <env>) or given with --ref/--name (long form). A long-form
#     --ref that disagrees with projects.ini is refused.
#   * The token comes from --token-file, else tokens.ini (short form) or
#     SUPABASE_ACCESS_TOKEN (long form), nowhere else. Nothing here runs
#     `supabase login` or lets the CLI fall back to its stored login, which on
#     a machine with several Supabase accounts may belong to the wrong one (and
#     `supabase login` would overwrite it).
#   * Before anything else, the token's account must be able to see the ref.
#   * The CLI only ever sees a private link in a fresh temp directory. No
#     project checkout's supabase/.temp/project-ref is read or written, so a
#     deploy or another backup running at the same time cannot repoint us.
#
# Callers parse their arguments into MODE (short|long), NAME, ENV, REF (long
# form only), TOKEN_FILE and BACKUP_ROOT_OPT, then call resolve_target.

TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECTS_INI="$TOOLS_DIR/projects.ini"
TOKENS_INI="$TOOLS_DIR/tokens.ini"

PROJECTS=""
BACKUP_DIR=""
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

# Project and environment names end up in paths and in CLI arguments; hold
# them to a shape that is harmless in both.
LABEL_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'
REF_RE='^[a-z]{20}$'

check_label() {  # <what> <value>
    [ -n "$2" ] || die "Missing $1."
    [[ "$2" =~ $LABEL_RE ]] || die "$1 may only use letters, digits, '.', '_' and '-' (got '$2')."
}

# ~ and ~/... expand to $HOME; anything else must already be absolute.
expand_path() {  # <path>
    case "$1" in
        "~")    printf '%s\n' "$HOME" ;;
        "~/"*)  printf '%s/%s\n' "$HOME" "${1#"~/"}" ;;
        /*)     printf '%s\n' "$1" ;;
        *)      return 1 ;;
    esac
}

# -------------------------------------------------------------- ini files --

# Parse an INI file into "section<TAB>key<TAB>value" lines. Strict: a line that
# is not blank, a comment, a [section] or a key = value is an error, and so are
# keys before any section and repeated sections or keys. A comment is a whole
# line starting with # or ;, or whitespace plus # or ; after a value. Errors
# name the line, never its contents: tokens.ini goes through here too.
ini_parse() {  # <file>
    awk -v file="$1" -v q="'" '
        function fail(msg) { printf "%s, line %d: %s\n", file, NR, msg > "/dev/stderr"; exit 1 }
        { sub(/\r$/, "") }
        /^[[:space:]]*([#;].*)?$/ { next }
        /^[[:space:]]*\[.*\][[:space:]]*$/ {
            s = $0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", s)
            sub(/[[:space:]]*\][[:space:]]*$/, "", s)
            if (s == "") fail("empty [section] name")
            if (s in seen) fail("[" s "] appears twice")
            seen[s] = 1; section = s
            next
        }
        /^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*=/ {
            if (section == "") fail("setting before any [section]")
            k = $0; sub(/^[[:space:]]*/, "", k); sub(/[[:space:]]*=.*$/, "", k)
            v = $0; sub(/^[^=]*=[[:space:]]*/, "", v)
            sub(/[[:space:]]+[#;].*$/, "", v); sub(/[[:space:]]+$/, "", v)
            if (length(v) >= 2 && (v ~ /^".*"$/ || v ~ ("^" q ".*" q "$")))
                v = substr(v, 2, length(v) - 2)
            if ((section, k) in have) fail(k " appears twice in [" section "]")
            have[section, k] = 1
            printf "%s\t%s\t%s\n", section, k, v
            next
        }
        { fail("not a comment, [section] or key = value") }
    ' "$1"
}

ini_value() {  # <parsed> <section> <key> — prints the value; fails if absent
    printf '%s\n' "$1" | awk -F'\t' -v s="$2" -v k="$3" '
        $1 == s && $2 == k { print $3; found = 1 }
        END { exit !found }'
}

# projects.ini, next to the scripts. Checked as a whole on every run, so a typo
# anywhere fails loudly instead of quietly falling back to a default.
load_projects_ini() {
    [ -f "$PROJECTS_INI" ] || return 0
    PROJECTS=$(ini_parse "$PROJECTS_INI") || exit 1
    printf '%s\n' "$PROJECTS" | awk -F'\t' -v file="$PROJECTS_INI" '
        function bad(msg) { printf "%s: %s\n", file, msg > "/dev/stderr"; failed = 1 }
        function label(v) { return v ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ }
        function ref(v) { return length(v) == 20 && v ~ /^[a-z]+$/ }
        function path(v) { return v ~ /^(\/|~\/|~$)/ }
        NF == 0 { next }
        $1 == "global" {
            if ($2 != "backup_root") bad("[global] has no setting \"" $2 "\" (only backup_root)")
            else if (!path($3)) bad("[global] backup_root must be absolute or start with ~/")
            next
        }
        !label($1) { bad("[" $1 "] is not a valid project name"); next }
        $2 == "account" {
            if (!label($3)) bad("[" $1 "] account = \"" $3 "\" is not a valid tokens.ini section name")
            next
        }
        $2 == "backup_dir" {
            if (!path($3)) bad("[" $1 "] backup_dir must be absolute or start with ~/")
            next
        }
        $2 == "backup_root" { bad("[" $1 "] backup_root: projects set backup_dir; backup_root belongs in [global]"); next }
        !label($2) { bad("[" $1 "] \"" $2 "\" is not a valid environment name"); next }
        !ref($3) {
            bad("[" $1 "] " $2 " = \"" $3 "\" is not a project ref (20 lowercase letters);" \
                " the only other settings are account and backup_dir")
        }
        END { exit failed }
    ' || exit 1
}

# Settle REF for NAME/ENV. Short form: projects.ini must have it. Long form:
# --ref as given, but refused if projects.ini knows NAME/ENV as something else.
resolve_target() {
    local configured
    load_projects_ini
    check_label "$([ "$MODE" = short ] && echo "<project>" || echo "--name")" "$NAME"
    check_label "<env>" "$ENV"
    [ "$NAME" != global ] || die "'global' is projects.ini's settings section, not a project name."
    case "$ENV" in
        account|backup_dir|backup_root) die "'$ENV' is a projects.ini setting, not an environment name." ;;
    esac
    configured=$(ini_value "$PROJECTS" "$NAME" "$ENV") || configured=""

    if [ "$MODE" = short ]; then
        [ -f "$PROJECTS_INI" ] ||
            die "No $PROJECTS_INI, which the short form reads <project> <env> from. Create it, or use --ref/--name."
        if [ -z "$configured" ]; then
            echo "$PROJECTS_INI has no ref for $NAME/$ENV. It knows:" >&2
            printf '%s\n' "$PROJECTS" | awk -F'\t' '
                NF && $1 != "global" && $2 != "account" && $2 != "backup_dir" { printf "  %s %s\n", $1, $2 }' >&2
            exit 1
        fi
        REF="$configured"
    else
        [[ "$REF" =~ $REF_RE ]] || die "--ref must be a project ref (20 lowercase letters), not '$REF'."
        if [ -n "$configured" ] && [ "$configured" != "$REF" ]; then
            die "--ref $REF disagrees with $PROJECTS_INI, which has $NAME/$ENV = $configured.
Check --ref, --name and <env>. If $NAME/$ENV really moved, update projects.ini."
        fi
    fi
}

# Snapshots for <env> go to $BACKUP_DIR/<env>/<UTC timestamp>/. The first of
# these that is set picks BACKUP_DIR:
#
#   --backup-root <dir>                   <dir>/<project>
#   projects.ini [<project>] backup_dir   that directory
#   projects.ini [global] backup_root     <root>/<project>
#   otherwise                             ~/supabase-backups/db-backups/<project>
#
# Deliberately not $BACKUP_ROOT: that name is generic enough that one project
# exporting it would send every other project's snapshots into its folder.
# Made absolute now, before anything cds into the temp link directory.
resolve_backup_dir() {
    local dir
    if [ -n "$BACKUP_ROOT_OPT" ]; then
        dir=$(expand_path "$BACKUP_ROOT_OPT") || dir="$PWD/$BACKUP_ROOT_OPT"
        BACKUP_DIR="$dir/$NAME"
    elif dir=$(ini_value "$PROJECTS" "$NAME" backup_dir); then
        BACKUP_DIR=$(expand_path "$dir")
    elif dir=$(ini_value "$PROJECTS" global backup_root); then
        BACKUP_DIR="$(expand_path "$dir")/$NAME"
    else
        BACKUP_DIR="$HOME/supabase-backups/db-backups/$NAME"
    fi
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

# tokens.ini holds account-wide credentials and lives inside a git checkout,
# so before reading a byte of it: only you may read it, git must not track it,
# and git must ignore it.
guard_tokens_ini() {
    local dir base
    dir=$(dirname "$TOKENS_INI")
    base=$(basename "$TOKENS_INI")
    case "$(ls -lnL "$TOKENS_INI" | cut -c5-10)" in
        ------) ;;
        *) die "$TOKENS_INI is readable by other users. Run: chmod 600 \"$TOKENS_INI\"" ;;
    esac
    if command -v git >/dev/null 2>&1 && git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        if git -C "$dir" ls-files --error-unmatch -- "$base" >/dev/null 2>&1; then
            die "$TOKENS_INI is tracked by git, so its tokens are in the repo.
Run: git rm --cached \"$TOKENS_INI\", commit, and rotate every token in it."
        fi
        if ! git -C "$dir" check-ignore -q -- "$base"; then
            die "$TOKENS_INI is not ignored by git, so it could be committed. Add it to .gitignore first."
        fi
    fi
}

# The short form's token: one [<account>] section per Supabase account in
# tokens.ini. A project uses the section named by its `account` setting in
# projects.ini, or its own name.
load_tokens_ini_token() {
    local account tokens
    account=$(ini_value "$PROJECTS" "$NAME" account) || account="$NAME"
    if [ ! -f "$TOKENS_INI" ]; then
        echo "No --token-file given and no $TOKENS_INI." >&2
        echo "Copy tokens.example.ini to tokens.ini, chmod 600 it, and add a [$account] token." >&2
        if [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
            echo "(SUPABASE_ACCESS_TOKEN is ignored in the short form.)" >&2
        fi
        exit 1
    fi
    guard_tokens_ini
    tokens=$(ini_parse "$TOKENS_INI") || exit 1
    printf '%s\n' "$tokens" | awk -F'\t' -v file="$TOKENS_INI" '
        function bad(msg) { printf "%s: %s\n", file, msg > "/dev/stderr"; failed = 1 }
        NF == 0 { next }
        $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ { bad("[" $1 "] is not a valid account name"); next }
        $2 != "token" { bad("[" $1 "] has no setting \"" $2 "\" (only token)"); next }
        $3 == "" || $3 ~ /[[:space:]]/ { bad("[" $1 "] token is empty or malformed") }
        END { exit failed }
    ' || exit 1
    if ! SUPABASE_ACCESS_TOKEN=$(ini_value "$tokens" "$account" token); then
        if [ "$account" = "$NAME" ]; then
            die "$TOKENS_INI has no [$account] token."
        fi
        die "$TOKENS_INI has no [$account] token (projects.ini says $NAME uses account $account)."
    fi
    TOKEN_SOURCE="tokens.ini [$account]"
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
    elif [ "$MODE" = short ]; then
        # An exported token belongs to one account; letting it override
        # tokens.ini would point it at every other account's projects too.
        load_tokens_ini_token
    elif [ -n "${SUPABASE_ACCESS_TOKEN:-}" ]; then
        TOKEN_SOURCE="SUPABASE_ACCESS_TOKEN"
    else
        cat >&2 <<EOF
No access token. With --ref, give one with --token-file <file> or
SUPABASE_ACCESS_TOKEN; or use the short form, which reads tokens.ini.

This script never uses the CLI's stored login ('supabase login'): with more than
one Supabase account on a machine it can silently be the wrong one. Create a
personal access token while signed in to the account that owns $REF:

  https://supabase.com/dashboard/account/tokens
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

# The newest complete snapshot in an <env> directory: the last timestamp-named
# directory holding a MANIFEST.txt. Found by listing rather than through the
# `latest` symlink, which does not survive a trip through OneDrive (it comes
# back as a plain file holding the target's name).
latest_snapshot() {  # <env dir>
    local snap
    snap=$(find "$1" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*T[0-9]*Z' 2>/dev/null \
        | LC_ALL=C sort \
        | while IFS= read -r d; do [ -f "$d/MANIFEST.txt" ] && printf '%s\n' "$d"; done \
        | tail -n 1)
    [ -n "$snap" ] && printf '%s\n' "$snap"
}

# A <project>/<env> directory belongs to one project ref. If its latest snapshot
# came from a different ref, the ref is likely a typo or a prod ref under a test
# label; refuse rather than mix the two.
check_ref_binding() {  # <env>
    local snap bound
    snap=$(latest_snapshot "$BACKUP_DIR/$1") || return 0
    bound=$(sed -n 's/^project ref: *//p' "$snap/MANIFEST.txt")
    if [ -n "$bound" ] && [ "$bound" != "$REF" ]; then
        die "Snapshots in $BACKUP_DIR/$1 are of project $bound, but the ref is $REF.
Check the ref, project and <env>. If $NAME/$1 really moved to a new project,
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
