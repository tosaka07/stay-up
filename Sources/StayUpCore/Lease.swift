import Foundation

/// リースの不透明な識別子。ULID 風の「時刻順に並ぶランダム ID」。
public struct LeaseID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 生成順に辞書順で並ぶ 26 文字の ID。
    public static func generate(now: Date = Date()) -> LeaseID {
        var timestamp = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var chars = [Character](repeating: "0", count: 26)
        // 先頭 10 文字 = ミリ秒タイムスタンプ（base32）
        for index in stride(from: 9, through: 0, by: -1) {
            chars[index] = alphabet[Int(timestamp % 32)]
            timestamp /= 32
        }
        // 残り 16 文字 = 乱数
        for index in 10..<26 {
            chars[index] = alphabet[Int.random(in: 0..<32)]
        }
        return LeaseID(rawValue: String(chars))
    }
}

/// リースを要求した主体。
///
/// spec §5.0 の通り 2 ケースのみ。「対話的か、外部プロセスからか」だけが
/// 振る舞いの差を生む本質的な区別で、それ以外は表示用の文字列でしかない。
public enum Client: Sendable, Codable, Equatable {
    /// アプリ自身の UI から要求されたもの。
    case interactive(trigger: Trigger)
    /// CLI 経由の外部プロセス。`name` は自由文字列で、中身は解釈しない。
    case external(name: String, pid: pid_t)

    public enum Trigger: String, Sendable, Codable, CaseIterable {
        case menuBar
        case window
        case hotkey
        case shortcut
        case urlScheme
        case autoStart
    }

    /// 表示・集計・ポリシー適用のキー。
    public var name: String {
        switch self {
        case .interactive: "手動"
        case .external(let name, _): name
        }
    }

    public var isInteractive: Bool {
        if case .interactive = self { return true }
        return false
    }

    public var pid: pid_t? {
        if case .external(_, let pid) = self { return pid }
        return nil
    }
}

/// リースの生存を外部の存在に紐づける方法。
public enum LeaseBinding: Sendable, Codable, Equatable {
    /// そのプロセスが消えたら自動解放。
    case pid(pid_t)
    /// ファイルが消えたら自動解放。
    case leaseFile(path: String)
    /// 名前でマッチするプロセスが全て消えたら自動解放。
    case processName(String)

    public var displayText: String {
        switch self {
        case .pid(let pid): "pid:\(pid)"
        case .leaseFile(let path): "file:\((path as NSString).lastPathComponent)"
        case .processName(let name): "name:\(name)"
        }
    }
}

/// 「スリープを抑止せよ」という要求の 1 単位。
public struct Lease: Sendable, Codable, Equatable, Identifiable {
    public let id: LeaseID
    public let client: Client
    /// UI に出す人間可読な説明。アプリは中身を解釈しない。
    public let label: String
    public let acquiredAt: Date
    /// TTL。nil（無期限）は `.interactive` のみ許可される。
    public var expiresAt: Date?
    public let binding: LeaseBinding?
    public var lastRenewedAt: Date
    public var renewCount: Int

    public init(
        id: LeaseID = .generate(),
        client: Client,
        label: String,
        acquiredAt: Date = Date(),
        expiresAt: Date? = nil,
        binding: LeaseBinding? = nil
    ) {
        self.id = id
        self.client = client
        self.label = label
        self.acquiredAt = acquiredAt
        self.expiresAt = expiresAt
        self.binding = binding
        self.lastRenewedAt = acquiredAt
        self.renewCount = 0
    }

    public func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    public func remainingSeconds(at now: Date) -> Int? {
        guard let expiresAt else { return nil }
        return max(0, Int(expiresAt.timeIntervalSince(now).rounded()))
    }

    public func durationSeconds(at now: Date) -> Int {
        max(0, Int(now.timeIntervalSince(acquiredAt).rounded()))
    }
}

/// リースが終わった理由。
public enum ReleaseReason: String, Sendable, Codable {
    // リース単位
    case explicit
    case ttlExpired
    case bindingLost
    // グローバル失効
    case battery
    case cpuIdle
    case thermal
    case maxDuration
    // システム
    case helperLost
    case appTerminating
    case systemShutdown
    case error

    public var isGlobal: Bool {
        switch self {
        case .battery, .cpuIdle, .thermal, .maxDuration: true
        default: false
        }
    }

    public var localizedDescription: String {
        switch self {
        case .explicit: "手動で解放"
        case .ttlExpired: "TTL 切れ"
        case .bindingLost: "バインド対象の消滅"
        case .battery: "バッテリー閾値"
        case .cpuIdle: "CPU アイドル"
        case .thermal: "熱状態"
        case .maxDuration: "総継続時間の上限"
        case .helperLost: "ヘルパーとの通信断"
        case .appTerminating: "アプリ終了"
        case .systemShutdown: "システム終了"
        case .error: "エラー"
        }
    }
}

/// 抑止の実効レベル。
public enum SuppressionCapability: String, Sendable, Codable {
    /// クラムシェルスリープも抑止できている。
    case full
    /// アイドルスリープのみ。ふたを閉じるとスリープする。
    case idleOnly

    public var localizedDescription: String {
        switch self {
        case .full: "ふたを閉じてもスリープしません"
        case .idleOnly: "ふたを閉じるとスリープします"
        }
    }
}

/// 状態機械の状態。
public enum SuppressionState: String, Sendable, Codable {
    case idle
    case activating
    case active
    case deactivating
    /// ヘルパー不在等でアイドル抑止のみ有効。
    case degraded
}
