import Foundation
import Observation
import StayUpCore
import os

/// 状態機械の本体（spec §5.1）。
///
/// UI も CLI もここだけを見る。真実の源はこのクラスが 1 つだけ持つ。
/// 遷移は**リース数が 0 と非 0 の境界を跨いだときだけ**発生し、
/// 2 個目の取得や 2 個中 1 個の解放では `pmset` を叩かない。
@MainActor
@Observable
public final class SessionManager {
    // MARK: - 公開状態

    public private(set) var state: SuppressionState = .idle
    public private(set) var capability: SuppressionCapability = .idleOnly
    public private(set) var leases: [Lease] = []
    public private(set) var battery: PowerReading = PowerReading(percent: nil, source: .unknown)
    public private(set) var warnings: [String] = []
    /// 抑止が始まった時刻（リース数が 0 → 1 になった瞬間）。
    public private(set) var suppressionStartedAt: Date?

    public var settings: Settings {
        didSet { settingsDidChange(from: oldValue) }
    }

    public var isActive: Bool { registry.isActive }

    /// 承認が必要なクライアントが現れたときに UI へ問い合わせる。
    /// nil のときは `ask` を `deny` として扱う（UI が無い状況で勝手に許可しない）。
    public var approvalHandler: ((String, String?) async -> Bool)?
    /// リースが自動で失効したときの通知用。
    public var onAutoRelease: (([Lease], ReleaseReason) -> Void)?

    // MARK: - 依存

    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "lease")
    private let assertions: any SleepAssertionHolding
    private var helper: any PrivilegedSleepControlling
    private let power: any PowerObserving
    private let watcher: any ProcessWatching
    private let exitObserver: any ProcessExitObserving
    private let sleepStateReader: any SleepStateReading
    private let history: HistoryStore
    private let stateStore: StateStore
    private let settingsStore: SettingsStore?

    private var registry = LeaseRegistry()
    private var ticker: Timer?
    /// 承認待ち・承認済みの判断をここで一度だけ行う。
    private var sessionApprovedClients: Set<String> = []

    public init(
        settings: Settings = .default,
        assertions: any SleepAssertionHolding = AssertionController(),
        helper: any PrivilegedSleepControlling = HelperClient(),
        power: any PowerObserving = PowerMonitor(),
        watcher: any ProcessWatching = ProcessWatcher(),
        exitObserver: any ProcessExitObserving = ProcessExitObserver(),
        sleepStateReader: any SleepStateReading = PMSetSleepStateReader(),
        history: HistoryStore = HistoryStore(),
        stateStore: StateStore = StateStore(),
        settingsStore: SettingsStore? = SettingsStore()
    ) {
        self.settingsStore = settingsStore
        self.settings = settingsStore?.load() ?? settings
        self.assertions = assertions
        self.helper = helper
        self.power = power
        self.watcher = watcher
        self.exitObserver = exitObserver
        self.sleepStateReader = sleepStateReader
        self.history = history
        self.stateStore = stateStore
    }

    // MARK: - 起動と終了

    public func start() {
        try? StayUpPaths.createSupportDirectories()
        history.pruneOldFiles(retentionDays: settings.logRetentionDays)
        battery = power.read()

        helper.onConnectionLost = { [weak self] in
            Task { @MainActor in self?.handleHelperLoss() }
        }
        power.startMonitoring { [weak self] reading in
            Task { @MainActor in self?.handlePowerChange(reading) }
        }

        startTicker()
    }

    /// アプリ終了時。復元保証の層 3。
    public func shutdown(reason: ReleaseReason = .appTerminating) async {
        ticker?.invalidate()
        ticker = nil
        exitObserver.cancelAll()
        power.stopMonitoring()

        let victims = registry.revokeAll()
        if !victims.isEmpty {
            recordReleases(victims, reason: reason)
        }
        await deactivateSuppression()
        helper.disconnect()
        persist()
    }

    // MARK: - 取得

    /// リースを 1 つ取得する。
    ///
    /// ヘルパーが使えなくても `degraded` で成立させる。
    /// 抑止は本来の作業の付随物なので、ここで失敗させて呼び出し元を止めない（spec §10）。
    public func acquire(
        client: Client,
        label: String,
        ttlSeconds: Int?,
        binding: LeaseBinding?,
        ifNotExists: Bool = false,
        reason: String? = nil
    ) async -> Result<AcquireOutcome, ControlError> {
        if !client.isInteractive {
            switch await authorize(client: client, reason: reason) {
            case .failure(let error):
                return .failure(error)
            case .success:
                break
            }
        }

        // バインド対象が最初から居ないなら、即座に消えるリースを作らない
        if let binding, !watcher.isAlive(binding) {
            return .failure(ControlError(
                code: .invalidArgument,
                message: "バインド対象が見つかりません: \(binding.displayText)",
                nonFatal: true
            ))
        }

        let wasActive = registry.isActive
        let result = registry.acquire(
            client: client,
            label: label,
            requestedTTLSeconds: ttlSeconds,
            binding: binding,
            ifNotExists: ifNotExists,
            settings: settings,
            now: Date()
        )

        guard case .success(let outcome) = result else { return result }

        if case .created(let lease) = outcome {
            history.append(.acquired(lease))
            observeBinding(of: lease)
            log.notice("リース取得: \(lease.client.name, privacy: .public) ttl=\(lease.expiresAt?.description ?? "∞", privacy: .public)")
        }

        // 0 → 1 の境界を跨いだときだけ実際に抑止を始める
        if !wasActive {
            await activateSuppression()
        }
        refresh()
        return result
    }

    // MARK: - 更新

    public func renew(id: LeaseID, ttlSeconds: Int?, requestedBy client: Client?) -> Result<Lease, ControlError> {
        let result = registry.renew(
            id: id, ttlSeconds: ttlSeconds, requestedBy: client,
            settings: settings, now: Date()
        )
        if case .success = result { refresh() }
        return result
    }

    public func renew(leaseFilePath: String, ttlSeconds: Int?, requestedBy client: Client?) -> Result<Lease, ControlError> {
        guard let lease = registry.lease(leaseFilePath: leaseFilePath) else {
            return .failure(ControlError(
                code: .notFound,
                message: "リースファイルに対応するリースがありません: \(leaseFilePath)",
                nonFatal: true
            ))
        }
        return renew(id: lease.id, ttlSeconds: ttlSeconds, requestedBy: client)
    }

    public func extend(id: LeaseID, bySeconds seconds: Int) {
        _ = registry.extend(id: id, bySeconds: seconds, now: Date())
        refresh()
    }

    // MARK: - 解放

    public func release(id: LeaseID, requestedBy client: Client?) async -> Result<Lease, ControlError> {
        let result = registry.release(id: id, requestedBy: client)
        if case .success(let lease) = result {
            finishRelease([lease], reason: .explicit)
            await deactivateIfIdle()
        }
        return result
    }

    public func release(leaseFilePath: String, requestedBy client: Client?) async -> Result<Lease, ControlError> {
        guard let lease = registry.lease(leaseFilePath: leaseFilePath) else {
            // 既に失効しているのは正常。冪等に扱う。
            return .failure(ControlError(
                code: .notFound,
                message: "リースファイルに対応するリースがありません（既に解放済みの可能性）",
                nonFatal: true
            ))
        }
        return await release(id: lease.id, requestedBy: client)
    }

    @discardableResult
    public func releaseAll(requestedBy client: Client?) async -> [Lease] {
        let victims = registry.releaseAll(requestedBy: client)
        if !victims.isEmpty {
            finishRelease(victims, reason: .explicit)
            await deactivateIfIdle()
        }
        return victims
    }

    /// メニューバー / コントロールのトグル。
    public func toggle(client: Client, label: String, ttlSeconds: Int?) async {
        if registry.isActive {
            await releaseAll(requestedBy: client)
        } else {
            _ = await acquire(client: client, label: label, ttlSeconds: ttlSeconds, binding: nil)
        }
    }

    // MARK: - 状態の公開

    public func statusSnapshot() -> StatusSnapshot {
        let (endsAt, endsReason) = projectedEnd()
        return StatusSnapshot(
            state: state,
            capability: capability,
            leases: registry.leases.map(LeaseSnapshot.init),
            activeSince: suppressionStartedAt,
            endsAt: endsAt,
            endsReason: endsReason,
            battery: battery.snapshot,
            warnings: warnings
        )
    }

    /// 次に抑止が終わる時刻と、その理由。
    private func projectedEnd() -> (Date?, String?) {
        var candidates: [(Date, String)] = []
        if let expiry = registry.earliestExpiry() {
            candidates.append((expiry, "ttl"))
        }
        if let start = suppressionStartedAt, let maxTotal = settings.maxTotalDurationSeconds {
            candidates.append((start.addingTimeInterval(Double(maxTotal)), "maxDuration"))
        }
        guard let soonest = candidates.min(by: { $0.0 < $1.0 }) else { return (nil, nil) }
        return (soonest.0, soonest.1)
    }

    // MARK: - 抑止の実行

    private func activateSuppression() async {
        state = .activating
        suppressionStartedAt = Date()

        // アイドル抑止は root 不要なので必ず先に効かせる
        assertions.acquire(
            keepDisplayAwake: settings.keepDisplayAwake,
            preventDiskSleep: settings.preventDiskSleep
        )

        // クラムシェル抑止はヘルパー経由。失敗しても degraded で続行する。
        let result = await helper.setDisableSleep(true)
        switch result {
        case .success:
            capability = .full
            state = .active
            warnings.removeAll { $0.hasPrefix("helper:") }
        case .failure(let error):
            capability = .idleOnly
            state = .degraded
            appendWarning("helper: \(error.message)")
            log.error("クラムシェル抑止を有効化できませんでした: \(error.message, privacy: .public)")
        }

        history.append(HistoryEvent(event: .suppressionStarted, leaseCount: registry.count))
        persist()
    }

    private func deactivateIfIdle() async {
        guard !registry.isActive else {
            refresh()
            return
        }
        await deactivateSuppression()
    }

    private func deactivateSuppression() async {
        guard state != .idle else { return }
        state = .deactivating

        assertions.releaseAll()
        _ = await helper.setDisableSleep(false)

        let duration = suppressionStartedAt.map { Int(Date().timeIntervalSince($0).rounded()) }
        history.append(HistoryEvent(event: .suppressionEnded, duration: duration, leaseCount: 0))

        suppressionStartedAt = nil
        capability = .idleOnly
        state = .idle
        refresh()
    }

    // MARK: - 自動失効

    private func startTicker() {
        // 1 秒ごとに TTL とグローバル条件を見る。
        // 電源とプロセスの監視はイベント駆動なので、ここは軽い判定だけ。
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func tick() async {
        // 停止中に台帳へ mutating アクセスすると、値が空のままでも Observation が
        // isActive の変更として通知し、開いているネイティブメニューを再構築してしまう。
        guard registry.isActive else { return }

        let now = Date()

        // グローバル条件はリースより強い（spec §5.2）
        if let reason = evaluateGlobalStop(now: now) {
            let victims = registry.revokeAll()
            if !victims.isEmpty {
                history.append(HistoryEvent(
                    event: .globalStop, reason: reason.rawValue, leaseCount: victims.count
                ))
                finishRelease(victims, reason: reason)
                onAutoRelease?(victims, reason)
            }
            await deactivateIfIdle()
            return
        }

        let hasExpiredLease = registry.leases.contains { $0.isExpired(at: now) }
        let expired = hasExpiredLease
            ? registry.expireLapsed(now: now)
            : []
        if !expired.isEmpty {
            finishRelease(expired, reason: .ttlExpired)
            onAutoRelease?(expired, .ttlExpired)
        }

        let hasLostBinding = registry.leases.contains { [watcher] lease in
            guard let binding = lease.binding else { return false }
            return !watcher.isAlive(binding)
        }
        let lost = hasLostBinding
            ? registry.releaseLostBindings { [watcher] binding in
                watcher.isAlive(binding)
            }
            : []
        if !lost.isEmpty {
            finishRelease(lost, reason: .bindingLost)
            onAutoRelease?(lost, .bindingLost)
        }

        if !expired.isEmpty || !lost.isEmpty {
            await deactivateIfIdle()
        }
    }

    /// グローバル停止条件の評価（spec §7.2 / §7.5 / §7.6）。
    private func evaluateGlobalStop(now: Date) -> ReleaseReason? {
        // 熱は無効化できない安全機構
        if power.isThermalCritical { return .thermal }

        if let threshold = settings.batteryThreshold,
           battery.source == .battery,
           let percent = battery.percent,
           percent <= threshold {
            return .battery
        }

        if let maxTotal = settings.maxTotalDurationSeconds,
           let start = suppressionStartedAt,
           now.timeIntervalSince(start) >= Double(maxTotal) {
            return .maxDuration
        }

        return nil
    }

    // MARK: - イベント

    private func handlePowerChange(_ reading: PowerReading) {
        battery = reading
    }

    private func handleHelperLoss() {
        guard registry.isActive else { return }
        // アイドル抑止は生きているので degraded に降格して続行する
        capability = .idleOnly
        state = .degraded
        appendWarning("helper: ヘルパーとの接続が切れました")
        history.append(HistoryEvent(event: .helperError, detail: "connection lost"))
        log.error("ヘルパーとの接続が切れたため degraded に降格しました")
    }

    private func observeBinding(of lease: Lease) {
        guard case .pid(let pid)? = lease.binding else { return }
        // kqueue で終了を即座に拾う。ticker の 1 秒待ちを避けるための最適化。
        exitObserver.observe(pid: pid) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
    }

    /// 前回のクラッシュでStayUp所有の `disablesleep=1` が残っていれば復元する。
    ///
    /// `disableSleepSetAt` がある場合だけ自動復元する。他ツールが設定した可能性のある
    /// `disablesleep=1` は変更せず、従来どおり警告に留める。
    public func recoverOwnedOrphanedState() async {
        guard stateStore.load()?.disableSleepSetAt != nil else {
            checkForUnownedOrphanedState()
            return
        }

        let result = await helper.setDisableSleep(false)
        switch result {
        case .success:
            _ = stateStore.clear()
            let message = "前回の異常終了で残ったスリープ設定を復元しました"
            history.append(HistoryEvent(event: .orphanDetected, detail: message))
            log.notice("\(message, privacy: .public)")

        case .failure(let error):
            let message = "前回のスリープ設定を復元できませんでした: \(error.message)"
            appendWarning(message)
            history.append(HistoryEvent(event: .helperError, detail: message))
            log.error("\(message, privacy: .public)")
        }
    }

    /// 起動時、追跡していない `disablesleep=1` が残っていないか確かめる（spec §10）。
    ///
    /// 他ツールが正当に設定している可能性があるので**自動復元はしない**。警告に留める。
    private func checkForUnownedOrphanedState() {
        guard sleepStateReader.isSleepDisabled() == true else { return }
        let message = "disablesleep が 1 のままですが、StayUp は何も抑止していません"
        appendWarning(message)
        history.append(HistoryEvent(event: .orphanDetected, detail: message))
        log.error("\(message, privacy: .public)")
    }

    /// ユーザーが明示的に復元を選んだとき（診断タブの緊急脱出ハッチ）。
    public func forceRestore() async {
        let victims = registry.revokeAll()
        if !victims.isEmpty { recordReleases(victims, reason: .explicit) }
        assertions.releaseAll()
        _ = await helper.setDisableSleep(false)
        warnings.removeAll()
        suppressionStartedAt = nil
        capability = .idleOnly
        state = .idle
        refresh()
    }

    // MARK: - 承認

    private func authorize(client: Client, reason: String?) async -> Result<Void, ControlError> {
        switch settings.clientPolicy {
        case .deny:
            return .failure(ControlError(
                code: .denied,
                message: "外部クライアントからの操作は拒否されています（clientPolicy: deny）",
                nonFatal: true
            ))
        case .allow:
            return .success(())
        case .ask:
            let name = client.name
            if settings.approvedClients.contains(name) || sessionApprovedClients.contains(name) {
                return .success(())
            }
            guard let approvalHandler else {
                return .failure(ControlError(
                    code: .denied,
                    message: "承認が必要ですが、応答できる UI がありません",
                    nonFatal: true
                ))
            }
            let approved = await approvalHandler(name, reason)
            guard approved else {
                return .failure(ControlError(
                    code: .denied,
                    message: "\"\(name)\" からの要求は拒否されました",
                    nonFatal: true
                ))
            }
            sessionApprovedClients.insert(name)
            return .success(())
        }
    }

    /// UI やソケット層から警告を積む。
    public func appendWarning(_ message: String) {
        guard !warnings.contains(message) else { return }
        warnings.append(message)
    }

    public func approveClientPermanently(_ name: String) {
        guard !settings.approvedClients.contains(name) else { return }
        settings.approvedClients.append(name)
    }

    // MARK: - 後始末

    private func finishRelease(_ leases: [Lease], reason: ReleaseReason) {
        recordReleases(leases, reason: reason)
        for lease in leases {
            if case .pid(let pid)? = lease.binding {
                exitObserver.cancel(pid: pid)
            }
        }
        refresh()
    }

    private func recordReleases(_ leases: [Lease], reason: ReleaseReason) {
        let now = Date()
        for lease in leases {
            history.append(.released(lease, reason: reason, at: now))
        }
    }

    private func settingsDidChange(from old: Settings) {
        guard old != settings else { return }
        settingsStore?.save(settings)

        guard registry.isActive else { return }
        if old.keepDisplayAwake != settings.keepDisplayAwake
            || old.preventDiskSleep != settings.preventDiskSleep {
            assertions.acquire(
                keepDisplayAwake: settings.keepDisplayAwake,
                preventDiskSleep: settings.preventDiskSleep
            )
        }
    }

    private func refresh() {
        leases = registry.leases
        persist()
    }

    private func persist() {
        stateStore.save(PersistedState(
            leases: registry.leases,
            disableSleepSetAt: capability == .full ? suppressionStartedAt : nil
        ))
    }
}
