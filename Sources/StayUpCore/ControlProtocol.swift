import Foundation

/// CLI とアプリの間で流れるメッセージ（spec §12.1）。
///
/// 1 行 1 メッセージの JSON。UNIX ドメインソケット上を双方向に流れる。
public enum ControlProtocol {
    /// スキーマのバージョン。破壊的変更をしないための契約。
    public static let version = 1
}

public struct AcquireOptions: Sendable, Codable, Equatable {
    public var owner: String?
    public var label: String?
    public var ttlSeconds: Int?
    public var binding: LeaseBinding?
    public var leaseFilePath: String?
    public var ifNotExists: Bool
    public var reason: String?
    /// 呼び出し元プロセスの PID。ソケット越しに自己申告される。
    public var clientPID: pid_t?

    public init(
        owner: String? = nil,
        label: String? = nil,
        ttlSeconds: Int? = nil,
        binding: LeaseBinding? = nil,
        leaseFilePath: String? = nil,
        ifNotExists: Bool = false,
        reason: String? = nil,
        clientPID: pid_t? = nil
    ) {
        self.owner = owner
        self.label = label
        self.ttlSeconds = ttlSeconds
        self.binding = binding
        self.leaseFilePath = leaseFilePath
        self.ifNotExists = ifNotExists
        self.reason = reason
        self.clientPID = clientPID
    }
}

public enum ControlRequest: Sendable, Codable {
    case acquire(AcquireOptions)
    case renew(id: LeaseID?, leaseFilePath: String?, ttlSeconds: Int?, owner: String?)
    case release(id: LeaseID?, leaseFilePath: String?, owner: String?)
    case releaseAll(owner: String?)
    case list
    case status
    case toggle(AcquireOptions)
    /// 全リースが消えるまでサーバ側で待つ。
    case wait
    case doctor
}

/// リースの外部表現。`status --json` / `list --json` の安定した契約。
public struct LeaseSnapshot: Sendable, Codable, Equatable {
    public let id: LeaseID
    public let owner: String
    /// `interactive` / `external`
    public let kind: String
    public let label: String
    public let acquiredAt: Date
    public let expiresAt: Date?
    public let binding: String?
    public let renewCount: Int

    public init(lease: Lease) {
        self.id = lease.id
        self.owner = lease.client.name
        self.kind = lease.client.isInteractive ? "interactive" : "external"
        self.label = lease.label
        self.acquiredAt = lease.acquiredAt
        self.expiresAt = lease.expiresAt
        self.binding = lease.binding?.displayText
        self.renewCount = lease.renewCount
    }
}

public struct BatterySnapshot: Sendable, Codable, Equatable {
    public let percent: Int?
    /// `ac` / `battery` / `unknown`
    public let source: String

    public init(percent: Int?, source: String) {
        self.percent = percent
        self.source = source
    }
}

/// `stay-up status --json` の出力（spec §12.5）。
public struct StatusSnapshot: Sendable, Codable, Equatable {
    public var v: Int = ControlProtocol.version
    public let state: String
    public let capability: String
    public let leaseCount: Int
    public let activeSince: Date?
    public let endsAt: Date?
    public let endsReason: String?
    public let leases: [LeaseSnapshot]
    public let battery: BatterySnapshot
    public let warnings: [String]

    public init(
        state: SuppressionState,
        capability: SuppressionCapability,
        leases: [LeaseSnapshot],
        activeSince: Date?,
        endsAt: Date?,
        endsReason: String?,
        battery: BatterySnapshot,
        warnings: [String]
    ) {
        self.state = state.rawValue
        self.capability = capability.rawValue
        self.leaseCount = leases.count
        self.activeSince = activeSince
        self.endsAt = endsAt
        self.endsReason = endsReason
        self.leases = leases
        self.battery = battery
        self.warnings = warnings
    }
}

/// CLI の終了コード（spec §10）。
public enum ControlErrorCode: Int, Sendable, Codable {
    case generic = 1
    case notConnected = 2
    case notFound = 3
    case appUnavailable = 4
    case denied = 5
    case limitExceeded = 6
    case invalidArgument = 7
}

public struct ControlError: Sendable, Codable, Equatable, Error {
    public let code: Int
    public let message: String
    /// 抑止は本来の作業の付随物なので、失敗しても呼び出し元を止めない場合がある。
    public let nonFatal: Bool

    public init(code: ControlErrorCode, message: String, nonFatal: Bool = false) {
        self.code = code.rawValue
        self.message = message
        self.nonFatal = nonFatal
    }
}

public enum ControlResponse: Sendable, Codable {
    case acquired(lease: LeaseSnapshot, capability: String, warning: String?)
    case renewed(lease: LeaseSnapshot)
    case released(count: Int)
    case list([LeaseSnapshot])
    case status(StatusSnapshot)
    case doctor(DoctorReport)
    case ok
    case failure(ControlError)
}

public struct DoctorReport: Sendable, Codable, Equatable {
    public struct Check: Sendable, Codable, Equatable {
        public let name: String
        public let ok: Bool
        public let detail: String
        public let remedy: String?

        public init(name: String, ok: Bool, detail: String, remedy: String? = nil) {
            self.name = name
            self.ok = ok
            self.detail = detail
            self.remedy = remedy
        }
    }

    public let checks: [Check]

    public init(checks: [Check]) {
        self.checks = checks
    }
}

// MARK: - エンコーディング

public enum ControlCoding {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 改行区切りで送るため、ペイロードに生の改行が混ざらないようにする。
    public static func encodeLine<T: Encodable>(_ value: T) throws -> Data {
        var data = try makeEncoder().encode(value)
        data.append(0x0A)
        return data
    }
}
