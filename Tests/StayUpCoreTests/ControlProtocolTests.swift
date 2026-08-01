import Foundation
import Testing

@testable import StayUpCore

@Suite("制御プロトコル契約")
struct ControlProtocolTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("取得オプションは全フィールドを保持して Codable 往復する")
    func acquireOptionsRoundTrip() throws {
        let options = AcquireOptions(
            owner: "owner",
            label: "label",
            ttlSeconds: 300,
            binding: .processName("swift"),
            leaseFilePath: "/tmp/stay-up.lease",
            ifNotExists: true,
            reason: "test",
            clientPID: 42
        )
        #expect(try roundTrip(options) == options)
        #expect(AcquireOptions() == AcquireOptions())
    }

    @Test("リーススナップショットは対話・外部リースを安定表現へ変換する")
    func leaseSnapshots() {
        let interactive = Lease(
            id: LeaseID(rawValue: "interactive"),
            client: .interactive(trigger: .menuBar),
            label: "manual",
            acquiredAt: now
        )
        let external = Lease(
            id: LeaseID(rawValue: "external"),
            client: .external(name: "build", pid: 42),
            label: "build",
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(300),
            binding: .pid(42)
        )

        #expect(LeaseSnapshot(lease: interactive).kind == "interactive")
        let snapshot = LeaseSnapshot(lease: external)
        #expect(snapshot.kind == "external")
        #expect(snapshot.binding == "pid:42")
    }

    @Test("状態スナップショットは派生項目と入力を保持する")
    func statusSnapshot() throws {
        let battery = BatterySnapshot(percent: nil, source: "unknown")
        let status = StatusSnapshot(
            state: .degraded,
            capability: .idleOnly,
            leases: [],
            activeSince: now,
            endsAt: nil,
            endsReason: nil,
            battery: battery,
            warnings: ["warning"]
        )

        #expect(status.v == ControlProtocol.version)
        #expect(status.state == "degraded")
        #expect(status.capability == "idleOnly")
        #expect(status.leaseCount == 0)
        #expect(try roundTrip(status) == status)
    }

    @Test("doctor レポートは remedy の有無を含めて往復する")
    func doctorReport() throws {
        let report = DoctorReport(checks: [
            .init(name: "socket", ok: true, detail: "ok"),
            .init(name: "helper", ok: false, detail: "missing", remedy: "install"),
        ])
        #expect(try roundTrip(report) == report)
    }

    @Test("エラーは終了コードと nonFatal を保持する")
    func controlError() throws {
        let error = ControlError(code: .notFound, message: "missing", nonFatal: true)
        #expect(error.code == ControlErrorCode.notFound.rawValue)
        #expect(try roundTrip(error) == error)
    }

    @Test("全リクエストを JSON 往復できる")
    func allRequestsRoundTrip() throws {
        let options = AcquireOptions(owner: "owner", ttlSeconds: 60)
        let id = LeaseID(rawValue: "lease")
        let requests: [ControlRequest] = [
            .acquire(options),
            .renew(id: id, leaseFilePath: nil, ttlSeconds: 60, owner: "owner"),
            .release(id: id, leaseFilePath: nil, owner: "owner"),
            .releaseAll(owner: "owner"),
            .list,
            .status,
            .toggle(options),
            .wait,
            .doctor,
        ]

        for request in requests {
            let data = try ControlCoding.makeEncoder().encode(request)
            _ = try ControlCoding.makeDecoder().decode(ControlRequest.self, from: data)
        }
    }

    @Test("全レスポンスを JSON 往復できる")
    func allResponsesRoundTrip() throws {
        let lease = Lease(
            client: .external(name: "build", pid: 42),
            label: "build",
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(60)
        )
        let leaseSnapshot = LeaseSnapshot(lease: lease)
        let status = StatusSnapshot(
            state: .active,
            capability: .full,
            leases: [leaseSnapshot],
            activeSince: now,
            endsAt: now.addingTimeInterval(60),
            endsReason: "ttl",
            battery: BatterySnapshot(percent: 80, source: "ac"),
            warnings: []
        )
        let responses: [ControlResponse] = [
            .acquired(lease: leaseSnapshot, capability: "full", warning: nil),
            .renewed(lease: leaseSnapshot),
            .released(count: 1),
            .list([leaseSnapshot]),
            .status(status),
            .doctor(DoctorReport(checks: [])),
            .ok,
            .failure(ControlError(code: .generic, message: "error")),
        ]

        for response in responses {
            let data = try ControlCoding.makeEncoder().encode(response)
            _ = try ControlCoding.makeDecoder().decode(ControlResponse.self, from: data)
        }
    }

    @Test("行プロトコルは ISO 8601 JSON の末尾に改行を1つ付ける")
    func encodeLine() throws {
        let value = StatusSnapshot(
            state: .idle,
            capability: .idleOnly,
            leases: [],
            activeSince: now,
            endsAt: nil,
            endsReason: nil,
            battery: BatterySnapshot(percent: 50, source: "battery"),
            warnings: []
        )
        let line = try ControlCoding.encodeLine(value)

        #expect(line.last == 0x0A)
        #expect(line.dropLast().contains(0x0A) == false)
        _ = try ControlCoding.makeDecoder().decode(StatusSnapshot.self, from: line.dropLast())
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try ControlCoding.makeEncoder().encode(value)
        return try ControlCoding.makeDecoder().decode(T.self, from: data)
    }
}
