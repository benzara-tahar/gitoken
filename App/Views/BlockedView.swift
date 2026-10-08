import AppKit
import GitokenCore
import SwiftUI

/// Shown instead of the inbox while `gh` is missing, logged out, or its token is rejected.
struct BlockedView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let error: AuthError
    var width: CGFloat
    @State private var retrying = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(width: width) {
                Text("Gitoken").font(.system(size: 13.5, weight: .semibold))
            } trailing: {
                IconButton(symbol: "slider.horizontal.3", label: "Settings") { model.open(.settings) }
            }
            VStack(alignment: .leading, spacing: 12) {
                BrandLogo(width: 132)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                HStack(spacing: 10) {
                    Image(systemName: "terminal")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(theme.warn)
                        .frame(width: 36, height: 36)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(theme.warn.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Text("Gitoken uses your GitHub CLI sign-in.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                }
                Text(error.instructions)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(command)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copied = true
                    }
                    .buttonStyle(SmallButtonStyle(theme: theme, tint: theme.accent))
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(theme.codeBackground))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(theme.hairline, lineWidth: 0.5))
                Text("Gitoken does not run these commands or require a separate token.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    PillButton(title: retrying ? "Checking…" : "Retry", symbol: "arrow.clockwise", kind: .primary) {
                        guard !retrying else { return }
                        retrying = true
                        Task {
                            await model.store.refresh()
                            retrying = false
                        }
                    }
                    .disabled(retrying)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .frame(width: width)
    }

    private var title: String {
        switch error {
        case .ghNotInstalled: "Install the GitHub CLI"
        case .notLoggedIn: "Sign in to GitHub"
        case .tokenRejected: "GitHub rejected the token"
        }
    }

    private var command: String {
        switch error {
        case .ghNotInstalled: "brew install gh && gh auth login"
        case .notLoggedIn, .tokenRejected: "gh auth login"
        }
    }

    private var detail: String? {
        switch error {
        case .ghNotInstalled(let searched): "Looked in \(searched.joined(separator: ", "))"
        case .notLoggedIn(let detail): detail.isEmpty ? nil : detail
        case .tokenRejected(let status, let scopes): "HTTP \(status)\(scopes.map { " · scopes: \($0)" } ?? "")"
        }
    }
}

/// Shown while the store connects for the first time.
struct StartingView: View {
    var width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            SurfaceHeader(width: width) {
                Text("Inbox").font(.system(size: 13.5, weight: .semibold))
            } trailing: {
                EmptyView()
            }
            VStack(spacing: 10) {
                InboxIllustration(.starting, size: 88)
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connecting to GitHub…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 20)
        }
        .frame(width: width)
    }
}
