import AppKit
import GitokenCore
import UniformTypeIdentifiers

/// Pasteboard representations for PR cards (drag-out, copy) and parsing of links dropped onto the circle.
enum ShelfTransfer {
    /// "owner/repo#142 Title"
    static func linkTitle(_ pr: PullRequestStatus) -> String {
        "\(pr.ref.repo.fullName)#\(pr.ref.number) \(pr.title)"
    }

    /// "owner/repo#142 Title — https://github.com/owner/repo/pull/142"
    static func plainText(_ pr: PullRequestStatus) -> String {
        "\(linkTitle(pr)) — \(pr.ref.htmlURL.absoluteString)"
    }

    static func html(_ pr: PullRequestStatus) -> String {
        "<a href=\"\(escape(pr.ref.htmlURL.absoluteString))\">\(escape(linkTitle(pr)))</a>"
    }

    static func rtf(_ pr: PullRequestStatus) -> Data? {
        let text = NSAttributedString(string: linkTitle(pr), attributes: [
            .link: pr.ref.htmlURL,
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
        ])
        return try? text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    /// Drag-out payload: web URL, plain text, rich text and HTML links, plus the local worktree folder when one exists.
    static func itemProvider(for pr: PullRequestStatus, worktree: URL?) -> NSItemProvider {
        let provider = NSItemProvider()
        let url = pr.ref.htmlURL
        let plain = plainText(pr)
        let html = html(pr)
        let rtf = rtf(pr)
        register(provider, .url) { url.dataRepresentation }
        register(provider, .utf8PlainText) { Data(plain.utf8) }
        if let rtf { register(provider, .rtf) { rtf } }
        register(provider, .html) { Data(html.utf8) }
        if let worktree {
            register(provider, .fileURL) { worktree.dataRepresentation }
        }
        return provider
    }

    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// Type identifiers accepted by the circle's drop target.
    static let droppableTypes: [UTType] = [.url, .utf8PlainText, .plainText]

    /// First GitHub pull request link among the dropped items, accepting URL objects and plain text containing a URL.
    static func pullRequestURL(from providers: [NSItemProvider]) async -> URL? {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadURL(provider), PullRequestRef(url: url) != nil {
                return url
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let text = await loadText(provider), let url = firstPullRequestURL(in: text) {
                return url
            }
        }
        return nil
    }

    /// Scans free text ("see https://github.com/o/r/pull/87, thanks") for the first PR link.
    static func firstPullRequestURL(in text: String) -> URL? {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>\"'()[],"))
        for token in text.components(separatedBy: separators) where token.contains("github.com/") {
            let candidate = token.hasPrefix("http") ? token : "https://\(token)"
            if let url = URL(string: candidate), PullRequestRef(url: url) != nil { return url }
        }
        return nil
    }

    private static func register(_ provider: NSItemProvider, _ type: UTType, _ data: @escaping @Sendable () -> Data) {
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .all) { completion in
            completion(data(), nil)
            return nil
        }
    }

    private static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                continuation.resume(returning: (object as? NSURL) as URL?)
            }
        }
    }

    private static func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: NSString.self) { object, _ in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
