import Sparkle

// アプリ内自動更新（Sparkle）の入り口。
// 更新フィード（SUFeedURL）と署名検証鍵（SUPublicEDKey）は Info.plist に置く。
@MainActor
final class UpdaterController: NSObject, SPUUpdaterDelegate {
    /// Sparkle の標準 UI（更新ダイアログ・進捗・再起動）をそのまま使う。
    /// startingUpdater: true で、SUScheduledCheckInterval に従った定期確認が起動時から動く。
    /// delegate に self を渡すため super.init 後に作る
    private var controller: SPUStandardUpdaterController!

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
    }

    /// 「更新を確認…」から呼ぶ。結果は Sparkle の UI がすべて表示する
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// 開発版が配布版の更新を見つけて通知したり置き換えたりしないよう、DEBUG ではバックグラウンド確認だけ止める。
    /// 設定値（ユーザーデフォルト）は書き換えない。同じバンドル ID の配布版の自動確認に影響するため。手動の確認は通す
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        if updateCheck == .updatesInBackground {
            throw NSError(domain: "JPAgentManager.Updater", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "DEBUG ビルドでは自動確認をしない"])
        }
        #endif
    }
}
