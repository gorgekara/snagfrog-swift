import Foundation

extension SnagReporter {
    /// The person's real home folder ("/Users/ana"), also inside the App Sandbox, where
    /// `NSHomeDirectory()` is the app's container.
    static var homeFolder: String {
        if let dir = getpwuid(getuid())?.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// Replaces the home folder with `~`, so a path keeps its meaning without naming the account:
    /// "/Users/ana/Library/Logs/app.log" becomes "~/Library/Logs/app.log". Also matches the
    /// escaped form macOS crash reports use ("\/Users\/ana"). A longer name that merely starts
    /// the same way ("/Users/anabel") is left alone.
    static func scrubHome(_ text: String, home: String = homeFolder) -> String {
        let parts = home.split(separator: "/").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard parts.count >= 2 else { return text }
        let pattern = parts.map { #"\\?/"# + $0 }.joined() + #"(?![\w.\-])"#
        return text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
    }

    /// A text file with the home folder replaced; images and other files are returned unchanged.
    static func scrubHome(_ file: Attachment, home: String = homeFolder) -> Attachment {
        guard file.contentType.hasPrefix("text/") else { return file }
        let scrubbed = scrubHome(String(decoding: file.data, as: UTF8.self), home: home)
        return Attachment(filename: file.filename, contentType: file.contentType, data: Data(scrubbed.utf8))
    }
}
