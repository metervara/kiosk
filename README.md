# Kiosk

A lightweight macOS menu-bar app for websites at museums, conferences, and public spaces. Built with Swift, AppKit, and an embedded WebKit browser. No Chrome installation or Xcode project required.

**macOS 13 or later · Apple Silicon and Intel · `xyz.metervara.kiosk`**

## When to use Kiosk

A good fit for museum displays, conference demos, and website-based exhibits on a dedicated Mac, where someone can set up and maintain the installation.

### What it CAN do

- Present your website full screen and keep it in front.
- Keep visitors on approved websites and block common ways of leaving the experience.
- Recover from common browser failures and app crashes, and return home between visitors.
- Keep the Mac awake and reduce distractions with optional Do Not Disturb automation.
- Let you test in a normal window and protect the operator exit with a passcode.

### What it CAN'T do

- Completely lock down a Mac or protect it against deliberate tampering.
- Guarantee that every macOS notification, system dialog, or gesture is blocked.
- Fix a broken website, restore a lost internet connection, or guarantee uninterrupted operation.
- Run Chrome extensions or support every website feature; camera, microphone, and downloads are blocked.
- Remotely manage a fleet of Macs or distribute website updates.

If your installation requires strict device security, central management, or Chrome-specific features, Kiosk alone is not enough.

## Run an exhibition

1. Enter the website address. Addresses without a scheme use HTTPS; local sites can use explicit `http://`.
2. Turn **Use full screen for kiosk sessions** on for the exhibition, or off to keep using other apps. Select the exhibit display for full-screen mode.
3. Add any extra hosts needed by redirects or login, including `www` subdomains.
4. Review **Operation** and **Mac setup**.
5. Use **Preview** to check the website, then **Start kiosk** when ready.

**Exit: Control + Option + Command + K (`⌃⌥⌘K`).** A saved passcode is required to end a kiosk session. Without a passcode, the shortcut exits immediately. Preview always exits without a passcode. The menu-bar menu also provides an end-session action when accessible.

Preview always uses a normal window and never starts the app watchdog or keeps the Mac awake. A windowed kiosk session retains browser restrictions, recovery, the optional app watchdog, and sleep prevention, while allowing you to switch apps. Full-screen sessions additionally hide system controls and restore focus to the website.

## Operation settings

| Setting | What it does |
| --- | --- |
| Return home after inactivity | Resets to the home page after no visitor interaction for this many seconds. `0` disables it. |
| Scheduled refresh | Resets the website at this interval in minutes, even during use. `0` disables it. |
| Page load timeout | Retries pages that take longer than this many seconds to load. Accepts 15–300 seconds. Browser crash recovery stays on. |
| Relaunch Kiosk if the app crashes or freezes | Runs a separate watchdog during kiosk sessions to restart the app if it exits unexpectedly or stops responding. |
| Start the website when Kiosk opens | Starts the saved website immediately instead of showing settings. |
| Open Kiosk at login | Launches the menu-bar app when this macOS account signs in. Enable automatic website startup as well to resume an exhibition after login. |
| Operator passcode | Requires a passcode when ending a kiosk session. Leave the field empty to keep the saved passcode. |

Move the app into `/Applications` before enabling launch at login. Automatic startup does not bypass macOS login or FileVault.

With **Remember website cookies and login** off, a new session discards its cookies and storage on idle resets, scheduled refreshes, recovery, and fresh starts. Turning it on uses this app’s persistent WebKit store, including in Preview. It does not share Safari’s profile.

## Do Not Disturb and Mac setup

**Mac setup** has separate **Turn DND On** and **Turn DND Off** buttons. Set them up once in Apple’s Shortcuts app:

1. Create **Turn DND On** with a **Set Focus** action that turns **Do Not Disturb** on until turned off.
2. Create **Turn DND Off** with a **Set Focus** action that turns **Do Not Disturb** off.
3. Run each once in Shortcuts to complete any prompts. Use only the Focus action, with no input requests or dialogs.
4. Return to Kiosk and click **Refresh status**. The app detects the shortcut names and enables the corresponding buttons.

The buttons run `/usr/bin/shortcuts run` without blocking the app. Errors and timeouts are reported. A completed shortcut is not a live reading of Focus: check **Control Center → Focus** to confirm. This uses Apple’s supported [Shortcuts command-line interface](https://support.apple.com/guide/shortcuts-mac/run-shortcuts-from-the-command-line-apd455c82f02/mac).

To automate this, enable **Turn DND on for kiosk sessions and off when they end** in Mac setup, then save. It defaults to off. Both shortcuts must exist: Kiosk waits for **Turn DND On** before opening a full-screen or windowed session, and runs **Turn DND Off** after you end it. Preview never changes Focus. Page reloads and inactivity resets do not toggle it.

Ending a session turns DND off even if you had enabled it beforehand; the app does not restore a previous Focus mode. If startup fails after attempting DND On, Kiosk attempts DND Off and reports any cleanup failure. A force quit, crash, or power loss cannot run the closing shortcut; watchdog recovery reapplies DND On when it resumes the session.

**Focus options** opens the settings for allowed people, apps, and interruptions; it is not the on/off control. Review those exceptions for the exhibition account.

The checklist also links to **Hot Corners**, **system gestures**, and **screen locking**, with specific instructions for each. Their statuses are saved confirmations from you, clearly labeled **Confirmed by you**, rather than live system readings. Recheck them after changing macOS settings.

## Browser behavior and limits

Kiosk blocks Escape, common browser commands, back/forward swipes, pinch zoom, context menus, and drag/drop. Normal typing and scrolling work. Allowed links requesting a new window open in the same view. Downloads, file pickers, external-app links, camera/microphone requests, and JavaScript dialogs are suppressed. Test the actual website in Preview, especially sign-in, video, and features written for Chromium.

Host restrictions apply to the main document, not embedded resources or frames. HTTPS certificates undergo normal validation. Renderer monitoring detects a stalled browser, not a website whose logic is broken but still responds to JavaScript.

Full-screen mode uses AppKit’s kiosk presentation controls. It cannot guarantee complete device lockdown: macOS gestures, system overlays, security prompts, hardware keys, and physical power actions can still interrupt an exhibition. Use a dedicated macOS account and review Mac setup. Kiosk prevents idle display and system sleep during a session, but cannot override explicit locking, sleep, or a closed laptop lid.

The operator passcode protects the in-app exit, not the macOS account. A user with filesystem or process-control access can still change settings or stop the app.

## Build

Install Apple’s Command Line Tools if needed (`xcode-select --install`), then:

```sh
./build.sh
open dist/Kiosk.app
```

The script runs `swift build -c release`, assembles the `.app`, copies its assets, and ad-hoc signs it. `./build.sh --universal` builds for both Apple Silicon and Intel. There is no `.xcodeproj`, storyboard, or asset catalog.

The assets stay editable:

| File | Purpose |
| --- | --- |
| `Assets/Info.plist` | Bundle settings and version; copied verbatim |
| `Assets/AppIcon.icns` | Bundled icon; copied verbatim |
| `Assets/AppIcon.svg` / `Assets/AppIcon.png` | Editable icon artwork |
| `Assets/MenuBarIcon.svg` / `Assets/MenuBarIconTemplate.png` | Matching menu-bar symbol; PNG is copied verbatim and adapts to the menu-bar appearance |
| `Model/Defaults.plist` | Initial kiosk settings |
| `Model/Kiosk.js` | In-page interaction guards |

After exporting a new square PNG, optionally run `./scripts/update-icon.sh Assets/AppIcon.png` to update the `.icns`. You can also replace the `.icns` directly. The build script never generates plists or icons. Saved settings override the bundled defaults.

## Release

Update the version and build number in `Assets/Info.plist`, or use:

```sh
./scripts/version.sh 1.1.0 2
```

Commit the release changes, then tag and push:

```sh
git tag -a v1.1.0 -m "Kiosk 1.1.0"
git push origin v1.1.0
```

GitHub Actions tests both architectures, builds the universal app, and publishes a GitHub Release with the app ZIP, checksum, and release notes. The tag must match the plist version. Tags such as `v1.1.0-rc.1` produce prereleases.

Local builds and GitHub releases always use **ad-hoc signing**. No Apple Developer account, certificates, signing secrets, or notarization setup is needed. The app is not notarized, so macOS may block a downloaded copy until manually approved. `./scripts/package-release.sh` creates the same download locally without publishing it.

Users download the app ZIP, unzip it, and move `Kiosk.app` into `/Applications`. Install updates between exhibitions; saved settings remain. There is no in-app updater.

## Development

```sh
swift test
python3 -m unittest discover -s Tests/DistributionTests
python3 Tests/Fixtures/server.py
```

Open `http://127.0.0.1:8765` in **Preview** to exercise navigation restrictions, retries, and browser recovery in a normal window. Focus tests use fake commands and never change the Mac’s Focus setting.

To open settings without automatic startup after stopping an existing session:

```sh
open -a /Applications/Kiosk.app --args --settings
```
