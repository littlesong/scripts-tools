#!/bin/bash
# Restore a snapshot produced by backup-supabase.sh into a project.
#
#   Usage: restore-supabase.sh [options] <project> <env> <snapshot>
#          restore-supabase.sh --ref <project-ref> --name <project> [options] <env> <snapshot>
#
#     <project> <env>       short form: the project to restore INTO, looked up in
#                           projects.ini; the token comes from tokens.ini
#     --ref <ref>           long form: the project to restore INTO
#     --name <project>      long form: your name for the project, e.g. zhiming
#     <env>                 environment label of the target, e.g. test or prod
#     <snapshot>            latest | <timestamp> — under <backup dir>/<source>/
#                           | <path>             — or a snapshot directory given directly
#
#   Options:
#     --token-file <file>   read the access token from <file>. Without it the short
#                           form uses tokens.ini, the long form $SUPABASE_ACCESS_TOKEN
#     --backup-root <dir>   look for snapshots under <dir>/<project>/ instead of
#                           where projects.ini says (see backup-supabase.sh)
#     --source <env>        where to read <snapshot> from (default: <env>)
#     --skip-db             do not touch the database
#     --skip-storage        do not touch Storage
#     --no-prune-storage    keep target objects that are absent from the snapshot
#                           (default: delete them, so storage matches exactly)
#     --rehearse            load the database inside a transaction, check it, then
#                           ROLL BACK; Storage is planned but not touched
#     --yes                 skip the confirmation prompt (for unattended use)
#     -h, --help
#
#   Examples:
#     # Check a snapshot restores cleanly, leaving the project unchanged:
#     restore-supabase.sh --rehearse zhiming test latest
#     # Verify prod's latest backup by restoring it into the test project:
#     restore-supabase.sh --source prod zhiming test latest
#     # Disaster recovery — put prod's latest snapshot back into prod:
#     restore-supabase.sh zhiming prod latest
#
# ============================ THIS IS DESTRUCTIVE ============================
# The target's data is replaced with the snapshot's. Every table in the dump is
# TRUNCATEd and reloaded, and (unless --no-prune-storage) Storage objects not in
# the snapshot are deleted. Restoring INTO prod overwrites live data. There is
# no undo — take a fresh backup first if the current state matters. You must
# type the target's project ref to go ahead.
# ============================================================================
#
# How it works, and its limits:
#   * The target, token and temp-directory link work exactly as in the backup:
#     the token's account must see the ref, and no project checkout's link is
#     used.
#   * Connects with the same short-lived login role the backup uses (obtained
#     from `supabase db dump --dry-run`), so NO database password is needed. The
#     role is a member of `postgres`; the restore does `SET ROLE postgres` to
#     gain access to the auth/storage schemas.
#   * The database load is a single transaction with ON_ERROR_STOP — it is
#     all-or-nothing. Triggers and FKs are bypassed (session_replication_role)
#     and tables are truncated with CASCADE, so load order does not matter.
#     Before committing, every table's row count is checked against the
#     snapshot; any difference rolls the whole load back.
#   * Storage is restored through the Storage API (`supabase storage`), which
#     owns the storage.objects rows. The storage schema is therefore EXCLUDED
#     from the SQL load to avoid the API and the dump fighting over those rows.
#   * The SCHEMA is NOT restored here. Deploy the project's migrations to the
#     target first; this script refuses to run if any table in the snapshot, or
#     any bucket it needs, is missing there. Tables that are not in the
#     snapshot are left alone.
#   * Not in any snapshot, so not restored: edge function secrets and dashboard
#     settings (auth providers, SMTP, storage bucket config).

set -euo pipefail
umask 077
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# ------------------------------------------------------------------ args --

REF=""
NAME=""
ENV=""
TOKEN_FILE=""
BACKUP_ROOT_OPT=""
SNAPSHOT_ARG=""
SOURCE_ENV=""
SKIP_DB=0
SKIP_STORAGE=0
PRUNE_STORAGE=1
REHEARSE=0
ASSUME_YES=0
POS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --ref)              need_value "$@"; REF="$2"; shift 2;;
        --name)             need_value "$@"; NAME="$2"; shift 2;;
        --token-file)       need_value "$@"; TOKEN_FILE="$2"; shift 2;;
        --backup-root)      need_value "$@"; BACKUP_ROOT_OPT="$2"; shift 2;;
        --source)           need_value "$@"; SOURCE_ENV="$2"; shift 2;;
        --skip-db)          SKIP_DB=1; shift;;
        --skip-storage)     SKIP_STORAGE=1; shift;;
        --no-prune-storage) PRUNE_STORAGE=0; shift;;
        --rehearse)         REHEARSE=1; shift;;
        --yes|-y)           ASSUME_YES=1; shift;;
        -h|--help)          usage 0;;
        -*)                 echo "Unknown option: $1" >&2; usage 1;;
        *)                  POS+=("$1"); shift;;
    esac
done

if [ -n "$REF" ]; then
    MODE=long
    [ -n "$NAME" ] || die "--ref needs --name <project> too (or use the short form: <project> <env> <snapshot>)."
    [ ${#POS[@]} -eq 2 ] || { echo "With --ref/--name, give <env> <snapshot>." >&2; usage 1; }
    ENV="${POS[0]}"
    SNAPSHOT_ARG="${POS[1]}"
else
    MODE=short
    [ -z "$NAME" ] || die "--name goes with --ref. The short form is: $(basename "$0") <project> <env> <snapshot>"
    [ ${#POS[@]} -eq 3 ] || { echo "Expected <project> <env> <snapshot> (e.g. 'latest' or a timestamp or a path)." >&2; usage 1; }
    NAME="${POS[0]}"
    ENV="${POS[1]}"
    SNAPSHOT_ARG="${POS[2]}"
fi

if [ "$SKIP_DB" = 1 ] && [ "$SKIP_STORAGE" = 1 ]; then
    echo "Nothing to do: both --skip-db and --skip-storage given." >&2; exit 1
fi
resolve_target
resolve_backup_dir
SOURCE_ENV="${SOURCE_ENV:-$ENV}"
check_label --source "$SOURCE_ENV"

# ------------------------------------------------------------- preflight --

use_libpq
require_tools supabase psql jq gzip shasum

# Resolve the snapshot directory. A value containing '/' is a path; otherwise it
# names a snapshot under <backup dir>/<source>/. 'latest' is the newest one
# there, found by listing: the latest symlink does not survive OneDrive.
case "$SNAPSHOT_ARG" in
    */*)    SNAP="$SNAPSHOT_ARG";;
    latest) SNAP=$(latest_snapshot "$BACKUP_DIR/$SOURCE_ENV") ||
                die "No snapshots in $BACKUP_DIR/$SOURCE_ENV.";;
    *)      check_label "<snapshot>" "$SNAPSHOT_ARG"
            SNAP="$BACKUP_DIR/$SOURCE_ENV/$SNAPSHOT_ARG";;
esac
if [ ! -d "$SNAP" ]; then
    echo "Snapshot directory not found: $SNAP" >&2; exit 1
fi
SNAP="$(cd "$SNAP" && pwd -P)"   # resolve symlink (latest) to a real path
for f in data.sql.gz manifest.json MANIFEST.txt; do
    if [ ! -f "$SNAP/$f" ]; then
        echo "Snapshot is missing $f — not a complete backup: $SNAP" >&2; exit 1
    fi
done

load_token
init_link_dir
WORK="$LINK_DIR"
cleanup() {
    local rc=$?
    if [ "$rc" != 0 ] && [ -s "$WORK/storage.log" ]; then
        echo "--- last lines of storage transfer log ---" >&2
        tail -20 "$WORK/storage.log" >&2
    fi
    remove_link_dir
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP

check_project_access
check_ref_binding "$ENV"

# ------------------------------------------------------ verify + link --

echo "==> Verifying snapshot checksums"
if ! ( cd "$SNAP" && shasum -a 256 -c <(sed -n '/^sha256:/,$p' MANIFEST.txt | tail -n +2) ) >/dev/null 2>&1; then
    echo "Snapshot failed checksum verification — refusing to restore from it." >&2
    echo "  Re-check: (cd $SNAP && shasum -a 256 -c <(sed -n '/^sha256:/,\$p' MANIFEST.txt | tail -n +2))" >&2
    exit 1
fi

SNAP_REF=$(sed -n 's/^project ref: *//p' "$SNAP/MANIFEST.txt")
SNAP_NAME=$(sed -n 's/^supabase name: *//p' "$SNAP/MANIFEST.txt")

link_project

# ----------------------------------------------------- plan database --

# The data dump minus the storage schema, which goes through the Storage API.
gunzip -c "$SNAP/data.sql.gz" | awk '
    inblock { if ($0 == "\\.") inblock = 0; if (!skip) print; next }
    /^COPY / { inblock = 1; skip = ($0 ~ /^COPY "storage"\./); if (!skip) print; next }
    { print }
' > "$WORK/data.nostorage.sql"

# Every table the dump loads, with the row count the snapshot has for it.
awk '
    inblock && $0 == "\\." { print t "\t" n; inblock = 0; next }
    inblock { n++; next }
    /^COPY "/ && match($0, /^COPY "[^"]+"\."[^"]+"/) { t = substr($0, 6, RLENGTH - 5); n = 0; inblock = 1 }
' "$WORK/data.nostorage.sql" > "$WORK/tables.tsv"

TABLE_COUNT=$(grep -c . "$WORK/tables.tsv" || true)
ROW_COUNT=$(awk -F'\t' '{ s += $2 } END { print s + 0 }' "$WORK/tables.tsv")
if [ "$TABLE_COUNT" = 0 ]; then
    echo "Snapshot has no table data to load: $SNAP" >&2; exit 1
fi
TRUNCATE_LIST=$(cut -f1 "$WORK/tables.tsv" | paste -sd, -)

# The schema must already be in place. Bail early if any table is missing.
CASCADE_TABLES=""
if [ "$SKIP_DB" = 0 ]; then
    echo "==> Checking target schema"
    {
        echo "select t from unnest(array["
        cut -f1 "$WORK/tables.tsv" | sed "s/'/''/g; s/.*/'&'/" | paste -sd, -
        echo "]::text[]) as t where to_regclass(t) is null order by t;"
    } > "$WORK/probe.sql"
    MISSING_TABLES=$(query_json "$WORK/probe.sql" | jq -r '.[].t')
    if [ -n "$MISSING_TABLES" ]; then
        echo "Target project $REF is missing tables the snapshot has data for:" >&2
        printf '%s\n' "$MISSING_TABLES" | sed 's/^/  /' >&2
        echo "Deploy the project's migrations to it first, then re-run this restore." >&2
        exit 1
    fi

    # TRUNCATE ... CASCADE also empties every table that references a loaded
    # one, directly or through others. Those get no rows back from the
    # snapshot, so name them up front — and never let it reach Storage, whose
    # rows must stay in step with the files the Storage API holds.
    {
        echo "with recursive loaded(oid) as (select unnest(array["
        cut -f1 "$WORK/tables.tsv" | sed "s/'/''/g; s/.*/'&'/" | paste -sd, -
        echo "]::text[])::regclass),"
        cat <<'SQL'
hit(oid) as (
    select c.conrelid from pg_constraint c
    where c.contype = 'f' and c.confrelid in (select oid from loaded)
      and c.conrelid not in (select oid from loaded)
  union
    select c.conrelid from pg_constraint c join hit on c.confrelid = hit.oid
    where c.contype = 'f' and c.conrelid not in (select oid from loaded)
)
select format('%I.%I', n.nspname, r.relname) as t, n.nspname = 'storage' as storage
from hit join pg_class r on r.oid = hit.oid join pg_namespace n on n.oid = r.relnamespace
order by 1;
SQL
    } > "$WORK/cascade.sql"
    query_json "$WORK/cascade.sql" > "$WORK/cascade.json"
    CASCADE_TABLES=$(jq -r '.[].t' "$WORK/cascade.json")
    if jq -e 'any(.[]; .storage)' "$WORK/cascade.json" >/dev/null; then
        echo "Restoring would empty Storage tables through foreign keys to loaded tables:" >&2
        jq -r '.[] | select(.storage) | "  " + .t' "$WORK/cascade.json" >&2
        echo "Refusing: that would orphan the files Storage holds. Drop or fix those" >&2
        echo "foreign keys on the target first." >&2
        exit 1
    fi
fi

# ----------------------------------------------------- plan storage --

# Buckets present in the snapshot.
BUCKETS=$(jq -r '[.[].bucket_id] | unique | .[]' "$SNAP/manifest.json")

if jq -e '.[] | select(.bucket_id | test("^[A-Za-z0-9._-]+$") | not)' "$SNAP/manifest.json" >/dev/null; then
    echo "Snapshot manifest contains an unsafe bucket name — aborting." >&2; exit 1
fi

# Per bucket, diff the snapshot manifest against the live bucket. Emits, per
# bucket, four files in $WORK: cp_new, cp_changed, rm_changed, rm_prune.
plan_storage() {
    local bucket="$1"
    jq -r --arg b "$bucket" '.[] | select(.bucket_id==$b) | "\(.name)\t\(.size)"' \
        "$SNAP/manifest.json" | LC_ALL=C sort > "$WORK/snap.$bucket"

    printf 'select name, (metadata->>%s)::bigint as size from storage.objects where bucket_id=%s order by name;\n' \
        "'size'" "'$bucket'" > "$WORK/tq.sql"
    query_json "$WORK/tq.sql" \
        | jq -r '.[] | "\(.name)\t\(.size)"' | LC_ALL=C sort > "$WORK/tgt.$bucket"

    cut -f1 "$WORK/snap.$bucket" | LC_ALL=C sort > "$WORK/snap.names.$bucket"
    cut -f1 "$WORK/tgt.$bucket"  | LC_ALL=C sort > "$WORK/tgt.names.$bucket"

    # New: names in snapshot but not in target.
    LC_ALL=C comm -23 "$WORK/snap.names.$bucket" "$WORK/tgt.names.$bucket" > "$WORK/cp_new.$bucket"
    # Prune: names in target but not in snapshot.
    LC_ALL=C comm -13 "$WORK/snap.names.$bucket" "$WORK/tgt.names.$bucket" > "$WORK/rm_prune.$bucket"
    # Changed: same name, different size -> must delete then re-upload.
    LC_ALL=C join -t"$(printf '\t')" -j1 "$WORK/snap.$bucket" "$WORK/tgt.$bucket" \
        | awk -F'\t' '$2 != $3 {print $1}' > "$WORK/cp_changed.$bucket"
    cp "$WORK/cp_changed.$bucket" "$WORK/rm_changed.$bucket"
}

STORAGE_SUMMARY=""
if [ "$SKIP_STORAGE" = 0 ] && [ -n "$BUCKETS" ]; then
    echo "==> Planning storage restore"
    # Bucket config is not in the snapshot; the buckets themselves must exist.
    echo "select id from storage.buckets order by id;" > "$WORK/bq.sql"
    query_json "$WORK/bq.sql" | jq -r '.[].id' > "$WORK/target.buckets"
    MISSING_BUCKETS=$(printf '%s\n' "$BUCKETS" | LC_ALL=C sort | LC_ALL=C comm -23 - <(LC_ALL=C sort "$WORK/target.buckets"))
    if [ -n "$MISSING_BUCKETS" ]; then
        echo "Target project $REF has no bucket(s):" >&2
        printf '%s\n' "$MISSING_BUCKETS" | sed 's/^/  /' >&2
        echo "Create them (migration or dashboard) first, then re-run this restore." >&2
        exit 1
    fi

    for bucket in $BUCKETS; do
        plan_storage "$bucket"
        n_new=$(grep -c . "$WORK/cp_new.$bucket" || true)
        n_chg=$(grep -c . "$WORK/cp_changed.$bucket" || true)
        n_prune=$(grep -c . "$WORK/rm_prune.$bucket" || true)
        snap_total=$(grep -c . "$WORK/snap.$bucket" || true)
        line="    $bucket: $snap_total in snapshot — upload $n_new new, replace $n_chg changed"
        if [ "$PRUNE_STORAGE" = 1 ]; then line="$line, delete $n_prune extra"
        else line="$line, keep $n_prune extra (no prune)"; fi
        STORAGE_SUMMARY="$STORAGE_SUMMARY$line"$'\n'
    done
fi

# ------------------------------------------------------ confirm --

TAKEN=$(sed -n 's/^taken at: *//p' "$SNAP/MANIFEST.txt")
echo
echo "======================================================================"
if [ "$REHEARSE" = 1 ]; then
    echo "  REHEARSAL — the load is rolled back; the target ends up unchanged"
else
    echo "  RESTORE — this OVERWRITES data in the target project"
fi
echo "----------------------------------------------------------------------"
echo "  Target:       $NAME/$ENV — Supabase project '$PROJECT_NAME' ($REF)"
echo "  Snapshot:     $SNAP"
echo "  Taken:        ${TAKEN:-unknown}, from '${SNAP_NAME:-?}' (${SNAP_REF:-unknown ref})"
if [ -n "$SNAP_REF" ] && [ "$SNAP_REF" != "$REF" ]; then
    echo "  NOTE:         the snapshot is of a DIFFERENT project than the target"
fi
if [ "$SKIP_DB" = 0 ]; then
    echo "  Database:     TRUNCATE + reload $TABLE_COUNT tables ($ROW_COUNT rows)"
    echo "                (expect $(awk -F'\t' '$1 == "\"auth\".\"users\"" { print $2 }' "$WORK/tables.tsv") auth users)"
    if [ -n "$CASCADE_TABLES" ]; then
        echo "  Also EMPTIED: tables not in the snapshot that reference loaded ones:"
        printf '%s\n' "$CASCADE_TABLES" | sed 's/^/                /'
    fi
else
    echo "  Database:     skipped (--skip-db)"
fi
if [ "$SKIP_STORAGE" = 1 ]; then
    echo "  Storage:      skipped (--skip-storage)"
elif [ -z "$BUCKETS" ]; then
    echo "  Storage:      snapshot has no objects; nothing to upload"
else
    echo "  Storage:$([ "$REHEARSE" = 1 ] && printf '      planned only (--rehearse)')"
    printf '%s' "$STORAGE_SUMMARY"
fi
echo "======================================================================"

if [ "$ASSUME_YES" = 1 ]; then
    echo "Proceeding (--yes)."
else
    # The env label is only a label, so it cannot tell us how careful to be:
    # always make the operator type the ref they are about to write to.
    prompt="Type the project ref '$REF' to $([ "$REHEARSE" = 1 ] && echo rehearse || echo restore) into $NAME/$ENV: "
    # Read the confirmation from the controlling terminal, so it works even when
    # stdin is a pipe. If there is no usable terminal (cron/launchd/CI), refuse
    # rather than guess — the caller must pass --yes to run unattended.
    if ! { exec 3<>/dev/tty; } 2>/dev/null; then
        echo "Refusing to run without confirmation (no terminal). Pass --yes to override." >&2
        exit 1
    fi
    printf '%s' "$prompt" >&3
    IFS= read -r reply <&3 || reply=""
    exec 3>&-
    if [ "$reply" != "$REF" ]; then
        echo "Confirmation did not match — aborting." >&2
        exit 1
    fi
fi

# ------------------------------------------------------ database --

if [ "$SKIP_DB" = 0 ]; then
    echo "==> $([ "$REHEARSE" = 1 ] && echo Rehearsing || echo Restoring) database"
    # Short-lived connection env from the CLI (same as the backup path). No
    # stored password; the login role is a member of postgres. The private link
    # means these credentials can only be for $REF.
    eval "$(supabase db dump --linked --workdir "$LINK_DIR" --dry-run </dev/null 2>/dev/null | grep -E '^export PG')"
    if [ -z "${PGHOST:-}" ] || [ -z "${PGPASSWORD:-}" ]; then
        echo "Could not obtain database connection from the CLI — aborting." >&2; exit 1
    fi
    case "$PGHOST $PGUSER" in
        *"$REF"*) ;;
        *) die "CLI gave a database connection ($PGHOST) that is not $REF's — aborting." ;;
    esac

    # Plain TRUNCATE CASCADE — no RESTART IDENTITY: postgres is not the owner of
    # the auth sequences (they belong to supabase_auth_admin), so RESTART would
    # fail. The dump carries its own setval() to restore sequence positions.
    # The dump ends in RESET ALL; the row check after it re-disables RLS so a
    # policy cannot hide rows from the count.
    {
        echo "BEGIN;"
        echo "SET ROLE postgres;"
        echo "SET session_replication_role = replica;"
        echo "TRUNCATE TABLE $TRUNCATE_LIST CASCADE;"
        cat "$WORK/data.nostorage.sql"
        echo "SET row_security = off;"
        echo 'DO $verify$ DECLARE n bigint; BEGIN'
        awk -F'\t' -v q="'" '{
            lit = $1; gsub(q, q q, lit)
            printf "  SELECT count(*) INTO n FROM %s; IF n <> %s THEN RAISE EXCEPTION %srow count for %% is %%, snapshot has %%%s, %s, n, %s; END IF;\n",
                $1, $2, q, q, q lit q, $2
        }' "$WORK/tables.tsv"
        echo 'END $verify$;'
        if [ "$REHEARSE" = 1 ]; then echo "ROLLBACK;"; else echo "COMMIT;"; fi
    } > "$WORK/restore.sql"

    # Stop on first error: psql exits, the open transaction dies with the
    # connection, and the target is unchanged. psql output (COPY counts, a
    # couple of set_config/setval result rows) goes to a log, surfaced only on
    # failure.
    if ! psql -X -v ON_ERROR_STOP=1 -q -f "$WORK/restore.sql" >"$WORK/psql.log" 2>&1; then
        echo "Database $([ "$REHEARSE" = 1 ] && echo rehearsal || echo restore) failed — the transaction rolled back, target is unchanged." >&2
        sed 's/^/    psql: /' "$WORK/psql.log" >&2
        exit 1
    fi
    if [ "$REHEARSE" = 1 ]; then
        echo "  - loaded and checked $TABLE_COUNT tables ($ROW_COUNT rows), then rolled back"
    else
        echo "  - loaded $TABLE_COUNT tables ($ROW_COUNT rows); every row count matched the snapshot"
    fi
fi

# ------------------------------------------------------ storage --

storage_rm()  { supabase storage rm    --experimental --workdir "$LINK_DIR" --yes "ss:///$1" </dev/null >>"$WORK/storage.log" 2>&1; }
storage_cp()  { supabase storage cp    --experimental --workdir "$LINK_DIR" "$1" "ss:///$2"  </dev/null >>"$WORK/storage.log" 2>&1; }
storage_cpr() { supabase storage cp -r --experimental --workdir "$LINK_DIR" "$1" "ss:///$2"  </dev/null >>"$WORK/storage.log" 2>&1; }

# Object names come from a backup and from the live DB; refuse anything that
# could escape the snapshot tree or confuse the path. ($'\n'/$'\r' are literal
# control chars — do NOT use $(printf '\n'), whose trailing newline is stripped,
# leaving an empty sub-pattern that matches every name.)
safe_name() {
    case "$1" in
        /* | *..* | *$'\n'* | *$'\r'* ) return 1 ;;
        * ) return 0 ;;
    esac
}

if [ "$SKIP_STORAGE" = 0 ] && [ "$REHEARSE" = 0 ] && [ -n "$BUCKETS" ]; then
    echo "==> Restoring storage"
    for bucket in $BUCKETS; do
        src_dir="$SNAP/storage/$bucket"
        tgt_have=$(grep -c . "$WORK/tgt.$bucket" || true)
        snap_total=$(grep -c . "$WORK/snap.$bucket" || true)

        if [ "$tgt_have" = 0 ]; then
            # Empty bucket: one bulk upload is far faster than per-object.
            echo "  - $bucket: uploading all $snap_total objects"
            storage_cpr "$src_dir" "$bucket"
        else
            # Delete changed + (optionally) pruned objects first, so re-uploads
            # do not hit the 'resource already exists' error.
            { cat "$WORK/rm_changed.$bucket"; [ "$PRUNE_STORAGE" = 1 ] && cat "$WORK/rm_prune.$bucket"; } \
                | while IFS= read -r name; do
                    [ -z "$name" ] && continue
                    safe_name "$name" || { echo "Unsafe object name, skipping: $name" >&2; continue; }
                    storage_rm "$bucket/$name"
                done
            # Upload new + changed objects.
            { cat "$WORK/cp_new.$bucket"; cat "$WORK/cp_changed.$bucket"; } \
                | while IFS= read -r name; do
                    [ -z "$name" ] && continue
                    safe_name "$name" || continue
                    if [ ! -f "$src_dir/$name" ]; then
                        echo "Snapshot is missing file $bucket/$name — aborting storage restore." >&2
                        exit 1
                    fi
                    storage_cp "$src_dir/$name" "$bucket/$name"
                done
            echo "  - $bucket: uploaded $(grep -c . "$WORK/cp_new.$bucket" || true) new + $(grep -c . "$WORK/cp_changed.$bucket" || true) changed$([ "$PRUNE_STORAGE" = 1 ] && printf ', deleted %s extra' "$(grep -c . "$WORK/rm_prune.$bucket" || true)")"
        fi
    done
fi

# ------------------------------------------------------ verify --

rc=0
if [ "$SKIP_STORAGE" = 0 ] && [ "$REHEARSE" = 0 ] && [ "$PRUNE_STORAGE" = 1 ] && [ -n "$BUCKETS" ]; then
    echo "==> Verifying storage"
    for bucket in $BUCKETS; do
        printf 'select count(*) as n from storage.objects where bucket_id=%s;\n' "'$bucket'" > "$WORK/vq.sql"
        got=$(query_json "$WORK/vq.sql" | jq -r '.[0].n')
        want=$(grep -c . "$WORK/snap.$bucket" || true)
        if [ "$got" = "$want" ]; then
            echo "  - storage OK: $bucket has $got objects"
        else
            echo "  - storage MISMATCH: $bucket has $got objects, expected $want" >&2
            rc=1
        fi
    done
fi

echo
if [ "$rc" != 0 ]; then
    echo "Restore finished WITH MISMATCHES — check the output above." >&2
elif [ "$REHEARSE" = 1 ]; then
    echo "Rehearsal passed: $SNAP loads cleanly into $NAME/$ENV ($REF); nothing was changed."
else
    echo "Restore complete: $SNAP -> $NAME/$ENV ($REF)"
fi
exit "$rc"
