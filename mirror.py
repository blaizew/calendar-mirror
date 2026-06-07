#!/usr/bin/env python3
"""
calendar-mirror — one-way sync of a personal calendar's busy time → a work calendar.

Reads merged free/busy from a SOURCE calendar (via an intermediary Google account that
has free/busy access to it) and reconciles a set of generic block events on that
intermediary account's own calendar, each inviting the WORK calendar. If the work
calendar auto-adds invitations, the blocks appear silently there so colleagues see true
availability — without exposing any event details.

Declarative reconciliation: every run makes the mirror's set of busy intervals EQUAL the
source's set. No change-detection; a "moved" event is just delete-old + create-new.
Idempotent and crash-safe (state lives in the calendar itself, identified by title + an
invisible private tag).

Safety:
  - DRY-RUN by default. Pass --apply to actually write.
  - Only ever creates/deletes events bearing BOTH the configured title AND the private
    tag. Never touches any other event.
  - On a failed/empty source read, does NOTHING (never mass-deletes on a hiccup).
  - All writes use sendUpdates=none (no notification emails, ever).

Config: copy config.sample.json to config.json (gitignored) and fill in your values.
Zero third-party dependencies (stdlib only). Drives the `gws` CLI.
"""

import json
import subprocess
import sys
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
CONFIG_PATH = HERE / "config.json"
LOG_FILE = HERE / "sync.log"
STATE_FILE = HERE / "state.json"  # heartbeat: overwritten every apply run (for the menu-bar app)

DEFAULTS = {
    "gws_path": "gws",
    "mirror_calendar": "primary",
    "event_name": "Personal",
    "interval_seconds": 60,
    "window_days": 30,
    "prune_past_blocks": False,
    "tag_key": "mirror",
    "tag_value": "personal-availability",
}
REQUIRED = ["source_calendar", "attendee_calendar"]


def load_config():
    if not CONFIG_PATH.exists():
        sys.exit(f"Missing {CONFIG_PATH.name}. Copy config.sample.json to config.json and fill it in.")
    cfg = dict(DEFAULTS)
    cfg.update(json.loads(CONFIG_PATH.read_text()))
    missing = [k for k in REQUIRED if not cfg.get(k)]
    if missing:
        sys.exit(f"config.json is missing required keys: {', '.join(missing)}")
    cfg["gws_path"] = str(Path(cfg["gws_path"]).expanduser())
    # Coerce/validate numeric settings — interval_seconds is rendered into the launchd plist,
    # so a non-integer would produce a malformed plist downstream.
    for k in ("interval_seconds", "window_days"):
        try:
            cfg[k] = int(cfg[k])
        except (TypeError, ValueError):
            sys.exit(f"config.json: {k} must be an integer (got {cfg[k]!r})")
        if cfg[k] <= 0:
            sys.exit(f"config.json: {k} must be a positive integer (got {cfg[k]})")
    return cfg


CFG = load_config()


# ---- gws helpers ---------------------------------------------------------
def gws(args, body=None, params=None):
    """Run a gws calendar command, return parsed JSON stdout (or None)."""
    cmd = [CFG["gws_path"], "calendar"] + args + ["--format", "json"]
    if params is not None:
        cmd += ["--params", json.dumps(params)]
    if body is not None:
        cmd += ["--json", json.dumps(body)]
    # Run with cwd=HERE (a writable dir we own): a delete returns an empty body and gws writes a
    # stray "download.html" to its cwd. Pinning cwd here makes that land in the project dir
    # (gitignored) instead of failing under launchd, whose cwd is "/". (gws rejects --output
    # paths outside the cwd, so controlling cwd — not --output /dev/null — is the fix.)
    res = subprocess.run(cmd, capture_output=True, text=True, cwd=str(HERE))
    if res.returncode != 0:
        raise RuntimeError(f"gws failed ({res.returncode}): {res.stderr.strip() or res.stdout.strip()}")
    out = res.stdout.strip()
    return json.loads(out) if out else None


def to_epoch(rfc3339):
    """Parse an RFC3339 timestamp to an integer UTC epoch (for matching)."""
    return int(datetime.fromisoformat(rfc3339.strip().replace("Z", "+00:00")).timestamp())


# ---- Window --------------------------------------------------------------
def window():
    now_local = datetime.now().astimezone()
    start = now_local.replace(hour=0, minute=0, second=0, microsecond=0)
    end = start + timedelta(days=CFG["window_days"])
    return start.isoformat(), end.isoformat()


# ---- Source: merged busy intervals from freebusy -------------------------
def read_source(time_min, time_max):
    """Return {(epoch_start, epoch_end): (rfc_start, rfc_end)} for busy ranges.

    Raises on any error so the caller can ABORT without mutating anything.
    """
    data = gws(
        ["freebusy", "query"],
        body={"timeMin": time_min, "timeMax": time_max, "items": [{"id": CFG["source_calendar"]}]},
    )
    if not data or "calendars" not in data:
        raise RuntimeError("freebusy returned no data")
    cal = data["calendars"].get(CFG["source_calendar"])
    if cal is None:
        raise RuntimeError(f"freebusy missing calendar {CFG['source_calendar']}")
    if cal.get("errors"):
        raise RuntimeError(f"freebusy errors: {cal['errors']}")
    out = {}
    for b in cal.get("busy", []):
        out[(to_epoch(b["start"]), to_epoch(b["end"]))] = (b["start"], b["end"])
    return out


# ---- Mirror state: existing tagged block events --------------------------
def read_mirror(time_min, time_max):
    """Return {(epoch_start, epoch_end): [event_id, ...]} for our own blocks."""
    data = gws(
        ["events", "list"],
        params={
            "calendarId": CFG["mirror_calendar"],
            "privateExtendedProperty": f"{CFG['tag_key']}={CFG['tag_value']}",
            "timeMin": time_min,
            "timeMax": time_max,
            "singleEvents": "true",
            "maxResults": "2500",
            "showDeleted": "false",
        },
    )
    out = {}
    for ev in (data or {}).get("items", []):
        # Belt-and-suspenders: require BOTH the tag (already filtered) AND the title.
        if ev.get("summary") != CFG["event_name"]:
            continue
        priv = ev.get("extendedProperties", {}).get("private", {})
        if priv.get(CFG["tag_key"]) != CFG["tag_value"]:
            continue
        start = ev.get("start", {}).get("dateTime")
        end = ev.get("end", {}).get("dateTime")
        if not start or not end:
            continue
        out.setdefault((to_epoch(start), to_epoch(end)), []).append(ev["id"])
    return out


# ---- Writes --------------------------------------------------------------
def create_block(rfc_start, rfc_end):
    gws(
        ["events", "insert"],
        params={"calendarId": CFG["mirror_calendar"], "sendUpdates": "none"},
        body={
            "summary": CFG["event_name"],
            "start": {"dateTime": rfc_start},
            "end": {"dateTime": rfc_end},
            "attendees": [{"email": CFG["attendee_calendar"]}],
            "transparency": "opaque",
            "reminders": {"useDefault": False, "overrides": []},
            "extendedProperties": {"private": {CFG["tag_key"]: CFG["tag_value"]}},
        },
    )


def delete_block(event_id):
    try:
        gws(["events", "delete"],
            params={"calendarId": CFG["mirror_calendar"], "eventId": event_id, "sendUpdates": "none"})
    except RuntimeError as e:
        # Idempotent: the event may already be gone (a concurrent run deleted it, or the list
        # was stale). Treat 404/410 "not found / already deleted" as success; re-raise anything else.
        msg = str(e).lower()
        if not ("deleted" in msg or "not found" in msg or "404" in msg or "410" in msg):
            raise
    (HERE / "download.html").unlink(missing_ok=True)  # tidy up gws's empty-response artifact


# ---- Main ----------------------------------------------------------------
def log(msg):
    line = f"{datetime.now().astimezone().isoformat(timespec='seconds')}  {msg}"
    print(line)
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def write_state(status, **fields):
    """Overwrite state.json — the heartbeat the menu-bar app reads (apply runs only)."""
    data = {"last_run": datetime.now().astimezone().isoformat(timespec="seconds"),
            "interval_seconds": CFG["interval_seconds"], "status": status, **fields}
    try:
        STATE_FILE.write_text(json.dumps(data, indent=2))
    except OSError:
        pass


def main():
    if "--print-interval" in sys.argv[1:]:
        print(CFG["interval_seconds"])  # used by install.sh to render the plist StartInterval
        return
    apply = "--apply" in sys.argv[1:]
    mode = "APPLY" if apply else "DRY-RUN"
    time_min, time_max = window()

    try:
        source = read_source(time_min, time_max)
    except Exception as e:
        log(f"[{mode}] ABORT: source read failed, no changes made: {e}")
        if apply:
            write_state("abort", error=str(e))
        sys.exit(1)

    # Source covers the forward window. Mirror is normally listed over that same window, so
    # blocks on past days (below the window) are never seen and linger. With prune_past_blocks
    # on, list the mirror far back instead: those past blocks then show up in `mirror` but not in
    # `source`, so the existing diff deletes them. No separate code path.
    mirror_min = time_min
    if CFG["prune_past_blocks"]:
        mirror_min = (datetime.fromisoformat(time_min) - timedelta(days=3650)).isoformat()
    mirror = read_mirror(mirror_min, time_max)
    source_keys = set(source.keys())
    mirror_keys = set(mirror.keys())

    to_create = source_keys - mirror_keys
    to_delete = []
    for key, ids in mirror.items():
        if key not in source_keys:
            to_delete.extend(ids)        # stale block(s)
        elif len(ids) > 1:
            to_delete.extend(ids[1:])    # de-dupe accidental duplicates
    unchanged = len(source_keys & mirror_keys)

    if not to_create and not to_delete:
        if apply:
            write_state("ok", mirrored=len(source_keys), created=0, deleted=0)
        return  # in sync — log nothing; logs stay a changelog of real changes only

    log(f"[{mode}] window {time_min[:10]}..{time_max[:10]} | "
        f"source={len(source_keys)} mirror={len(mirror_keys)} | "
        f"create={len(to_create)} delete={len(to_delete)} unchanged={unchanged}")

    for key in sorted(to_create):
        rfc_start, rfc_end = source[key]
        if apply:
            create_block(rfc_start, rfc_end)
        log(f"[{mode}] {'created' if apply else 'would create'} block {rfc_start} -> {rfc_end}")

    for event_id in to_delete:
        if apply:
            delete_block(event_id)
        log(f"[{mode}] {'deleted' if apply else 'would delete'} block id={event_id}")

    log(f"[{mode}] done.")
    if apply:
        write_state("ok", mirrored=len(source_keys), created=len(to_create), deleted=len(to_delete))


if __name__ == "__main__":
    main()
