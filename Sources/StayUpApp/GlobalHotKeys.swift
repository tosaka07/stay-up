import Carbon.HIToolbox
import SwiftUI

enum StartDurationPreset: UInt32, CaseIterable, Identifiable {
    case thirtyMinutes = 1
    case oneHour = 2
    case twoHours = 3
    case unlimited = 4

    var id: Self { self }

    var seconds: Int? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .unlimited: nil
        }
    }

    var durationTitle: String {
        switch self {
        case .thirtyMinutes: "30分"
        case .oneHour: "1時間"
        case .twoHours: "2時間"
        case .unlimited: "無期限"
        }
    }

    var actionTitle: String {
        "\(durationTitle)で開始"
    }

    var keyEquivalent: KeyEquivalent {
        switch self {
        case .thirtyMinutes: "1"
        case .oneHour: "2"
        case .twoHours: "3"
        case .unlimited: "4"
        }
    }

    var virtualKeyCode: UInt32 {
        switch self {
        case .thirtyMinutes: UInt32(kVK_ANSI_1)
        case .oneHour: UInt32(kVK_ANSI_2)
        case .twoHours: UInt32(kVK_ANSI_3)
        case .unlimited: UInt32(kVK_ANSI_4)
        }
    }

    static func matching(seconds: Int?) -> Self? {
        allCases.first { $0.seconds == seconds }
    }
}

enum GlobalHotKeyAction: Equatable {
    case start(StartDurationPreset)
    case stop

    var identifier: UInt32 {
        switch self {
        case .start(let preset): preset.rawValue
        case .stop: 0
        }
    }

    var virtualKeyCode: UInt32 {
        switch self {
        case .start(let preset): preset.virtualKeyCode
        case .stop: UInt32(kVK_ANSI_0)
        }
    }

    var shortcutDescription: String {
        switch self {
        case .start(let preset): "⌃⌥⌘\(preset.rawValue)"
        case .stop: "⌃⌥⌘0"
        }
    }

    static let all: [Self] =
        StartDurationPreset.allCases.map(Self.start) + [.stop]

    static func from(identifier: UInt32) -> Self? {
        if identifier == 0 {
            return .stop
        }
        guard let preset = StartDurationPreset(rawValue: identifier) else {
            return nil
        }
        return .start(preset)
    }
}

extension SwiftUI.EventModifiers {
    static let stayUpGlobalHotKey: Self = [.control, .option, .command]
}

@MainActor
final class GlobalHotKeyController {
    private var eventHandler: EventHandlerRef?
    private var hotKeyReferences: [EventHotKeyRef] = []
    private var actionHandler: ((GlobalHotKeyAction) -> Void)?

    func start(actionHandler: @escaping (GlobalHotKeyAction) -> Void) -> [GlobalHotKeyAction] {
        guard eventHandler == nil else { return [] }
        self.actionHandler = actionHandler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            stayUpHotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            eventHandler = nil
            self.actionHandler = nil
            return GlobalHotKeyAction.all
        }

        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        var failures: [GlobalHotKeyAction] = []

        for action in GlobalHotKeyAction.all {
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(
                signature: stayUpHotKeySignature,
                id: action.identifier
            )
            let status = RegisterEventHotKey(
                action.virtualKeyCode,
                modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &reference
            )
            if status == noErr, let reference {
                hotKeyReferences.append(reference)
            } else {
                failures.append(action)
            }
        }

        return failures
    }

    func stop() {
        for reference in hotKeyReferences {
            UnregisterEventHotKey(reference)
        }
        hotKeyReferences.removeAll()

        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
        eventHandler = nil
        actionHandler = nil
    }

    fileprivate func handle(_ action: GlobalHotKeyAction) {
        actionHandler?(action)
    }
}

private let stayUpHotKeySignature: OSType = 0x53545550 // "STUP"

private func stayUpHotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else {
        return OSStatus(eventNotHandledErr)
    }

    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr,
          identifier.signature == stayUpHotKeySignature,
          let action = GlobalHotKeyAction.from(identifier: identifier.id)
    else {
        return status == noErr ? OSStatus(eventNotHandledErr) : status
    }

    let controllerAddress = UInt(bitPattern: userData)
    return MainActor.assumeIsolated {
        guard let controllerPointer = UnsafeMutableRawPointer(bitPattern: controllerAddress) else {
            return OSStatus(eventNotHandledErr)
        }
        let controller = Unmanaged<GlobalHotKeyController>
            .fromOpaque(controllerPointer)
            .takeUnretainedValue()
        controller.handle(action)
        return noErr
    }
}
