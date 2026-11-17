import SwiftUI

/// State of the preview popup.
@MainActor
final class PopupModel: ObservableObject {
    enum Status: Equatable { case working, streaming, done, failed(String) }

    @Published var original: String
    @Published var result = ""
    @Published var mode: Mode = .auto
    @Published var status: Status = .working
    @Published var showDiff: Bool
    let context: AppContext
    let replaceTitle: String

    init(original: String, context: AppContext, showDiff: Bool, replaceTitle: String) {
        self.original = original
        self.context = context
        self.showDiff = showDiff
        self.replaceTitle = replaceTitle
    }

    /// What `auto` resolved to in this app, for the chip label.
    var detected: Mode? { context.suggestedMode }

    var effectiveMode: Mode { mode == .auto ? (detected ?? .auto) : mode }

    var diff: [TextDiff.Op]? {
        guard status == .done else { return nil }
        return TextDiff.diff(original, result)
    }

    var direction: LayoutDirection { TextDirection.of(result.isEmpty ? original : result) }
}

enum TextDirection {
    /// Direction of the first strong character (Hebrew/Arabic → RTL).
    static func of(_ s: String) -> LayoutDirection {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0590...0x08FF, 0xFB1D...0xFDFF, 0xFE70...0xFEFF: return .rightToLeft
            case 0x41...0x5A, 0x61...0x7A, 0x00C0...0x024F, 0x0370...0x052F: return .leftToRight
            default: continue
            }
        }
        return .leftToRight
    }
}

struct PopupView: View {
    @ObservedObject var model: PopupModel
    var onAction: (PopupAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            modeBar
            content
            footer
        }
        .padding(14)
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.separator.opacity(0.6)))
        .environment(\.layoutDirection, AppLayout.direction == .rightToLeft ? .rightToLeft : .leftToRight)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "drop.fill").foregroundStyle(.tint)
            Text("Inkfix").font(.headline)
            Text(model.context.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            statusView
        }
    }

    @ViewBuilder private var statusView: some View {
        switch model.status {
        case .working, .streaming:
            ProgressView().controlSize(.small)
        case .done:
            if let diff = model.diff, TextDiff.changeCount(diff) == 0 {
                Label(L("No changes needed"), systemImage: "checkmark.seal").font(.caption).foregroundStyle(.green)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var modeBar: some View {
        FlowLayout(spacing: 6) {
            Group {
                ForEach(Array(Mode.pickable.enumerated()), id: \.element) { index, mode in
                    Button { onAction(.mode(mode)) } label: {
                        HStack(spacing: 4) {
                            Text("\(index + 1)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                            Image(systemName: mode.symbol)
                            Text(chipTitle(mode))
                        }
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(model.mode == mode ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.06),
                                    in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func chipTitle(_ mode: Mode) -> String {
        guard mode == .auto, let detected = model.detected else { return mode.title }
        return mode.title + ": " + detected.title
    }

    @ViewBuilder private var content: some View {
        ScrollView {
            Group {
                switch model.status {
                case .failed(let message):
                    Text(message).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .working where model.result.isEmpty:
                    Text(model.original).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                default:
                    resultText.textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .environment(\.layoutDirection, model.direction)
            .font(.system(size: 14))
            .lineSpacing(3)
            .padding(10)
        }
        .frame(minHeight: 70, maxHeight: 340)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var resultText: Text {
        guard model.showDiff, let diff = model.diff else { return Text(model.result) }
        var out = AttributedString()
        for op in diff {
            switch op {
            case .same(let s):
                out += AttributedString(s)
            case .added(let s):
                var a = AttributedString(s)
                a.backgroundColor = Color.green.opacity(0.25)
                out += a
            case .removed(let s):
                var a = AttributedString(s)
                a.strikethroughStyle = .single
                a.foregroundColor = Color.red.opacity(0.8)
                out += a
            }
        }
        return Text(out)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("↩", model.replaceTitle, .replace).foregroundStyle(.primary)
            hint("⌘C", L("Copy"), .copy)
            hint("⌘D", model.showDiff ? L("Hide changes") : L("Show changes"), .toggleDiff)
            hint("⌘R", L("Retry"), .retry)
            Spacer()
            hint("esc", L("Cancel"), .cancel)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func hint(_ key: String, _ title: String, _ action: PopupAction) -> some View {
        Button { onAction(action) } label: {
            HStack(spacing: 4) {
                Text(key).font(.caption.monospaced())
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Text(title)
            }
        }
        .buttonStyle(.plain)
    }
}

enum PopupAction: Equatable {
    case replace, copy, cancel, retry, toggleDiff, mode(Mode)
}

/// Wraps chips onto as many rows as needed (leading-aligned, mirrors in RTL).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, sub) in subviews.enumerated() {
            let size = sub.sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].indices.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
