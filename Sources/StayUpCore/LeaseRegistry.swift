import Foundation

/// リース取得の結果。
public enum AcquireOutcome: Sendable, Equatable {
    case created(Lease)
    /// `--if-not-exists` で既存のリースが再利用された。
    case existing(Lease)

    public var lease: Lease {
        switch self {
        case .created(let lease), .existing(let lease): lease
        }
    }
}

/// リース台帳（spec §5）。
///
/// 純粋なデータ構造として実装し、時刻は常に外から渡す。
/// 副作用（pmset・アサーション・タイマー）は `SessionManager` が持ち、
/// ここには「誰が何を持っていて、誰が何を解放できるか」だけを置く。
public struct LeaseRegistry: Sendable {
    private var storage: [LeaseID: Lease] = [:]

    public init(leases: [Lease] = []) {
        for lease in leases {
            storage[lease.id] = lease
        }
    }

    // MARK: - 参照

    /// 取得順に並んだ全リース。
    public var leases: [Lease] {
        storage.values.sorted { $0.acquiredAt < $1.acquiredAt }
    }

    public var count: Int { storage.count }

    /// 有効なリースが 1 つ以上あるか。抑止するかどうかはこれだけで決まる。
    public var isActive: Bool { !storage.isEmpty }

    public func lease(id: LeaseID) -> Lease? { storage[id] }

    public func lease(leaseFilePath path: String) -> Lease? {
        storage.values.first { $0.binding == .leaseFile(path: path) }
    }

    public func count(forClientNamed name: String) -> Int {
        storage.values.count { $0.client.name == name }
    }

    /// 最も早く終わるリースの期限。無期限のリースがあれば nil。
    public func earliestExpiry() -> Date? {
        var earliest: Date?
        for lease in storage.values {
            guard let expiresAt = lease.expiresAt else { return nil }
            if earliest == nil || expiresAt < earliest! {
                earliest = expiresAt
            }
        }
        return earliest
    }

    // MARK: - 取得

    /// リースを 1 つ作る。
    ///
    /// TTL の切り詰めと同時保持数の上限はここで適用する。
    /// 承認モード（`ClientPolicy`）の判定は呼び出し側の責務。
    public mutating func acquire(
        client: Client,
        label: String,
        requestedTTLSeconds: Int?,
        binding: LeaseBinding?,
        ifNotExists: Bool,
        settings: Settings,
        now: Date = Date()
    ) -> Result<AcquireOutcome, ControlError> {
        // --if-not-exists: 同じリースファイルに紐づくものがあれば再利用する（冪等）
        if ifNotExists, case .leaseFile(let path)? = binding, let existing = lease(leaseFilePath: path) {
            return .success(.existing(existing))
        }

        if !client.isInteractive {
            let existing = count(forClientNamed: client.name)
            guard existing < settings.maxLeasesPerClient else {
                return .failure(ControlError(
                    code: .limitExceeded,
                    message: "\"\(client.name)\" のリースが上限 \(settings.maxLeasesPerClient) 件に達しています",
                    nonFatal: true
                ))
            }
        }

        let ttl = settings.clampedTTL(requested: requestedTTLSeconds, isInteractive: client.isInteractive)
        let lease = Lease(
            client: client,
            label: label,
            acquiredAt: now,
            expiresAt: ttl.map { now.addingTimeInterval(Double($0)) },
            binding: binding
        )
        storage[lease.id] = lease
        return .success(.created(lease))
    }

    // MARK: - 更新

    /// TTL を延長する。クライアントはこれをハートビートとして使う。
    public mutating func renew(
        id: LeaseID,
        ttlSeconds: Int?,
        requestedBy client: Client?,
        settings: Settings,
        now: Date = Date()
    ) -> Result<Lease, ControlError> {
        guard var lease = storage[id] else {
            return .failure(ControlError(code: .notFound, message: "リースが見つかりません: \(id)", nonFatal: true))
        }
        if let client, let error = authorize(client, toModify: lease) {
            return .failure(error)
        }

        let ttl = settings.clampedTTL(
            requested: ttlSeconds,
            isInteractive: lease.client.isInteractive
        )
        lease.expiresAt = ttl.map { now.addingTimeInterval(Double($0)) }
        lease.lastRenewedAt = now
        lease.renewCount += 1
        storage[id] = lease
        return .success(lease)
    }

    /// 対話的リースを一定時間延長する（メニューの「+30分」）。
    public mutating func extend(id: LeaseID, bySeconds seconds: Int, now: Date = Date()) -> Lease? {
        guard var lease = storage[id] else { return nil }
        // 既に切れかけている場合は現在時刻を起点にする
        let base = max(lease.expiresAt ?? now, now)
        lease.expiresAt = base.addingTimeInterval(Double(seconds))
        storage[id] = lease
        return lease
    }

    // MARK: - 解放

    /// 明示的に 1 件解放する。
    public mutating func release(
        id: LeaseID,
        requestedBy client: Client?
    ) -> Result<Lease, ControlError> {
        guard let lease = storage[id] else {
            // 既に失効しているのは正常なケースなので、冪等に扱う
            return .failure(ControlError(code: .notFound, message: "リースが見つかりません: \(id)", nonFatal: true))
        }
        if let client, let error = authorize(client, toModify: lease) {
            return .failure(error)
        }
        storage.removeValue(forKey: id)
        return .success(lease)
    }

    /// 指定クライアントのリースを全て解放する。
    ///
    /// `client` が対話的な場合は**外部クライアントのものも含めて全て**解放する。
    /// ユーザーの明示的な意思が最優先（spec §8.1）。
    public mutating func releaseAll(requestedBy client: Client?) -> [Lease] {
        let victims: [Lease]
        switch client {
        case .none:
            victims = leases
        case .some(let client) where client.isInteractive:
            victims = leases
        case .some(let client):
            victims = leases.filter { $0.client.name == client.name }
        }
        for lease in victims {
            storage.removeValue(forKey: lease.id)
        }
        return victims
    }

    /// 全リースを強制失効させる（グローバル停止条件）。
    public mutating func revokeAll() -> [Lease] {
        let all = leases
        storage.removeAll()
        return all
    }

    // MARK: - 自動失効

    /// TTL 切れのリースを取り除いて返す。
    public mutating func expireLapsed(now: Date = Date()) -> [Lease] {
        let expired = storage.values.filter { $0.isExpired(at: now) }
        for lease in expired {
            storage.removeValue(forKey: lease.id)
        }
        return expired.sorted { $0.acquiredAt < $1.acquiredAt }
    }

    /// バインド対象が消えたリースを取り除いて返す。
    ///
    /// 生存判定は外から渡す（プロセス確認とファイル確認を注入可能にする）。
    public mutating func releaseLostBindings(
        isAlive: (LeaseBinding) -> Bool
    ) -> [Lease] {
        let lost = storage.values.filter { lease in
            guard let binding = lease.binding else { return false }
            return !isAlive(binding)
        }
        for lease in lost {
            storage.removeValue(forKey: lease.id)
        }
        return lost.sorted { $0.acquiredAt < $1.acquiredAt }
    }

    // MARK: - 権限

    /// 外部クライアントは自分と同じ名前のリースしか触れない（spec §12.4）。
    private func authorize(_ client: Client, toModify lease: Lease) -> ControlError? {
        if client.isInteractive { return nil }
        if lease.client.name == client.name { return nil }
        return ControlError(
            code: .denied,
            message: "\"\(client.name)\" は \"\(lease.client.name)\" のリースを操作できません",
            nonFatal: true
        )
    }
}
