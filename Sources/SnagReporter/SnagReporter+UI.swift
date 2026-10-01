#if canImport(AppKit)
import AppKit

extension SnagReporter {
    /// The Snag app icon (the frog), for menus, buttons and about boxes.
    ///
    /// As a Swift package it comes from the package's resources. If you vendor these files into
    /// an app instead, add `SnagIcon.png` to the app's asset catalog as an image set named "SnagIcon".
    public static var icon: NSImage {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "SnagIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        #else
        if let image = NSImage(named: "SnagIcon") {
            return image
        }
        #endif
        return NSImage(size: NSSize(width: 16, height: 16))
    }

    /// A ready-made “Report an Issue…” menu item with the Snag icon. Add it to your Help menu:
    ///
    /// ```swift
    /// NSApp.helpMenu?.addItem(snag.menuItem(logFiles: { [logFileURL] }))
    /// ```
    ///
    /// - Parameter logFiles: evaluated when the item is chosen, so it can return the current logs.
    @MainActor
    public func menuItem(
        title: String = "Report an Issue…",
        logFiles: @escaping @MainActor () -> [URL] = { [] }
    ) -> NSMenuItem {
        let target = SnagMenuTarget(reporter: self, logFiles: logFiles)
        let item = NSMenuItem(title: title, action: #selector(SnagMenuTarget.report(_:)), keyEquivalent: "")
        item.target = target
        // NSMenuItem.target is weak; the item keeps its target alive this way.
        item.representedObject = target
        item.image = Self.icon(size: 16)
        return item
    }

    /// The icon resized for a given point size (the image keeps its full resolution).
    public static func icon(size: CGFloat) -> NSImage {
        let image = icon.copy() as! NSImage
        image.size = NSSize(width: size, height: size)
        return image
    }
}

@MainActor
final class SnagMenuTarget: NSObject {
    let reporter: SnagReporter
    let logFiles: @MainActor () -> [URL]

    init(reporter: SnagReporter, logFiles: @escaping @MainActor () -> [URL]) {
        self.reporter = reporter
        self.logFiles = logFiles
    }

    @objc func report(_ sender: Any?) {
        let files = logFiles()
        Task { await reporter.report(logFiles: files) }
    }
}

/// A small floating panel with the Snag icon and a spinner, shown while logs upload.
@MainActor
final class SnagProgressPanel {
    private let panel: NSPanel

    private init(panel: NSPanel) {
        self.panel = panel
    }

    static func show(message: String = "Preparing your report…") -> SnagProgressPanel {
        let size = NSSize(width: 280, height: 64)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]

        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 14
        background.layer?.masksToBounds = true

        let icon = NSImageView(image: SnagReporter.icon(size: 36))
        icon.frame = NSRect(x: 14, y: 14, width: 36, height: 36)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.frame = NSRect(x: 60, y: 22, width: 180, height: 20)

        let spinner = NSProgressIndicator(frame: NSRect(x: size.width - 34, y: 24, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        background.addSubview(icon)
        background.addSubview(label)
        background.addSubview(spinner)
        panel.contentView = background

        // Centre over the app's window if there is one, otherwise over the main screen.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            let frame = window.frame
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        return SnagProgressPanel(panel: panel)
    }

    func close() {
        panel.orderOut(nil)
        panel.close()
    }
}
#endif
