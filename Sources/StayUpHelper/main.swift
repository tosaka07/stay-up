import Foundation
import StayUpCore
import os

/// LaunchDaemon として root で常駐し、`pmset disablesleep` だけを担当する。
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HelperService()
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "helper")
    /// コード署名要件を OS に任せられたか。false なら UID で判定する。
    private var hasSigningRequirement = false

    func start() {
        // 起動時に孤児を回収してから受け付ける（復元保証の層 4）
        service.restoreOrphanedStateAtStartup()

        let listener = NSXPCListener(machServiceName: StayUpPaths.helperIdentifier)
        hasSigningRequirement = ConnectionValidator.applyCodeSigningRequirement(to: listener)
        listener.delegate = self
        listener.resume()
        log.notice("StayUpHelper \(HelperConstants.version, privacy: .public) が待ち受けを開始しました")
        RunLoop.main.run()
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        // 署名要件を設定できていれば、この時点で OS が既に検証済み。
        // できていない（未署名の開発ビルド）ときだけ UID で足切りする。
        if !hasSigningRequirement, !ConnectionValidator.isAcceptableWithoutSigning(connection) {
            log.error("信頼できない接続を拒否しました")
            return false
        }

        connection.exportedInterface = NSXPCInterface(with: StayUpHelperProtocol.self)
        connection.exportedObject = service

        // 接続が切れたら復元する。これが復元保証の層 2 の本体。
        // interruption（相手のクラッシュ）と invalidation（切断）の両方を拾う。
        let service = self.service
        connection.interruptionHandler = { [weak connection] in
            guard let connection else { return }
            service.unregister(connection)
        }
        connection.invalidationHandler = { [weak connection] in
            guard let connection else { return }
            service.unregister(connection)
        }

        service.register(connection)
        connection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
delegate.start()
