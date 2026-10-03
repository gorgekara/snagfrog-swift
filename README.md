# SnagReporter for macOS

Let people report bugs from your Mac app to [SnagFrog](https://snagfrog.com). One call uploads
your logs, standard diagnostics and a snapshot of the key window, then opens your app's report
page in the browser. The reporter sees what's attached and can opt out before sending.

## Install

In Xcode, choose **File → Add Package Dependencies…** and enter:

```
https://github.com/gorgekara/snagfrog-swift
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/gorgekara/snagfrog-swift", from: "0.2.0")
```

Requires macOS 12 or later.

## Use

```swift
import SnagReporter

let snag = SnagReporter(
    appSlug: "your-app",
    publicKey: "snag_pk_…",                      // SnagFrog dashboard → Apps → your app
    baseURL: URL(string: "https://snagfrog.com")!
)

// Adds "Report an Issue…" with the SnagFrog icon to the Help menu:
NSApp.helpMenu?.addItem(snag.menuItem(logFiles: { [logFileURL] }))

// …or trigger it from your own UI:
Task { await snag.report(logFiles: [logFileURL]) }
```

While logs upload, a small panel shows "Preparing your report…" (pass `showsProgress: false` to
hide it). `SnagReporter.icon` and `SnagReporter.icon(size:)` give you the icon for your own buttons.

## After a crash

If macOS wrote a crash report for your app in the last 7 days, `report()` attaches it and marks
the report as a crash in your SnagFrog inbox (`includeCrashReport: false` to skip it).

To ask people right after a crash, call this once at launch:

```swift
Task { await snag.offerReportAfterCrash(logFiles: [logFileURL]) }
```

If the app crashed since the last launch, it shows "YourApp quit unexpectedly. Would you like to
send a report?" once per crash, and opens the report page with the crash log attached.

Nothing is sent on its own: the person chooses to report and sees what is attached. Apps in the
App Sandbox (Mac App Store builds) cannot read macOS crash reports, so there both features do
nothing and reports work as usual.

## What gets sent

- The last 512 KB of each log file (`maxLogBytes`). At most 4 files go up, including the window
  snapshot, and the total stays under about 4.4 MB: the oldest logs are dropped or trimmed first.
- Diagnostics: app version and build, macOS version, model, architecture, locale and memory.
  Add your own with `extraDiagnostics:`.
- The app's newest crash report (`.ips`) from the last 7 days, if there is one.
- A JPEG of the key window (`includeWindowSnapshot: false` to skip it).

If the upload fails, the report page still opens, with the diagnostics in the URL.

The public key is publishable: all it can do is create capture sessions for that app. You can
rotate it from the dashboard.

## License

MIT
