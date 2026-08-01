import Foundation
import Security
import ServiceManagement
import StayUpCore
import os

public enum HelperStatus: Sendable, Equatable {
    case notRegistered
    case requiresApproval
    case enabled
    case unavailable(String)

    public var localizedDescription: String {
        switch self {
        case .notRegistered: "未登録"
        case .requiresApproval: "システム設定での承認待ち"
        case .enabled: "有効"
        case .unavailable(let reason): "利用不可: \(reason)"
        }
    }
}

public enum HelperRegistrationError: LocalizedError {
    case unsignedBuild
    case invalidState(HelperStatus)

    public var errorDescription: String? {
        switch self {
        case .unsignedBuild:
            "このStayUpはDeveloper IDで署名されていないため、ヘルパーを登録できません。"
        case .invalidState(let status):
            "現在の状態ではヘルパーを登録できません（\(status.localizedDescription)）。"
        }
    }
}

/// `CheckedContinuation` を高々 1 度だけ再開させる箱。
///
/// XPC では「reply が来る」「エラーハンドラが呼ばれる」「どちらも来ない」の
/// いずれもありうる。二重 resume はクラッシュ、ゼロ resume はハングになるため、
/// 経路をここに集約する。
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

/// root ヘルパーとの XPC 通信（spec §6）。
///
/// **接続を維持し続けることが復元保証そのもの**である点に注意。
/// アプリが死ねば接続が切れ、ヘルパー側が `disablesleep` を 0 に戻す。
public final class HelperClient: @unchecked Sendable {
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "helper")
    private let lock = NSLock()

    private var connection: NSXPCConnection?
    private var heartbeatTimer: DispatchSourceTimer?
    private var reconnectAttempts = 0

    /// 接続が失われたときに呼ばれる。SessionManager が degraded へ降格させる。
    public var onConnectionLost: (@Sendable () -> Void)?

    public init() {}

    // MARK: - 登録

    public var status: HelperStatus {
        guard Self.teamIdentifier != nil else {
            return .unavailable("Developer ID署名がない開発ビルドです")
        }
        return Self.normalizedStatus(
            SMAppService.daemon(plistName: StayUpPaths.helperPlistName).status
        )
    }

    /// ServiceManagement の状態を、ユーザーが次に取れる操作へ正規化する。
    ///
    /// macOS 26 では、有効な埋め込み LaunchDaemon でも初回登録前の `status` が
    /// `.notFound` になる。`register()` を呼ぶとバックグラウンド項目が作成され、
    /// `.requiresApproval` へ遷移するため、初回だけは登録可能な状態として扱う。
    static func normalizedStatus(_ status: SMAppService.Status) -> HelperStatus {
        switch status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notRegistered
        @unknown default: .unavailable("不明な状態")
        }
    }

    /// ヘルパーを LaunchDaemon として登録する。初回はシステム設定での承認が要る。
    public func register() throws {
        guard Self.teamIdentifier != nil else {
            throw HelperRegistrationError.unsignedBuild
        }
        let service = SMAppService.daemon(plistName: StayUpPaths.helperPlistName)
        let currentStatus = Self.normalizedStatus(service.status)
        guard currentStatus == .notRegistered else {
            throw HelperRegistrationError.invalidState(currentStatus)
        }

        do {
            try service.register()
        } catch {
            // macOS 26 は LaunchDaemon の初回登録時、項目を承認待ちへ進めた後でも
            // EPERM を返すことがある。状態遷移が完了していれば登録フローは成功。
            let resultingStatus = Self.normalizedStatus(service.status)
            guard resultingStatus == .requiresApproval || resultingStatus == .enabled else {
                throw error
            }
        }
    }

    /// 登録を解除する。呼び出し側は事前に `setDisableSleep(false)` を済ませること。
    public func unregister() throws {
        try SMAppService.daemon(plistName: StayUpPaths.helperPlistName).unregister()
    }

    public func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// アプリ自身のコード署名に含まれる Team ID。
    ///
    /// ad-hoc 署名では nil になる。特権ヘルパーを登録できる配布ビルドかどうかを、
    /// 登録操作の前に判定するために使う。
    public static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &information) == errSecSuccess,
              let dictionary = information as? [String: Any]
        else { return nil }

        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    // MARK: - 接続

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: StayUpPaths.helperIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: StayUpHelperProtocol.self)

        let handler: @Sendable () -> Void = { [weak self] in
            self?.handleConnectionLoss()
        }
        connection.interruptionHandler = handler
        connection.invalidationHandler = handler

        connection.resume()
        return connection
    }

    /// エラー時にも必ず 1 度だけ結果を返すプロキシを作る。
    ///
    /// `remoteObjectProxyWithErrorHandler` は失敗時に reply ブロックを**呼ばない**。
    /// 素朴に `withCheckedContinuation` で包むと、ヘルパー未登録のときに永久にハングする。
    /// エラーハンドラ側からも必ず resume できるようにしておく。
    private func proxy(
        onError: @escaping @Sendable (ControlError) -> Void
    ) -> StayUpHelperProtocol? {
        lock.lock()
        if connection == nil {
            connection = makeConnection()
        }
        let current = connection
        lock.unlock()

        return current?.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.log.error("XPC エラー: \(error.localizedDescription, privacy: .public)")
            onError(ControlError(
                code: .notConnected,
                message: "ヘルパーとの通信に失敗しました: \(error.localizedDescription)",
                nonFatal: true
            ))
        } as? StayUpHelperProtocol
    }

    private func handleConnectionLoss() {
        lock.lock()
        connection = nil
        lock.unlock()
        log.error("ヘルパーとの接続が切れました")
        onConnectionLost?()
    }

    // MARK: - 操作

    /// `disablesleep` を切り替える。成功したら heartbeat を開始する。
    public func setDisableSleep(_ enabled: Bool) async -> Result<Void, ControlError> {
        // ヘルパーが登録されていないなら XPC を張らずに即座に諦める。
        // ここで待たされると、抑止の開始そのものが遅れてしまう。
        guard status == .enabled else {
            return .failure(ControlError(
                code: .notConnected,
                message: "ヘルパーが利用できません（\(status.localizedDescription)）",
                nonFatal: true
            ))
        }

        let result: Result<Void, ControlError> = await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { error in box.resume(.failure(error)) }) else {
                box.resume(.failure(ControlError(
                    code: .notConnected, message: "ヘルパーに接続できません", nonFatal: true
                )))
                return
            }
            proxy.setDisableSleep(enabled) { ok, message in
                box.resume(ok ? .success(()) : .failure(ControlError(
                    code: .generic,
                    message: message ?? "pmset の実行に失敗しました",
                    nonFatal: true
                )))
            }
        }

        if case .success = result {
            if enabled { startHeartbeat() } else { stopHeartbeat() }
        }
        return result
    }

    public func queryState() async -> (sleepDisabled: Bool, version: String)? {
        guard status == .enabled else { return nil }
        return await withCheckedContinuation { continuation in
            let box = ResumeOnce(continuation)
            guard let proxy = proxy(onError: { _ in box.resume(nil) }) else {
                box.resume(nil)
                return
            }
            proxy.queryState { disabled, version in
                box.resume((disabled, version))
            }
        }
    }

    /// アプリ側からヘルパーへの明示的な切断。
    public func disconnect() {
        stopHeartbeat()
        lock.lock()
        let current = connection
        connection = nil
        lock.unlock()
        current?.invalidate()
    }

    // MARK: - heartbeat

    private func startHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        guard heartbeatTimer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + HelperConstants.heartbeatInterval,
                       repeating: HelperConstants.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let proxy = self.proxy(onError: { _ in }) else { return }
            proxy.heartbeat { _ in }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func stopHeartbeat() {
        lock.lock()
        defer { lock.unlock() }
        heartbeatTimer?.cancel()
        heartbeatTimer = nil
    }
}
