#if os(iOS)
import SwiftUI
import UIKit

extension StareGlareReporter {
    /// Shows the review sheet and waits for the person. Returns the files they kept, or nil if
    /// they cancelled. With nothing on screen to present from, everything is kept, as on the Mac
    /// without a running app.
    @MainActor
    static func reviewInSheet(diagnostics: [String: String], files: [Attachment], destination: URL) async -> [Attachment]? {
        guard let presenter = topViewController() else { return files }
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? ProcessInfo.processInfo.processName
        return await withCheckedContinuation { continuation in
            var finished = false
            let view = StareGlareReviewView(
                appName: appName,
                host: destination.host ?? destination.absoluteString,
                details: reviewDetails(diagnostics),
                files: files
            ) { [weak presenter] kept in
                guard !finished else { return }
                finished = true
                // Resume once the sheet is gone, so the report page can be presented next.
                if let presenter, presenter.presentedViewController != nil {
                    presenter.dismiss(animated: true) { continuation.resume(returning: kept) }
                } else {
                    continuation.resume(returning: kept)
                }
            }
            let host = UIHostingController(rootView: view)
            // Swiping the sheet away would be an unclear answer: Cancel and Continue are the ways out.
            host.isModalInPresentation = true
            presenter.present(host, animated: true)
        }
    }
}

/// Lists what a report will carry (the details and each file, with a switch and a way to read
/// it) before anything is uploaded. The iOS counterpart of the Mac's review window.
struct StareGlareReviewView: View {
    let appName: String
    let host: String
    let details: String
    let files: [Attachment]
    let finish: ([Attachment]?) -> Void

    @State private var kept: [Bool]
    @State private var preview: Preview?

    struct Preview: Identifiable {
        let id: Int
    }

    init(appName: String, host: String, details: String, files: [Attachment], finish: @escaping ([Attachment]?) -> Void) {
        self.appName = appName
        self.host = host
        self.details = details
        self.files = files
        self.finish = finish
        _kept = State(initialValue: Array(repeating: true, count: files.count))
    }

    var body: some View {
        NavigationView {
            List {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(uiImage: StareGlareReporter.icon)
                            .resizable()
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing has been sent yet").font(.headline)
                            Text("\(appName) will send what is listed here to its developer through StareGlare (\(host)). Next, you describe the problem.")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !files.isEmpty {
                    Section(header: Text("Files"), footer: Text("Turn off anything you'd rather not send.")) {
                        ForEach(files.indices, id: \.self) { index in
                            fileRow(index)
                        }
                    }
                }
                Section(header: Text("Details")) {
                    Text(details)
                        .font(.footnote)
                        .textSelection(.enabled)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Review Your Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { finish(nil) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") {
                        finish(zip(files, kept).filter { $0.1 }.map { $0.0 })
                    }
                }
            }
            .sheet(item: $preview) { item in
                StareGlareFilePreview(file: files[item.id])
            }
        }
        .navigationViewStyle(.stack)
    }

    private func fileRow(_ index: Int) -> some View {
        let file = files[index]
        let size = ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(StareGlareReporter.reviewKind(of: file))
                Text("\(file.filename) (\(size))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button("Show") { preview = Preview(id: index) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Show \(file.filename)")
            Toggle("Send \(file.filename)", isOn: $kept[index])
                .labelsHidden()
        }
    }
}

/// Shows exactly the bytes that would be uploaded: the tail of a log, not the file on disk.
struct StareGlareFilePreview: View {
    let file: Attachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Group {
                if file.contentType.hasPrefix("image/"), let image = UIImage(data: file.data) {
                    ScrollView {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                } else {
                    StareGlareTextView(text: String(decoding: file.data, as: UTF8.self))
                }
            }
            .navigationTitle(StareGlareReporter.reviewKind(of: file))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// A read-only text view: crash records and logs run to hundreds of KB, which a UITextView lays
/// out lazily and a SwiftUI `Text` does not.
struct StareGlareTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text { view.text = text }
    }
}
#endif
