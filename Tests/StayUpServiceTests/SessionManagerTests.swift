import Foundation
import Observation
import Testing

@testable import StayUpCore
@testable import StayUpService

// MARK: - テストダブル

private final class FakeAssertions: SleepAssertionHolding, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var acquireCount = 0
    private(set) var releaseCount = 0
    private(set) var isHeld = false
    private(set) var lastKeepDisplayAwake = false
    private(set) var lastPreventDiskSleep = false

    func acquire(keepDisplayAwake: Bool, preventDiskSleep: Bool) {
        lock.lock(); defer { lock.unlock() }
        acquireCount += 1
        isHeld = true
        lastKeepDisplayAwake = keepDisplayAwake
        lastPreventDiskSleep = preventDiskSleep
    }

    func releaseAll() {
        lock.lock(); defer { lock.unlock() }
        releaseCount += 1
        isHeld = false
    }
}

private final class FakeHelper: PrivilegedSleepControlling, @unchecked Sendable {
    private let lock = NSLock()
    var isAvailable: Bool
    var onConnectionLost: (@Sendable () -> Void)?
    /// setDisableSleep を失敗させる（ヘルパー未登録の再現）。
    var shouldFail: Bool

    private(set) var calls: [Bool] = []
    var disableSleepIsSet: Bool { calls.last ?? false }

    init(isAvailable: Bool = true, shouldFail: Bool = false) {
        self.isAvailable = isAvailable
        self.shouldFail = shouldFail
    }

    func setDisableSleep(_ enabled: Bool) async -> Result<Void, ControlError> {
        lock.withLock {
            guard isAvailable, !shouldFail else {
                return .failure(ControlError(code: .notConnected, message: "テスト用の失敗", nonFatal: true))
            }
            calls.append(enabled)
            return .success(())
        }
    }

    func disconnect() {}

    /// unregister を失敗させる。
    var unregisterShouldThrow = false
    private(set) var didUnregister = false

    func unregister() throws {
        if unregisterShouldThrow {
            throw ControlError(code: .generic, message: "テスト用の登録解除失敗")
        }
        lock.withLock { didUnregister = true }
    }

    /// 接続断を再現する。
    func simulateConnectionLoss() {
        onConnectionLost?()
    }
}

/// 電源監視の代役。
///
/// 本物は `IOPSNotificationCreateRunLoopSource` の通知で駆動する（ポーリングしない）ので、
/// この代役も値の変更時に必ずコールバックを発火させ、同じ振る舞いにする。
private final class FakePower: PowerObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var reading: PowerReading
    private var handler: (@Sendable (PowerReading) -> Void)?
    var isThermalCritical: Bool

    init(percent: Int? = 80, source: PowerSource = .ac, thermalCritical: Bool = false) {
        self.reading = PowerReading(percent: percent, source: source)
        self.isThermalCritical = thermalCritical
    }

    func read() -> PowerReading {
        lock.withLock { reading }
    }

    func set(percent: Int, source: PowerSource) {
        let updated = PowerReading(percent: percent, source: source)
        let handler: (@Sendable (PowerReading) -> Void)? = lock.withLock {
            reading = updated
            return self.handler
        }
        handler?(updated)
    }

    func startMonitoring(onChange: @escaping @Sendable (PowerReading) -> Void) {
        lock.withLock { handler = onChange }
    }

    func stopMonitoring() {
        lock.withLock { handler = nil }
    }
}

private final class FakeProcessWatcher: ProcessWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var alive: Bool

    init(alive: Bool) {
        self.alive = alive
    }

    func setAlive(_ alive: Bool) {
        lock.withLock { self.alive = alive }
    }

    func isAlive(_ binding: LeaseBinding) -> Bool {
        lock.withLock { alive }
    }
}

private final class FakeProcessExitObserver: ProcessExitObserving, @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [pid_t: @Sendable (pid_t) -> Void] = [:]
    private(set) var cancelledPIDs: [pid_t] = []

    func observe(pid: pid_t, onExit: @escaping @Sendable (pid_t) -> Void) -> Bool {
        lock.withLock { handlers[pid] = onExit }
        return true
    }

    func cancel(pid: pid_t) {
        lock.withLock {
            cancelledPIDs.append(pid)
            handlers[pid] = nil
        }
    }

    func cancelAll() {
        lock.withLock { handlers.removeAll() }
    }

    func simulateExit(pid: pid_t) {
        let handler = lock.withLock { handlers[pid] }
        handler?(pid)
    }
}

private struct FakeSleepStateReader: SleepStateReading {
    let sleepDisabled: Bool?

    func isSleepDisabled() -> Bool? {
        sleepDisabled
    }
}

private final class AutoReleaseRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ReleaseReason] = []

    var reasons: [ReleaseReason] {
        lock.withLock { recorded }
    }

    func record(reason: ReleaseReason) {
        lock.withLock { recorded.append(reason) }
    }
}

private final class ObservationChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCount = 0

    var count: Int {
        lock.withLock { recordedCount }
    }

    func record() {
        lock.withLock { recordedCount += 1 }
    }
}

/// テスト用に隔離したディレクトリで SessionManager を組み立てる。
@MainActor
private func makeManager(
    settings: Settings = Settings(clientPolicy: .allow),
    assertions: FakeAssertions = FakeAssertions(),
    helper: FakeHelper = FakeHelper(),
    power: FakePower = FakePower(),
    watcher: any ProcessWatching = ProcessWatcher(),
    exitObserver: any ProcessExitObserving = ProcessExitObserver(),
    sleepStateReader: any SleepStateReading = PMSetSleepStateReader(),
    thermalGraceSeconds: TimeInterval = 60,
    processNameGraceSeconds: TimeInterval = 10,
    approvalTimeoutSeconds: TimeInterval = 30
) -> (SessionManager, FakeAssertions, FakeHelper, FakePower, URL) {
    let dir = URL(filePath: NSTemporaryDirectory())
        .appending(path: "stayup-svc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let manager = SessionManager(
        settings: settings,
        assertions: assertions,
        helper: helper,
        power: power,
        watcher: watcher,
        exitObserver: exitObserver,
        sleepStateReader: sleepStateReader,
        history: HistoryStore(directory: dir.appending(path: "history")),
        stateStore: StateStore(fileURL: dir.appending(path: "state.json")),
        // UserDefaults を汚さないため設定の永続化は無効にする
        settingsStore: nil,
        thermalGraceSeconds: thermalGraceSeconds,
        processNameGraceSeconds: processNameGraceSeconds,
        approvalTimeoutSeconds: approvalTimeoutSeconds
    )
    manager.settings = settings
    return (manager, assertions, helper, power, dir)
}

// MARK: - テスト

@Suite("SessionManager: 抑止の境界", .serialized)
@MainActor
struct SuppressionBoundaryTests {
    @Test("リース数 0→1 の境界でだけ抑止を開始する")
    func activatesOnlyAtBoundary() async {
        let (manager, assertions, helper, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 600, binding: nil
        )
        #expect(assertions.acquireCount == 1)
        #expect(helper.calls == [true])

        // 2 個目では pmset を叩かない
        _ = await manager.acquire(
            client: .external(name: "b", pid: 2), label: "b", ttlSeconds: 600, binding: nil
        )
        #expect(assertions.acquireCount == 1)
        #expect(helper.calls == [true])
        #expect(manager.state == .active)
    }

    @Test("リース数 1→0 の境界でだけ抑止を解除する")
    func deactivatesOnlyAtBoundary() async {
        let (manager, assertions, helper, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let a = try! (await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 600, binding: nil
        )).get().lease
        let b = try! (await manager.acquire(
            client: .external(name: "b", pid: 2), label: "b", ttlSeconds: 600, binding: nil
        )).get().lease

        // 1 個消えてもまだ抑止は続く
        _ = await manager.release(id: a.id, requestedBy: nil)
        #expect(assertions.releaseCount == 0)
        #expect(manager.isActive)

        // 最後の 1 個が消えて初めて解除される
        _ = await manager.release(id: b.id, requestedBy: nil)
        #expect(assertions.releaseCount == 1)
        #expect(helper.calls == [true, false])
        #expect(manager.state == .idle)
    }
}

@Suite("SessionManager: degraded", .serialized)
@MainActor
struct DegradedTests {
    @Test("ヘルパーが使えなくてもアイドル抑止だけは効かせ、degraded で続行する")
    func degradesWhenHelperUnavailable() async {
        let helper = FakeHelper(isAvailable: false)
        let (manager, assertions, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 600, binding: nil
        )

        // 呼び出し元を失敗させない
        #expect(throws: Never.self) { try result.get() }
        // アイドル抑止は必ず効いている
        #expect(assertions.isHeld)
        #expect(manager.state == .degraded)
        #expect(manager.capability == .idleOnly)
        #expect(!manager.warnings.isEmpty)
    }

    @Test("接続断で degraded へ降格するが、リースは維持される")
    func degradesOnConnectionLoss() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()
        defer { Task { await manager.shutdown() } }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 600, binding: nil
        )
        #expect(manager.state == .active)

        helper.simulateConnectionLoss()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.state == .degraded)
        #expect(manager.capability == .idleOnly)
        // 抑止の要求自体は失われない
        #expect(manager.leases.count == 1)
    }

    @Test("警告は重複して積まれない")
    func warningsAreDeduplicated() async {
        let helper = FakeHelper(isAvailable: false)
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }

        for index in 0..<5 {
            _ = await manager.acquire(
                client: .external(name: "c\(index)", pid: 1), label: "x", ttlSeconds: 600, binding: nil
            )
            _ = await manager.releaseAll(requestedBy: nil)
        }
        #expect(manager.warnings.count == 1)
    }

    @Test("ヘルパーが復旧した次の開始で古い警告を消す")
    func successfulActivationClearsHelperWarning() async {
        let helper = FakeHelper(shouldFail: true)
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .interactive(trigger: .window),
            label: "first",
            ttlSeconds: 60,
            binding: nil
        )
        #expect(manager.warnings.count == 1)
        _ = await manager.releaseAll(requestedBy: nil)

        helper.shouldFail = false
        _ = await manager.acquire(
            client: .interactive(trigger: .window),
            label: "second",
            ttlSeconds: 60,
            binding: nil
        )

        #expect(manager.state == .active)
        #expect(manager.warnings.isEmpty)
    }

    @Test("停止中のヘルパー切断は状態を変更しない")
    func connectionLossWhileIdleIsIgnored() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        helper.simulateConnectionLoss()
        try? await Task.sleep(for: .milliseconds(50))

        #expect(manager.state == .idle)
        #expect(manager.warnings.isEmpty)
        await manager.shutdown()
    }
}

@Suite("SessionManager: グローバル拒否権", .serialized)
@MainActor
struct GlobalStopTests {
    @Test("TTL到達で対象リースを自動解除して理由を通知する")
    func ttlAutomaticallyReleasesLease() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(
                maxTotalDurationSeconds: nil,
                clientPolicy: .allow
            )
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = AutoReleaseRecorder()
        manager.onAutoRelease = { _, reason in recorder.record(reason: reason) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "short", pid: 1),
            label: "short",
            ttlSeconds: 1,
            binding: nil
        )
        try? await Task.sleep(for: .milliseconds(1300))

        #expect(manager.leases.isEmpty)
        #expect(recorder.reasons == [.ttlExpired])
        await manager.shutdown()
    }

    @Test("総継続時間の上限で無期限リースも自動解除する")
    func maxDurationRevokesInfiniteLease() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(
                maxTotalDurationSeconds: 1,
                clientPolicy: .allow
            )
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = AutoReleaseRecorder()
        manager.onAutoRelease = { _, reason in recorder.record(reason: reason) }
        manager.start()

        _ = await manager.acquire(
            client: .interactive(trigger: .menuBar),
            label: "manual",
            ttlSeconds: nil,
            binding: nil
        )
        try? await Task.sleep(for: .milliseconds(1300))

        #expect(manager.leases.isEmpty)
        #expect(recorder.reasons == [.maxDuration])
        await manager.shutdown()
    }

    @Test("停止中の定期評価はメニューが監視するリースを再通知しない")
    func idleTickIsNoop() async {
        let (manager, assertions, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = ObservationChangeRecorder()

        withObservationTracking {
            _ = manager.isActive
            _ = manager.leases
        } onChange: {
            recorder.record()
        }

        manager.start()
        try? await Task.sleep(for: .milliseconds(1100))

        #expect(manager.state == .idle)
        #expect(assertions.releaseCount == 0)
        #expect(recorder.count == 0)
        await manager.shutdown()
    }

    @Test("実行中もリースに変化がなければメニュー監視値を再通知しない")
    func unchangedActiveTickIsNoop() async {
        let (manager, _, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .interactive(trigger: .menuBar),
            label: "manual",
            ttlSeconds: nil,
            binding: nil
        )

        let recorder = ObservationChangeRecorder()
        withObservationTracking {
            _ = manager.isActive
            _ = manager.leases
        } onChange: {
            recorder.record()
        }

        try? await Task.sleep(for: .milliseconds(1100))

        #expect(manager.state == .active)
        #expect(recorder.count == 0)
        await manager.shutdown()
    }

    @Test("バッテリー閾値を割ると、外部クライアントのリースも含めて全て失効する")
    func batteryRevokesEverything() async {
        let power = FakePower(percent: 50, source: .battery)
        let (manager, _, helper, _, dir) = makeManager(
            settings: Settings(batteryThreshold: 20, clientPolicy: .allow),
            power: power
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        _ = await manager.acquire(
            client: .interactive(trigger: .menuBar), label: "手動", ttlSeconds: nil, binding: nil
        )
        #expect(manager.leases.count == 2)

        // バッテリーが閾値を割る
        power.set(percent: 15, source: .battery)
        try? await Task.sleep(for: .milliseconds(1300))

        #expect(manager.leases.isEmpty)
        #expect(manager.state == .idle)
        #expect(helper.calls.last == false)
        await manager.shutdown()
    }

    @Test("AC 接続中はバッテリー閾値を評価しない")
    func batteryIgnoredOnAC() async {
        let power = FakePower(percent: 5, source: .ac)
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(batteryThreshold: 20, clientPolicy: .allow),
            power: power
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        try? await Task.sleep(for: .milliseconds(1300))

        #expect(manager.leases.count == 1)
        await manager.shutdown()
    }

    @Test("熱の危険域が続けば無効化できずに全失効する")
    func thermalRevokesEverything() async {
        let power = FakePower(thermalCritical: true)
        let (manager, _, _, _, dir) = makeManager(
            // 熱以外のグローバル条件は全て無効にしておく
            settings: Settings(batteryThreshold: nil, maxTotalDurationSeconds: nil, clientPolicy: .allow),
            power: power,
            thermalGraceSeconds: 0.1
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        // 1 ティック目で計測を始め、2 ティック目で猶予超過を検出する
        try? await Task.sleep(for: .milliseconds(2300))

        #expect(manager.leases.isEmpty)
        await manager.shutdown()
    }
}

@Suite("SessionManager: 承認ポリシー", .serialized)
@MainActor
struct ClientPolicyTests {
    @Test("deny では外部クライアントの取得を拒否する")
    func denyRejectsExternal() async {
        let (manager, _, _, _, dir) = makeManager(settings: Settings(clientPolicy: .deny))
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 600, binding: nil
        )
        guard case .failure(let error) = result else {
            Issue.record("拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.denied.rawValue)
        // 呼び出し元の処理は止めない
        #expect(error.nonFatal)
        #expect(!manager.isActive)
    }

    @Test("deny でも対話的な操作は通る")
    func denyAllowsInteractive() async {
        let (manager, _, _, _, dir) = makeManager(settings: Settings(clientPolicy: .deny))
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.acquire(
            client: .interactive(trigger: .menuBar), label: "手動", ttlSeconds: nil, binding: nil
        )
        #expect(throws: Never.self) { try result.get() }
    }

    @Test("ask で応答できる UI が無ければ拒否する（黙って許可しない）")
    func askWithoutHandlerDenies() async {
        let (manager, _, _, _, dir) = makeManager(settings: Settings(clientPolicy: .ask))
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.approvalHandler = nil

        let result = await manager.acquire(
            client: .external(name: "unknown", pid: 1), label: "x", ttlSeconds: 600, binding: nil
        )
        #expect(throws: ControlError.self) { try result.get() }
    }

    @Test("ask で一度承認したクライアントは二度目以降聞かれない")
    func askRemembersApproval() async {
        let (manager, _, _, _, dir) = makeManager(settings: Settings(clientPolicy: .ask))
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = AskCounter()
        manager.approvalHandler = { _, _ in
            await counter.increment()
            return true
        }

        for _ in 0..<3 {
            _ = await manager.acquire(
                client: .external(name: "tool", pid: 1), label: "x", ttlSeconds: 600, binding: nil
            )
        }
        #expect(await counter.value == 1)
    }

    @Test("承認済みクライアントは最初から聞かれない")
    func approvedClientsSkipPrompt() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(clientPolicy: .ask, approvedClients: ["trusted"])
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let counter = AskCounter()
        manager.approvalHandler = { _, _ in
            await counter.increment()
            return true
        }

        _ = await manager.acquire(
            client: .external(name: "trusted", pid: 1), label: "x", ttlSeconds: 600, binding: nil
        )
        #expect(await counter.value == 0)
    }

    @Test("承認画面で拒否したクライアントにはリースを発行しない")
    func rejectedPromptDeniesAcquire() async {
        let (manager, _, _, _, dir) = makeManager(settings: Settings(clientPolicy: .ask))
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.approvalHandler = { _, _ in false }

        let result = await manager.acquire(
            client: .external(name: "rejected", pid: 1),
            label: "x",
            ttlSeconds: 60,
            binding: nil
        )

        guard case .failure(let error) = result else {
            Issue.record("拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.denied.rawValue)
        #expect(manager.leases.isEmpty)
    }
}

private actor AskCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

@Suite("SessionManager: リース操作API", .serialized)
@MainActor
struct LeaseOperationAPITests {
    @Test("取得上限エラーを台帳からそのまま返す")
    func acquisitionPropagatesRegistryFailure() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(clientPolicy: .allow, maxLeasesPerClient: 1)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "tool", pid: 1),
            label: "first",
            ttlSeconds: 600,
            binding: nil
        )
        let overflow = await manager.acquire(
            client: .external(name: "tool", pid: 1),
            label: "second",
            ttlSeconds: 600,
            binding: nil
        )

        guard case .failure(let error) = overflow else {
            Issue.record("上限超過になるはず")
            return
        }
        #expect(error.code == ControlErrorCode.limitExceeded.rawValue)
        #expect(manager.leases.count == 1)
    }

    @Test("IDとリースファイルの両方から更新できる")
    func renewsByIDAndLeaseFile() async throws {
        let watcher = FakeProcessWatcher(alive: true)
        let (manager, _, _, _, dir) = makeManager(watcher: watcher)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: ".lease").path(percentEncoded: false)

        let lease = try await manager.acquire(
            client: .external(name: "tool", pid: 1),
            label: "tool",
            ttlSeconds: 60,
            binding: .leaseFile(path: path)
        ).get().lease

        let byID = try manager.renew(
            id: lease.id,
            ttlSeconds: 120,
            requestedBy: .external(name: "tool", pid: 2)
        ).get()
        #expect(byID.renewCount == 1)

        let byFile = try manager.renew(
            leaseFilePath: path,
            ttlSeconds: 180,
            requestedBy: .external(name: "tool", pid: 3)
        ).get()
        #expect(byFile.renewCount == 2)

        manager.extend(id: lease.id, bySeconds: 60)
        #expect(manager.leases[0].expiresAt! > byFile.expiresAt!)
    }

    @Test("存在しないIDとリースファイルの更新はnotFoundになる")
    func missingRenewTargetsReturnNotFound() {
        let (manager, _, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let byID = manager.renew(
            id: LeaseID(rawValue: "missing"),
            ttlSeconds: 60,
            requestedBy: nil
        )
        let byFile = manager.renew(
            leaseFilePath: "/missing",
            ttlSeconds: 60,
            requestedBy: nil
        )

        #expect(throws: ControlError.self) { try byID.get() }
        #expect(throws: ControlError.self) { try byFile.get() }
    }

    @Test("リースファイルから解放でき、再解放はnotFoundになる")
    func releasesByLeaseFileIdempotently() async throws {
        let watcher = FakeProcessWatcher(alive: true)
        let (manager, _, _, _, dir) = makeManager(watcher: watcher)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: ".lease").path(percentEncoded: false)

        _ = try await manager.acquire(
            client: .external(name: "tool", pid: 1),
            label: "tool",
            ttlSeconds: 60,
            binding: .leaseFile(path: path)
        ).get()

        let released = try await manager.release(
            leaseFilePath: path,
            requestedBy: .external(name: "tool", pid: 2)
        ).get()
        #expect(released.client.name == "tool")
        #expect(manager.leases.isEmpty)

        let repeated = await manager.release(
            leaseFilePath: path,
            requestedBy: .external(name: "tool", pid: 2)
        )
        #expect(throws: ControlError.self) { try repeated.get() }
    }

    @Test("トグルは停止中なら開始し、実行中なら全解除する")
    func toggleStartsAndStops() async {
        let (manager, _, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = Client.interactive(trigger: .menuBar)

        await manager.toggle(client: client, label: "manual", ttlSeconds: 600)
        #expect(manager.leases.count == 1)

        await manager.toggle(client: client, label: "manual", ttlSeconds: 600)
        #expect(manager.leases.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test("状態スナップショットは最も早い停止条件を示す")
    func statusSnapshotUsesEarliestStopCondition() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(
                maxTotalDurationSeconds: 60,
                clientPolicy: .allow
            )
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let idle = manager.statusSnapshot()
        #expect(idle.leaseCount == 0)
        #expect(idle.endsAt == nil)

        _ = await manager.acquire(
            client: .external(name: "tool", pid: 1),
            label: "tool",
            ttlSeconds: 600,
            binding: nil
        )
        let active = manager.statusSnapshot()

        #expect(active.leaseCount == 1)
        #expect(active.endsReason == "maxDuration")
        #expect(active.leases[0].owner == "tool")
        #expect(active.endsAt != nil)
    }

    @Test("設定変更を永続化し、抑止範囲の変更だけアサーションを張り直す")
    func settingsChangesPersistAndReconfigureAssertions() async {
        let suiteName = "stayup-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = SettingsStore(defaults: defaults)
        let initial = Settings(clientPolicy: .allow)
        store.save(initial)

        let assertions = FakeAssertions()
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "stayup-settings-manager-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(
            settings: initial,
            assertions: assertions,
            helper: FakeHelper(),
            power: FakePower(),
            history: HistoryStore(directory: dir.appending(path: "history")),
            stateStore: StateStore(fileURL: dir.appending(path: "state.json")),
            settingsStore: store
        )

        manager.approveClientPermanently("trusted")
        manager.approveClientPermanently("trusted")
        #expect(manager.settings.approvedClients == ["trusted"])
        #expect(store.load().approvedClients == ["trusted"])
        #expect(assertions.acquireCount == 0)

        _ = await manager.acquire(
            client: .interactive(trigger: .window),
            label: "manual",
            ttlSeconds: 60,
            binding: nil
        )
        #expect(assertions.acquireCount == 1)

        manager.settings.keepDisplayAwake = true
        #expect(assertions.acquireCount == 2)
        #expect(assertions.lastKeepDisplayAwake)

        manager.settings.maxLeasesPerClient = 16
        #expect(assertions.acquireCount == 2)

        manager.settings.preventDiskSleep = true
        #expect(assertions.acquireCount == 3)
        #expect(assertions.lastPreventDiskSleep)
        #expect(store.load().preventDiskSleep)
    }
}

@Suite("SessionManager: バインド", .serialized)
@MainActor
struct BindingTests {
    @Test("PID終了通知を受けると待たずにリースを解放する")
    func processExitNotificationReleasesImmediately() async throws {
        let watcher = FakeProcessWatcher(alive: true)
        let exitObserver = FakeProcessExitObserver()
        let (manager, _, _, _, dir) = makeManager(
            watcher: watcher,
            exitObserver: exitObserver
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        let recorder = AutoReleaseRecorder()
        manager.onAutoRelease = { _, reason in recorder.record(reason: reason) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1),
            label: "a",
            ttlSeconds: 3600,
            binding: .pid(42)
        )
        #expect(manager.leases.count == 1)

        watcher.setAlive(false)
        exitObserver.simulateExit(pid: 42)
        try await Task.sleep(for: .milliseconds(50))

        #expect(manager.leases.isEmpty)
        #expect(exitObserver.cancelledPIDs == [42])
        #expect(recorder.reasons == [.bindingLost])
    }

    @Test("存在しない PID にはバインドできない（即座に消えるリースを作らない）")
    func rejectsDeadBinding() async {
        let (manager, _, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a",
            ttlSeconds: 600, binding: .pid(999_999)
        )
        guard case .failure(let error) = result else {
            Issue.record("拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.invalidArgument.rawValue)
        #expect(!manager.isActive)
    }

    @Test("リースファイルが消えるとリースも消える")
    func releasesWhenLeaseFileRemoved() async throws {
        let (manager, _, _, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        let leaseFile = dir.appending(path: ".stay-up-lease")
        FileManager.default.createFile(atPath: leaseFile.path(percentEncoded: false), contents: Data())

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600,
            binding: .leaseFile(path: leaseFile.path(percentEncoded: false))
        )
        #expect(manager.leases.count == 1)

        try FileManager.default.removeItem(at: leaseFile)
        try? await Task.sleep(for: .milliseconds(1300))

        #expect(manager.leases.isEmpty)
        await manager.shutdown()
    }
}

@Suite("SessionManager: 終了時の復元", .serialized)
@MainActor
struct ShutdownTests {
    @Test("所有記録なしのdisablesleepは他ツールの可能性があるため警告だけにする")
    func unownedSleepStateIsNotChanged() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: true)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await manager.recoverOwnedOrphanedState()

        #expect(helper.calls.isEmpty)
        #expect(manager.warnings == [
            "disablesleep が 1 のままですが、StayUp は何も抑止していません"
        ])
    }

    @Test("所有記録も残留設定もなければ復元処理は何もしない")
    func cleanStartupNeedsNoRecovery() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: false)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        await manager.recoverOwnedOrphanedState()

        #expect(helper.calls.isEmpty)
        #expect(manager.warnings.isEmpty)
    }

    @Test("クラッシュ後の再起動でStayUp所有のdisablesleepを復元する")
    func restartRestoresOwnedOrphan() async {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "stayup-restart-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateStore = StateStore(fileURL: dir.appending(path: "state.json"))
        let firstHelper = FakeHelper()
        let firstManager = SessionManager(
            settings: Settings(clientPolicy: .allow),
            assertions: FakeAssertions(),
            helper: firstHelper,
            power: FakePower(),
            history: HistoryStore(directory: dir.appending(path: "history")),
            stateStore: stateStore,
            settingsStore: nil
        )
        firstManager.settings = Settings(clientPolicy: .allow)

        _ = await firstManager.acquire(
            client: .external(name: "a", pid: 1),
            label: "a",
            ttlSeconds: 3600,
            binding: nil
        )
        #expect(stateStore.load()?.disableSleepSetAt != nil)

        // shutdown() を呼ばず、新しいプロセスが同じstate.jsonを読む状況を再現する。
        let restartedHelper = FakeHelper()
        let restartedManager = SessionManager(
            settings: Settings(clientPolicy: .allow),
            assertions: FakeAssertions(),
            helper: restartedHelper,
            power: FakePower(),
            history: HistoryStore(directory: dir.appending(path: "history")),
            stateStore: stateStore,
            settingsStore: nil
        )
        await restartedManager.recoverOwnedOrphanedState()

        #expect(restartedHelper.calls == [false])
        #expect(stateStore.load()?.disableSleepSetAt == nil)
        #expect(restartedManager.leases.isEmpty)
    }

    @Test("所有状態の復元に失敗したら記録を消さず再試行可能にする")
    func failedOwnedRecoveryKeepsMarker() async {
        let dir = URL(filePath: NSTemporaryDirectory())
            .appending(path: "stayup-restart-failure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let stateStore = StateStore(fileURL: dir.appending(path: "state.json"))
        let marker = Date(timeIntervalSince1970: 1_753_000_000)
        #expect(stateStore.save(PersistedState(
            leases: [],
            disableSleepSetAt: marker,
            updatedAt: marker
        )))

        let helper = FakeHelper(shouldFail: true)
        let manager = SessionManager(
            settings: Settings(clientPolicy: .allow),
            assertions: FakeAssertions(),
            helper: helper,
            power: FakePower(),
            sleepStateReader: FakeSleepStateReader(sleepDisabled: true),
            history: HistoryStore(directory: dir.appending(path: "history")),
            stateStore: stateStore,
            settingsStore: nil
        )

        await manager.recoverOwnedOrphanedState()

        #expect(stateStore.load()?.disableSleepSetAt == marker)
        #expect(manager.warnings.count == 1)
        #expect(manager.warnings[0].hasPrefix("前回のスリープ設定を復元できませんでした"))
    }

    @Test("終了時に全リースを解放し、disablesleep を戻す")
    func shutdownRestores() async {
        let (manager, assertions, helper, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        #expect(helper.disableSleepIsSet)

        await manager.shutdown()

        #expect(manager.leases.isEmpty)
        #expect(!helper.disableSleepIsSet)
        #expect(!assertions.isHeld)
    }

    @Test("forceRestore は全て捨てて idle に戻す（緊急脱出ハッチ）")
    func forceRestoreClearsEverything() async {
        let (manager, assertions, helper, _, dir) = makeManager()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        await manager.forceRestore()

        #expect(manager.leases.isEmpty)
        #expect(manager.state == .idle)
        #expect(!helper.disableSleepIsSet)
        #expect(!assertions.isHeld)
        #expect(manager.warnings.isEmpty)
    }

    // MARK: - アンインストール導線

    @Test("uninstallHelper は復元を確認してから登録解除する")
    func uninstallHelperVerifiesBeforeUnregistering() async {
        let helper = FakeHelper()
        let (manager, assertions, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: false)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        let result = await manager.uninstallHelper()

        if case .failure(let error) = result {
            Issue.record("成功するはずが失敗しました: \(error.message)")
        }
        #expect(helper.didUnregister)
        #expect(!helper.disableSleepIsSet)
        #expect(!assertions.isHeld)
        #expect(manager.leases.isEmpty)
        #expect(manager.state == .idle)
    }

    @Test("disablesleep が 1 のままなら登録解除しない")
    func uninstallHelperAbortsWhenStillDisabled() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: true)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.uninstallHelper()

        guard case .failure(.stillDisabled) = result else {
            Issue.record("stillDisabled になるはずでした")
            return
        }
        // 復元を担う唯一のプロセスを残す。これが中止の意味。
        #expect(!helper.didUnregister)
    }

    @Test("disablesleep を読めないなら登録解除しない")
    func uninstallHelperAbortsWhenStateUnknown() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: nil)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.uninstallHelper()

        guard case .failure(.stateUnknown) = result else {
            Issue.record("stateUnknown になるはずでした")
            return
        }
        #expect(!helper.didUnregister)
    }

    @Test("登録解除そのものが失敗したら理由を返す")
    func uninstallHelperReportsUnregisterFailure() async {
        let helper = FakeHelper()
        helper.unregisterShouldThrow = true
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: false)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.uninstallHelper()

        guard case .failure(.unregisterFailed) = result else {
            Issue.record("unregisterFailed になるはずでした")
            return
        }
        #expect(!helper.didUnregister)
    }

    @Test("ヘルパーが使えないときは pmset の残留を理由に止めない")
    func uninstallHelperSkipsVerificationWhenUnavailable() async {
        // 使えないヘルパーは何も抑止できない。残った 1 は他ツールのもので、
        // それを理由にこちらの登録解除を妨げるのは筋が違う。
        let helper = FakeHelper(isAvailable: false)
        let (manager, _, _, _, dir) = makeManager(
            helper: helper,
            sleepStateReader: FakeSleepStateReader(sleepDisabled: true)
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = await manager.uninstallHelper()

        if case .failure(let error) = result {
            Issue.record("成功するはずが失敗しました: \(error.message)")
        }
        #expect(helper.didUnregister)
    }

    @Test("HelperUninstallError は中止した理由を説明する")
    func uninstallErrorMessages() {
        #expect(HelperUninstallError.stillDisabled.message.contains("中止"))
        #expect(HelperUninstallError.stateUnknown.message.contains("確認できない"))
        #expect(HelperUninstallError.unregisterFailed("詳細X").message.contains("詳細X"))
    }
}

/// 記録用の小さな受け皿。
private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    var all: [String] { lock.withLock { messages } }

    func record(_ message: String) {
        lock.withLock { messages.append(message) }
    }
}

@Suite("SessionManager: 誤爆させないための猶予", .serialized)
@MainActor
struct SessionManagerGraceTests {
    @Test("熱が一瞬 critical になっただけではリースを消さない")
    func thermalSpikeDoesNotRevoke() async {
        // ふたを閉じて CPU を回すのが本来の用途なので、
        // 瞬間的な critical で全部飛ばすと目的そのものを壊す。
        let power = FakePower(thermalCritical: true)
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(batteryThreshold: nil, maxTotalDurationSeconds: nil, clientPolicy: .allow),
            power: power,
            thermalGraceSeconds: 60
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        try? await Task.sleep(for: .milliseconds(2300))

        #expect(!manager.leases.isEmpty)
        await manager.shutdown()
    }

    @Test("プロセス名バインドは猶予の内側なら生き残る")
    func processNameBindingSurvivesRestart() async {
        let watcher = FakeProcessWatcher(alive: true)
        let (manager, _, _, _, dir) = makeManager(
            watcher: watcher,
            processNameGraceSeconds: 60
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a",
            ttlSeconds: 3600, binding: .processName("dummy")
        )
        // まず生きている状態で 1 ティック回してから、再起動の一瞬を再現する
        try? await Task.sleep(for: .milliseconds(1200))
        watcher.setAlive(false)
        try? await Task.sleep(for: .milliseconds(2300))

        #expect(!manager.leases.isEmpty)
        await manager.shutdown()
    }

    @Test("プロセス名バインドは猶予を超えたら解放される")
    func processNameBindingReleasedAfterGrace() async {
        let watcher = FakeProcessWatcher(alive: true)
        let (manager, _, _, _, dir) = makeManager(
            watcher: watcher,
            processNameGraceSeconds: 0.1
        )
        defer { try? FileManager.default.removeItem(at: dir) }
        manager.start()

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a",
            ttlSeconds: 3600, binding: .processName("dummy")
        )
        watcher.setAlive(false)
        try? await Task.sleep(for: .milliseconds(2300))

        #expect(manager.leases.isEmpty)
        await manager.shutdown()
    }

    @Test("承認の応答がなければタイムアウトして拒否する")
    func approvalTimesOut() async {
        let (manager, _, _, _, dir) = makeManager(
            settings: Settings(clientPolicy: .ask),
            approvalTimeoutSeconds: 0.2
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        // 応答を返さない UI を再現する。無期限に待たないことを確かめる。
        manager.approvalHandler = { _, _ in
            try? await Task.sleep(for: .seconds(30))
            return true
        }

        let result = await manager.acquire(
            client: .external(name: "slow", pid: 1), label: "x", ttlSeconds: 60, binding: nil
        )

        guard case .failure(let error) = result else {
            Issue.record("タイムアウトで拒否されるはずでした")
            return
        }
        #expect(error.code == ControlErrorCode.denied.rawValue)
        #expect(manager.leases.isEmpty)
    }

    @Test("復元に失敗したら警告と通知を出す")
    func restoreFailureIsReported() async {
        let helper = FakeHelper()
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        #expect(manager.capability == .full)

        let recorder = MessageRecorder()
        manager.onRestoreFailed = { recorder.record($0) }
        helper.shouldFail = true
        _ = await manager.releaseAll(requestedBy: nil)

        #expect(recorder.all.count == 1)
        #expect(manager.warnings.contains { $0.contains("復元に失敗") })
    }

    @Test("degraded では復元の失敗を報告しない")
    func degradedRestoreFailureIsSilent() async {
        // 1 にしていないのだから、戻せなくても報告することはない。
        let helper = FakeHelper(isAvailable: false)
        let (manager, _, _, _, dir) = makeManager(helper: helper)
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = await manager.acquire(
            client: .external(name: "a", pid: 1), label: "a", ttlSeconds: 3600, binding: nil
        )
        #expect(manager.capability == .idleOnly)

        let recorder = MessageRecorder()
        manager.onRestoreFailed = { recorder.record($0) }
        _ = await manager.releaseAll(requestedBy: nil)

        #expect(recorder.all.isEmpty)
    }
}
