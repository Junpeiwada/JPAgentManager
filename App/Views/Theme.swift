import AppKit
import SwiftUI

/// 色と寸法の定義。色はシステムカラー中心でライト／ダークに自動で追従する
enum Theme {
    // MARK: 状態の色
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .waiting: return .orange
        case .running: return .blue
        case .idle: return .gray
        case .empty: return .secondary
        }
    }

    // MARK: リポジトリの色（橙・青・黄に近い色は状態色や許可待ちの点と紛れるので入れない）
    /// ライト／ダークで値を変える動的カラー。耳の上は白字なので、どちらも白字が読める濃さにする
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

    static let repoPalette: [Color] = [
        dynamicColor(light: 0xAF52DE, dark: 0xA050D0),  // 紫
        dynamicColor(light: 0x00A89F, dark: 0x00958D),  // ミント
        dynamicColor(light: 0xA2845E, dark: 0x93764F),  // ブラウン
        dynamicColor(light: 0xE0457B, dark: 0xD03A70),  // ピンク
        dynamicColor(light: 0x3A9D4A, dark: 0x2F8A3E),  // 緑
        dynamicColor(light: 0xB02A8F, dark: 0xA02380),  // 赤紫
        dynamicColor(light: 0x7D8A2B, dark: 0x6E7A22),  // オリーブ
    ]

    /// repoID（NFC に正規化）の FNV-1a(32bit) ハッシュでパレットの添字を決める。起動をまたいで安定する
    static func repoColorIndex(for repoID: String) -> Int {
        var hash: UInt32 = 2166136261
        for byte in repoID.precomposedStringWithCanonicalMapping.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return Int(hash % UInt32(repoPalette.count))
    }

    static func repoColor(for repoID: String) -> Color {
        repoPalette[repoColorIndex(for: repoID)]
    }

    /// 許可待ちを示す点の黄色（耳の上で橙と紛れないよう黄）
    static let waitingDotColor = Color(red: 1.0, green: 0.84, blue: 0.04)

    // MARK: 寸法
    /// パネル内容の幅
    static let panelContentWidth: CGFloat = 400

    // MARK: 角の丸め（画面図の値）
    static let panelCornerRadius: CGFloat = 16
    static let folderCornerRadius: CGFloat = 12
    static let rowCornerRadius: CGFloat = 11

    // MARK: 不透明度（画面図の値）
    /// 許可待ちの行の塗り
    static let waitingRowFillOpacity: Double = 0.14
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

    // MARK: 未確認の完了（FR-111）
    /// 未確認の完了の色（行の塗り・カプセル・メニューバーの点）
    static let completedColor = Color.green
    /// 未確認の完了の行の塗り
    static let completedRowFillOpacity: Double = 0.16
}
