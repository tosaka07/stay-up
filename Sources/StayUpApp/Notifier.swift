import Foundation
import StayUpCore
import UserNotifications
import os

/// spec §8.4 の通知。
///
/// 0.1.0 で出すのは、既定 ON のうち「黙って失敗すると気づきようがない」2 つに絞る。
///
/// - グローバル条件による強制失効（バッテリー・熱・総継続時間）
/// - `disablesleep` の復元失敗
///
/// StayUp はふたを閉じて使う道具なので、**利用者が画面を見ていない前提**で考える。
/// 抑止が失われたことを伝える経路がないと、寝落ちした Mac を後から見つけることになる。
@MainActor
final class Notifier {
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "notification")

    /// バンドル外で動かすと `UNUserNotificationCenter.current()` は例外を投げる。
    /// SwiftPM が直接吐いた実行ファイルを起動したときに落とさないための門番。
    private let center: UNUserNotificationCenter? =
        Bundle.main.bundleIdentifier == nil ? nil : .current()

    private var isAuthorized = false

    func requestAuthorization() async {
        guard let center else { return }
        do {
            isAuthorized = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("通知の許可を取得できませんでした: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// グローバル条件で全リースが失効したことを伝える。
    ///
    /// TTL 切れやバインド消滅は既定 OFF なので出さない。
    /// 複数リースが同時に消えても 1 通にまとめる（spec §8.4）。
    func notifyGlobalStop(leases: [Lease], reason: ReleaseReason) {
        guard reason.isGlobal else { return }

        let body = if let only = leases.first, leases.count == 1 {
            "「\(only.label)」を解除しました（理由: \(reason.localizedDescription)）"
        } else {
            "\(leases.count) 件のリースを解除しました（理由: \(reason.localizedDescription)）"
        }
        post(title: "スリープ抑止を解除しました", body: body, id: "global-stop")
    }

    func notifyRestoreFailure(_ message: String) {
        post(title: "スリープ設定の復元に失敗しました", body: message, id: "restore-failure")
    }

    private func post(title: String, body: String, id: String) {
        guard let center, isAuthorized else {
            log.notice("通知を送れないため記録だけ残します: \(title, privacy: .public)")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        // 同じ id は上書きされる。繰り返し起きても通知が積み上がらない。
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                try await center.add(request)
            } catch {
                log.error("通知を送れませんでした: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
