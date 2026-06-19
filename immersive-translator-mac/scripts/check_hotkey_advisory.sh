#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/HotKeyManager.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-hotkey-advisory.XXXXXX")"
CHECK_PATH="$TMP_DIR/HotKeyAdvisoryCheck.swift"
BINARY_PATH="$TMP_DIR/check_hotkey_advisory"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import AppKit\nimport Carbon\nimport Foundation\n\n'
    awk '
        /^struct HotKeyShortcut[: ]/ { printing = 1 }
        /^struct HotKeyRegistrationReport / { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
private struct HotKeyAdvisoryCheck {
    static func main() {
        let stableSuggestion = HotKeyShortcut.suggestionText(
            excluding: [.optionSpace, .controlOptionSpace],
            limit: 4
        )
        expect(
            stableSuggestion == "Control + Option + T 或 Control + Option + O 或 Control + Option + G 或 Control + Option + E",
            "unexpected stable suggestions: \(stableSuggestion)"
        )
        expect(
            !stableSuggestion.contains("Command + Option + Space"),
            "suggestions should avoid Command + Option + Space while low-risk options exist"
        )

        let commandSpace = HotKeyShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(cmdKey | optionKey),
            keyLabel: "Space"
        )
        expect(
            commandSpace.advisorySeverity == .highRisk,
            "Command + Option + Space should be high-risk"
        )
        expect(
            commandSpace.advisoryMessage(suggestion: "Control + Option + T")?.contains("Spotlight") == true,
            "Command + Option + Space should mention Spotlight/input method risk"
        )

        let screenshotShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_4),
            modifiers: UInt32(cmdKey | shiftKey),
            keyLabel: "4"
        )
        expect(
            screenshotShortcut.advisorySeverity == .highRisk,
            "Command + Shift + 4 should be high-risk"
        )
        expect(
            screenshotShortcut.advisoryMessage(suggestion: "Control + Option + O")?.contains("截图") == true,
            "screenshot shortcuts should explain screenshot conflict"
        )

        let appSwitcher = HotKeyShortcut(
            keyCode: UInt32(kVK_Tab),
            modifiers: UInt32(cmdKey),
            keyLabel: "Tab"
        )
        expect(
            appSwitcher.advisoryMessage(suggestion: "Control + Option + T")?.contains("App 切换器") == true,
            "Command + Tab should explain app switcher conflict"
        )

        let commandMenuShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(cmdKey),
            keyLabel: "C"
        )
        expect(
            commandMenuShortcut.advisorySeverity == .highRisk,
            "Command + C should be high-risk"
        )
        expect(
            commandMenuShortcut.advisoryMessage(suggestion: "Control + Option + T")?.contains("文本操作") == true,
            "Command + C should explain clipboard/editing risk"
        )

        let commandQuitShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Q),
            modifiers: UInt32(cmdKey),
            keyLabel: "Q"
        )
        expect(
            commandQuitShortcut.advisoryMessage(suggestion: "Control + Option + T")?.contains("退出") == true,
            "Command + Q should explain app lifecycle risk"
        )

        let commandRefreshShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_R),
            modifiers: UInt32(cmdKey),
            keyLabel: "R"
        )
        expect(
            commandRefreshShortcut.advisorySeverity == .highRisk,
            "Command + R should be high-risk"
        )
        expect(
            commandRefreshShortcut.advisoryMessage(suggestion: "Control + Option + G")?.contains("刷新") == true,
            "Command + R should explain browser/document shortcut risk"
        )

        let commandLocationShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_L),
            modifiers: UInt32(cmdKey),
            keyLabel: "L"
        )
        expect(
            commandLocationShortcut.advisorySeverity == .highRisk,
            "Command + L should be high-risk"
        )
        expect(
            commandLocationShortcut.advisoryMessage(suggestion: "Control + Option + O")?.contains("地址栏/定位栏") == true,
            "Command + L should explain address/location bar shortcut risk"
        )

        let commandFindSelectionShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_E),
            modifiers: UInt32(cmdKey),
            keyLabel: "E"
        )
        expect(
            commandFindSelectionShortcut.advisorySeverity == .highRisk,
            "Command + E should be high-risk"
        )
        expect(
            commandFindSelectionShortcut.advisoryMessage(suggestion: "Control + Option + E")?.contains("搜索") == true,
            "Command + E should explain search/document shortcut risk"
        )

        let commandNewTabShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(cmdKey),
            keyLabel: "T"
        )
        expect(
            commandNewTabShortcut.advisorySeverity == .highRisk,
            "Command + T should be high-risk"
        )
        expect(
            commandNewTabShortcut.advisoryMessage(suggestion: "Control + Option + T")?.contains("新建标签页") == true,
            "Command + T should explain browser tab shortcut risk"
        )

        let commandBookmarkShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_D),
            modifiers: UInt32(cmdKey),
            keyLabel: "D"
        )
        expect(
            commandBookmarkShortcut.advisorySeverity == .highRisk,
            "Command + D should be high-risk"
        )
        expect(
            commandBookmarkShortcut.advisoryMessage(suggestion: "Control + Option + D")?.contains("书签") == true,
            "Command + D should explain bookmark/document shortcut risk"
        )

        let commandLinkShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_K),
            modifiers: UInt32(cmdKey),
            keyLabel: "K"
        )
        expect(
            commandLinkShortcut.advisorySeverity == .highRisk,
            "Command + K should be high-risk"
        )
        expect(
            commandLinkShortcut.advisoryMessage(suggestion: "Control + Option + K")?.contains("链接") == true,
            "Command + K should explain link shortcut risk"
        )

        let commandBoldShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_B),
            modifiers: UInt32(cmdKey),
            keyLabel: "B"
        )
        expect(
            commandBoldShortcut.advisorySeverity == .highRisk,
            "Command + B should be high-risk"
        )
        expect(
            commandBoldShortcut.advisoryMessage(suggestion: "Control + Option + B")?.contains("文字格式") == true,
            "Command + B should explain text formatting shortcut risk"
        )

        let commandSettingsShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Comma),
            modifiers: UInt32(cmdKey),
            keyLabel: ","
        )
        expect(
            commandSettingsShortcut.advisorySeverity == .highRisk,
            "Command + comma should be high-risk"
        )
        expect(
            commandSettingsShortcut.advisoryMessage(suggestion: "Control + Option + T")?.contains("设置") == true,
            "Command + comma should explain settings/menu shortcut risk"
        )

        let commandCancelShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Period),
            modifiers: UInt32(cmdKey),
            keyLabel: "."
        )
        expect(
            commandCancelShortcut.advisorySeverity == .highRisk,
            "Command + period should be high-risk"
        )
        expect(
            commandCancelShortcut.advisoryMessage(suggestion: "Control + Option + O")?.contains("取消") == true,
            "Command + period should explain cancel/menu shortcut risk"
        )

        let commandHelpShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Slash),
            modifiers: UInt32(cmdKey),
            keyLabel: "/"
        )
        expect(
            commandHelpShortcut.advisorySeverity == .highRisk,
            "Command + slash should be high-risk"
        )
        expect(
            commandHelpShortcut.advisoryMessage(suggestion: "Control + Option + G")?.contains("帮助") == true,
            "Command + slash should explain help shortcut risk"
        )

        let commandBackShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_LeftBracket),
            modifiers: UInt32(cmdKey),
            keyLabel: "["
        )
        expect(
            commandBackShortcut.advisorySeverity == .highRisk,
            "Command + left bracket should be high-risk"
        )
        expect(
            commandBackShortcut.advisoryMessage(suggestion: "Control + Option + E")?.contains("前进/后退") == true,
            "Command + left bracket should explain navigation shortcut risk"
        )

        let commandZoomShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_Equal),
            modifiers: UInt32(cmdKey),
            keyLabel: "="
        )
        expect(
            commandZoomShortcut.advisorySeverity == .highRisk,
            "Command + equal should be high-risk"
        )
        expect(
            commandZoomShortcut.advisoryMessage(suggestion: "Control + Option + T")?.contains("缩放") == true,
            "Command + equal should explain zoom shortcut risk"
        )

        let commandResetZoomShortcut = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_0),
            modifiers: UInt32(cmdKey),
            keyLabel: "0"
        )
        expect(
            commandResetZoomShortcut.advisorySeverity == .highRisk,
            "Command + 0 should be high-risk"
        )
        expect(
            commandResetZoomShortcut.advisoryMessage(suggestion: "Control + Option + O")?.contains("缩放") == true,
            "Command + 0 should explain zoom shortcut risk"
        )

        let controlSpace = HotKeyShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey),
            keyLabel: "Space"
        )
        expect(
            controlSpace.advisorySeverity == .caution,
            "Control + Space should be a caution"
        )

        let controlOptionSpace = HotKeyShortcut(
            keyCode: UInt32(kVK_Space),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "Space"
        )
        expect(
            controlOptionSpace.advisorySeverity == .caution,
            "Control + Option + Space should be a caution because macOS can use it for input source switching"
        )
        expect(
            controlOptionSpace.advisoryMessage(suggestion: "Control + Option + O")?.contains("输入源") == true,
            "Control + Option + Space should explain input source conflict"
        )

        let controlUpArrow = HotKeyShortcut(
            keyCode: UInt32(kVK_UpArrow),
            modifiers: UInt32(controlKey),
            keyLabel: "Up Arrow"
        )
        expect(
            controlUpArrow.advisorySeverity == .highRisk,
            "Control + Up Arrow should be high-risk because macOS commonly uses it for Mission Control"
        )
        expect(
            controlUpArrow.advisoryMessage(suggestion: "Control + Option + T")?.contains("Mission Control") == true,
            "Control + Up Arrow should explain Mission Control conflict"
        )

        let controlLeftArrow = HotKeyShortcut(
            keyCode: UInt32(kVK_LeftArrow),
            modifiers: UInt32(controlKey),
            keyLabel: "Left Arrow"
        )
        expect(
            controlLeftArrow.advisorySeverity == .highRisk,
            "Control + Left Arrow should be high-risk because macOS commonly uses it for Space switching"
        )
        expect(
            controlLeftArrow.advisoryMessage(suggestion: "Control + Option + O")?.contains("桌面空间切换") == true,
            "Control + Left Arrow should explain Space switching conflict"
        )

        let lowRiskLetter = HotKeyShortcut(
            keyCode: UInt32(kVK_ANSI_T),
            modifiers: UInt32(controlKey | optionKey),
            keyLabel: "T"
        )
        expect(
            lowRiskLetter.advisoryMessage(suggestion: "Control + Option + O") == nil,
            "Control + Option + T should not warn"
        )

        let allRecommendations = HotKeyShortcut.recommendedAlternatives
        expect(
            Set(allRecommendations).count == allRecommendations.count,
            "recommended alternatives should not contain duplicates"
        )

        print("ok: hotkey advisory cases passed")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("error: hotkey advisory regression\n\(message)\n", stderr)
            exit(1)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "advisoryMessage" "$CHECK_PATH"; then
    echo "error: failed to extract HotKeyShortcut advisory helpers from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
