import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension SnagReporter {
    /// A plain name for a file, so the person knows what each one is.
    static func reviewKind(of file: Attachment) -> String {
        let name = file.filename.lowercased()
        if name.hasSuffix(".ips") || name.hasSuffix(".crash") { return "Crash report" }
        if file.contentType.hasPrefix("image/") { return "Window snapshot" }
        return "Log"
    }

    /// "Crash report · Capta-2026-10-03.ips (212 KB)"
    static func reviewTitle(for file: Attachment) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
        return "\(reviewKind(of: file)) · \(file.filename) (\(size))"
    }

    /// The details as readable lines, in a stable order: "App version: 1.4.2".
    static func reviewDetails(_ diagnostics: [String: String]) -> String {
        diagnostics.sorted { $0.key < $1.key }.map { key, value in
            let words = key.replacingOccurrences(of: "_", with: " ")
            return "\(words.prefix(1).uppercased())\(words.dropFirst()): \(value)"
        }.joined(separator: "\n")
    }

    #if canImport(AppKit)
    /// Shows the review window and waits for the person. Returns the files they kept, or nil if
    /// they cancelled. Without a running app there is no window to show, so everything is kept.
    @MainActor
    static func reviewInWindow(diagnostics: [String: String], files: [Attachment], destination: URL) -> [Attachment]? {
        guard NSApp != nil else { return files }
        return SnagReviewWindow(diagnostics: diagnostics, files: files, destination: destination).run()
    }
    #endif
}

#if canImport(AppKit)
/// Lists what a report will carry (the details and each file, with a tick box and a way to read
/// it) before anything is uploaded.
@MainActor
final class SnagReviewWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let files: [Attachment]
    private(set) var boxes: [NSButton] = []
    private var kept: [Attachment]?

    private static let width: CGFloat = 480

    init(diagnostics: [String: String], files: [Attachment], destination: URL) {
        self.files = files
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Review Your Report"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        let host = destination.host ?? destination.absoluteString

        let title = NSTextField(labelWithString: "Nothing has been sent yet")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let intro = Self.wrapping(
            "\(appName) will send what is listed here to its developer through SnagFrog (\(host)). "
                + "Next, you describe the problem in your browser."
        )
        let heading = NSStackView(views: [title, intro])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 4
        let icon = NSImageView(image: SnagReporter.icon(size: 44))
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let header = NSStackView(views: [icon, heading])
        header.alignment = .top
        header.spacing = 12

        var rows: [NSView] = [header]
        if !files.isEmpty {
            rows.append(Self.caption("Files"))
            for (index, file) in files.enumerated() {
                let box = NSButton(checkboxWithTitle: SnagReporter.reviewTitle(for: file), target: nil, action: nil)
                box.state = .on
                box.lineBreakMode = .byTruncatingMiddle
                box.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                boxes.append(box)
                let show = NSButton(title: "Show", target: self, action: #selector(show(_:)))
                show.controlSize = .small
                show.tag = index
                show.setContentHuggingPriority(.required, for: .horizontal)
                show.setAccessibilityLabel("Show \(file.filename)")
                let row = NSStackView(views: [box, NSView(), show])
                row.spacing = 8
                rows.append(row)
            }
            rows.append(Self.wrapping("Untick anything you'd rather not send.", small: true))
        }
        rows.append(Self.caption("Details"))
        let details = Self.textScroll(SnagReporter.reviewDetails(diagnostics), monospaced: false)
        details.heightAnchor.constraint(equalToConstant: 112).isActive = true
        rows.append(details)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let proceed = NSButton(title: "Continue in Browser", target: self, action: #selector(proceed(_:)))
        proceed.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, proceed])
        buttons.spacing = 10
        rows.append(buttons)

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(16, after: header)
        stack.setCustomSpacing(16, after: details)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let inner = Self.width - 40
        for row in rows { row.widthAnchor.constraint(equalToConstant: inner).isActive = true }

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor)
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
        window.defaultButtonCell = proceed.cell as? NSButtonCell
    }

    /// Blocks until the person continues or cancels. Returns the ticked files, or nil on cancel.
    func run() -> [Attachment]? {
        // A menu-bar app is not active when its menu item is chosen.
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return kept
    }

    /// The files that are ticked right now.
    var ticked: [Attachment] {
        zip(files, boxes).filter { $0.1.state == .on }.map { $0.0 }
    }

    @objc func proceed(_ sender: Any?) {
        kept = ticked
        NSApp.stopModal()
    }

    @objc func cancel(_ sender: Any?) {
        kept = nil
        NSApp.stopModal()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel(nil)
        return false
    }

    /// Shows exactly the bytes that would be uploaded: the tail of a log, not the file on disk.
    @objc func show(_ sender: NSButton) {
        let file = files[sender.tag]
        let size = NSSize(width: 640, height: 460)
        let sheet = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheet.isReleasedWhenClosed = false

        let body: NSView
        if file.contentType.hasPrefix("image/"), let image = NSImage(data: file.data) {
            let view = NSImageView(image: image)
            view.imageScaling = .scaleProportionallyDown
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            body = view
        } else {
            body = Self.textScroll(String(decoding: file.data, as: UTF8.self), monospaced: true)
        }
        let name = NSTextField(labelWithString: SnagReporter.reviewTitle(for: file))
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let done = NSButton(title: "Done", target: self, action: #selector(closePreview(_:)))
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [name, NSView(), done])
        let stack = NSStackView(views: [body, footer])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.frame = NSRect(origin: .zero, size: size)
        stack.autoresizingMask = [.width, .height]
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.addSubview(stack)
        sheet.contentView = content
        sheet.minSize = NSSize(width: 420, height: 300)
        window.beginSheet(sheet)
    }

    @objc func closePreview(_ sender: Any?) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private static func wrapping(_ text: String, small: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: small ? 11 : 13)
        label.textColor = .secondaryLabelColor
        label.isSelectable = false
        label.preferredMaxLayoutWidth = width - (small ? 40 : 96)
        return label
    }

    private static func textScroll(_ text: String, monospaced: Bool) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = false
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = monospaced
                ? .monospacedSystemFont(ofSize: 11, weight: .regular)
                : .systemFont(ofSize: 12)
            view.textContainerInset = NSSize(width: 4, height: 6)
            // Crash reports run to megabytes; lay out only what is scrolled into view.
            view.layoutManager?.allowsNonContiguousLayout = true
            view.string = text
        }
        return scroll
    }
}
#endif
