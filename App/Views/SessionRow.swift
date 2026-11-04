import SwiftUI

/// セッション 1 行。行全体がボタン
struct SessionRow: View {
    let session: Session
    var now: Date = Date()
    var onSelect: (Session) -> Void = { _ in }

    @State private var hovering = false

    /// 許可待ちの「指示」行に使う橙系の文字色（ダークでは明るめ）
    private static let promptColor = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.7, blue: 0.3, alpha: 1)
            : NSColor(red: 0.64, green: 0.35, blue: 0.0, alpha: 1)
    })

    private var isDimmed: Bool { session.status == .idle || session.status == .empty }

    /// 改行を空白に置き換えて1行にする
    private static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    /// title が無いときは、まだ指示なしの空タブだけ専用の文言。それ以外は直近の指示、無ければ未取得
    private var displayTitle: String {
        if let title = session.title, !title.isEmpty { return Self.oneLine(title) }
        if session.status == .empty { return "（新しいタブ・まだ指示なし）" }
        if let prompt = session.lastPrompt, !prompt.isEmpty { return Self.oneLine(prompt) }
        return "（タイトル未取得）"
    }

    var body: some View {
        Button { onSelect(session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: isDimmed ? .regular : .semibold))
                        .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    StatusCapsule(session: session, now: now)
                }
                if let action = session.lastAction {
                    detailLine(label: "直近", text: Self.oneLine(action), color: .secondary)
                }
                if session.status == .waiting, let prompt = session.lastPrompt {
                    detailLine(label: "指示", text: "「\(Self.oneLine(prompt))」", color: Self.promptColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private func detailLine(label: String, text: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.rowCornerRadius, style: .continuous)
        if session.status == .waiting {
            shape.fill(Theme.color(for: .waiting).opacity(Theme.waitingRowFillOpacity))
                .overlay(shape.fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        } else {
            shape.fill(Color.primary.opacity(hovering ? 0.06 : 0))
        }
    }
}
