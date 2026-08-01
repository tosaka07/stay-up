import Foundation

/// 外部クライアントからのリクエストの扱い（spec §12.4）。
public enum ClientPolicy: String, Sendable, Codable, CaseIterable {
    /// 初出のクライアント名ごとに承認を求める。
    case ask
    case allow
    /// 状態の書き換えを一切受け付けない（読み取り専用）。
    case deny
}

/// spec §9 の設定項目。
public struct Settings: Sendable, Codable, Equatable {
    // 対話的リース
    public var defaultDurationSeconds: Int?

    // グローバル停止条件
    public var batteryThreshold: Int?
    public var maxTotalDurationSeconds: Int?
    public var cpuIdleThreshold: Double?
    public var cpuIdleWindowSeconds: Int

    // 外部クライアント
    public var clientPolicy: ClientPolicy
    public var approvedClients: [String]
    public var defaultClientLeaseTTLSeconds: Int
    public var maxClientLeaseTTLSeconds: Int
    public var maxLeasesPerClient: Int
    public var cliEnabled: Bool

    // 抑止の範囲
    public var keepDisplayAwake: Bool
    public var preventDiskSleep: Bool

    // UI
    public var showRemainingInMenuBar: Bool

    // ライフサイクル
    public var launchAtLogin: Bool
    public var autoStartOnLaunch: Bool

    // 保持
    public var logRetentionDays: Int

    public init(
        defaultDurationSeconds: Int? = nil,
        batteryThreshold: Int? = 20,
        maxTotalDurationSeconds: Int? = 12 * 3600,
        cpuIdleThreshold: Double? = nil,
        cpuIdleWindowSeconds: Int = 600,
        clientPolicy: ClientPolicy = .ask,
        approvedClients: [String] = [],
        defaultClientLeaseTTLSeconds: Int = 1800,
        maxClientLeaseTTLSeconds: Int = 7200,
        maxLeasesPerClient: Int = 8,
        cliEnabled: Bool = true,
        keepDisplayAwake: Bool = false,
        preventDiskSleep: Bool = false,
        showRemainingInMenuBar: Bool = false,
        launchAtLogin: Bool = true,
        autoStartOnLaunch: Bool = false,
        logRetentionDays: Int = 30
    ) {
        self.defaultDurationSeconds = defaultDurationSeconds
        self.batteryThreshold = batteryThreshold
        self.maxTotalDurationSeconds = maxTotalDurationSeconds
        self.cpuIdleThreshold = cpuIdleThreshold
        self.cpuIdleWindowSeconds = cpuIdleWindowSeconds
        self.clientPolicy = clientPolicy
        self.approvedClients = approvedClients
        self.defaultClientLeaseTTLSeconds = defaultClientLeaseTTLSeconds
        self.maxClientLeaseTTLSeconds = maxClientLeaseTTLSeconds
        self.maxLeasesPerClient = maxLeasesPerClient
        self.cliEnabled = cliEnabled
        self.keepDisplayAwake = keepDisplayAwake
        self.preventDiskSleep = preventDiskSleep
        self.showRemainingInMenuBar = showRemainingInMenuBar
        self.launchAtLogin = launchAtLogin
        self.autoStartOnLaunch = autoStartOnLaunch
        self.logRetentionDays = logRetentionDays
    }

    public static let `default` = Settings()

    /// 外部クライアントが要求した TTL を、ポリシーの範囲に収める。
    ///
    /// 無期限（nil）は対話的リースにのみ許され、外部クライアントには必ず TTL が付く。
    public func clampedTTL(requested: Int?, isInteractive: Bool) -> Int? {
        if isInteractive {
            return requested
        }
        let ttl = requested ?? defaultClientLeaseTTLSeconds
        return min(max(1, ttl), maxClientLeaseTTLSeconds)
    }
}
