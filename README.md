# Codex Usage Status

English | [简体中文](README.zh-CN.md)

A native macOS menu bar utility that reads data from the local `codex app-server` and displays:

- Remaining capacity in the 5-hour and 7-day windows
- Time until each window resets
- Available reset credits, shown only when the count is greater than zero

The app is read-only. It does not consume reset credits or directly read or record Codex authentication files.

## Requirements

- macOS 13 or later
- Codex CLI installed and signed in with a ChatGPT account

Regular users do not need Xcode. Xcode is only required for development or building the app from source.

The app automatically checks these common Codex CLI locations:

```text
/opt/homebrew/bin/codex
/usr/local/bin/codex
```

You can also select the `codex` executable manually from the app popover.

## Download and install

1. Download the latest `CodexUsageStatus-<version>-macos-universal.zip` from the project releases page.
2. Double-click the ZIP file to extract `CodexUsageStatus.app`.
3. Drag `CodexUsageStatus.app` into the Applications folder.
4. Open `CodexUsageStatus` from Applications.
5. Look for the usage display on the right side of the macOS menu bar.

This is a menu bar app. It does not open a normal window or show an icon in the Dock.

A release signed and notarized by Apple can be opened normally. If you received an ad-hoc signed development build, right-click the app in Finder, choose **Open**, and confirm **Open** again. Only do this for packages from a source you trust.

## First-time setup

### 1. Check the Codex CLI

Open Terminal and run:

```bash
codex --version
```

If a version number appears, the Codex CLI is installed. If Terminal reports `command not found` and Node.js with npm is already installed, use the official installation command:

```bash
npm install --global @openai/codex
```

Sign in with your ChatGPT account:

```bash
codex login
```

Complete the browser sign-in flow, then verify the session:

```bash
codex login status
```

Codex Usage Status reuses the Codex CLI session. You do not need to enter an API key in the app.

> The current version supports Codex signed in with a ChatGPT account. API key and Amazon Bedrock authentication cannot provide the account usage shown by this app.

### 2. Read the menu bar display

The menu bar uses two rows on a translucent glass-like background with a subtle border. Both windows are shown by default. Light appearance uses dark glyphs; dark appearance uses white glyphs and a dimmer glass tint:

- The clock icon identifies the remaining percentage in the 5-hour window. Its second row shows the local 24-hour reset time, such as `18:00`; a next-day reset is marked `明 01:00`.
- The calendar icon identifies the remaining percentage in the weekly window. Its second row shows the reset date as `MM.dd`, such as `11.08`.
- The card icon identifies available reset credits, with **重置卡** on its second row. The **显示重置卡次数** toggle defaults to on. This group is hidden when disabled, zero, or unavailable; the details popover still shows the count.
- `…` means loading. `--%` / `--` means the quota or reset time is unavailable. **待重置** means the reset time has been reached and a backend update is pending. The other window remains visible.

Use **显示模式** (Display mode) to choose **5 小时** (5 hours), **一周** (weekly), or **全部** (both). Changes apply immediately and persist across launches. Hover over the status item for complete reset dates. Date labels and countdowns in the details table update locally once per minute.

### 3. View details

Click the usage display in the menu bar to open the details popover. It includes:

- A compact Window / Remaining / Reset table with percentages, progress bars, and reset countdowns for both windows
- Exact reset dates in countdown tooltips
- Available reset credits
- Last update in the footer, with the next refresh time in its tooltip

Use the refresh button in the upper-right corner to fetch fresh data immediately.

### 4. Configure automatic refresh

Choose one of the available intervals in the **Automatic refresh** section:

- 5 minutes
- 10 minutes, the default
- 30 minutes
- 1 hour

The selection is saved automatically. The app also reconciles usage after the Mac wakes from sleep and when a quota reset is reached.

### 5. Launch at login

After moving the app into Applications, enable **Launch at login** in the details popover. If macOS asks for approval, open:

```text
System Settings → General → Login Items & Extensions
```

### 6. Quit the app

Click the usage display in the menu bar, then click **Quit** at the bottom of the popover.


## Troubleshooting

### “Codex CLI not found”

Run `codex --version` in Terminal first. If Terminal can find it but the app cannot:

1. Open the app popover.
2. Click the gear in the lower-right corner to expand **Codex CLI** settings.
3. Click **Choose…**.
4. Select the actual `codex` executable.

Common locations:

```text
/opt/homebrew/bin/codex
/usr/local/bin/codex
```

### “Sign in with a ChatGPT account first”

Run:

```bash
codex login
```

After signing in, return to the app and click the refresh button.

### Nothing appears in the menu bar

- Open Activity Monitor and search for `CodexUsageStatus` to confirm that it is running.
- If the menu bar is full, quit some other menu bar utilities.
- Remember that this app does not appear in the Dock.

### Usage does not change

- Click the refresh button in the details popover.
- Check that the Codex CLI is still signed in.
- Check whether automatic refresh is set to 1 hour.
- When existing data becomes stale, the app retries with bounded delays of 1, 2, 5, 10, and 30 seconds.

### Launch at login does not work

Confirm that the app is in the Applications folder, then turn **Launch at login** off and on again. If it still fails, check **System Settings → General → Login Items & Extensions** for a pending approval.

## Build and test

Development requires Xcode 26 because the project uses Swift 6. Regular users do not need to run these commands.

```bash
xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  test
```

To run the optional integration test against the locally installed Codex CLI:

```bash
xcodebuild \
  -project CodexUsageStatus.xcodeproj \
  -scheme CodexUsageStatus \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/codex-usage-status-derived \
  CODE_SIGNING_ALLOWED=NO \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) CODEX_INTEGRATION_TESTS' \
  -only-testing:CodexUsageStatusTests/ProtocolDecodingTests/testLiveCodexAppServerWhenEnabled \
  test
```

To use **Launch at login** in a local build, build with **Sign to Run Locally**, move the app into `/Applications`, and then enable the setting.

## Create a release package

Run:

```bash
./scripts/package-release.sh
```

The script creates a Release build and writes these files to `dist/`:

```text
CodexUsageStatus.app
CodexUsageStatus-0.1.0-macos-universal.zip
CodexUsageStatus-0.1.0-macos-universal.zip.sha256
```

The ZIP supports both Apple silicon and Intel Macs. Without a distribution certificate, the script uses an ad-hoc signature. This is suitable for local testing or trusted distribution, but macOS will show a security warning on first launch.

For public distribution, sign with a Developer ID Application certificate and submit the app to Apple for notarization:

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Your Name (TEAMID)" \
NOTARYTOOL_PROFILE="codex-usage-status-notary" \
./scripts/package-release.sh
```

`NOTARYTOOL_PROFILE` is the profile name previously stored in Keychain with `xcrun notarytool store-credentials`. After signing and notarization, upload the ZIP and `.sha256` file to the project releases page. Users can then install the app without Xcode.

## Refresh behavior

- Available intervals are 5 minutes, 10 minutes, 30 minutes, and 1 hour; the default is 10 minutes.
- Reset countdowns in the details table update locally once per minute without making a network request.
- A manual refresh recalculates the next scheduled refresh.
- The app reconciles usage when either window resets or after waking from sleep with stale data.
- `account/rateLimits/updated` notifications merge usage fields locally and do not bypass the selected polling interval.
