import AppKit

enum PrivacyPaneKind {
    case accessibility
    case screenRecording

    var url: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

enum PermissionPrompter {
    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func isScreenCaptureTrusted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    static func requestAccessibilityIfNeeded() -> Bool {
        if isAccessibilityTrusted() {
            return true
        }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenCaptureIfNeeded() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        return CGRequestScreenCaptureAccess()
    }

    static func openPrivacyPane(kind: PrivacyPaneKind) {
        NSWorkspace.shared.open(kind.url)
    }
}
