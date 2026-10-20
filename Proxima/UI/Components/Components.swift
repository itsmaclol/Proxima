import SwiftUI

// MARK: Containers

/// A content panel. Inner tiles can use `ConcentricRectangle()` to nest corners neatly.
struct Card<Content: View, Accessory: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || !(accessory is EmptyView) {
                HStack(alignment: .firstTextBaseline) {
                    if let title {
                        Label {
                            Text(title).font(.headline)
                        } icon: {
                            if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary) }
                        }
                    }
                    Spacer(minLength: 8)
                    accessory
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: .rect(cornerRadius: Theme.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
        }
        .containerShape(.rect(cornerRadius: Theme.cardRadius))
    }
}

extension Card where Accessory == EmptyView {
    init(title: String? = nil, systemImage: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, systemImage: systemImage, content: content, accessory: { EmptyView() })
    }
}

/// Standard scrolling page body with consistent margins.
struct Page<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) { content }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1400, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
    }
}

// MARK: Status

/// Power state as shape plus color, so it reads without color too.
struct StatusGlyph: View {
    let power: PowerState
    var isTemplate = false
    var size: CGFloat = 9

    var body: some View {
        Group {
            if isTemplate {
                RoundedRectangle(cornerRadius: 2).strokeBorder(Color.purple, lineWidth: 1.5)
            } else {
                switch power {
                case .running: Circle().fill(Color.green)
                case .stopped: Circle().strokeBorder(Color.secondary, lineWidth: 1.5)
                case .paused: Capsule().fill(Color.yellow).frame(width: size * 0.55)
                case .unknown: Image(systemName: "exclamationmark.triangle.fill").resizable().foregroundStyle(.red)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(isTemplate ? "Template" : power.label)
    }
}

struct StatusBadge: View {
    let power: PowerState
    var isTemplate = false

    var body: some View {
        let color = isTemplate ? Color.purple : Theme.color(power)
        HStack(spacing: 6) {
            StatusGlyph(power: power, isTemplate: isTemplate, size: 8)
            Text(isTemplate ? "Template" : power.label)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.14), in: .capsule)
        .foregroundStyle(power == .stopped && !isTemplate ? Color.secondary : color)
    }
}

struct Pill: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            if let systemImage { Image(systemName: systemImage) }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.13), in: .capsule)
        .foregroundStyle(color)
    }
}

struct TagChip: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Theme.tag(tag).opacity(0.18), in: .capsule)
            .foregroundStyle(Theme.tag(tag).mix(with: .primary, by: 0.35))
    }
}

struct TagRow: View {
    let tags: [String]
    var limit = 6

    var body: some View {
        // As many chips as fit, then "+N", so long tag names never push the count out of view.
        ViewThatFits(in: .horizontal) {
            ForEach(Array(stride(from: min(limit, tags.count), through: 0, by: -1)), id: \.self) { shown in
                HStack(spacing: 4) {
                    ForEach(tags.prefix(shown), id: \.self) { TagChip(tag: $0) }
                    if tags.count > shown {
                        Text("+\(tags.count - shown)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
        }
    }
}

// MARK: Metrics

/// A ring gauge with the value in the middle. Digits roll instead of jumping.
struct MetricRing: View {
    let fraction: Double
    var color: Color = .accentColor
    var lineWidth: CGFloat = 9
    var label: String?
    /// Usage turns orange and red as it fills; a ring where full is good (e.g. backup coverage) keeps its color.
    var fullIsBad = true

    var body: some View {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        let tint = fullIsBad ? Theme.usage(clamped, base: color) : color
        ZStack {
            Circle().stroke(tint.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: clamped)
                .stroke(AngularGradient(colors: [tint.opacity(0.65), tint], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * clamped)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(label ?? Format.percent(clamped))
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText(value: clamped))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(lineWidth + 2)
        }
        .animation(.smooth(duration: 0.6), value: clamped)
        .accessibilityElement()
        .accessibilityLabel(label ?? Format.percent(clamped))
    }
}

struct UsageBar: View {
    let fraction: Double
    var color: Color = .accentColor
    var height: CGFloat = 6

    var body: some View {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.usage(clamped, base: color).gradient)
                    .frame(width: max(clamped > 0 ? height : 0, proxy.size.width * clamped))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.5), value: clamped)
        .accessibilityValue(Format.percent(clamped))
    }
}

/// "CPU  ███░░  34%" — a compact labelled meter for tables and blades.
struct Meter: View {
    let title: String
    let fraction: Double
    var color: Color = .accentColor
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Text(detail ?? Format.percent(fraction))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            UsageBar(fraction: fraction, color: color, height: 5)
        }
    }
}

/// A big rounded number with a caption beneath: "12 · running".
struct StatTile: View {
    let value: String
    let caption: String
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(color)
            Text(caption).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.04), in: ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true))
    }
}

// MARK: Key/value rows

struct InfoGrid: View {
    let rows: [(String, String)]
    var monospacedValues: Set<String> = []

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    Text(row.1.isEmpty ? "–" : row.1)
                        .fontDesign(monospacedValues.contains(row.0) ? .monospaced : .default)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .font(.callout)
    }
}

// MARK: Feedback

struct ErrorBanner: View {
    let message: String
    var retry: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).textSelection(.enabled)
            Spacer()
            if let retry { Button("Try Again", action: retry) }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 12))
    }
}

/// Loading, error, empty or content — the four states every remote list has.
struct Loadable<Content: View>: View {
    let loading: Bool
    let error: String?
    var isEmpty = false
    var emptyTitle = "Nothing here"
    var emptySymbol = "tray"
    var emptyMessage: String?
    var retry: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        // Placeholders fill the space, so a page with an empty list keeps its header at the top.
        if let error {
            ContentUnavailableView {
                Label("Couldn't load this", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if let retry { Button("Try Again", action: retry) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading && isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: emptySymbol, description: emptyMessage.map { Text($0) })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            content
        }
    }
}

// MARK: Text

/// Renders the subset of Markdown people put in Proxmox notes: headings, bullets, inline styles.
struct MarkdownText: View {
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(source.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                lineView(line)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder private func lineView(_ line: String) -> some View {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Spacer().frame(height: 2)
        } else if let heading = trimmed.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
            Text(inline(String(heading.2)))
                .font(heading.1.count == 1 ? .title3.weight(.semibold) : .headline)
                .padding(.top, 4)
        } else if let bullet = trimmed.firstMatch(of: /^[-*+]\s+(.*)$/) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                Text(inline(String(bullet.1)))
            }
        } else {
            Text(inline(trimmed))
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
