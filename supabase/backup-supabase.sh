#!/bin/bash
# Full local backup of a Supabase project: database dump + Storage objects.
#
#   Usage: backup-supabase.sh [options] <project> <env>
#          backup-supabase.sh --ref <project-ref> --name <project> [options] <env>
#
#     <project> <env>      short form: the ref comes from projects.ini and the
#                          token from tokens.ini, both next to this script
#     --ref <ref>          long form: the project to back up (20 lowercase letters)
#     --name <project>     long form: your name for the project, e.g. zhiming
#     <env>                environment label, e.g. test or prod
#     --token-file <file>  read the access token from <file>. Without it the short
#                          form uses tokens.ini, the long form $SUPABASE_ACCESS_TOKEN
#     --backup-root <dir>  put snapshots under <dir>/<project>/ instead of where
#                          projects.ini says
#     -h, --help
#
#   Examples:
#     backup-supabase.sh zhiming test
#     backup-supabase.sh --ref abcdefghijklmnopqrst --name zhiming \
#         --token-file ~/development/suanming-app/.env.local test
#
# Writes a self-contained, timestamped snapshot to
# <backup dir>/<env>/<UTC timestamp>/. <backup dir> is the first that applies:
#
#   --backup-root <dir>                   <dir>/<project>
#   projects.ini [<project>] backup_dir   that directory
#   projects.ini [global] backup_root     <root>/<project>
#   otherwise                             ~/supabase-backups/db-backups/<project>
#
# Each snapshot holds:
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
#     tokens.ini, --token-file or SUPABASE_ACCESS_TOKEN. Its account must be
#     able to see the project, or the script stops before doing anything.
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
# project. Each run links the ref in its own temp directory and runs every CLI
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
# Each snapshot is assembled in a private staging directory under $TMPDIR and
# moved into the backup folder only when complete, which also keeps the script
# working when that folder is cloud-synced (OneDrive, iCloud; see README.md).
# Point TMPDIR elsewhere to stage on another volume.
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
POS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)         need_value "$@"; REF="$2"; shift 2;;
        --name)        need_value "$@"; NAME="$2"; shift 2;;
        --token-file)  need_value "$@"; TOKEN_FILE="$2"; shift 2;;
        --backup-root) need_value "$@"; BACKUP_ROOT_OPT="$2"; shift 2;;
        -h|--help)     usage 0;;
        -*)            echo "Unknown option: $1" >&2; usage 1;;
        *)             POS+=("$1"); shift;;
    esac
done

if [ -n "$REF" ]; then
    MODE=long
    [ -n "$NAME" ] || die "--ref needs --name <project> too (or use the short form: <project> <env>)."
    [ ${#POS[@]} -eq 1 ] || { echo "With --ref/--name, give just <env>." >&2; usage 1; }
    ENV="${POS[0]}"
else
    MODE=short
    [ -z "$NAME" ] || die "--name goes with --ref. The short form is: $(basename "$0") <project> <env>"
    [ ${#POS[@]} -eq 2 ] || { echo "Expected <project> <env>, or --ref <ref> --name <project> <env>." >&2; usage 1; }
    NAME="${POS[0]}"
    ENV="${POS[1]}"
fi

resolve_target
resolve_backup_dir

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

SNAP_ROOT="$BACKUP_DIR/$ENV"
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$SNAP_ROOT/$STAMP"
LATEST="$SNAP_ROOT/latest"
PREV=$(latest_snapshot "$SNAP_ROOT" || true)

# Build the snapshot in a private local staging directory and move it into
# SNAP_ROOT only once it is complete. Streaming dumps straight into a
# cloud-synced folder (OneDrive or iCloud, which macOS runs through File
# Provider) can fail mid-write with "Operation timed out" while the sync client
# is busy. A finished directory moved in with one rename avoids that, and on the
# same volume ($TMPDIR and ~/Library/CloudStorage both live on the data volume)
# the move is instant.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/supabase-snapshot.XXXXXX")
KEEP_STAGE=0
WORK="$STAGE/$STAMP"
mkdir "$WORK"
DL_LOG="$WORK/.download.log"
# Only a completed run is allowed to leave a snapshot behind. Storage transfer
# output is quiet unless something goes wrong, hence the log tail here.
cleanup() {
    if [ -s "$DL_LOG" ]; then
        echo "--- last lines of storage transfer log ---" >&2
        tail -20 "$DL_LOG" >&2
    fi
    if [ "$KEEP_STAGE" = 0 ]; then rm -rf "$STAGE"; fi
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

# ----------------------------------------------------------------- move in --

# In as <stamp>.partial, then renamed: one rename on the same volume, a copy
# and a rename on another. Nobody sees a half-written snapshot under its final
# name, and if either step fails the complete snapshot is kept for you.
echo "==> Moving the snapshot into $SNAP_ROOT"
if ! { mkdir -p "$SNAP_ROOT" && mv "$WORK" "$DEST.partial"; }; then
    rm -rf "$DEST.partial"
    KEEP_STAGE=1
    die "Could not move the finished snapshot into $SNAP_ROOT.
It is complete and kept at $WORK. Move it in by hand once that folder works:
  mv \"$WORK\" \"$DEST\""
fi
if ! mv "$DEST.partial" "$DEST"; then
    die "The snapshot is complete but still named $DEST.partial. Rename it by hand:
  mv \"$DEST.partial\" \"$DEST\""
fi
rm -rf "$STAGE"
trap remove_link_dir EXIT
# For people browsing the folder. The scripts find the newest snapshot by
# listing instead (see latest_snapshot), since OneDrive does not keep symlinks.
ln -sfn "$STAMP" "$LATEST" 2>/dev/null || echo "warning: could not update $LATEST" >&2

# ---------------------------------------------------------------- retention --

# Hard links mean pruning an old snapshot only frees the objects unique to it.
# (macOS ships bash 3.2, so no mapfile here.)
find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*T[0-9]*Z' \
    | sort -r | tail -n "+$(( KEEP + 1 ))" \
    | while IFS= read -r old; do
        echo "==> Pruning $(basename "$old")"
        rm -rf "$old"
    done

echo
echo "Done: $DEST"
du -sh "$DEST" | awk '{print "Snapshot size: " $1}'
echo "Total for $NAME/$ENV: $(du -sh "$SNAP_ROOT" | awk '{print $1}') across $(find "$SNAP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*T[0-9]*Z' | wc -l | tr -d ' ') snapshots"
