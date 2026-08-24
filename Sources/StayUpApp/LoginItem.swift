import Foundation
import ServiceManagement
import StayUpCore
import os

/// ログイン時起動（spec §9）。
///
/// **状態を `Settings` に持たない。** macOS 側の登録状態が真実で、
/// こちらが別に覚えると「設定は有効なのに実際は登録されていない」という
/// 食い違いが生まれる。この手の食い違いは利用者から見て嘘になるので、
/// 保存せず毎回 OS に聞く。
@MainActor
enum LoginItem {
    private static let log = Logger(
        subsystem: StayUpPaths.bundleIdentifier,
        category: "loginItem"
    )

    /// 現在ログイン項目として登録されているか。
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 登録・解除する。
    ///
    /// - Returns: 失敗した理由。成功したら nil。
    static func setEnabled(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
                log.notice("ログイン項目に登録しました")
            } else {
                try SMAppService.mainApp.unregister()
                log.notice("ログイン項目から解除しました")
            }
            return nil
        } catch {
            log.error("ログイン項目の変更に失敗: \(error.localizedDescription, privacy: .public)")
            return error.localizedDescription
        }
    }
}
