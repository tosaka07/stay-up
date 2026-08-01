import Foundation
import StayUpCore
import os

/// CLI からのリクエストを受け付ける UNIX ドメインソケットサーバ（spec §12.1）。
///
/// 接続元の UID を検証し、リクエストを `SessionManager` に委譲する。
/// ソケットに接続できる時点で同一ユーザー権限なので、これ以上の防御は意味を持たない。
public final class ControlSocketServer: @unchecked Sendable {
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "socket")
    private let path: String
    private let handler: ControlRequestHandler

    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "dev.tosaka.StayUp.socket", qos: .userInitiated)

    public init(path: String = StayUpPaths.socketFile.path(percentEncoded: false), handler: ControlRequestHandler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        try StayUpPaths.createSupportDirectories()
        listenFD = try UnixSocket.listen(at: path)

        let source = DispatchSource.makeReadSource(fileDescriptor: listenFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptOne()
        }
        source.setCancelHandler { [listenFD = self.listenFD, path = self.path] in
            close(listenFD)
            unlink(path)
        }
        source.resume()
        acceptSource = source
        log.notice("コントロールソケットを開きました: \(self.path, privacy: .public)")
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
    }

    private func acceptOne() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        // 同一ユーザーからの接続のみ受け付ける
        let ownUID = getuid()
        guard let peerUID = UnixSocket.peerUID(clientFD), peerUID == ownUID else {
            log.error("他ユーザーからの接続を拒否しました")
            close(clientFD)
            return
        }

        queue.async { [weak self] in
            self?.serve(clientFD)
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        guard let line = UnixSocket.readLine(fd) else { return }

        let decoder = ControlCoding.makeDecoder()
        let response: ControlResponse
        if let request = try? decoder.decode(ControlRequest.self, from: line) {
            response = handler.handleSynchronously(request)
        } else {
            response = .failure(ControlError(
                code: .invalidArgument,
                message: "リクエストを解釈できませんでした"
            ))
        }

        if let data = try? ControlCoding.encodeLine(response) {
            _ = UnixSocket.writeAll(fd, data)
        }
    }
}

/// ソケットのリクエストを `SessionManager` に橋渡しする。
///
/// ソケットは専用キューで動き、`SessionManager` は `@MainActor` なので、
/// ここで一度だけメインアクターへ渡す。
public final class ControlRequestHandler: @unchecked Sendable {
    private let manager: SessionManager

    public init(manager: SessionManager) {
        self.manager = manager
    }

    /// ソケットのワーカスレッドから同期的に呼ばれる。
    func handleSynchronously(_ request: ControlRequest) -> ControlResponse {
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: ControlResponse = .failure(
            ControlError(code: .generic, message: "応答がありませんでした")
        )

        Task { @MainActor in
            result = await self.handle(request)
            semaphore.signal()
        }

        // CLI 側にもタイムアウトがあるので、ここは十分長く待つ。
        // 承認プロンプトの応答待ち（30 秒）を吸収できる長さにする。
        if semaphore.wait(timeout: .now() + 35) == .timedOut {
            return .failure(ControlError(
                code: .denied,
                message: "応答がタイムアウトしました",
                nonFatal: true
            ))
        }
        return result
    }

    @MainActor
    func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request {
        case .acquire(let options):
            return await acquire(options)

        case .renew(let id, let leaseFilePath, let ttl, let owner):
            let client = owner.map { Client.external(name: $0, pid: 0) }
            let result: Result<Lease, ControlError> =
                if let id {
                    manager.renew(id: id, ttlSeconds: ttl, requestedBy: client)
                } else if let leaseFilePath {
                    manager.renew(leaseFilePath: leaseFilePath, ttlSeconds: ttl, requestedBy: client)
                } else {
                    .failure(ControlError(code: .invalidArgument, message: "id か --lease-file が必要です"))
                }
            return switch result {
            case .success(let lease): .renewed(lease: LeaseSnapshot(lease: lease))
            case .failure(let error): .failure(error)
            }

        case .release(let id, let leaseFilePath, let owner):
            let client = owner.map { Client.external(name: $0, pid: 0) }
            let result: Result<Lease, ControlError> =
                if let id {
                    await manager.release(id: id, requestedBy: client)
                } else if let leaseFilePath {
                    await manager.release(leaseFilePath: leaseFilePath, requestedBy: client)
                } else {
                    .failure(ControlError(code: .invalidArgument, message: "id か --lease-file が必要です"))
                }
            return switch result {
            case .success: .released(count: 1)
            case .failure(let error): .failure(error)
            }

        case .releaseAll(let owner):
            let client = owner.map { Client.external(name: $0, pid: 0) }
            let released = await manager.releaseAll(requestedBy: client)
            return .released(count: released.count)

        case .list:
            return .list(manager.leases.map(LeaseSnapshot.init))

        case .status:
            return .status(manager.statusSnapshot())

        case .toggle(let options):
            if manager.isActive {
                let released = await manager.releaseAll(
                    requestedBy: options.owner.map { Client.external(name: $0, pid: options.clientPID ?? 0) }
                )
                return .released(count: released.count)
            }
            return await acquire(options)

        case .wait:
            while manager.isActive {
                try? await Task.sleep(for: .milliseconds(250))
            }
            return .ok

        case .doctor:
            return .doctor(buildDoctorReport())
        }
    }

    @MainActor
    private func acquire(_ options: AcquireOptions) async -> ControlResponse {
        let client: Client =
            if let owner = options.owner {
                .external(name: owner, pid: options.clientPID ?? 0)
            } else {
                .interactive(trigger: .menuBar)
            }

        var binding = options.binding
        if binding == nil, let path = options.leaseFilePath {
            binding = .leaseFile(path: path)
        }

        // リースファイル方式では、まずファイルを作ってからバインドする
        if case .leaseFile(let path)? = binding,
           !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: Data())
        }

        let result = await manager.acquire(
            client: client,
            label: options.label ?? options.owner ?? "手動",
            ttlSeconds: options.ttlSeconds,
            binding: binding,
            ifNotExists: options.ifNotExists,
            reason: options.reason
        )

        switch result {
        case .success(let outcome):
            let lease = outcome.lease
            // リースファイルに ID を書き、後続コマンドが ID を持ち回らなくて済むようにする
            if case .leaseFile(let path)? = lease.binding {
                try? Data(lease.id.rawValue.utf8).write(to: URL(filePath: path))
            }
            let warning: String? = manager.capability == .idleOnly
                ? "ふたを閉じるとスリープします（ヘルパー未設定）"
                : nil
            return .acquired(
                lease: LeaseSnapshot(lease: lease),
                capability: manager.capability.rawValue,
                warning: warning
            )
        case .failure(let error):
            return .failure(error)
        }
    }

    @MainActor
    private func buildDoctorReport() -> DoctorReport {
        var checks: [DoctorReport.Check] = []

        let helperStatus = HelperClient().status
        checks.append(DoctorReport.Check(
            name: "ヘルパー",
            ok: helperStatus == .enabled,
            detail: helperStatus.localizedDescription,
            remedy: helperStatus == .enabled
                ? nil
                : "StayUp の設定からヘルパーを登録し、システム設定で承認してください"
        ))

        let sleepDisabled = PMSet.sleepDisabled()
        let leaseCount = manager.leases.count
        let orphaned = sleepDisabled == true && leaseCount == 0
        checks.append(DoctorReport.Check(
            name: "pmset disablesleep",
            ok: !orphaned,
            detail: "SleepDisabled=\(sleepDisabled.map { $0 ? "1" : "0" } ?? "不明"), リース \(leaseCount) 件",
            remedy: orphaned ? "StayUp の診断タブから「スリープ設定を強制的に復元」を実行してください" : nil
        ))

        checks.append(DoctorReport.Check(
            name: "抑止の範囲",
            ok: manager.capability == .full || leaseCount == 0,
            detail: manager.capability.localizedDescription,
            remedy: manager.capability == .idleOnly && leaseCount > 0
                ? "ヘルパーを登録するとクラムシェルスリープも抑止できます"
                : nil
        ))

        return DoctorReport(checks: checks)
    }
}
