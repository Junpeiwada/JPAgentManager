import SwiftUI

/// 書類棚。ヘッダー・フォルダの並び・待機だけのフォルダの折りたたみ行。
/// 並び順は変えず、渡された順に出す。スクロールはパネル側が担当する
struct ShelfView: View {
    let repos: [Repo]
    var now: Date = Date()
    var onSelect: (Session) -> Void = { _ in }

    @State private var idleExpanded = false

    private var sessions: [Session] { repos.flatMap(\.sessions) }

    var body: some View {
        // セッションが0件のリポジトリは出さない。残りを待機だけ（折りたたみ対象）とそれ以外に1回で振り分ける
        let shown = repos.filter { !$0.sessions.isEmpty }
        let idleRepos = shown.filter(Sorting.isIdleOnly)
        let activeRepos = shown.filter { !Sorting.isIdleOnly($0) }
        return VStack(alignment: .leading, spacing: 10) {
            header
            ForEach(activeRepos) { folder($0) }
            if !idleRepos.isEmpty {
                collapsedRow(idleRepos)
                if idleExpanded {
                    ForEach(idleRepos) { folder($0) }
                }
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

    // MARK: 待機中だけのフォルダの折りたたみ行
    private func collapsedRow(_ idleRepos: [Repo]) -> some View {
        Button {
            idleExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(idleExpanded ? 90 : 0))
                Text("待機中だけのフォルダ（\(idleRepos.count)）")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 8)
                if !idleExpanded {
                    HStack(spacing: 6) {
                        ForEach(idleRepos) { chip($0) }
                    }
                    .clipped()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 34)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 小さな耳の形のチップ（リポジトリ色）
    private func chip(_ repo: Repo) -> some View {
        Text(repo.name)
            .font(.system(size: 10))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .frame(height: 16)
            .background(
                UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 0,
                                       bottomTrailingRadius: 0, topTrailingRadius: 5,
                                       style: .continuous)
                    .fill(Theme.repoColor(for: repo.id))
            )
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
