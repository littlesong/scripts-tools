# Supabase backup and restore

Two project-agnostic scripts that take a full local snapshot of a Supabase
project (database + Storage files) and put one back:

| Script | What it does |
| --- | --- |
| [`backup-supabase.sh`](backup-supabase.sh) | Dumps roles, schema and data, downloads every Storage object, writes checksums. |
| [`restore-supabase.sh`](restore-supabase.sh) | Reloads a snapshot's data and Storage objects into a project. **Destructive.** |

Day to day you name the project and environment and nothing else:

```bash
supabase/backup-supabase.sh zhiming test
supabase/restore-supabase.sh --rehearse zhiming test latest
```

The ref and backup location come from [`projects.ini`](projects.ini). The
access token comes from `tokens.ini`, which is not in git. Both files sit next
to the scripts. Everything can also be given on the command line instead (the
[long form](#long-form)).

## Requirements

- Supabase CLI
- `pg_dump` and `psql`: `brew install libpq`. It is keg-only; the scripts find
  it under `/opt/homebrew/opt/libpq/bin` themselves.
- `jq`
- A personal access token per Supabase account (below)

No Docker, no database password, and never `supabase login`.

## projects.ini

Refs and backup locations. No secrets, so it is committed:

```ini
[global]
backup_root = ~/supabase-backups/db-backups

[zhiming]
test = stfwyybgesmctalxmezl
prod = ydqcnjernsmdqhnulhbt

[dating]
backup_dir = ~/Library/CloudStorage/OneDrive-Personal/.../we-dating-app/db-backups
test = ...
prod = ...
```

| Setting | Meaning |
| --- | --- |
| `[global] backup_root` | Parent of all project folders: snapshots go to `<root>/<project>/<env>/`. |
| `[<project>] <env> = <ref>` | One line per environment. `<env>` is the label you type, e.g. `test` or `prod`. |
| `[<project>] backup_dir` | This project's own folder: snapshots go to `<backup_dir>/<env>/`, ignoring `backup_root`. |
| `[<project>] account` | The `tokens.ini` section holding the token. Defaults to the project's name; set it when two projects share an account. |

Paths are absolute or start with `~/`. The file is checked as a whole on every
run, so a mistake anywhere stops the scripts instead of quietly falling back to
a default. A misspelled `[global]` section shows up as a project with a
`backup_root` setting, which is an error. So is any project setting that isn't
`account`, `backup_dir` or a valid 20-letter ref. A ref is not a secret (it is
in every app build), but keep the file in a private repo all the same.

## tokens.ini

The short form's access tokens, one section per Supabase **account**:

```ini
[zhiming]
token = sbp_...
```

Set it up from the template:

```bash
cd supabase && cp tokens.example.ini tokens.ini && chmod 600 tokens.ini
```

Create each token at <https://supabase.com/dashboard/account/tokens> while
signed in to the account that owns the projects. A token is account-wide: it
can manage **every** project in that account, prod included. It must never
reach git, private repo or not. `tokens.ini` is in `.gitignore`. Before
reading it, the scripts also refuse if:

- anyone but you can read it (`chmod 600`),
- git tracks it (it was force-added or committed: remove it and rotate every
  token in it), or
- git would not ignore it (the ignore rule was lost).

Why not `supabase login`? The CLI's stored login (in the macOS keychain) is
global. With projects on more than one account it can silently be the wrong
one, and logging in for one project overwrites another's login. So the scripts
never use it and never run it.

Whatever the token's source, the scripts first run `supabase projects list`
with it and refuse unless the target ref is among the projects that account
can see. The error lists what the token *can* see, so a token from the wrong
account is easy to spot. A paused project is refused as well.

## Backup

```bash
supabase/backup-supabase.sh [--token-file <file>] [--backup-root <dir>] <project> <env>
```

Each run writes a new snapshot:

```
<backup dir>/<env>/
├── 20261025T192358Z/
│   ├── roles.sql.gz      cluster roles
│   ├── schema.sql.gz     DDL for all non-internal schemas
│   ├── data.sql.gz       every row, including auth.users and storage.objects
│   ├── storage/<bucket>/ the files in every Storage bucket
│   ├── manifest.json     bucket, name, size, updated_at of every object
│   └── MANIFEST.txt      project, ref, time, tool versions, sha256 of the above
└── latest -> 20261025T192358Z
```

`<backup dir>` is the first of these that applies:

| Source | `<backup dir>` |
| --- | --- |
| `--backup-root <dir>` | `<dir>/<project>` |
| `projects.ini [<project>] backup_dir` | that directory |
| `projects.ini [global] backup_root` | `<root>/<project>` |
| otherwise | `~/supabase-backups/db-backups/<project>` |

The scripts deliberately ignore `$BACKUP_ROOT`. That name is generic, and one
project exporting it in a shell profile (the dating app's `~/.zshrc` does)
would pull every other project's snapshots into its folder.

Environment knobs: `KEEP` (snapshots kept per `<project>/<env>`, default 30)
and `BULK_THRESHOLD` (past this many new objects in a bucket, download the
whole bucket instead of one by one; default 50).

Storage downloads are incremental. Objects whose size and `updated_at` match
the previous snapshot are hard-linked from it, so every snapshot is still a
complete standalone copy while unchanged files share disk.

Each snapshot is built in a private staging directory under `$TMPDIR` and
moved into place only when complete, so a failed run leaves nothing behind
(see [Cloud-synced backup folders](#cloud-synced-backup-folders)). `latest` is a
convenience symlink; on the command line, `latest` means the newest snapshot
directory, whatever the symlink says. Snapshots are written owner-only (`umask 077`), because
`data.sql` holds password hashes, emails and user data: keep the backup
location out of git, and think twice before pointing it at a shared drive.

Not backed up: edge function secrets (write-only in Supabase; keep them in a
password manager) and dashboard settings (auth providers, SMTP, bucket config).

## Cloud-synced backup folders

`backup_root` and `backup_dir` can point into OneDrive or iCloud Drive
(anything under `~/Library/CloudStorage`). macOS runs those folders through
File Provider, and a long write into one can fail with `Operation timed out`
while the sync client is busy. So the backup never writes into the folder
while it dumps. It stages locally and moves the finished snapshot in with one
rename (instant: `$TMPDIR` is on the same volume). If even that move fails,
the complete snapshot stays in the staging directory, and the error prints
the `mv` command that finishes the job.

Worth knowing when the folder is synced:

- **Symlinks don't survive OneDrive.** `latest` can come back as a plain file.
  The scripts don't rely on it.
- **Hard links only save space on this Mac.** OneDrive uploads every
  snapshot's Storage files in full, so cloud usage grows with `KEEP` × your
  Storage size.
- **Keep the folder on the device.** Turn on *Always keep on this device* for
  it. Otherwise OneDrive may make old snapshots online-only, and a restore (or
  the next backup reusing their files) has to download them first.
- **The cloud provider stores your users' data.** Snapshots hold password
  hashes, emails and user data, and a synced folder uploads them.
- **Staging needs room for one full snapshot** on the `$TMPDIR` volume. Set
  `TMPDIR` to stage somewhere else.

## Restore

```bash
supabase/restore-supabase.sh [options] <project> <env> <snapshot>
```

`<snapshot>` is `latest`, a timestamp, or a path to a snapshot directory.
Names resolve under `<backup dir>/<source>/`, where `<source>` is `--source
<env>` and defaults to `<env>`.

| Option | |
| --- | --- |
| `--rehearse` | Load the database inside a transaction, run every check, then **roll back**. Storage is only planned. The target ends up unchanged. |
| `--source <env>` | Read the snapshot from another environment, e.g. restore prod's backup into test. |
| `--skip-db` / `--skip-storage` | Restore only one half. |
| `--no-prune-storage` | Keep target objects that are not in the snapshot (default: delete them). |
| `--token-file <file>`, `--backup-root <dir>` | As for backup. |
| `--yes` | Skip the confirmation prompt, for unattended runs. |

```bash
# Prove a snapshot restores cleanly, changing nothing:
supabase/restore-supabase.sh --rehearse zhiming test latest

# Check prod's latest backup by restoring it into the test project:
supabase/restore-supabase.sh --source prod zhiming test latest
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

## Long form

Every setting can be given on the command line instead, for a project that is
not in `projects.ini` or when you want to override it:

```bash
supabase/backup-supabase.sh --ref <project-ref> --name <project> [--token-file <file>] [--backup-root <dir>] <env>
supabase/restore-supabase.sh --ref <project-ref> --name <project> [options] <env> <snapshot>
```

- `--ref` is the 20-letter project ref (the subdomain in `SUPABASE_URL`).
- `--name` is your name for the project. It picks the backup location just
  as `<project>` does in the short form.
- The token comes from `--token-file`, else `$SUPABASE_ACCESS_TOKEN`. The long
  form does not read `tokens.ini`.
- If `projects.ini` lists `--name`/`<env>` with a different ref, the scripts
  refuse: one of the two is wrong.

The short form takes `--token-file` too, and then uses it instead of
`tokens.ini`. It ignores `$SUPABASE_ACCESS_TOKEN`: a token exported for one
account would otherwise override `tokens.ini` for every project. A token file
can be dotenv-style (`SUPABASE_ACCESS_TOKEN=sbp_...`; other keys are ignored,
`export` and quotes are fine) or hold just the token. It is parsed, never
sourced.

## Safety checks

| Check | Where |
| --- | --- |
| `projects.ini` and `tokens.ini` parsed strictly; any unknown setting or malformed ref is an error | both |
| Long-form `--ref` must match `projects.ini` when it lists that project/env | both |
| Token only from `--token-file`, `tokens.ini` or `SUPABASE_ACCESS_TOKEN`; never `supabase login` or the stored login | both |
| `tokens.ini` must be `chmod 600`, untracked and git-ignored | both |
| Token's account must see the ref, and the project must be active | both, before anything else |
| CLI runs against a private link in a fresh temp directory, deleted on exit | both |
| `<project>/<env>` is tied to the ref of its latest snapshot; a different ref is refused | both |
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

## Old snapshots

Snapshots from the dating app's old scripts have the same contents. The
`[dating]` entry's `backup_dir` points at the folder those scripts wrote to,
so its `<env>/` series simply continues. Any snapshot can also be restored by
path.
