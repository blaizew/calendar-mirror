# Setup Instructions

Full setup for `calendar-mirror`, from zero to a running sync. The fiddly part is the Google
Cloud OAuth setup (Steps 2 to 4). Take it slowly and it's fine.

## Concepts: the three accounts

- **Personal calendar** is the calendar whose *busy times* you want reflected (the source).
- **Work calendar** is where colleagues go to book you. It receives the silent "busy" blocks.
- **Intermediary account** is a *separate* Google account that acts as the bridge. It gets
  free/busy-only access to your personal calendar, and `gws` authenticates as it. This is what
  keeps your event details private: the intermediary (and so this app) can only ever see *when*
  you're busy, never *what*.

Why an intermediary instead of your personal account directly? You want the app to fully
control *its own* calendar (to create and remove blocks) while seeing only free/busy on your
*personal* one. A dedicated account gives you that split, and Google enforces it.

---

## Step 1: Create the intermediary account and share your calendar

1. Create a new Google account (e.g. `you.agent@gmail.com`) to act as the intermediary.
2. From your **personal** Google Calendar: **Settings → Settings for my calendars → [your
   calendar] → Share with specific people** → add the intermediary account with permission
   **"See only free/busy (hide details)"**. Save.

That one-way share is what limits the app to availability-only on your personal calendar.

---

## Step 2: Google Cloud project and the Calendar API

Do all of this while signed into Google **as the intermediary account**.

1. Go to <https://console.cloud.google.com> → top project dropdown → **New Project** (name it
   e.g. `calendar-mirror`) → Create, then select it.
2. **APIs & Services → Library** → search **"Google Calendar API"** → **Enable**. That's the
   only API this app needs.

---

## Step 3: Configure the OAuth consent screen ("Google Auth Platform")

Google's newer UI calls this **"Google Auth Platform"** and splits it across the left-nav tabs.
Start from **APIs & Services → OAuth consent screen** (or "Google Auth Platform"):

1. Click **Get started** and complete the short wizard:
   - **App Information**: app name (e.g. `calendar-mirror`), user support email = the
     intermediary account.
   - **Audience**: choose **External**.
   - **Contact Information**: the intermediary account email.
   - Agree and **Create**.
2. **Data Access** tab → **Add or remove scopes** → add one scope:
   - `https://www.googleapis.com/auth/calendar` (full Calendar: it reads free/busy on the source
     and creates/deletes blocks on the intermediary's own calendar)

   Click **Update**, then **Save**.
3. **Audience** tab, two things here:
   - **Test users → Add users** → add the **intermediary account**. Required, or you'll hit an
     "Access blocked" error at login.
   - **Publishing status → Publish app** → confirm. This moves it from *Testing* to *In
     production*. It stays unverified, which is fine for personal use. Do this because in
     *Testing* mode Google expires the refresh token after 7 days, so the sync would quietly stop
     every week. The cost is a one-time "unverified app" warning at login (see Step 5).

---

## Step 4: Create the OAuth client

1. **APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. **Application type: Desktop app** → name it (e.g. `calendar-mirror-desktop`) → **Create**.
3. In the confirmation dialog, **Download JSON**. Keep this file; it's your client secret.

---

## Step 5: Install `gws` and authenticate

1. Install the official Google Workspace CLI: <https://github.com/googleworkspace/cli> (pre-built
   binary, Homebrew, or `cargo`). Verify with `gws --version`.
2. Put the client JSON where `gws` looks for it:
   ```bash
   mkdir -p ~/.config/gws
   mv ~/Downloads/client_secret_*.json ~/.config/gws/client_secret.json
   chmod 600 ~/.config/gws/client_secret.json
   ```
3. Authenticate as the intermediary account, requesting only the calendar scope:
   ```bash
   gws auth login --scopes https://www.googleapis.com/auth/calendar
   ```
   In the browser that opens:
   - Pick the **intermediary account**, not your personal one.
   - You'll see **"Google hasn't verified this app"**. Click **Advanced → Go to … (unsafe)**.
     This is expected, since the app is published but unverified.
   - **Allow** the calendar access. The terminal will report success.
4. Confirm with `gws auth status`. It should show the intermediary account and the `calendar`
   scope.

---

## Step 6: Enable auto-add on the work calendar

On the **work** calendar's account: **Google Calendar → Settings → Event settings → "Add
invitations to my calendar"** → set it to **"From everyone"** (auto-add).

This is required. It's what makes the blocks appear silently on the work calendar without invite
emails. If your work Google Workspace admin has locked this setting, the silent mirror won't
work, so talk to your admin.

---

## Step 7: Configure and run

```bash
cp config.sample.json config.json          # config.json is gitignored
# edit config.json:
#   source_calendar    = your personal calendar id (e.g. you@gmail.com)
#   attendee_calendar  = your work calendar id
#   gws_path           = path to gws if it isn't on your PATH
#   event_name / interval_seconds / window_days as desired

python3 mirror.py            # dry-run: prints the plan, writes nothing
python3 mirror.py --apply    # create the blocks once, for real

./install.sh                 # schedule it (launchd) + build/install the menu-bar app
```

See the [README](README.md) for usage, the menu-bar app, and troubleshooting.

---

## Common pitfalls

- **"Access blocked" at login:** you didn't add the intermediary account as a **Test user**
  (Step 3), or you're signing in with the wrong account.
- **Sync quietly stops after about a week:** the consent screen is still in **Testing** mode.
  Publish it (Step 3).
- **Blocks never appear on the work calendar:** auto-add invitations isn't enabled there (Step
  6). The app can't detect this, since it never reads the work calendar.
- **`gws auth status` shows the wrong account:** you authorized your personal account instead of
  the intermediary at Step 5. Run `gws auth logout` and redo Step 5.
