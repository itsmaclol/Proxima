import SwiftUI

/// A soft mesh of the state's colors fading into the window background. It sits under the
/// toolbar and, through the background extension effect, under the floating sidebar too.
struct Aura: View {
    let colors: [Color]

    var body: some View {
        let a = colors.first ?? .accentColor
        let b = colors.dropFirst().first ?? a
        MeshGradient(
            width: 3, height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.45], [0.6, 0.4], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: [
                a.opacity(0.42), b.opacity(0.34), a.opacity(0.16),
                b.opacity(0.20), a.opacity(0.14), b.opacity(0.06),
                Theme.canvas.opacity(0), Theme.canvas.opacity(0), Theme.canvas.opacity(0),
            ]
        )
        .animation(.smooth(duration: 0.8), value: colors)
    }
}

/// The page header for a guest, node, storage or the datacenter.
struct Hero<Badges: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    let colors: [Color]
    @ViewBuilder var badges: Badges
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.title2.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(title)
                        .font(.system(.largeTitle, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 8) { badges }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .background(alignment: .top) {
            Aura(colors: colors)
                .frame(height: 260)
                .ignoresSafeArea(edges: .top)
                .backgroundExtensionEffect()
                .allowsHitTesting(false)
        }
    }
}

extension Hero where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, colors: [Color], @ViewBuilder badges: () -> Badges) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, colors: colors, badges: badges, trailing: { EmptyView() })
    }
}

/// One tab of a page's section switcher.
struct PageTab: Identifiable, Hashable {
    let id: String
    let title: String
    let symbol: String
}

/// A Liquid Glass track holding the page's sections; the selected pill slides between them.
/// Content switches instantly — only the pill moves — and labels fold into icons when space runs short.
struct TabStrip: View {
    let tabs: [PageTab]
    @Binding var selection: String
    @Namespace private var namespace

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(compact: false)
            track(compact: true)
            ScrollView(.horizontal) { track(compact: true) }.scrollIndicators(.never)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            if !tabs.contains(where: { $0.id == selection }), let first = tabs.first { selection = first.id }
        }
        #if DEBUG
        // Visual checks: PROXIMA_DEBUG_TAB (or the navigator file) opens that tab once it exists (some pages add tabs as data loads).
        .task(id: "\(tabs.map(\.id))-\(DebugNavigator.shared.sequence)") {
            let wanted = DebugNavigator.shared.sequence > 0 ? DebugNavigator.shared.tab
                : (debugTabApplied ? nil : ProcessInfo.processInfo.environment["PROXIMA_DEBUG_TAB"])
            if let wanted, tabs.contains(where: { $0.id == wanted }) {
                selection = wanted
                debugTabApplied = true
            }
        }
        #endif
    }

    #if DEBUG
    @State private var debugTabApplied = false
    #endif

    private func track(compact: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = tab.id == selection
                Button { selection = tab.id } label: {
                    Group {
                        if compact && !selected {
                            Image(systemName: tab.symbol).frame(width: 22)
                        } else {
                            Label(tab.title, systemImage: tab.symbol)
                        }
                    }
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .padding(.horizontal, compact ? 9 : 12)
                    .padding(.vertical, 6)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .foregroundStyle(selected ? .primary : .secondary)
                .help(tab.title)
                .background {
                    if selected {
                        Capsule()
                            .fill(Color.primary.opacity(0.1))
                            .matchedGeometryEffect(id: "selection", in: namespace)
                    }
                }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: selection)
    }
}

#if DEBUG
/// Carries the tab a visual-check script asked for to whichever tab strip shows next.
@Observable final class DebugNavigator {
    static let shared = DebugNavigator()
    private(set) var tab: String?
    private(set) var sequence = 0

    func go(tab: String?) {
        self.tab = tab
        sequence += 1
    }
}
#endif

