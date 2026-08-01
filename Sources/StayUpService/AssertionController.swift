import Foundation
import IOKit.pwr_mgt
import StayUpCore
import os

/// `IOPMAssertion` によるスリープ抑止（spec §3）。
///
/// アサーションはプロセス単位で、**プロセスが死ねば OS が自動解放する**。
/// root も要らない。ここが失敗することは基本的に無いので、
/// クラムシェル抑止（ヘルパー経由）が使えなくても、この層だけは必ず効かせる。
public final class AssertionController: @unchecked Sendable {
    private let log = Logger(subsystem: StayUpPaths.bundleIdentifier, category: "power")
    private let lock = NSLock()

    private var systemAssertion: IOPMAssertionID?
    private var displayAssertion: IOPMAssertionID?
    private var diskAssertion: IOPMAssertionID?

    public init() {}

    public var isHoldingAssertions: Bool {
        lock.lock()
        defer { lock.unlock() }
        return systemAssertion != nil
    }

    /// アイドルスリープ抑止を開始する。
    public func acquire(keepDisplayAwake: Bool, preventDiskSleep: Bool) {
        lock.lock()
        defer { lock.unlock() }

        if systemAssertion == nil {
            systemAssertion = createAssertion(kIOPMAssertPreventUserIdleSystemSleep)
        }

        if keepDisplayAwake {
            if displayAssertion == nil {
                displayAssertion = createAssertion(kIOPMAssertPreventUserIdleDisplaySleep)
            }
        } else if let id = displayAssertion {
            IOPMAssertionRelease(id)
            displayAssertion = nil
        }

        if preventDiskSleep {
            if diskAssertion == nil {
                diskAssertion = createAssertion(kIOPMAssertPreventDiskIdle)
            }
        } else if let id = diskAssertion {
            IOPMAssertionRelease(id)
            diskAssertion = nil
        }
    }

    public func releaseAll() {
        lock.lock()
        defer { lock.unlock() }

        for id in [systemAssertion, displayAssertion, diskAssertion].compactMap({ $0 }) {
            IOPMAssertionRelease(id)
        }
        systemAssertion = nil
        displayAssertion = nil
        diskAssertion = nil
    }

    private func createAssertion(_ type: String) -> IOPMAssertionID? {
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "StayUp: スリープ抑止中" as CFString,
            &id
        )
        guard result == kIOReturnSuccess else {
            log.error("IOPMAssertion の作成に失敗: \(type, privacy: .public) result=\(result)")
            return nil
        }
        return id
    }

    deinit {
        for id in [systemAssertion, displayAssertion, diskAssertion].compactMap({ $0 }) {
            IOPMAssertionRelease(id)
        }
    }
}
