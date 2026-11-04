import SwiftUI

/// 行の右端に出す状態カプセル（「許可待ち 2分」の形）
struct StatusCapsule: View {
    let session: Session
    var now: Date = Date()

    private var label: String {
        // 入力待ち（input needed）と許可待ちを区別する
        if session.status == .waiting, session.waitingFor == "input needed" { return "入力待ち" }
        return session.status.label
    }

    private var text: String {
        // 空は「空」だけ。それ以外は「状態 経過時間」
        session.status == .empty
            ? label
            : "\(label) \(session.elapsedText(now: now))"
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(textColor)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .frame(height: 17)
            .background(background)
    }

    private var textColor: Color {
        switch session.status {
        case .waiting: return .white
        case .running: return Theme.color(for: .running)
        case .idle: return Color(nsColor: .secondaryLabelColor)
        case .empty: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    @ViewBuilder
    private var background: some View {
        switch session.status {
        case .waiting:
            Capsule().fill(Theme.color(for: .waiting))
        case .running, .idle:
            Capsule().fill(Theme.color(for: session.status).opacity(Theme.capsuleFillOpacity))
        case .empty:
            Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }
}
