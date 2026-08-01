import Foundation
import StayUpCore
import os

/// root ヘルパーの本体。
///
/// **このクラスの最重要責務は「復元」であって「設定」ではない**（spec §6.2）。
/// クライアントがどんな死に方をしても `disablesleep` を 0 に戻す。
final class HelperService: NSObject, StayUpHelperProtocol, @unchecked Sendable {
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "helper")
    private let lock = NSLock()

    /// 現在接続しているクライアント。全て切れたら復元する。
    private var connections: Set<ObjectIdentifier> = []
    /// このヘルパーが disablesleep を 1 にしたかどうか。
    private var didDisableSleep = false
    private var lastHeartbeat = Date()
    private var watchdog: DispatchSourceTimer?

    override init() {
        super.init()
        startWatchdog()
    }

    // MARK: - StayUpHelperProtocol

    func setDisableSleep(_ enabled: Bool, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let result = PMSetWriter.setDisableSleep(enabled)

        lock.lock()
        if result.ok {
            didDisableSleep = enabled
            lastHeartbeat = Date()
        }
        lock.unlock()

        if result.ok {
            log.notice("pmset disablesleep = \(enabled ? 1 : 0)")
        } else {
            log.error("pmset の実行に失敗: \(result.message ?? "不明", privacy: .public)")
        }
        reply(result.ok, result.message)
    }

    func queryState(reply: @escaping @Sendable (Bool, String) -> Void) {
        reply(PMSetWriter.sleepDisabled() ?? false, HelperConstants.version)
    }

    func heartbeat(reply: @escaping @Sendable (Bool) -> Void) {
        lock.lock()
        lastHeartbeat = Date()
        lock.unlock()
        reply(true)
    }

    // MARK: - 接続の追跡（復元保証の層 2）

    func register(_ connection: NSXPCConnection) {
        lock.lock()
        connections.insert(ObjectIdentifier(connection))
        lastHeartbeat = Date()
        let count = connections.count
        lock.unlock()
        log.notice("クライアントが接続しました (計 \(count))")
    }

    /// 接続が切れたときに呼ばれる。
    ///
    /// **全ての接続が失われたら、理由を問わず復元する。**
    /// これがアプリのクラッシュ・強制終了・SIGKILL をカバーする層。
    func unregister(_ connection: NSXPCConnection) {
        lock.lock()
        connections.remove(ObjectIdentifier(connection))
        let remaining = connections.count
        let shouldRestore = remaining == 0 && didDisableSleep
        lock.unlock()

        log.notice("クライアントが切断しました (残り \(remaining))")
        if shouldRestore {
            log.notice("接続が全て失われたため、スリープ設定を復元します")
            restore(reason: "全クライアントの切断")
        }
    }

    // MARK: - ウォッチドッグ（復元保証の層 5）

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            self?.checkHeartbeat()
        }
        timer.resume()
        watchdog = timer
    }

    private func checkHeartbeat() {
        lock.lock()
        let stale = didDisableSleep
            && Date().timeIntervalSince(lastHeartbeat) > HelperConstants.heartbeatTimeout
        lock.unlock()

        guard stale else { return }
        log.error("heartbeat が \(Int(HelperConstants.heartbeatTimeout)) 秒途絶えました。復元します")
        restore(reason: "heartbeat の途絶")
    }

    // MARK: - 復元

    func restore(reason: String) {
        let result = PMSetWriter.setDisableSleep(false)
        lock.lock()
        if result.ok { didDisableSleep = false }
        lock.unlock()

        if result.ok {
            log.notice("スリープ設定を復元しました (\(reason, privacy: .public))")
        } else {
            log.fault("復元に失敗しました: \(result.message ?? "不明", privacy: .public)")
        }
    }

    /// ヘルパー起動時の孤児チェック（復元保証の層 4）。
    ///
    /// 電源断やカーネルパニックの後、`disablesleep=1` だけが残っていることがある。
    /// 起動直後はクライアントが 1 つも繋がっていないので、残っていれば孤児と判断できる。
    func restoreOrphanedStateAtStartup() {
        guard PMSetWriter.sleepDisabled() == true else { return }
        log.error("起動時に disablesleep=1 を検出しました（クライアント無し）。孤児として復元します")
        restore(reason: "起動時の孤児検出")
    }
}
