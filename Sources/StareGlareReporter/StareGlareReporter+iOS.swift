#if os(iOS)
import os
import SafariServices
import UIKit

/// Where the report page opens on iOS.
public enum ReportPagePresentation: Sendable {
    /// In a Safari sheet over the app; the person closes it to come back.
    case inApp
    /// In the Safari app.
    case browser
}

extension StareGlareReporter {
    /// The StareGlare app icon, for buttons and settings rows.
    ///
    /// As a Swift package it comes from the package's resources. If you vendor these files into
    /// an app instead, add `StareGlareIcon.png` to the app's asset catalog as an image set named "StareGlareIcon".
    public static var icon: UIImage {
        #if SWIFT_PACKAGE
        if let url = Bundle.module.url(forResource: "StareGlareIcon", withExtension: "png"),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }
        #else
        if let image = UIImage(named: "StareGlareIcon") {
            return image
        }
        #endif
        return UIImage()
    }

    /// Details that need no UI: the model identifier, free disk, memory, low power mode.
    static func mobileDiagnostics() -> [String: String] {
        var d: [String: String] = [:]
        d["device_model"] = modelIdentifier()
        #if targetEnvironment(simulator)
        d["simulator"] = "yes"
        #endif
        let home = URL(fileURLWithPath: NSHomeDirectory())
        if let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage {
            d["free_disk_gb"] = String(format: "%.1f", Double(free) / 1_000_000_000)
        }
        // How much more the app may allocate before iOS ends it for using too much memory.
        // 0 where no limit applies (the simulator): left out rather than read as "out of memory".
        let available = os_proc_available_memory()
        if available > 0 { d["memory_available_mb"] = String(available / 1_048_576) }
        d["low_power_mode"] = ProcessInfo.processInfo.isLowPowerModeEnabled ? "on" : "off"
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: d["thermal_state"] = "nominal"
        case .fair: d["thermal_state"] = "fair"
        case .serious: d["thermal_state"] = "serious"
        case .critical: d["thermal_state"] = "critical"
        @unknown default: break
        }
        return d
    }

    /// "iPhone15,2". In the simulator, the model it simulates.
    static func modelIdentifier() -> String? {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #endif
        return sysctlString("hw.machine")
    }

    /// Details that come from UIKit: system name ("iPadOS" on an iPad), device family, battery,
    /// orientation and screen. The device's name is not read: it is often the owner's name.
    @MainActor
    static func deviceDiagnostics() -> [String: String] {
        var d: [String: String] = [:]
        let device = UIDevice.current
        d["os_version"] = "\(device.systemName) \(device.systemVersion)"
        d["device_family"] = device.model

        let wasMonitoring = device.isBatteryMonitoringEnabled
        device.isBatteryMonitoringEnabled = true
        if device.batteryLevel >= 0 {
            var battery = "\(Int((device.batteryLevel * 100).rounded()))%"
            switch device.batteryState {
            case .charging: battery += ", charging"
            case .full: battery += ", full"
            case .unplugged: battery += ", unplugged"
            default: break
            }
            d["battery"] = battery
        }
        device.isBatteryMonitoringEnabled = wasMonitoring

        if let window = keyWindow() {
            if let scene = window.windowScene {
                switch scene.interfaceOrientation {
                case .portrait: d["orientation"] = "portrait"
                case .portraitUpsideDown: d["orientation"] = "portrait upside down"
                case .landscapeLeft: d["orientation"] = "landscape left"
                case .landscapeRight: d["orientation"] = "landscape right"
                default: break
                }
            }
            let screen = window.screen
            d["screen"] = "\(Int(screen.bounds.width))×\(Int(screen.bounds.height)) pt @\(Int(screen.scale))x"
        }
        return d
    }

    /// The key window of the foreground scene, or the first window of any scene.
    @MainActor
    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let ordered = scenes.filter { $0.activationState == .foregroundActive }
            + scenes.filter { $0.activationState != .foregroundActive }
        for scene in ordered {
            if let window = scene.windows.first(where: \.isKeyWindow) { return window }
        }
        return ordered.first?.windows.first
    }

    /// The view controller that is showing right now, to present from.
    @MainActor
    static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    @MainActor
    static func openReportPage(_ url: URL, presentation: ReportPagePresentation) {
        let isWeb = ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        if presentation == .inApp, isWeb, let top = topViewController() {
            let safari = SFSafariViewController(url: url)
            safari.dismissButtonStyle = .close
            top.present(safari, animated: true)
        } else {
            UIApplication.shared.open(url)
        }
    }
}

/// A small card with the StareGlare icon and a spinner over the app, shown while logs are read and
/// uploaded. The iOS counterpart of the Mac's floating panel.
@MainActor
final class StareGlareProgressPanel {
    private let view: UIView

    private init(view: UIView) {
        self.view = view
    }

    static func show(message: String = "Preparing your report…") -> StareGlareProgressPanel? {
        guard let window = StareGlareReporter.keyWindow() else { return nil }
        let card = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        card.layer.cornerRadius = 14
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isAccessibilityElement = true
        card.accessibilityLabel = message
        card.accessibilityTraits = .updatesFrequently

        let icon = UIImageView(image: StareGlareReporter.icon)
        icon.contentMode = .scaleAspectFit
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 2
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()

        let row = UIStackView(arrangedSubviews: [icon, label, spinner])
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        card.contentView.addSubview(row)
        window.addSubview(card)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),
            row.topAnchor.constraint(equalTo: card.contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor, constant: -18),
            card.centerXAnchor.constraint(equalTo: window.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: window.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualTo: window.widthAnchor, constant: -48)
        ])
        UIAccessibility.post(notification: .announcement, argument: message)
        return StareGlareProgressPanel(view: card)
    }

    func close() {
        view.removeFromSuperview()
    }
}

// MARK: - Shake to report

extension StareGlareReporter {
    /// Opt in to reporting by shaking the device: a shake starts `report()` as if the person had
    /// chosen "Report an Issue". Off unless you call this; call it once, e.g. at launch.
    ///
    /// ```swift
    /// stareGlare.reportsOnShake(logFiles: { [logFileURL] }, unifiedLog: .app)
    /// ```
    ///
    /// It listens on every window, through the responder chain: a view controller that handles
    /// shakes itself without calling `super` keeps them.
    @MainActor
    public func reportsOnShake(
        logFiles: @escaping @MainActor () -> [URL] = { [] },
        unifiedLog: UnifiedLog? = nil
    ) {
        StareGlareShake.installOnce()
        StareGlareShake.handler = {
            // One report at a time, and not while the report page is up.
            guard !StareGlareShake.isReporting, !(Self.topViewController() is SFSafariViewController) else { return }
            StareGlareShake.isReporting = true
            Task { @MainActor in
                await self.report(logFiles: logFiles(), unifiedLog: unifiedLog)
                StareGlareShake.isReporting = false
            }
        }
    }

    /// Stops reporting on shake.
    @MainActor
    public static func stopReportingOnShake() {
        StareGlareShake.handler = nil
    }
}

@MainActor
enum StareGlareShake {
    static var handler: (@MainActor () -> Void)?
    static var isReporting = false
    private static var installed = false

    /// Gives `UIWindow` its own `motionEnded(_:with:)` that calls the original and then the
    /// handler. Added to `UIWindow` only, so other responders are untouched.
    static func installOnce() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = UIWindow.self
        let originalSelector = #selector(UIResponder.motionEnded(_:with:))
        let stareGlareSelector = #selector(UIWindow.stareGlare_motionEnded(_:with:))
        guard let original = class_getInstanceMethod(cls, originalSelector),
              let stareGlare = class_getInstanceMethod(cls, stareGlareSelector) else { return }
        if class_addMethod(cls, originalSelector, method_getImplementation(stareGlare), method_getTypeEncoding(stareGlare)) {
            // UIWindow inherited the method: it now has its own, and stareGlare_ calls the inherited one.
            class_replaceMethod(cls, stareGlareSelector, method_getImplementation(original), method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, stareGlare)
        }
    }
}

extension UIWindow {
    @objc func stareGlare_motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        // After the swap this calls the original implementation.
        stareGlare_motionEnded(motion, with: event)
        if motion == .motionShake { StareGlareShake.handler?() }
    }
}
#endif
