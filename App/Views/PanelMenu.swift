import SwiftUI

/// A dropdown rendered inside the notch surface (never as a separate window), clamped to the surface bounds.
struct PanelMenu: Identifiable {
    enum Item {
        case label(String)
        case separator
        case action(title: String, subtitle: String?, symbol: String?, checked: Bool?, run: @MainActor () -> Void)

        static func action(
            _ title: String, subtitle: String? = nil, symbol: String? = nil, checked: Bool? = nil,
            run: @escaping @MainActor () -> Void
        ) -> Item {
            .action(title: title, subtitle: subtitle, symbol: symbol, checked: checked, run: run)
        }

        var isActionable: Bool {
            if case .action = self { return true }
            return false
        }

        func perform(dismiss: () -> Void) {
            guard case .action(_, _, _, _, let run) = self else { return }
            dismiss()
            run()
        }
    }

    let id = UUID()
    /// Identifies the button that opened it; pressing that button again closes the menu.
    var anchorID: String
    /// Anchor frame in the `PanelMenu.space` coordinate space.
    var anchor: CGRect
    var items: [Item]
    /// Opens above the anchor (controls at the bottom of the surface, like the composer), so the surface never
    /// has to grow past the screen edge to fit it.
    var opensUpward = false

    nonisolated static let space = "gitoken.surface"
}

/// Records a control's frame in the surface coordinate space so menus can anchor to it.
struct MenuAnchorReader: ViewModifier {
    @Binding var frame: CGRect

    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PanelMenu.space)) } action: { frame = $0 }
    }
}

extension View {
    func menuAnchor(_ frame: Binding<CGRect>) -> some View { modifier(MenuAnchorReader(frame: frame)) }
}

/// Overlay hosting the open menu; also reserves enough surface height for it to fit.
struct PanelMenuLayer: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    var surfaceSize: CGSize
    @State private var menuSize: CGSize = .zero

    var body: some View {
        if let menu = model.menu {
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { model.dismissMenu() }
                    .accessibilityHidden(true)
                PanelMenuView(menu: menu)
                    .onGeometryChange(for: CGSize.self) { $0.size } action: { menuSize = $0 }
                    .offset(origin(for: menu))
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
            .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .topLeading)
        }
    }

    private func origin(for menu: PanelMenu) -> CGSize {
        let w = menuSize.width, h = menuSize.height
        let x = min(max(menu.anchor.maxX - w, 8), max(8, surfaceSize.width - w - 8))
        var y = menu.opensUpward ? menu.anchor.minY - h - 6 : menu.anchor.maxY + 6
        if y + h > surfaceSize.height - 8 { y = menu.anchor.minY - h - 6 }
        y = min(max(y, 8), max(8, surfaceSize.height - h - 8))
        return CGSize(width: x, height: y)
    }
}

/// Minimum surface height required to show `menu` below its anchor without leaving the panel.
func requiredHeight(for menu: PanelMenu?) -> CGFloat {
    guard let menu, !menu.opensUpward else { return 0 }
    var h: CGFloat = 10
    for item in menu.items {
        switch item {
        case .label: h += 22
        case .separator: h += 9
        case .action: h += 28
        }
    }
    return menu.anchor.maxY + 6 + h + 10
}

private struct PanelMenuView: View {
    @Environment(NotchModel.self) private var model
    @Environment(\.theme) private var theme
    let menu: PanelMenu

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(menu.items.enumerated()), id: \.offset) { index, item in
                row(item, index: index)
            }
        }
        .padding(5)
        .frame(minWidth: 232, alignment: .leading)
        .fixedSize()
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(theme.menuBackground)
                .shadow(color: .black.opacity(0.28), radius: 18, y: 10)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private func row(_ item: PanelMenu.Item, index: Int) -> some View {
        switch item {
        case .label(let text):
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.top, 5)
                .padding(.bottom, 3)
        case .separator:
            Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 4)
        case .action(let title, let subtitle, let symbol, let checked, _):
            MenuRowButton(
                title: title, subtitle: subtitle, symbol: symbol, checked: checked,
                highlighted: model.menuHighlight == index,
                onHover: { if $0 { model.menuHighlight = index } else if model.menuHighlight == index { model.menuHighlight = nil } }
            ) {
                item.perform(dismiss: model.dismissMenu)
            }
        }
    }
}

private struct MenuRowButton: View {
    var title: String
    var subtitle: String?
    var symbol: String?
    var checked: Bool?
    var highlighted: Bool
    var onHover: (Bool) -> Void
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let symbol {
                    Image(systemName: symbol).font(.system(size: 12)).frame(width: 15).opacity(highlighted ? 1 : 0.75)
                }
                Text(title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 12)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).monospacedDigit().opacity(highlighted ? 0.85 : 0.55)
                }
                if let checked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(checked ? 1 : 0)
                }
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(highlighted ? Color.accentColor : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover(perform: onHover)
        .accessibilityAddTraits(checked == true ? .isSelected : [])
    }
}
