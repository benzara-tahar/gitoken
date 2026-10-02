import Foundation
import Synchronization

extension RichBody {
    /// The display model. GitHub's HTML when present, else the markdown converted to HTML: one parsing path.
    /// Parsed documents are memoized because SwiftUI re-evaluates bodies often.
    public var document: RichDocument {
        if let cached = documentCache.withLock({ $0[self] }) { return cached }
        let document = RichHTMLParser.parse(html ?? MarkdownHTML.render(markdown))
        documentCache.withLock { cache in
            if cache.count >= 256 { cache.removeAll(keepingCapacity: true) }
            cache[self] = document
        }
        return document
    }

    /// Text for previews and snippets: GitHub's `bodyText` when present, else the rendered document's text.
    /// Never contains tags or HTML comments.
    public var plainText: String {
        if let plain { return plain }
        return document.plainText
    }

    /// Whether the source mentions `@login` as a whole handle.
    public func mentions(_ login: String?) -> Bool {
        guard let login, !login.isEmpty else { return false }
        return ActivityAnalysis.mentions(Actor(login: login), in: markdown)
    }
}

private let documentCache = Mutex<[RichBody: RichDocument]>([:])
