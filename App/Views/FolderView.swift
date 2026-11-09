import SwiftUI

/// リポジトリ 1 件分のフォルダ。左上に耳、下に本体のカード
struct FolderView: View {
    let repo: Repo
    var now: Date = Date()
    var onSelect: (Session) -> Void = { _ in }
    /// 待機グループの中ならグレーの耳にする
    var isInIdleGroup: Bool = false
    /// 耳の右の表示を右端から離す幅（待機グループの見出しを避ける）
    var gitSummaryTrailingInset: CGFloat = 0

    private var color: Color { isInIdleGroup ? Theme.idleFolderTabColor : Theme.folderTabColor }

    var body: some View {
        // 耳と本体をまとめて 1 枚の影を落とす。耳の右の文字に影が付かないよう、
        // 行の中には幅取り用の透明なコピーを置き、本物は影の外から重ねる
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                tab.layoutPriority(1)
                Spacer(minLength: 0)
                gitSummaryPlaced.hidden()
            }
            body_
        }
        .compositingGroup()
        .shadow(color: Theme.folderShadowColor, radius: Theme.folderShadowRadius, y: Theme.folderShadowY)
        .overlay(alignment: .topTrailing) {
            gitSummaryPlaced.frame(height: 24)
        }
    }

    private var gitSummaryPlaced: some View {
        gitSummary.padding(.trailing, gitSummaryTrailingInset + 6)
    }

    // MARK: 耳（上の角だけ丸い）
    private var tab: some View {
        HStack(spacing: 6) {
            Text(repo.name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
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

    // MARK: 耳の右（ブランチ・コミット差・変更ファイル数）
    private var gitSummary: some View {
        HStack(spacing: 5) {
            if let branch = repo.branch {
                Text(branch)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let status = repo.gitStatus {
                Group {
                    if status.behind > 0 {
                        Text("↓\(status.behind)")
                            .fontWeight(.bold)
                            .foregroundStyle(Theme.behindColor)
                    }
                    if status.ahead > 0 {
                        Text("↑\(status.ahead)").foregroundStyle(.secondary)
                    }
                    if status.changedFiles > 0 {
                        Text("✎\(status.changedFiles)").foregroundStyle(.secondary)
                    }
                    if status.fetchFailed {
                        Image(systemName: "exclamationmark.icloud").foregroundStyle(.secondary)
                    }
                }
                .fixedSize()
            }
        }
        .font(.system(size: 11, weight: .medium))
        .help(repo.gitStatus?.helpText ?? "")
    }

    @ViewBuilder
    private func statusDot(_ session: Session) -> some View {
        if session.completedUnseen {
            // 耳の色と見分けるため白い縁を付ける
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
            Circle().fill(Theme.waitingDotColor)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 0.8))
                .frame(width: 7, height: 7)
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
