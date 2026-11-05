import SwiftUI

/// リポジトリ 1 件分のフォルダ。左上に耳、下に本体のカード
struct FolderView: View {
    let repo: Repo
    var now: Date = Date()
    var onSelect: (Session) -> Void = { _ in }

    private var color: Color { Theme.repoColor(for: repo.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            tab
            body_
        }
    }

    // MARK: 耳（上の角だけ丸い）
    private var tab: some View {
        HStack(spacing: 6) {
            Text(repo.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Text("\(repo.sessions.count)")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 16)
                .background(Capsule().fill(Color.white.opacity(0.28)))
            HStack(spacing: 3) {
                ForEach(repo.sessions) { statusDot($0) }
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 11, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 11,
                                   style: .continuous)
                .fill(color)
        )
    }

    @ViewBuilder
    private func statusDot(_ session: Session) -> some View {
        if session.completedUnseen {
            // 耳の色に緑やミントがあるので、白い縁で見分ける
            Circle().fill(Theme.completedColor)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1))
                .frame(width: 7, height: 7)
        } else {
            plainDot(session.status)
        }
    }

    @ViewBuilder
    private func plainDot(_ status: SessionStatus) -> some View {
        switch status {
        case .waiting:
            Circle().fill(Theme.waitingDotColor).frame(width: 6, height: 6)
        case .running:
            Circle().fill(Color.white).frame(width: 6, height: 6)
        case .idle:
            Circle().fill(Color.white.opacity(0.45)).frame(width: 6, height: 6)
        case .empty:
            Circle().strokeBorder(Color.white.opacity(0.85), lineWidth: 1).frame(width: 6, height: 6)
        }
    }

    // MARK: 本体（左上だけ角を立てる）
    private var body_: some View {
        let r = Theme.folderCornerRadius
        let shape = UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: r,
                                           bottomTrailingRadius: r, topTrailingRadius: r,
                                           style: .continuous)
        return VStack(spacing: 0) {
            ForEach(Array(repo.sessions.enumerated()), id: \.element.id) { index, session in
                if index > 0 && !touchesHighlighted(index) {
                    Divider().padding(.horizontal, 10)
                }
                SessionRow(session: session, now: now, onSelect: onSelect)
                    // 塗りのある行（許可待ち・未確認の完了）が続くとくっつくので、前の行も塗りがあれば隙間を入れる
                    .padding(.top, index > 0 && Self.isHighlighted(session)
                             && Self.isHighlighted(repo.sessions[index - 1]) ? 2 : 0)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 7)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .top) { color.frame(height: 3) }
        .clipShape(shape)
    }

    /// 行に塗りがあるか（許可待ち、または未確認の完了）
    private static func isHighlighted(_ session: Session) -> Bool {
        session.status == .waiting || session.completedUnseen
    }

    /// 区切り線の前後どちらかに塗りがあれば true（線を出さない）
    private func touchesHighlighted(_ index: Int) -> Bool {
        Self.isHighlighted(repo.sessions[index]) || Self.isHighlighted(repo.sessions[index - 1])
    }
}
