import AppKit

enum SelectedTextReaderError: LocalizedError {
    case accessibilityNotTrusted
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "还没有辅助功能权限，无法模拟 Command + C 读取当前选区。请在系统设置里允许本工具使用辅助功能，授权后重新触发翻译。"
        case .copyFailed:
            return "没有从当前 App 复制到文本。请确认当前窗口仍在前台、已经选中可复制文字；某些 App 的自定义文本区域可能不响应模拟 Command + C。"
        }
    }
}

enum SelectedTextReader {
    @MainActor
    static func readSelectedText() async throws -> String {
        guard PermissionPrompter.isAccessibilityTrusted() else {
            throw SelectedTextReaderError.accessibilityNotTrusted
        }

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
