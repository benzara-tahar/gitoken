import SwiftUI

enum InboxArtwork: String {
    case empty = "InboxEmpty"
    case caughtUp = "InboxCaughtUp"
    case noSearchResults = "InboxNoSearchResults"
    case quiet = "InboxQuiet"
    case connectionError = "InboxConnectionError"
    case starting = "InboxStarting"
}

struct BrandLogo: View {
    var width: CGFloat = 132

    var body: some View {
        Image("GitokenLogo")
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: width, height: width / 2.75)
            .accessibilityLabel("Gitoken")
    }
}

struct InboxIllustration: View {
    let artwork: InboxArtwork
    var size: CGFloat

    init(_ artwork: InboxArtwork, size: CGFloat = 88) {
        self.artwork = artwork
        self.size = size
    }

    var body: some View {
        Image(decorative: artwork.rawValue)
            .renderingMode(.original)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
