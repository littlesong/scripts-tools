# Supabase backup and restore

Two project-agnostic scripts that take a full local snapshot of a Supabase
project (database + Storage files) and put one back:

| Script | What it does |
| --- | --- |
| [`backup-supabase.sh`](backup-supabase.sh) | Dumps roles, schema and data, downloads every Storage object, writes checksums. |
| [`restore-supabase.sh`](restore-supabase.sh) | Reloads a snapshot's data and Storage objects into a project. **Destructive.** |

The project is always given on the command line (`--ref`, `--name`, `<env>`), so
the same scripts serve every project on the machine. Each project can later
add a thin wrapper that fills those in (see [Project wrappers](#project-wrappers)).

## Requirements

- Supabase CLI
- `pg_dump` and `psql`: `brew install libpq`. It is keg-only; the scripts find
  it under `/opt/homebrew/opt/libpq/bin` themselves.
- `jq`
- A personal access token (below)

No Docker, no database password, and never `supabase login`.

## Access token

The CLI's stored login (`supabase login`, kept in the macOS keychain) is
global. With projects on more than one Supabase account it can silently be the
wrong account, and running `supabase login` for one project overwrites another
project's login. So the scripts never use it and never run it. They take a
token from:

1. `--token-file <file>`, if given, or else
2. `$SUPABASE_ACCESS_TOKEN`.

With neither, they stop. Create the token while signed in to the account
that owns the project, at <https://supabase.com/dashboard/account/tokens>, and
keep it in a file only you can read:

```bash
echo 'SUPABASE_ACCESS_TOKEN=sbp_...' > .env.local && chmod 600 .env.local
```

The file can be dotenv-style (other keys are ignored; `export` and quotes are
fine) or hold just the token. It is parsed, never sourced. The scripts warn if
other users can read it.

Before doing anything else, the scripts run `supabase projects list` with the
token and refuse unless `--ref` is among the projects that account can see.
The error lists what the token *can* see, so a token from the wrong account is
easy to spot. A paused project is refused as well.

## Backup

```bash
supabase/backup-supabase.sh --ref <project-ref> --name <project> [--token-file <file>] <env>
```

For example, the Zhiming test project:

```bash
supabase/backup-supabase.sh --ref stfwyybgesmctalxmezl --name zhiming --token-file ~/development/suanming-app/.env.local test
```

- `--ref` is the 20-letter project ref (the subdomain in `SUPABASE_URL`).
- `--name` is your name for the project and `<env>` the environment label.
  Together they pick the snapshot directory. Both may use only letters,
  digits, `.`, `_` and `-`.

Each run writes a new snapshot:

```
<backup root>/db-backups/<name>/<env>/
├── 20261025T192358Z/
│   ├── roles.sql.gz      cluster roles
│   ├── schema.sql.gz     DDL for all non-internal schemas
│   ├── data.sql.gz       every row, including auth.users and storage.objects
│   ├── storage/<bucket>/ the files in every Storage bucket
│   ├── manifest.json     bucket, name, size, updated_at of every object
│   └── MANIFEST.txt      project, ref, time, tool versions, sha256 of the above
└── latest -> 20261025T192358Z
```

The backup root is `--backup-root <dir>`, else `$SUPABASE_BACKUP_ROOT`, else
`~/supabase-backups`. The scripts deliberately ignore `$BACKUP_ROOT`. That
name is generic, and one project exporting it in a shell profile (the dating
app's `~/.zshrc` does) would pull every other project's snapshots into its
folder.

Environment knobs: `KEEP` (snapshots kept per `<name>/<env>`, default 30) and
`BULK_THRESHOLD` (past this many new objects in a bucket, download the whole
bucket instead of one by one; default 50).

Storage downloads are incremental. Objects whose size and `updated_at` match
the previous snapshot are hard-linked from it, so every snapshot is still a
complete standalone copy while unchanged files share disk.

Only a finished run leaves a snapshot behind. A failure removes the
`.partial` directory. Snapshots are written owner-only (`umask 077`), because
`data.sql` holds password hashes, emails and user data: keep the root off
shared drives and out of git.

Not backed up: edge function secrets (write-only in Supabase; keep them in a
password manager) and dashboard settings (auth providers, SMTP, bucket config).

## Restore

```bash
supabase/restore-supabase.sh --ref <project-ref> --name <project> [options] <env> <snapshot>
```

`<snapshot>` is `latest`, a timestamp, or a path to a snapshot directory.
Names resolve under `<backup root>/db-backups/<name>/<source>/`. `<source>`
is `--source <env>` and defaults to `<env>`.

| Option | |
| --- | --- |
| `--rehearse` | Load the database inside a transaction, run every check, then **roll back**. Storage is only planned. The target ends up unchanged. |
| `--source <env>` | Read the snapshot from another environment, e.g. restore prod's backup into test. |
| `--skip-db` / `--skip-storage` | Restore only one half. |
| `--no-prune-storage` | Keep target objects that are not in the snapshot (default: delete them). |
| `--backup-root <dir>` | As for backup. |
| `--yes` | Skip the confirmation prompt, for unattended runs. |

```bash
# Prove a snapshot restores cleanly, changing nothing:
supabase/restore-supabase.sh --ref stfwyybgesmctalxmezl --name zhiming --token-file ~/development/suanming-app/.env.local --rehearse test latest

# Check prod's latest backup by restoring it into the test project:
supabase/restore-supabase.sh --ref <test-ref> --name zhiming --token-file <file> --source prod test latest
```

**This overwrites data.** Every table in the snapshot is truncated and
reloaded. Storage objects missing from the snapshot are deleted unless you
pass `--no-prune-storage`. There is no undo, so take a fresh backup first if
the current state matters. Before anything is written, the script prints a
summary (target, snapshot, tables and rows, Storage plan) and asks you to
**type the target's project ref**. That holds for every environment, because
`<env>` is only a label and cannot say which project is prod.

How the restore works:

- **Database.** One transaction with `ON_ERROR_STOP`, so it is all or
  nothing. As `postgres` with `session_replication_role = replica`, so
  triggers and FKs do not fire and load order does not matter. Before
  `COMMIT`, every table's row count is checked against the snapshot. Any
  difference rolls the whole load back.
- **Storage** goes through the Storage API, which owns `storage.objects`, so
  the `storage` schema is left out of the SQL load.
- **Schema is not restored.** Deploy the project's migrations to the target
  first. The script refuses if any table the snapshot has data for, or any
  bucket it has files for, is missing.
- `TRUNCATE … CASCADE` also empties tables that are *not* in the snapshot but
  reference ones that are. Those tables are listed in the summary. If any of
  them is in the `storage` schema the script refuses, since that would orphan
  the stored files. Tables unrelated to the snapshot are left alone.

## Safety checks

| Check | Where |
| --- | --- |
| Token only from `--token-file` / `SUPABASE_ACCESS_TOKEN`; never `supabase login` or the stored login | both |
| Token's account must see `--ref`, and the project must be active | both, before anything else |
| CLI runs against a private link in a fresh temp directory, deleted on exit | both |
| `<name>/<env>` is tied to the ref of its latest snapshot; a different `--ref` is refused | both |
| `auth.users` must be in the dump; every object must be on disk where the manifest says | backup |
| Snapshot checksums must verify | restore |
| Missing tables or buckets on the target → refuse | restore |
| Type the project ref to confirm | restore |
| Row counts verified inside the transaction | restore |

About the temp-directory link: `supabase storage` (and `supabase db dump
--linked`) only act on a *linked* project, and a link is one shared file,
`supabase/.temp/project-ref` in a checkout. The scripts never read or write a
checkout's link. Each run does `supabase link` in its own `mktemp -d`
directory and points every CLI call there with `--workdir`. So a deploy or a
second backup running at the same time cannot repoint it, and running a
backup does not change what your project checkout is linked to.

## Project wrappers

A project wrapper only needs to supply the arguments. For example, a
`scripts/backup-supabase.sh` in a project that keeps its URL in
`dart-defines.<env>.json` could look like this. It is a sketch for later; no
wrapper has been added to any project yet:

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ENV="${1:?usage: $0 test|prod}"
REF=$(sed -n 's|.*"SUPABASE_URL": *"https://\([a-z0-9]*\)\.supabase\.co".*|\1|p' "dart-defines.$ENV.json")
exec ~/development/scripts-tools/supabase/backup-supabase.sh \
    --ref "$REF" --name zhiming --token-file .env.local "$ENV"
```

A wrapper is also the place for project-specific guards, such as a list of
refs from another account that the project must never touch, and for a
`--backup-root` if that project's snapshots belong somewhere else.

Snapshots from the dating app's old scripts (`<root>/db-backups/<env>/<stamp>/`)
have the same contents and restore with these scripts by path. To get them
under the new layout, move `<env>/` to `<name>/<env>/`.
