import Carbon
import Foundation

enum HotKeyAction {
    case translateSelection
    case translateScreenshot
}

final class HotKeyManager {
    private let handler: (HotKeyAction) -> Void
    private var eventHandler: EventHandlerRef?
    private var translateSelectionRef: EventHotKeyRef?
    private var translateScreenshotRef: EventHotKeyRef?
    private let signature = fourCharCode("imtr")

    init(handler: @escaping (HotKeyAction) -> Void) {
        self.handler = handler
    }

    deinit {
        if let translateSelectionRef {
            UnregisterEventHotKey(translateSelectionRef)
        }
        if let translateScreenshotRef {
            UnregisterEventHotKey(translateScreenshotRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register() {
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                switch hotKeyID.id {
                case 1:
                    manager.handler(.translateSelection)
                case 2:
                    manager.handler(.translateScreenshot)
                default:
                    break
                }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let selectionID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            selectionID,
            GetApplicationEventTarget(),
            0,
            &translateSelectionRef
        )

        let screenshotID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey | controlKey),
            screenshotID,
            GetApplicationEventTarget(),
            0,
            &translateScreenshotRef
        )
    }
}

private func fourCharCode(_ text: String) -> OSType {
    var result: OSType = 0
    for scalar in text.unicodeScalars.prefix(4) {
        result = (result << 8) + OSType(scalar.value)
    }
    return result
}
