import Foundation
import Testing

@testable import StayUpCore

@Suite("リース値オブジェクト")
struct LeaseModelTests {
    @Test("LeaseID は文字列表現と Codable 往復を保つ")
    func leaseIDValueSemantics() throws {
        let id = LeaseID(rawValue: "01LEASE")
        #expect(id.description == "01LEASE")

        let data = try ControlCoding.makeEncoder().encode(id)
        #expect(try ControlCoding.makeDecoder().decode(LeaseID.self, from: data) == id)
    }

    @Test("1970年より前でも有効な26文字IDを生成する")
    func leaseIDBeforeEpoch() {
        let id = LeaseID.generate(now: Date(timeIntervalSince1970: -1))
        #expect(id.rawValue.count == 26)
        #expect(id.rawValue.hasPrefix("0000000000"))
    }

    @Test("クライアント属性は対話・外部を正しく表す")
    func clientProperties() {
        let interactive = Client.interactive(trigger: .hotkey)
        #expect(interactive.name == "手動")
        #expect(interactive.isInteractive)
        #expect(interactive.pid == nil)

        let external = Client.external(name: "build", pid: 42)
        #expect(external.name == "build")
        #expect(!external.isInteractive)
        #expect(external.pid == 42)
    }

    @Test(
        "バインドは人間向け表示へ変換される",
        arguments: [
            (LeaseBinding.pid(42), "pid:42"),
            (.leaseFile(path: "/tmp/example.lease"), "file:example.lease"),
            (.processName("swift-build"), "name:swift-build"),
        ]
    )
    func bindingDisplay(binding: LeaseBinding, expected: String) {
        #expect(binding.displayText == expected)
    }

    @Test("残り時間と継続時間は0未満にならない")
    func leaseTiming() {
        let acquiredAt = Date(timeIntervalSince1970: 1_000)
        let infinite = Lease(
            client: .interactive(trigger: .window),
            label: "manual",
            acquiredAt: acquiredAt
        )
        #expect(infinite.remainingSeconds(at: acquiredAt) == nil)
        #expect(infinite.durationSeconds(at: acquiredAt.addingTimeInterval(-10)) == 0)

        let finite = Lease(
            client: .external(name: "build", pid: 1),
            label: "build",
            acquiredAt: acquiredAt,
            expiresAt: acquiredAt.addingTimeInterval(60)
        )
        #expect(finite.remainingSeconds(at: acquiredAt.addingTimeInterval(90)) == 0)
    }

    @Test("解放理由のスコープと表示文言")
    func releaseReasons() {
        let expectations: [(ReleaseReason, Bool, String)] = [
            (.explicit, false, "手動で解放"),
            (.ttlExpired, false, "TTL 切れ"),
            (.bindingLost, false, "バインド対象の消滅"),
            (.battery, true, "バッテリー閾値"),
            (.cpuIdle, true, "CPU アイドル"),
            (.thermal, true, "熱状態"),
            (.maxDuration, true, "総継続時間の上限"),
            (.helperLost, false, "ヘルパーとの通信断"),
            (.appTerminating, false, "アプリ終了"),
            (.systemShutdown, false, "システム終了"),
            (.error, false, "エラー"),
        ]

        for (reason, isGlobal, description) in expectations {
            #expect(reason.isGlobal == isGlobal)
            #expect(reason.localizedDescription == description)
        }
    }

    @Test("抑止能力の表示文言")
    func suppressionCapabilityDescriptions() {
        #expect(SuppressionCapability.full.localizedDescription == "ふたを閉じてもスリープしません")
        #expect(SuppressionCapability.idleOnly.localizedDescription == "ふたを閉じるとスリープします")
    }
}
