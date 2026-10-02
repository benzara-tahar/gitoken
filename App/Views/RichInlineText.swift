import AppKit
import GitokenCore
import SwiftUI

/// A run of inlines as one wrapping `Text`: styled text, links, mentions, references, emoji, and inline images
/// (`Text(Image)` once loaded, an alt-text chip until then).
struct RichInlineText: View {
    let inlines: [RichInline]
    let style: RichStyleContext
    var weight: Font.Weight = .regular
    var alignment: TextAlignment = .leading
    @State private var loaded: [URL: NSImage] = [:]

    var body: some View {
        let images = inlines.compactMap { inline -> RichImage? in
            if case .image(let image) = inline { return image }
            return nil
        }
        text
            .font(.system(size: style.size, weight: weight))
            .lineSpacing(2)
            .multilineTextAlignment(alignment)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.openURL, OpenURLAction { url in
                NSWorkspace.shared.open(url)
                return .handled
            })
            .task(id: images.map { "\($0.url.absoluteString)|\(style.dark)" }) {
                for image in images where loaded[image.url] == nil {
                    if RichImageLoader.shared.cached(image, dark: style.dark) != nil { continue }
                    if let result = await RichImageLoader.shared.load(image, dark: style.dark) {
                        loaded[image.url] = result
                    }
                }
            }
    }

    private var text: Text {
        var result = Text(verbatim: "")
        for inline in inlines {
            result = Text("\(result)\(piece(inline))")
        }
        return result
    }

    private func piece(_ inline: RichInline) -> Text {
        let theme = style.theme
        switch inline {
        case .text(let string, let traits):
            return Text(attributed(string, traits))
        case .link(let string, let url, let traits):
            var s = attributed(string, traits)
            s.link = url
            s.foregroundColor = theme.accent
            return Text(s)
        case .mention(let login, let url):
            var s = AttributedString("@\(login)")
            s.font = .system(size: style.size, weight: .semibold)
            s.foregroundColor = theme.accent
            if login.caseInsensitiveCompare(style.viewer ?? "") == .orderedSame {
                s.backgroundColor = theme.accent.opacity(0.15)
            }
            s.link = url ?? URL(string: "https://github.com/\(login)")
            return Text(s)
        case .reference(let string, let url):
            var s = AttributedString(string)
            s.foregroundColor = theme.accent
            s.link = url
            return Text(s)
        case .emoji(let string):
            return Text(verbatim: string)
        case .lineBreak:
            return Text(verbatim: "\n")
        case .image(let image):
            return imageText(image)
        }
    }

    private func attributed(_ string: String, _ traits: RichStyle) -> AttributedString {
        let code = traits.contains(.code)
        // Word joiners keep short code spans like `?q=` on one line; long spans may still wrap.
        let body = code && string.count <= 32 ? string.map(String.init).joined(separator: "\u{2060}") : string
        var s = AttributedString(code ? "\u{2009}\u{2060}\(body)\u{2060}\u{2009}" : body)
        var font = Font.system(
            size: code ? style.size - 1.5 : style.size, weight: traits.contains(.bold) ? .semibold : weight,
            design: code ? .monospaced : .default)
        if traits.contains(.italic) { font = font.italic() }
        s.font = font
        if code { s.backgroundColor = style.theme.chipBackground }
        if traits.contains(.strikethrough) { s.strikethroughStyle = .single }
        return s
    }

    private func imageText(_ image: RichImage) -> Text {
        guard let nsImage = loaded[image.url] ?? RichImageLoader.shared.cached(image, dark: style.dark) else {
            var chip = AttributedString("\u{2009}\(image.alt.isEmpty ? "image" : image.alt)\u{2009}")
            chip.font = .system(size: style.size - 2.5, weight: .medium)
            chip.foregroundColor = .secondary
            chip.backgroundColor = style.theme.chipBackground
            if let link = image.link { chip.link = link }
            return Text(chip)
        }
        let size = displaySize(image, natural: nsImage.size)
        let sized = nsImage.copy() as! NSImage
        sized.size = size
        // Center tall images on the text's x-height rather than sitting them on the baseline.
        let offset = -max(0, size.height - style.size * 0.75) / 2
        return Text(Image(nsImage: sized)).baselineOffset(offset)
    }

    private func displaySize(_ image: RichImage, natural: CGSize) -> CGSize {
        let ratio = natural.height > 0 ? natural.width / natural.height : 1
        switch (image.width, image.height) {
        case (let w?, let h?): return CGSize(width: w, height: h)
        case (let w?, nil): return CGSize(width: w, height: w / ratio)
        case (nil, let h?): return CGSize(width: h * ratio, height: h)
        case (nil, nil):
            let height = min(natural.height, style.size * 1.6)
            return CGSize(width: height * ratio, height: height)
        }
    }
}
