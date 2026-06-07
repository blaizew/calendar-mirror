# calendar-mirror

Mirrors your personal calendar's busy time onto a work calendar, so colleagues can see when
you're actually free and book around it. They never see what your personal events are, only
that you're busy.

It runs itself on a `launchd` timer (every minute by default, configurable). Nothing runs at
sync time except a small Python script (stdlib only) driving the
[`gws`](https://github.com/googleworkspace/cli) Google Workspace CLI.

## The problem it solves

You work somewhere part-time, or across a few orgs. Colleagues need to book time on your work
calendar, which means knowing when you're already busy on your *personal* calendar. Sharing
your personal calendar with every colleague isn't something you want to do, and you definitely
don't want them reading your personal events.

## How it works

- An intermediary Google account gets **free/busy-only** access to your personal calendar (a
  one-way share). It can see *when* you're busy, never *what*.
- `gws` is authenticated as that intermediary account. Each run reads merged busy ranges from
  the personal calendar (`freebusy.query`) for a rolling window (default 30 days) and reconciles
  a set of generic block events (default title "Personal") on the intermediary's *own* calendar.
  Each block invites your work calendar.
- Your work calendar has "automatically add invitations" turned on, so the blocks show up there
  silently. Colleagues see "Personal" busy blocks and nothing else.
- The script never reads the work calendar. It only pushes invitations outward.

### Declarative reconciliation (why it's simple and spam-free)

Every run makes the mirror's set of busy intervals *equal* the source's set:

```
source = busy intervals from freebusy        # what's true now
mirror = my existing block events            # what I've already placed
create  source - mirror     # missing  -> add
delete  mirror - source     # stale    -> remove
# intersection: left untouched
```

There's no change-detection. A moved event is just delete-old plus create-new. When nothing
changed, both diffs are empty and the run writes nothing, so a fast cadence creates no churn.
Every write uses `sendUpdates=none`, so even on a real change, no invite/update/cancel emails go
out.

## Privacy & safety

- Colleagues see only generic blocks. Merged ranges hide how many meetings you have and where
  they start and end.
- The script is blind to the work calendar. It's invite-only and never reads it.
- Dry-run by default. It writes nothing unless you pass `--apply`.
- It only ever creates or deletes events that carry *both* the configured title *and* a private
  tag (`extendedProperties.private.<tag_key> == <tag_value>`). Nothing else on the calendar can
  be touched.
- If the source read fails or comes back empty, it does nothing. It won't wipe your blocks
  because of a momentary read hiccup.

## Setup

New here? Follow **[INSTRUCTIONS.md](INSTRUCTIONS.md)** for the full step-by-step, including the
Google Cloud OAuth setup (project, consent screen, scopes, client). That's the part with the
most moving pieces. The summary below is just the shape of it.

1. **Create an intermediary Google account** and share your personal calendar with it at "See
   only free/busy" permission.
2. **Install and authenticate [`gws`](https://github.com/googleworkspace/cli)** as that
   intermediary account, with the `calendar` scope. (OAuth steps are in
   [INSTRUCTIONS.md](INSTRUCTIONS.md).)
3. **Turn on auto-add** on your work calendar: Settings → Event settings → "Add invitations to
   my calendar: From everyone". Without this the blocks won't appear.
4. **Configure:**
   ```bash
   cp config.sample.json config.json     # config.json is gitignored
   # edit config.json: set source_calendar (personal) and attendee_calendar (work),
   # and gws_path if gws isn't on your PATH.
   ```

`config.json` keys (only `source_calendar` and `attendee_calendar` are required):

| key | default | meaning |
|---|---|---|
| `source_calendar` | — | personal calendar id (free/busy source) |
| `attendee_calendar` | — | work calendar id (invited to each block) |
| `gws_path` | `gws` | path to the `gws` binary (default assumes it's on `PATH`) |
| `mirror_calendar` | `primary` | which of the intermediary's calendars holds the blocks |
| `event_name` | `Personal` | block title colleagues will see |
| `interval_seconds` | `60` | how often the launchd job runs (applied by `install.sh`) |
| `window_days` | `30` | rolling look-ahead window |
| `prune_past_blocks` | `false` | when `true`, also delete blocks dated before today so the past calendar stays uncluttered (only forward-looking blocks remain). When `false`, past blocks are left untouched. |
| `tag_key` / `tag_value` | `mirror` / `personal-availability` | private tag used to identify our blocks |

## Usage

```bash
# Dry-run: print the plan, write nothing (default)
python3 mirror.py

# Apply: create/delete blocks for real
python3 mirror.py --apply
```

Logging is changelog-only. A run that finds nothing changed writes nothing. `sync.log` records
only real creates, deletes, and aborts, so it stays a clean history of actual edits.

## Scheduling (macOS launchd)

The scheduler is a **LaunchAgent** (user session, `~/Library/LaunchAgents/`), not a system
daemon, which is what lets it read the `gws` OAuth token from your login keychain. Once
installed it auto-starts at every login; you never start it by hand. It runs only while you're
logged into your Mac, so it won't run with the laptop shut down or logged out.

```bash
./install.sh      # renders the plist (interval from config.json) and loads it
./uninstall.sh    # stops and removes it (leaves existing blocks on the calendar)
```

- **Change cadence:** edit `interval_seconds` in `config.json`, then re-run `./install.sh`.
- **Teardown:** `./uninstall.sh`. To also remove the blocks it made, delete every event with the
  configured `event_name` plus private tag on the intermediary's calendar.

## Menu-bar status app (optional, macOS)

A small AppKit menu-bar indicator (`menubar/`) shows the sync job's health at a glance. No
third-party software, no Dock icon. `install.sh` builds it (`swift build -c release`) and
registers it as its own auto-starting, keep-alive LaunchAgent (`com.calendar-mirror.menubar`).

- 🟢 Healthy: last successful run within ~3× the interval
- 🟡 Stale: no recent run (Mac was asleep, or the sync job is stopped)
- 🔴 Error: last run aborted (e.g. token expired), or the sync job isn't scheduled

The dropdown shows last-sync-ago and blocks mirrored, with Sync now, Open logs, and Quit. It's a
read-only viewer: it reads `state.json` (a heartbeat `mirror.py` overwrites every run) plus
`launchctl` status, and never touches the calendar itself. Needs a Swift toolchain (Xcode or
Command Line Tools). `uninstall.sh` removes it along with the sync job.

## Troubleshooting

- **Blocks not appearing on the work calendar:** check that auto-add invitations is enabled
  there. The script can't verify this, since it never reads that calendar.
- **launchd run does nothing, or a keychain prompt appears:** the first scheduled run may pop a
  macOS *"gws wants to use the login keychain"* dialog. Click **Always Allow** once. If it keeps
  failing, run `mirror.py --apply` manually to seed keychain access, then check `sync.log` and
  `launchd.err.log`.
- **`ABORT: source read failed`:** the freebusy read failed (token expired or network), and it
  correctly made no changes. Check `gws auth status`.
- **Stray `download.html`:** `gws` writes a file for empty/204 responses (like deletes) to its
  working directory. The script runs `gws` with cwd pinned to the project folder, so that file
  lands here (gitignored) instead of failing under launchd (whose cwd is `/`). Note: `gws`
  rejects `--output` paths outside the cwd, so redirecting to `/dev/null` does not work;
  controlling cwd is the fix.

## Files

- `mirror.py`: the reconciler (dry-run by default; `--apply` to write).
- `config.sample.json`: copy to `config.json` (gitignored) and fill in.
- `install.sh` / `uninstall.sh`: register or remove the launchd jobs (sync + menu-bar; both auto-start at login).
- `calendar-mirror.plist.template`: sync LaunchAgent template (`__DIR__` / `__PYTHON__` / `__INTERVAL__`).
- `com.calendar-mirror.menubar.plist.template`: menu-bar app LaunchAgent template.
- `menubar/`: Swift package for the optional menu-bar status app.

## License

MIT
