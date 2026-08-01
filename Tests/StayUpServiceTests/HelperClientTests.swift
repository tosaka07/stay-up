import ServiceManagement
import Testing

@testable import StayUpService

@Suite("HelperClient: SMAppService 状態の正規化")
struct HelperClientStatusTests {
    @Test("macOS 26 の初回 notFound は登録可能な未登録状態として扱う")
    func treatsInitialNotFoundAsNotRegistered() {
        #expect(HelperClient.normalizedStatus(.notFound) == .notRegistered)
    }

    @Test(
        "通常の ServiceManagement 状態をそのままUI状態へ写す",
        arguments: [
            (SMAppService.Status.notRegistered, HelperStatus.notRegistered),
            (SMAppService.Status.requiresApproval, HelperStatus.requiresApproval),
            (SMAppService.Status.enabled, HelperStatus.enabled),
        ]
    )
    func mapsKnownStatuses(
        serviceStatus: SMAppService.Status,
        expected: HelperStatus
    ) {
        #expect(HelperClient.normalizedStatus(serviceStatus) == expected)
    }
}
