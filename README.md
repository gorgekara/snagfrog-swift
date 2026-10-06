# SnagReporter for macOS

Let people report bugs from your Mac app to [SnagFrog](https://snagfrog.com). One call uploads
your logs (files, or the app's entries in the unified log), standard diagnostics and a snapshot
of the key window, then opens your app's report page in the browser. The reporter sees what's attached and can opt out before sending.

## Install

In Xcode, choose **File → Add Package Dependencies…** and enter:

```
https://github.com/gorgekara/snagfrog-swift
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/gorgekara/snagfrog-swift", from: "0.3.0")
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

## No log file? Attach the unified log

If your app logs with `Logger` or `os_log` and keeps no log file, ask for the unified log
instead (0.3.0 or later). Nobody has to run `log show` or a sysdiagnose:

```swift
NSApp.helpMenu?.addItem(snag.menuItem(unifiedLog: .app))

// …or from your own UI, with or without log files:
Task { await snag.report(unifiedLog: .app) }
```

`.app` takes what your app logged in the last 15 minutes under its bundle identifier
(`com.acme.app`, and children such as `com.acme.app.network`), plus entries with no subsystem,
which is how `Logger()` writes. To choose:

```swift
let log = SnagReporter.UnifiedLog(
    subsystems: ["com.acme.core", "com.acme.sync"],  // instead of the bundle identifier
    last: 60 * 60,                                     // seconds to go back
    includesUnlabeled: false                           // leave out entries with no subsystem
)
Task { await snag.report(unifiedLog: log) }
```

It arrives as `unified-log.log`, one entry per line, newest last:

```
2026-10-06 14:03:21.118+0200 info   [com.acme.app:sync] Sync started
2026-10-06 14:03:22.431+0200 error  [com.acme.app:network] Request failed: 503
```

What to know:

- It is off unless you ask for it.
- macOS only lets an app read its own entries since it was launched. Other apps are never read,
  and neither is an earlier launch: after a crash, the log of the run that crashed is not
  available this way. A log file is, so keep one if you need that.
- Values appear as `<private>`, as they do in Console, unless your code marked them
  `privacy: .public`. Interpolated strings are private by default, so mark the ones worth
  reading in a report. An entry that is nothing but `<private>` is left out, and that includes
  every `NSLog` message: macOS hides their text.
- Debug entries are not kept by macOS, so they are not there to send.
- Reading takes about a second. It runs off the main thread while the progress panel shows.
- It works in the App Sandbox.

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
- With `unifiedLog:`, your app's recent entries in the unified log, up to the same 512 KB. Over
  that, the oldest entries are left out and the first line says how many.
- Diagnostics: app version and build, macOS version, model, architecture, locale and memory.
  Add your own with `extraDiagnostics:`.
- The app's newest crash report (`.ips`) from the last 7 days, if there is one.
- A JPEG of the key window (`includeWindowSnapshot: false` to skip it).

If the upload fails, the report page still opens, with the diagnostics in the URL.

The public key is publishable: all it can do is create capture sessions for that app. You can
rotate it from the dashboard.

## License

MIT
