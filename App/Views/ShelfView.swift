import SwiftUI

/// 書類棚。ヘッダー・フォルダの並び・待機だけのフォルダのグループ。
/// 並び順は変えず、渡された順に出す。スクロールはパネル側が担当する
struct ShelfView: View {
    let repos: [Repo]
    var now: Date = Date()
    var onSelect: (Session) -> Void = { _ in }

    private var sessions: [Session] { repos.flatMap(\.sessions) }

    var body: some View {
        // セッションが0件のリポジトリは出さない。残りを待機だけ（グループ対象）とそれ以外に振り分ける。
        // 未確認の完了を含むリポジトリは、目立つようグループに入れない（FR-111）
        let shown = repos.filter { !$0.sessions.isEmpty }
        let isGrouped: (Repo) -> Bool = { Sorting.isIdleOnly($0) && !$0.sessions.contains(where: \.completedUnseen) }
        let idleRepos = shown.filter(isGrouped)
        let activeRepos = shown.filter { !isGrouped($0) }
        return VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(activeRepos) { folder($0) }
            if !idleRepos.isEmpty {
                idleGroup(idleRepos)
            }
        }
        .padding(12)
        .frame(width: Theme.panelContentWidth, alignment: .leading)
    }

    private func folder(_ repo: Repo) -> some View {
        FolderView(repo: repo, now: now, onSelect: onSelect)
    }

    // MARK: ヘッダー
    private var header: some View {
        HStack(spacing: 6) {
            Text("Claude")
                .font(.system(size: 17, weight: .bold))
            Spacer(minLength: 8)
            let waiting = sessions.filter { $0.status == .waiting }.count
            let running = sessions.filter { $0.status == .running }.count
            summaryCapsule("許可待ち \(waiting)", dot: Theme.color(for: .waiting))
            summaryCapsule("実行中 \(running)", dot: Theme.color(for: .running))
            let completed = sessions.filter(\.completedUnseen).count
            if completed > 0 {
                summaryCapsule("完了 \(completed)", dot: Theme.completedColor)
            }
            summaryCapsule("タブ \(sessions.count)", dot: nil)
        }
        .padding(.horizontal, 4)
    }

    private func summaryCapsule(_ text: String, dot: Color?) -> some View {
        HStack(spacing: 4) {
            if let dot { Circle().fill(dot).frame(width: 7, height: 7) }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 8)
        .frame(height: 20)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }

    // MARK: 待機だけのフォルダのグループ
    /// 1枚のグレーの背景に載せる。背景の余白は外へはみ出させ、フォルダの幅を他と揃える
    private func idleGroup(_ idleRepos: [Repo]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(idleRepos) { folder($0) }
        }
        .padding(Theme.idleGroupPadding)
        .background(
            RoundedRectangle(cornerRadius: Theme.idleGroupCornerRadius, style: .continuous)
                .fill(Theme.idleGroupFill)
        )
        .overlay(alignment: .topTrailing) {
            // 1つ目のフォルダの耳と同じ高さの右側に置く。高さを増やさないよう重ねる
            Text("待機中のみ")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
                .frame(height: 24)
                .padding(.top, Theme.idleGroupPadding)
                .padding(.trailing, Theme.idleGroupPadding + 6)
        }
        .padding(.horizontal, -Theme.idleGroupPadding)
    }
}

#Preview("ライト") {
    ShelfView(repos: SampleData.repos())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.light)
}

#Preview("ダーク") {
    ShelfView(repos: SampleData.repos())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
