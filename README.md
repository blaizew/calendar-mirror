# calendar-mirror

One-way sync of your **personal calendar's busy time → a work calendar**, so colleagues
can see your real availability and book around it — **without** ever exposing what your
personal events actually are.

It runs itself on a `launchd` timer (default: every 5 minutes). No LLM is involved at
runtime — it's a plain Python script (stdlib only) driving the
[`gws`](https://github.com/googleworkspace/cli) Google Workspace CLI.

## The problem it solves

You work somewhere part-time (or across multiple orgs). Colleagues need to book time on
your work calendar, which requires knowing when you're already busy on your **personal**
calendar. You can't — or don't want to — share your personal calendar with every colleague
individually, and you don't want them seeing what your personal events are.

## How it works

- An **intermediary Google account** is given **free/busy-only** access to your personal
  calendar (a one-way calendar share). It can see *when* you're busy, never *what*.
- `gws` is authenticated as that intermediary account. Each run reads merged busy ranges
  from the personal calendar (`freebusy.query`) for a rolling window (default 30 days) and
  reconciles a set of generic block events (default title **"Personal"**) on the
  intermediary's *own* calendar. Each block **invites your work calendar**.
- Your work calendar has **"automatically add invitations"** enabled, so the blocks appear
  silently there. Colleagues see "Personal" busy blocks — nothing more.
- The script **never reads the work calendar.** It only pushes invitations outward.

### Declarative reconciliation (why it's simple and spam-free)

Every run makes the mirror's set of busy intervals **equal** the source's set:

```
source = busy intervals from freebusy        # what's true now
mirror = my existing block events            # what I've already placed
create  source - mirror     # missing  -> add
delete  mirror - source     # stale    -> remove
# intersection: left untouched
```

There is **no change-detection**. A moved event is just `delete-old + create-new`. If
nothing changed, both diffs are empty and the run makes **zero writes** — so a frequent
cadence generates no churn. All writes use `sendUpdates=none`, so even when something
*does* change, **no invite/update/cancel emails are ever sent**.

## Privacy & safety

- Colleagues see only generic blocks; merged ranges hide meeting count and boundaries.
- The script is blind to the work calendar (invite-only; it never reads it).
- **Dry-run by default.** It writes nothing unless given `--apply`.
- It only ever creates/deletes events bearing **both** the configured title **and** a
  private tag (`extendedProperties.private.<tag_key> == <tag_value>`). It can never touch
  any other event on the calendar.
- On a **failed or empty source read it does nothing** — it never mass-deletes blocks
  because a read hiccupped.

## Setup

1. **Create an intermediary Google account** and share your personal calendar with it at
   **"See only free/busy"** permission.
2. **Install & authenticate [`gws`](https://github.com/googleworkspace/cli)** as that
   intermediary account, with the `calendar` scope.
3. On your **work** calendar, enable **Settings → Event settings → "Add invitations to my
   calendar: From everyone"** (auto-add). **Required** — without it the blocks won't appear.
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
| `tag_key` / `tag_value` | `mirror` / `personal-availability` | private tag used to identify our blocks |

## Usage

```bash
# Dry-run — print the plan, write nothing (default):
python3 mirror.py

# Apply — actually create/delete blocks:
python3 mirror.py --apply
```

Logging is **changelog-only**: a run that finds nothing changed writes nothing. `sync.log`
records only actual creates/deletes (and aborts), so it stays a clean history of real edits.

## Scheduling (macOS launchd)

A **LaunchAgent** (user session, `~/Library/LaunchAgents/`) runs `--apply` on a timer — not a
system daemon — so it can read the `gws` OAuth token from the login keychain. Once installed it
**auto-starts at every login**; you never start it manually. It runs only while you're logged
into your Mac (it can't run with the laptop shut down or logged out).

```bash
./install.sh      # renders the plist (interval from config.json) and loads it
./uninstall.sh    # stops and removes it (leaves existing blocks on the calendar)
```

- **Change cadence:** edit `interval_seconds` in `config.json`, then re-run `./install.sh`.
- **Teardown:** `./uninstall.sh`. To also remove the blocks it made, delete every event with
  the configured `event_name` + private tag on the intermediary's calendar.

## Menu-bar status app (optional, macOS)

A tiny AppKit menu-bar indicator (`menubar/`) shows the sync job's health at a glance — no
third-party software, no Dock icon. `install.sh` builds it (`swift build -c release`) and
registers it as its own auto-starting, keep-alive LaunchAgent (`com.calendar-mirror.menubar`).

- 🟢 **Healthy** — last successful run within ~3× the interval
- 🟡 **Stale** — no recent run (Mac was asleep, or the sync job is stopped)
- 🔴 **Error** — last run aborted (e.g., token expired), or the sync job isn't scheduled

The dropdown shows last-sync-ago + blocks mirrored, with **Sync now**, **Open logs**, **Quit**.
It's a read-only viewer: it reads `state.json` (a heartbeat `mirror.py` overwrites every run)
and `launchctl` status — it never touches the calendar itself. Requires a Swift toolchain
(Xcode or Command Line Tools). `uninstall.sh` removes it along with the sync job.

## Troubleshooting

- **Blocks not appearing on the work calendar:** confirm auto-add invitations is enabled
  there. The script can't verify this (it never reads that calendar).
- **launchd run does nothing / keychain prompt:** the first scheduled run may pop a macOS
  *"gws wants to use the login keychain"* dialog — click **Always Allow** once. If it keeps
  failing, run `mirror.py --apply` once manually to seed keychain access, then check
  `sync.log` and `launchd.err.log`.
- **`ABORT — source read failed`:** the freebusy read failed (token expired or network); it
  correctly made no changes. Check `gws auth status`.
- **Stray `download.html`:** `gws` writes a file for empty/204 responses (e.g. deletes) to the
  cwd; under launchd (cwd `/`) that *fails* the call. Handled here: deletes pass
  `--output /dev/null`, and the plist sets `WorkingDirectory`. If you call `gws` deletes
  yourself, do the same or run from a writable dir.

## Files

- `mirror.py` — the reconciler (dry-run by default; `--apply` to write).
- `config.sample.json` — copy to `config.json` (gitignored) and fill in.
- `install.sh` / `uninstall.sh` — register / remove the launchd jobs (sync + menu-bar; auto-start at login).
- `calendar-mirror.plist.template` — sync LaunchAgent template (`__DIR__` / `__PYTHON__` / `__INTERVAL__`).
- `com.calendar-mirror.menubar.plist.template` — menu-bar app LaunchAgent template.
- `menubar/` — Swift package for the optional menu-bar status app.

## License

MIT
