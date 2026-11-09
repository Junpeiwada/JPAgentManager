import AppKit
import SwiftUI

/// 色と寸法の定義。色はシステムカラー中心でライト／ダークに自動で追従する
enum Theme {
    // MARK: 状態の色
    /// 許可待ちの朱。アイコンの背景色に近い。白字を載せるのでライト・ダークとも同じ濃さにする
    private static let waitingColor = dynamicColor(light: 0xC4411C, dark: 0xC4411C)
    /// 実行中の緑。カプセルの文字にも使うので、ライトでは読める濃さにする
    private static let runningColor = dynamicColor(light: 0x1F7A3A, dark: 0x6BDB8B)

    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .waiting: return waitingColor
        case .running: return runningColor
        case .idle: return .gray
        case .empty: return .secondary
        }
    }

    // MARK: 動的カラー
    /// ライト／ダークで値を変える色
    private static func dynamicColor(light: UInt32, dark: UInt32) -> Color {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }

    // MARK: フォルダの耳
    /// 全リポジトリ共通の藍色。耳の上は白字なので、どちらの外観でも白字が読める濃さにする
    static let folderTabColor = dynamicColor(light: 0x4F5B93, dark: 0x4A5588)
    /// 待機グループの耳のグレー
    static let idleFolderTabColor = dynamicColor(light: 0x6B6F78, dark: 0x55585F)

    // MARK: フォルダの影
    /// 耳＋本体に落とす薄い影。ダークは見えにくいので濃くする
    static let folderShadowColor = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(isDark ? 0.35 : 0.12)
    })
    static let folderShadowRadius: CGFloat = 2.5
    static let folderShadowY: CGFloat = 1

    // MARK: git の状態
    /// プルが必要なコミット数の色。朱の文字色と同じ「あなたの番」の意味
    static var behindColor: Color { attentionTextColor }

    // MARK: 許可待ち
    /// 許可待ちの行の塗り
    static let waitingRowFill = dynamicColor(light: 0xFBE7E0, dark: 0x46291E)
    /// 許可待ちの行の「指示」の文字色
    static let waitingPromptColor = dynamicColor(light: 0x963012, dark: 0xFFB59E)
    /// パネルの地に載せる朱の文字色（エラー・プルが必要なコミット数）
    static let attentionTextColor = dynamicColor(light: 0xB23A17, dark: 0xFF8F6E)
    /// 許可待ちを示す点の黄色（藍の耳の上で目立つ色）
    static let waitingDotColor = Color(red: 1.0, green: 0.84, blue: 0.04)

    // MARK: 寸法
    /// パネル内容の幅
    static let panelContentWidth: CGFloat = 400

    // MARK: 角の丸め（画面図の値）
    static let panelCornerRadius: CGFloat = 16
    static let folderCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 11

    // MARK: 不透明度（画面図の値）
    /// tinted カプセルの塗り
    static let capsuleFillOpacity: Double = 0.14

    // MARK: 待機だけのフォルダのグループ（FR-107）
    /// 背景の塗り。周囲より少し暗いグレー。ダークは差が出にくいので黒を濃くする
    static let idleGroupFill = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor.black.withAlphaComponent(isDark ? 0.4 : 0.18)
    })
    static let idleGroupPadding: CGFloat = 6
    static let idleGroupCornerRadius: CGFloat = 16
    /// 右肩の「待機中のみ」が占める幅
    static let idleGroupLabelInset: CGFloat = 66

    // MARK: 未確認の完了（FR-111）
    /// 未確認の完了の色（カプセルの文字・メニューバーの点）。実行中の緑と紛れない地味なグレー
    static let completedColor = dynamicColor(light: 0x4E5968, dark: 0xB9BDC6)
    /// 未確認の完了のカプセルの塗り
    static let completedCapsuleFill = dynamicColor(light: 0xE8EAED, dark: 0x3A3D44)
    /// 未確認の完了の行の塗り
    static let completedRowFill = dynamicColor(light: 0xF3F4F6, dark: 0x31343B)
}
