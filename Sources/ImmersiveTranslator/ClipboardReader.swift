import AppKit

enum SelectedTextReaderError: LocalizedError {
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .copyFailed:
            return "没有从当前 App 复制到文本。请确认已经选中文本，并允许辅助功能权限。"
        }
    }
}

enum SelectedTextReader {
    @MainActor
    static func readSelectedText() async throws -> String {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        let originalChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        sendCopyShortcut()

        let deadline = Date().addingTimeInterval(0.8)
        var copiedText = ""
        while Date() < deadline {
            if pasteboard.changeCount != originalChangeCount,
               let text = pasteboard.string(forType: .string),
               !text.isEmpty {
                copiedText = text
                break
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }

        snapshot.restore(to: pasteboard)

        if copiedText.isEmpty {
            throw SelectedTextReaderError.copyFailed
        }
        return copiedText
    }

    private static func sendCopyShortcut() {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyCode = CGKeyCode(8)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

private struct ClipboardSnapshot {
    private let items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> ClipboardSnapshot {
        let copiedItems = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let clone = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    clone.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    clone.setString(string, forType: type)
                }
            }
            return clone
        } ?? []
        return ClipboardSnapshot(items: copiedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
