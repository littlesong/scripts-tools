#!/bin/bash
# Full local backup of a Supabase project: database dump + Storage objects.
#
#   Usage: backup-supabase.sh --ref <project-ref> --name <project> [options] <env>
#
#     --ref <ref>          the project to back up (20 lowercase letters)
#     --name <project>     your name for the project, e.g. zhiming
#     <env>                environment label, e.g. test or prod
#     --token-file <file>  read the access token from <file> instead of
#                          $SUPABASE_ACCESS_TOKEN
#     --backup-root <dir>  where snapshots go (default: $SUPABASE_BACKUP_ROOT,
#                          else ~/supabase-backups)
#     -h, --help
#
#   Example:
#     backup-supabase.sh --ref abcdefghijklmnopqrst --name zhiming \
#         --token-file ~/development/suanming-app/.env.local test
#
# Writes a self-contained, timestamped snapshot to
# <backup root>/db-backups/<project>/<env>/<UTC timestamp>/:
#
#   roles.sql.gz    cluster roles
#   schema.sql.gz   DDL for all non-internal schemas
#   data.sql.gz     every row, including auth.users and storage.objects
#   storage/<bucket>/ the actual files from every Storage bucket
#   manifest.json   bucket/name/size/updated_at of every storage object
#   MANIFEST.txt    project, checksums, counts and tool versions
#
# Requirements — no Docker, no database password and no `supabase login`:
#   * supabase CLI
#   * a personal access token for the account that owns the project, in
#     SUPABASE_ACCESS_TOKEN or --token-file. Its account must be able to see
#     --ref, or the script stops before doing anything.
#   * pg_dump (brew install libpq); this script finds the keg-only build itself
#   * jq
#
# The CLI normally shells out to pg_dump inside a Docker container. We ask it
# for the script it *would* run (--dry-run), which arrives complete with
# credentials for a short-lived login role, and run that against the local
# pg_dump instead. That keeps the platform's schema/table exclusions intact
# without needing Docker or storing the database password anywhere.
#
# `supabase storage` has no --project-ref flag; it only acts on a linked
# project. Each run links --ref in its own temp directory and runs every CLI
# command against that, so it never touches a project checkout's link and
# nothing else can repoint it mid-run.
#
# A <project>/<env> directory is tied to the ref its snapshots came from: the
# script refuses to add a snapshot of a different ref to it.
#
# Storage downloads are incremental: objects whose size and updated_at are
# unchanged since the previous snapshot are hard-linked from it rather than
# re-fetched. Every snapshot directory is still a complete standalone copy.
#
# Secrets are deliberately NOT backed up. Edge function secrets are write-only
# in Supabase and cannot be read back; keep them in a password manager.
#
# WARNING: data.sql contains password hashes, emails and private user data.
# Snapshots are written owner-only, outside any repo. Keep them off shared
# drives and out of git.
#
# To restore, see restore-supabase.sh and README.md next to this script.

set -euo pipefail
umask 077
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

KEEP="${KEEP:-30}"          # number of snapshots to retain per <project>/<env>
BULK_THRESHOLD="${BULK_THRESHOLD:-50}"  # fetch the whole bucket past this many new objects

# ------------------------------------------------------------------ args --

REF=""
NAME=""
ENV=""
TOKEN_FILE=""
BACKUP_ROOT_OPT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)         need_value "$@"; REF="$2"; shift 2;;
        --name)        need_value "$@"; NAME="$2"; shift 2;;
        --token-file)  need_value "$@"; TOKEN_FILE="$2"; shift 2;;
        --backup-root) need_value "$@"; BACKUP_ROOT_OPT="$2"; shift 2;;
        -h|--help)     usage 0;;
        -*)            echo "Unknown option: $1" >&2; usage 1;;
        *)
            [ -z "$ENV" ] || { echo "Unexpected argument: $1" >&2; usage 1; }
            ENV="$1"; shift;;
    esac
done

check_target_args
resolve_backups_dir

# ---------------------------------------------------------------- preflight --

use_libpq
require_tools supabase pg_dump jq gzip shasum

load_token
init_link_dir
trap remove_link_dir EXIT
trap 'exit 130' INT TERM HUP

check_project_access
check_ref_binding "$ENV"
link_project

SNAP_ROOT="$BACKUPS_DIR/$NAME/$ENV"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$SNAP_ROOT/$STAMP"
LATEST="$SNAP_ROOT/latest"
PREV=$(readlink "$LATEST" 2>/dev/null || true)
[ -n "$PREV" ] && PREV="$SNAP_ROOT/$(basename "$PREV")"

WORK="$DEST.partial"
rm -rf "$WORK"
mkdir -p "$WORK"
DL_LOG="$WORK/.download.log"
# Only a completed run is allowed to leave a snapshot behind. Storage transfer
# output is quiet unless something goes wrong, hence the log tail here.
cleanup() {
    if [ -s "$DL_LOG" ]; then
        echo "--- last lines of storage transfer log ---" >&2
        tail -20 "$DL_LOG" >&2
    fi
    rm -rf "$WORK"
    remove_link_dir
}
trap cleanup EXIT

echo "==> Backing up $NAME/$ENV: Supabase project '$PROJECT_NAME' ($REF)"
echo "    token from $TOKEN_SOURCE"
echo "    to $DEST"

# ---------------------------------------------------------------- database --

# Ask the CLI for the pg_dump script it would run in Docker, then run it here.
dump() {
    local label="$1" out="$2"; shift 2
    echo "  - $label"
    if ! supabase db dump --linked --workdir "$LINK_DIR" "$@" --dry-run </dev/null 2>"$LINK_DIR/dump.err" \
            | bash > "$WORK/$out"; then
        echo "Dumping $label failed." >&2
        sed 's/^/  /' "$LINK_DIR/dump.err" >&2
        exit 1
    fi
    if [ ! -s "$WORK/$out" ]; then
        echo "Dump produced an empty $out — aborting." >&2
        exit 1
    fi
}

echo "==> Dumping database"
dump "roles"  roles.sql  --role-only
dump "schema" schema.sql
dump "data"   data.sql   --data-only --use-copy

# A dump that lost auth.users would restore to data nobody can log into.
if ! grep -q '^COPY "auth"\."users"' "$WORK/data.sql"; then
    echo "data.sql has no auth.users COPY block — aborting." >&2
    exit 1
fi

# ----------------------------------------------------------------- storage --

echo "==> Reading storage manifest"
cat > "$LINK_DIR/manifest.sql" <<'SQL'
select o.bucket_id, o.name, (o.metadata->>'size')::bigint as size, o.updated_at
from storage.objects o
order by o.bucket_id, o.name;
SQL
query_json "$LINK_DIR/manifest.sql" > "$WORK/manifest.json"

if ! jq -e 'type == "array"' "$WORK/manifest.json" >/dev/null 2>&1; then
    echo "Storage manifest query did not return rows — aborting." >&2
    exit 1
fi

OBJECT_COUNT=$(jq 'length' "$WORK/manifest.json")
echo "  - $OBJECT_COUNT objects"

BUCKETS=$(jq -r '[.[].bucket_id] | unique | .[]' "$WORK/manifest.json")
mkdir -p "$WORK/storage"

# Bucket and object names come from users. Refuse anything that could escape
# the snapshot directory rather than trusting it into a path.
if jq -e '.[] | select((.name | test("(^/)|(\\.\\.)|[\\n\\r]")) or (.bucket_id | test("^[A-Za-z0-9._-]+$") | not))' \
        "$WORK/manifest.json" >/dev/null; then
    echo "Storage manifest contains an unsafe bucket or object name — aborting." >&2
    exit 1
fi

linked_count=0
fetched_count=0

for bucket in $BUCKETS; do
    echo "==> Storage: $bucket"

    # Split this bucket's objects into ones the previous snapshot already has
    # byte-for-byte (same size and updated_at) and ones we have to fetch.
    reuse_list="$WORK/.reuse"
    fetch_list="$WORK/.fetch"
    prev_manifest="$PREV/manifest.json"
    [ -n "$PREV" ] && [ -f "$prev_manifest" ] || prev_manifest=/dev/null

    jq -r --arg b "$bucket" --slurpfile prev "$prev_manifest" '
        (($prev[0] // []) | map(select(.bucket_id == $b)) | map({key: .name, value: "\(.size)|\(.updated_at)"}) | from_entries) as $old
        | map(select(.bucket_id == $b))
        | .[]
        | select($old[.name] == "\(.size)|\(.updated_at)")
        | .name
    ' "$WORK/manifest.json" > "$reuse_list"

    jq -r --arg b "$bucket" --slurpfile prev "$prev_manifest" '
        (($prev[0] // []) | map(select(.bucket_id == $b)) | map({key: .name, value: "\(.size)|\(.updated_at)"}) | from_entries) as $old
        | map(select(.bucket_id == $b))
        | .[]
        | select($old[.name] != "\(.size)|\(.updated_at)")
        | .name
    ' "$WORK/manifest.json" > "$fetch_list"

    total=$(jq -r --arg b "$bucket" '[.[] | select(.bucket_id == $b)] | length' "$WORK/manifest.json")
    reusable=$(grep -c . "$reuse_list" || true)
    missing=$(grep -c . "$fetch_list" || true)

    if [ "$reusable" -gt 0 ] && [ "$missing" -le "$BULK_THRESHOLD" ]; then
        echo "  - reusing $reusable unchanged, fetching $missing"
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            src="$PREV/storage/$bucket/$name"
            mkdir -p "$WORK/storage/$bucket/$(dirname "$name")"
            if [ -f "$src" ]; then
                ln "$src" "$WORK/storage/$bucket/$name"
                linked_count=$(( linked_count + 1 ))
            else
                # Manifest says unchanged but the file is gone; refetch it.
                echo "$name" >> "$fetch_list"
            fi
        done < "$reuse_list"

        while IFS= read -r name; do
            [ -z "$name" ] && continue
            mkdir -p "$WORK/storage/$bucket/$(dirname "$name")"
            supabase storage cp --experimental --workdir "$LINK_DIR" \
                "ss:///$bucket/$name" "$WORK/storage/$bucket/$name" </dev/null >>"$DL_LOG" 2>&1
            fetched_count=$(( fetched_count + 1 ))
        done < "$fetch_list"
    else
        # First run, or too much has changed to be worth fetching one by one.
        # The destination must NOT exist yet: `cp -r` copies *into* a directory
        # that already exists, which would nest an extra <bucket>/ level and
        # break hard-linking against this snapshot next time.
        echo "  - downloading all $total objects"
        rm -rf "$WORK/storage/$bucket"
        supabase storage cp -r --experimental --workdir "$LINK_DIR" \
            "ss:///$bucket" "$WORK/storage/$bucket" </dev/null >>"$DL_LOG" 2>&1
        fetched_count=$(( fetched_count + total ))
    fi
    rm -f "$reuse_list" "$fetch_list"

    # Every object must be on disk at exactly the path the manifest names, so a
    # restore can walk the manifest. A plain file count would not catch the
    # layout drifting by a directory level.
    jq -r --arg b "$bucket" '.[] | select(.bucket_id == $b) | .name' "$WORK/manifest.json" \
        | while IFS= read -r name; do
            if [ ! -f "$WORK/storage/$bucket/$name" ]; then
                echo "Missing from snapshot: $bucket/$name" >&2
                exit 1
            fi
        done

    on_disk=$(find "$WORK/storage/$bucket" -type f | wc -l | tr -d ' ')
    if [ "$on_disk" -ne "$total" ]; then
        echo "Expected $total files in $bucket, found $on_disk — aborting." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------- finalise --

echo "==> Compressing and checksumming"
rm -f "$DL_LOG"
gzip -9 "$WORK/roles.sql" "$WORK/schema.sql" "$WORK/data.sql"

{
    echo "project:       $NAME"
    echo "environment:   $ENV"
    echo "project ref:   $REF"
    echo "supabase name: $PROJECT_NAME"
    echo "taken at:      $(date -u +'%Y-%m-%d %H:%M:%S UTC')"
    echo "supabase cli:  $(supabase --version 2>/dev/null | head -1)"
    echo "pg_dump:       $(pg_dump --version)"
    echo "postgres:      $(cat "$LINK_DIR/supabase/.temp/postgres-version" 2>/dev/null || echo unknown)"
    echo "storage:       $OBJECT_COUNT objects ($fetched_count fetched, $linked_count hard-linked from previous)"
    [ -n "$PREV" ] && echo "previous:      $(basename "$PREV")"
    echo
    echo "sha256:"
    (cd "$WORK" && shasum -a 256 ./*.sql.gz manifest.json)
} > "$WORK/MANIFEST.txt"

mv "$WORK" "$DEST"
trap remove_link_dir EXIT
ln -sfn "$STAMP" "$LATEST"

# ---------------------------------------------------------------- retention --

# Hard links mean pruning an old snapshot only frees the objects unique to it.
# (macOS ships bash 3.2, so no mapfile here.)
find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' \
    | sort -r | tail -n "+$(( KEEP + 1 ))" \
    | while IFS= read -r old; do
        echo "==> Pruning $(basename "$old")"
        rm -rf "$old"
    done

echo
echo "Done: $DEST"
du -sh "$DEST" | awk '{print "Snapshot size: " $1}'
echo "Total for $NAME/$ENV: $(du -sh "$SNAP_ROOT" | awk '{print $1}') across $(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' | wc -l | tr -d ' ') snapshots"
