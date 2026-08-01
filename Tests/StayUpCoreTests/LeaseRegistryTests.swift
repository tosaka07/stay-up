import Foundation
import Testing

@testable import StayUpCore

private let t0 = Date(timeIntervalSince1970: 1_753_000_000)
private let settings = Settings.default

private func acquireExternal(
    _ registry: inout LeaseRegistry,
    name: String,
    ttl: Int? = 1800,
    binding: LeaseBinding? = nil,
    ifNotExists: Bool = false,
    now: Date = t0
) -> Result<AcquireOutcome, ControlError> {
    registry.acquire(
        client: .external(name: name, pid: 100),
        label: name,
        requestedTTLSeconds: ttl,
        binding: binding,
        ifNotExists: ifNotExists,
        settings: settings,
        now: now
    )
}

@Suite("リース台帳: 参照カウント")
struct LeaseRegistryCountingTests {
    @Test("保存済みリースから台帳を復元し、取得時刻順に公開する")
    func restoresPersistedLeasesInAcquisitionOrder() {
        let later = Lease(
            id: LeaseID(rawValue: "later"),
            client: .external(name: "later", pid: 2),
            label: "later",
            acquiredAt: t0.addingTimeInterval(20),
            expiresAt: t0.addingTimeInterval(120)
        )
        let earlier = Lease(
            id: LeaseID(rawValue: "earlier"),
            client: .external(name: "earlier", pid: 1),
            label: "earlier",
            acquiredAt: t0,
            expiresAt: t0.addingTimeInterval(60)
        )

        let registry = LeaseRegistry(leases: [later, earlier])

        #expect(registry.leases.map(\.id) == [earlier.id, later.id])
        #expect(registry.count(forClientNamed: "missing") == 0)
        #expect(registry.earliestExpiry() == earlier.expiresAt)
    }

    @Test("リースが 1 つ以上あるときだけ active")
    func activeReflectsCount() throws {
        var registry = LeaseRegistry()
        #expect(!registry.isActive)

        let a = try acquireExternal(&registry, name: "a").get().lease
        #expect(registry.isActive)

        let b = try acquireExternal(&registry, name: "b").get().lease
        #expect(registry.count == 2)

        // 片方を解放しても、もう片方が生きている限り active のまま
        _ = registry.release(id: a.id, requestedBy: nil)
        #expect(registry.isActive)
        #expect(registry.count == 1)

        _ = registry.release(id: b.id, requestedBy: nil)
        #expect(!registry.isActive)
    }

    @Test("同じクライアントが並走してもリースは別物として扱われる")
    func parallelLeasesFromSameClient() throws {
        var registry = LeaseRegistry()
        let first = try acquireExternal(
            &registry, name: "tool", binding: .leaseFile(path: "/w1/.lease")
        ).get().lease
        let second = try acquireExternal(
            &registry, name: "tool", binding: .leaseFile(path: "/w2/.lease")
        ).get().lease

        #expect(first.id != second.id)
        #expect(registry.count == 2)

        // 片方の作業ディレクトリが終わっても、もう片方は解除されない
        _ = registry.release(id: first.id, requestedBy: .external(name: "tool", pid: 1))
        #expect(registry.isActive)
        #expect(registry.lease(id: second.id) != nil)
    }

    @Test("最も早い期限を返す。無期限が混ざれば nil")
    func earliestExpiry() throws {
        var registry = LeaseRegistry()
        _ = try acquireExternal(&registry, name: "a", ttl: 3600).get()
        _ = try acquireExternal(&registry, name: "b", ttl: 600).get()
        #expect(registry.earliestExpiry() == t0.addingTimeInterval(600))

        // 対話的リースは無期限を持てる
        _ = registry.acquire(
            client: .interactive(trigger: .menuBar), label: "manual",
            requestedTTLSeconds: nil, binding: nil, ifNotExists: false,
            settings: settings, now: t0
        )
        #expect(registry.earliestExpiry() == nil)
    }
}

@Suite("リース台帳: TTL と失効")
struct LeaseRegistryExpiryTests {
    @Test("存在しないリースは更新も延長もできない")
    func missingLeaseCannotBeRenewedOrExtended() {
        var registry = LeaseRegistry()
        let missing = LeaseID(rawValue: "missing")

        let renewed = registry.renew(
            id: missing,
            ttlSeconds: 60,
            requestedBy: nil,
            settings: settings,
            now: t0
        )

        #expect(throws: ControlError.self) { try renewed.get() }
        #expect(registry.extend(id: missing, bySeconds: 60, now: t0) == nil)
    }

    @Test("無期限の対話的リースは現在時刻を起点に延長する")
    func extendingInfiniteLeaseStartsAtNow() throws {
        var registry = LeaseRegistry()
        let lease = try registry.acquire(
            client: .interactive(trigger: .menuBar),
            label: "manual",
            requestedTTLSeconds: nil,
            binding: nil,
            ifNotExists: false,
            settings: settings,
            now: t0
        ).get().lease

        let extended = registry.extend(id: lease.id, bySeconds: 300, now: t0)

        #expect(extended?.expiresAt == t0.addingTimeInterval(300))
    }

    @Test("TTL 切れのリースだけが取り除かれる")
    func expiresLapsedOnly() throws {
        var registry = LeaseRegistry()
        _ = try acquireExternal(&registry, name: "short", ttl: 60).get()
        let long = try acquireExternal(&registry, name: "long", ttl: 3600).get().lease

        let expired = registry.expireLapsed(now: t0.addingTimeInterval(120))
        #expect(expired.count == 1)
        #expect(expired[0].client.name == "short")
        #expect(registry.lease(id: long.id) != nil)
    }

    @Test("同時に失効したリースは取得時刻順で返す")
    func expiredLeasesAreReturnedInAcquisitionOrder() throws {
        var registry = LeaseRegistry()
        let earlier = try acquireExternal(
            &registry,
            name: "earlier",
            ttl: 30,
            now: t0
        ).get().lease
        let later = try acquireExternal(
            &registry,
            name: "later",
            ttl: 30,
            now: t0.addingTimeInterval(10)
        ).get().lease

        let expired = registry.expireLapsed(now: t0.addingTimeInterval(60))

        #expect(expired.map(\.id) == [earlier.id, later.id])
    }

    @Test("renew でハートビートを打つと失効しない")
    func renewPreventsExpiry() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "tool", ttl: 60).get().lease

        // 30 秒時点で更新 → 期限が t0+90 に伸びる
        let renewed = try registry.renew(
            id: lease.id, ttlSeconds: 60, requestedBy: nil,
            settings: settings, now: t0.addingTimeInterval(30)
        ).get()
        #expect(renewed.renewCount == 1)
        #expect(renewed.expiresAt == t0.addingTimeInterval(90))

        #expect(registry.expireLapsed(now: t0.addingTimeInterval(70)).isEmpty)
        // 打つのをやめれば自然に失効する
        #expect(registry.expireLapsed(now: t0.addingTimeInterval(100)).count == 1)
    }

    @Test("外部クライアントの TTL は上限で頭打ちになる")
    func externalTTLIsCapped() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "greedy", ttl: 999_999).get().lease
        // maxClientLeaseTTLSeconds = 7200
        #expect(lease.expiresAt == t0.addingTimeInterval(7200))
    }

    @Test("外部クライアントは無期限リースを作れない")
    func externalCannotBeInfinite() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "tool", ttl: nil).get().lease
        #expect(lease.expiresAt == t0.addingTimeInterval(1800))  // 既定 30 分
    }

    @Test("対話的リースは無期限でいられる")
    func interactiveMayBeInfinite() throws {
        var registry = LeaseRegistry()
        let outcome = try registry.acquire(
            client: .interactive(trigger: .menuBar), label: "manual",
            requestedTTLSeconds: nil, binding: nil, ifNotExists: false,
            settings: settings, now: t0
        ).get()
        #expect(outcome.lease.expiresAt == nil)
        #expect(registry.expireLapsed(now: t0.addingTimeInterval(86_400 * 365)).isEmpty)
    }

    @Test("extend は残り時間に加算し、切れかけていれば現在時刻を起点にする")
    func extendSemantics() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "tool", ttl: 600).get().lease

        let extended = registry.extend(id: lease.id, bySeconds: 1800, now: t0)
        #expect(extended?.expiresAt == t0.addingTimeInterval(2400))

        // 期限を過ぎている場合は now が起点
        let late = t0.addingTimeInterval(10_000)
        let reExtended = registry.extend(id: lease.id, bySeconds: 600, now: late)
        #expect(reExtended?.expiresAt == late.addingTimeInterval(600))
    }
}

@Suite("リース台帳: バインド")
struct LeaseRegistryBindingTests {
    @Test("バインド対象が消えたリースだけが解放される")
    func releasesLostBindings() throws {
        var registry = LeaseRegistry()
        let dead = try acquireExternal(&registry, name: "dead", binding: .pid(999)).get().lease
        let alive = try acquireExternal(&registry, name: "alive", binding: .pid(1)).get().lease
        _ = try acquireExternal(&registry, name: "unbound", binding: nil).get()

        let lost = registry.releaseLostBindings { binding in
            binding != .pid(999)
        }

        #expect(lost.count == 1)
        #expect(lost[0].id == dead.id)
        #expect(registry.lease(id: alive.id) != nil)
        // バインドの無いリースは影響を受けない
        #expect(registry.count == 2)
    }

    @Test("同時に失われたバインドは取得時刻順で返す")
    func lostBindingsAreReturnedInAcquisitionOrder() throws {
        var registry = LeaseRegistry()
        let earlier = try acquireExternal(
            &registry,
            name: "earlier",
            binding: .pid(10),
            now: t0
        ).get().lease
        let later = try acquireExternal(
            &registry,
            name: "later",
            binding: .pid(20),
            now: t0.addingTimeInterval(10)
        ).get().lease

        let lost = registry.releaseLostBindings { _ in false }

        #expect(lost.map(\.id) == [earlier.id, later.id])
    }

    @Test("--if-not-exists は同じリースファイルのリースを再利用する")
    func ifNotExistsIsIdempotent() throws {
        var registry = LeaseRegistry()
        let path = "/tmp/w/.stay-up-lease"
        let first = try acquireExternal(
            &registry, name: "tool", binding: .leaseFile(path: path), ifNotExists: true
        ).get()
        let second = try acquireExternal(
            &registry, name: "tool", binding: .leaseFile(path: path), ifNotExists: true
        ).get()

        #expect(first == .created(first.lease))
        if case .existing(let lease) = second {
            #expect(lease.id == first.lease.id)
        } else {
            Issue.record("2 回目は既存リースの再利用になるはず")
        }
        #expect(registry.count == 1)
    }

    @Test("--if-not-exists を付けなければ二重に取得される")
    func withoutIfNotExistsDuplicates() throws {
        var registry = LeaseRegistry()
        let path = "/tmp/w/.stay-up-lease"
        _ = try acquireExternal(&registry, name: "tool", binding: .leaseFile(path: path)).get()
        _ = try acquireExternal(&registry, name: "tool", binding: .leaseFile(path: path)).get()
        #expect(registry.count == 2)
    }
}

@Suite("リース台帳: 権限の非対称性")
struct LeaseRegistryAuthorizationTests {
    @Test("存在しないリースの解放は冪等なnotFoundになる")
    func releasingMissingLeaseReturnsNotFound() {
        var registry = LeaseRegistry()

        let result = registry.release(
            id: LeaseID(rawValue: "missing"),
            requestedBy: .interactive(trigger: .window)
        )

        guard case .failure(let error) = result else {
            Issue.record("存在しないリースはnotFoundになるはず")
            return
        }
        #expect(error.code == ControlErrorCode.notFound.rawValue)
        #expect(error.nonFatal)
    }

    @Test("ユーザーは所有者に関係なく個別リースを更新・解放できる")
    func interactiveClientMayModifyAnyLease() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "tool").get().lease

        let renewed = try registry.renew(
            id: lease.id,
            ttlSeconds: nil,
            requestedBy: .interactive(trigger: .window),
            settings: settings,
            now: t0.addingTimeInterval(10)
        ).get()
        #expect(renewed.expiresAt == t0.addingTimeInterval(10 + 1800))

        let released = try registry.release(
            id: lease.id,
            requestedBy: .interactive(trigger: .window)
        ).get()
        #expect(released.id == lease.id)
        #expect(!registry.isActive)
    }

    @Test("外部クライアントは他人のリースを解放できない")
    func externalCannotReleaseOthers() throws {
        var registry = LeaseRegistry()
        let victim = try acquireExternal(&registry, name: "victim").get().lease

        let result = registry.release(id: victim.id, requestedBy: .external(name: "attacker", pid: 2))
        guard case .failure(let error) = result else {
            Issue.record("拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.denied.rawValue)
        #expect(registry.lease(id: victim.id) != nil)
    }

    @Test("外部クライアントは他人のリースを renew できない")
    func externalCannotRenewOthers() throws {
        var registry = LeaseRegistry()
        let victim = try acquireExternal(&registry, name: "victim").get().lease

        let result = registry.renew(
            id: victim.id, ttlSeconds: 600,
            requestedBy: .external(name: "attacker", pid: 2),
            settings: settings, now: t0
        )
        guard case .failure(let error) = result else {
            Issue.record("拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.denied.rawValue)
    }

    @Test("外部クライアントは自分のリースなら操作できる")
    func externalCanReleaseOwn() throws {
        var registry = LeaseRegistry()
        let lease = try acquireExternal(&registry, name: "tool").get().lease
        let result = registry.release(id: lease.id, requestedBy: .external(name: "tool", pid: 5))
        #expect(throws: Never.self) { try result.get() }
        #expect(!registry.isActive)
    }

    @Test("releaseAll: 外部クライアントは自分の分だけ、ユーザーは全部")
    func releaseAllScope() throws {
        var registry = LeaseRegistry()
        _ = try acquireExternal(&registry, name: "toolA").get()
        _ = try acquireExternal(&registry, name: "toolA").get()
        _ = try acquireExternal(&registry, name: "toolB").get()
        _ = registry.acquire(
            client: .interactive(trigger: .menuBar), label: "manual",
            requestedTTLSeconds: nil, binding: nil, ifNotExists: false,
            settings: settings, now: t0
        )

        // 外部クライアントは自分の名前のものだけ
        let releasedByTool = registry.releaseAll(requestedBy: .external(name: "toolA", pid: 1))
        #expect(releasedByTool.count == 2)
        #expect(registry.count == 2)

        // ユーザーの明示操作は外部クライアントのものも含めて全部
        let releasedByUser = registry.releaseAll(requestedBy: .interactive(trigger: .menuBar))
        #expect(releasedByUser.count == 2)
        #expect(!registry.isActive)
    }

    @Test("同時保持数の上限を超えると拒否される")
    func perClientLimit() throws {
        var registry = LeaseRegistry()
        let limited = Settings(maxLeasesPerClient: 2)

        for _ in 0..<2 {
            let result = registry.acquire(
                client: .external(name: "runaway", pid: 1), label: "x",
                requestedTTLSeconds: 600, binding: nil, ifNotExists: false,
                settings: limited, now: t0
            )
            #expect(throws: Never.self) { try result.get() }
        }

        let overflow = registry.acquire(
            client: .external(name: "runaway", pid: 1), label: "x",
            requestedTTLSeconds: 600, binding: nil, ifNotExists: false,
            settings: limited, now: t0
        )
        guard case .failure(let error) = overflow else {
            Issue.record("上限で拒否されるはず")
            return
        }
        #expect(error.code == ControlErrorCode.limitExceeded.rawValue)
        // 呼び出し元の処理は止めない
        #expect(error.nonFatal)

        // 別のクライアントは上限に達していないので取れる
        #expect(throws: Never.self) {
            try registry.acquire(
                client: .external(name: "other", pid: 2), label: "x",
                requestedTTLSeconds: 600, binding: nil, ifNotExists: false,
                settings: limited, now: t0
            ).get()
        }
    }

    @Test("上限は対話的リースには適用されない")
    func interactiveIgnoresLimit() throws {
        var registry = LeaseRegistry()
        let limited = Settings(maxLeasesPerClient: 1)
        for _ in 0..<5 {
            #expect(throws: Never.self) {
                try registry.acquire(
                    client: .interactive(trigger: .menuBar), label: "manual",
                    requestedTTLSeconds: nil, binding: nil, ifNotExists: false,
                    settings: limited, now: t0
                ).get()
            }
        }
        #expect(registry.count == 5)
    }
}

@Suite("リース台帳: グローバル失効")
struct LeaseRegistryRevokeTests {
    @Test("revokeAll は所有者に関わらず全て失効させる")
    func revokeAllIgnoresOwnership() throws {
        var registry = LeaseRegistry()
        _ = try acquireExternal(&registry, name: "a").get()
        _ = try acquireExternal(&registry, name: "b").get()
        _ = registry.acquire(
            client: .interactive(trigger: .menuBar), label: "manual",
            requestedTTLSeconds: nil, binding: nil, ifNotExists: false,
            settings: settings, now: t0
        )

        let revoked = registry.revokeAll()
        #expect(revoked.count == 3)
        #expect(!registry.isActive)
    }
}
