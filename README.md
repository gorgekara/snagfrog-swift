# SnagReporter for macOS and iOS

Let people report bugs from your Mac or iOS app to [StareGlare](https://stareglare.com). One call uploads
your logs (files, or the app's entries in the unified log), standard diagnostics and a snapshot
of the key window, then opens your app's report page (in the browser on the Mac, in a Safari
sheet on iOS). The reporter sees what's attached and can opt out before sending.

## Install

In Xcode, choose **File → Add Package Dependencies…** and enter:

```
https://github.com/gorgekara/snagfrog-swift
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/gorgekara/snagfrog-swift", from: "0.6.0")
```

Requires macOS 12 or later, or iOS 15 or later. iOS setup is [below](#ios).

## Use

```swift
import SnagReporter

let snag = SnagReporter(
    appSlug: "your-app",
    publicKey: "snag_pk_…",                      // StareGlare dashboard → Apps → your app
    baseURL: URL(string: "https://stareglare.com")!
)

// Adds "Report an Issue…" with the StareGlare icon to the Help menu:
NSApp.helpMenu?.addItem(snag.menuItem(logFiles: { [logFileURL] }))

// …or trigger it from your own UI:
Task { await snag.report(logFiles: [logFileURL]) }
```

Since 0.4.0, before anything is uploaded, a review window lists what was collected: the details, and each file
with a tick box and a Show button that displays exactly the bytes that would be sent. Nothing
leaves the Mac until the person chooses Continue in Browser, unticked files are never sent, and
Cancel sends nothing (`report()` then returns nil). Pass `reviewsBeforeUpload: false` only if your
app has already shown the person what will be sent.

While the upload runs, a small panel shows "Opening the report form…" (pass `showsProgress: false`
to hide it). `SnagReporter.icon` and `SnagReporter.icon(size:)` give you the icon for your own
buttons.

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
the report as a crash in your StareGlare inbox (`includeCrashReport: false` to skip it).

To ask people right after a crash, call this once at launch:

```swift
Task { await snag.offerReportAfterCrash(logFiles: [logFileURL]) }
```

If the app crashed since the last launch, it shows "YourApp quit unexpectedly. Would you like to
send a report?" once per crash. Choosing Send Report… opens the review window with the crash log
listed; the report page opens once the person continues.

Nothing is sent on its own: the person chooses to report, and reads and approves what is attached
before it is uploaded. Apps in the
App Sandbox (Mac App Store builds) cannot read macOS crash reports, so there both features do
nothing and reports work as usual.

## Reporting errors and crashes without asking

Off unless you call it. These send to the app's **Errors** tab in StareGlare, where identical errors
are grouped and counted. Nothing is shown to the person using the app, and no name, email address
or file is sent: only the message, the stack, the app version and the macOS version.

```swift
// At launch: if the app crashed since the last check, send the exception and the crashed thread.
Task { await snag.sendCrashAutomatically() }

// Anywhere: an error you caught.
Task { try? await snag.send(error: "\(error)", context: ["screen": "export"]) }
```

Each crash is sent once, and the crash file itself is not uploaded. Use `offerReportAfterCrash`
instead when you want to ask first. Because these send data without the person doing anything,
only use them if your privacy policy says the app reports errors or crashes on its own.

## What gets sent

- The last 512 KB of each log file (`maxLogBytes`). At most 4 files go up, including the window
  snapshot, and the total stays under about 4.4 MB: the oldest logs are dropped or trimmed first.
- With `unifiedLog:`, your app's recent entries in the unified log, up to the same 512 KB. Over
  that, the oldest entries are left out and the first line says how many.
- Diagnostics: app version and build, macOS version, model, architecture, locale and memory.
  Add your own with `extraDiagnostics:`.
- The app's newest crash report (`.ips`) from the last 7 days, if there is one.
- A JPEG of the key window (`includeWindowSnapshot: false` to skip it).

In logs, crash reports and details, the person's home folder is replaced with `~`
(`/Users/ana/Library/…` becomes `~/Library/…`), so paths stay useful without naming the account.

All of it is shown in the review window first, and only what the person keeps is uploaded.
If the upload fails, the report page still opens, with the diagnostics in the URL.

The public key is publishable: all it can do is create capture sessions for that app. You can
rotate it from the dashboard.

## iOS

Since 0.6.0 the same package works in iPhone and iPad apps (iOS 15 or later). `report()` and
the error API are the same as on the Mac; what differs is set up below.

```swift
import SnagReporter

let snag = SnagReporter(appSlug: "your-app", publicKey: "snag_pk_…",
                        baseURL: URL(string: "https://stareglare.com")!)

@main
struct MyApp: App {
    init() {
        // As early as possible: records crashes so the next launch can report them.
        SnagReporter.installCrashDetection(unifiedLog: .app)
        // Optional: shaking the device opens a report.
        snag.reportsOnShake(logFiles: { [logFileURL] }, unifiedLog: .app)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // After a crash: "MyApp quit unexpectedly. Would you like to send a report?"
                .task { await snag.offerReportAfterCrash(logFiles: [logFileURL]) }
        }
    }
}

// From your own button, e.g. in Settings or a Help screen:
Button("Report an Issue") { Task { await snag.report(logFiles: [logFileURL], unifiedLog: .app) } }
```

In a UIKit app, call `installCrashDetection()` and `reportsOnShake` in
`application(_:didFinishLaunchingWithOptions:)`, and `offerReportAfterCrash` once your first
screen is showing.

**Review.** Before anything is uploaded, a sheet lists the details and each file with a switch
and a Show button, as the review window does on the Mac. Cancel sends nothing.

**Report page.** It opens in a Safari sheet over your app; the person closes it to come back.
To open Safari instead: `snag.reportPagePresentation = .browser`.

**Snapshot.** A JPEG of the key window, taken before the review sheet appears
(`includeWindowSnapshot: false` to skip it). Only your app's own window is captured: not the
keyboard, system alerts or other apps.

**Details.** App version and build, iOS (or iPadOS) version, model identifier (`iPhone15,2`),
device family, architecture, locale, memory, how much more memory the app may use, free disk,
battery level and charging, Low Power Mode, thermal state, orientation and screen size. The
device's name is never read: it is often the owner's name.

**Unified log.** `unifiedLog: .app` works as on the Mac: this launch's entries only. In the
simulator, and while Xcode is attached, iOS does not hide `<private>` values, so those entries
show their text there; on a device in use they are hidden as usual.

**Shake to report.** Off unless you call `reportsOnShake`. `SnagReporter.stopReportingOnShake()`
turns it off again. A view controller that handles shakes itself and does not call `super`
keeps them.

### Crashes on iOS

iOS does not let an app read its crash reports, so `installCrashDetection()` records crashes
itself:

- an uncaught Objective-C exception (`NSRangeException`, …): its name, reason and stack, and,
  if you pass `unifiedLog:`, the app's unified log up to the crash, since the next launch cannot
  read it;
- a fatal signal: a Swift runtime error (force-unwrapping nil, `fatalError`, an index out of
  range: `EXC_BREAKPOINT (SIGTRAP)`), a bad memory access (`SIGSEGV`, `SIGBUS`), an abort, an
  illegal instruction or an arithmetic error. Only the stack can be recorded safely here, not
  Swift's message or the log.

The record also names your binary's load address and UUID, so `atos` and your dSYM turn the
addresses into function names:
`atos -o MyApp.app.dSYM/Contents/Resources/DWARF/MyApp -l <load address> <address>`.

On the next launch only, `report()` attaches that crash (as `last-crash.crash`) and marks the
report as a crash, like a Mac crash report; `offerReportAfterCrash` asks the person first, once
per crash; and `sendCrashAutomatically()` sends the exception and stack to the Errors tab without
asking (same privacy rules as on the Mac). Crash handlers installed before yours, such as another
crash reporter, still run afterwards, and iOS still writes its own report for Xcode's Organizer.
Being ended by iOS (for memory, a watchdog timeout, or the person swiping the app away) is not a
crash and is not recorded. With the debugger attached, Xcode stops on the crash first.

## License

MIT
