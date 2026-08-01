import Foundation
import Security
import StayUpCore
import os

/// XPC 接続元の検証（spec §6.4）。
///
/// 検証は `NSXPCListener.setConnectionCodeSigningRequirement(_:)` に任せる。
/// これは macOS 13 で追加された公開 API で、OS が audit token ベースで judge するため、
/// PID 再利用に弱い自前の PID 判定を書かずに済む。
enum ConnectionValidator {
    private static let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "helper")

    /// リスナーに「同一チームが署名した StayUp.app のみ」という要件を設定する。
    ///
    /// - Returns: 要件を設定できたか。未署名の開発ビルドでは false。
    @discardableResult
    static func applyCodeSigningRequirement(to listener: NSXPCListener) -> Bool {
        guard let teamID = ownTeamIdentifier() else {
            // 未署名 = 開発ビルド。root で動く以上これは危険なので、はっきり記録する。
            log.error("""
                ヘルパーが署名されていないため、接続元のコード署名を検証できません。
                この状態で運用しないでください（開発ビルドのみ想定）。
                """)
            return false
        }

        let requirement = """
            identifier "\(StayUpPaths.bundleIdentifier)" \
            and anchor apple generic \
            and certificate leaf[subject.OU] = "\(teamID)"
            """
        listener.setConnectionCodeSigningRequirement(requirement)
        log.notice("接続元のコード署名要件を設定しました (team \(teamID, privacy: .public))")
        return true
    }

    /// 署名要件が設定できなかったときの最後の防波堤。
    ///
    /// 同一ユーザーか root からの接続のみ通す。
    static func isAcceptableWithoutSigning(_ connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier
        return uid == 0 || uid == consoleUserID()
    }

    /// ヘルパー自身の Team ID。未署名なら nil。
    private static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }

        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any]
        else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// コンソールにログインしているユーザーの UID。`/dev/console` の所有者を見る。
    private static func consoleUserID() -> uid_t {
        var info = stat()
        guard stat("/dev/console", &info) == 0 else { return 0 }
        return info.st_uid
    }
}
