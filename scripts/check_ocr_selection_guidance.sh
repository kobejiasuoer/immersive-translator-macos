#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/ScreenSelection.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-ocr-selection-guidance.XXXXXX")"
CHECK_PATH="$TMP_DIR/OCRSelectionGuidanceCheck.swift"
BINARY_PATH="$TMP_DIR/check_ocr_selection_guidance"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import AppKit\nimport Foundation\n\n'
    awk '
        /^private enum ScreenSelectionConstants / { printing = 1 }
        /^private struct ScreenSelectionMetrics / { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private enum ScreenSelectionGuidance / { printing = 1 }
        /^private enum SelectionVisualState / { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private enum SelectionSnapEdge/ { printing = 1 }
        /^private enum SelectionDragMode/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
private struct OCRSelectionGuidanceCheck {
    static func main() {
        checkReadabilityHints()
        checkEdgeSnapping()
        checkKeyboardHints()
        print("ok: OCR selection guidance cases passed")
    }

    private static func checkReadabilityHints() {
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 72, height: 24)) == "选区偏小，可能只截到局部文字；向外多框一点",
            "tiny selection warning should explain both width and height risk"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 240, height: 24)) == "高度偏低，可能只截到半行文字",
            "low-height warning should explain half-line OCR risk"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 72, height: 120)) == "宽度偏窄，尽量覆盖完整单词或一整列",
            "narrow-width warning should suggest covering words/columns"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 72, height: 320)) == "选区窄而高，可能截到列边缘或跨行碎片；建议横向扩到完整一列",
            "tall narrow warning should explain column-edge and cross-line fragment risk"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 960, height: 70)) == "像超长单行，确认左右边缘是否完整",
            "long single-line warning should mention left/right edges"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 1800, height: 1600)) == "区域较大，OCR 可能稍慢；可只框文字区域",
            "large-area warning should set speed expectations"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 360, height: 160)) == nil,
            "normal readable selection should not warn"
        )
        expect(
            ScreenSelectionGuidance.readabilityHint(forPixelSize: CGSize(width: 0, height: 160)) == nil,
            "invalid zero-width selection should not produce a misleading warning"
        )
    }

    private static func checkEdgeSnapping() {
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
        expect(
            ScreenSelectionGuidance.edgeSnapDescription(for: CGPoint(x: 5, y: 77), bounds: bounds) == "已吸附左边缘/上边缘",
            "point snap should describe left/top edges"
        )
        expect(
            ScreenSelectionGuidance.edgeSnapDescription(for: CGPoint(x: 96, y: 3), bounds: bounds) == "已吸附右边缘/下边缘",
            "point snap should describe right/bottom edges"
        )
        expect(
            ScreenSelectionGuidance.edgeSnapDescription(for: CGPoint(x: 50, y: 40), bounds: bounds) == nil,
            "center point should not be reported as snapped"
        )
        expect(
            ScreenSelectionGuidance.snappedEdgeDescription(for: CGRect(x: 0, y: 0, width: 100, height: 80), bounds: bounds) == "贴齐左/右/下/上",
            "full-screen rect should report all aligned edges"
        )
        expect(
            ScreenSelectionGuidance.snappedEdgeDescription(for: CGRect(x: 0.25, y: 10, width: 42, height: 30), bounds: bounds) == "贴齐左",
            "rect edge tolerance should catch sub-point left alignment"
        )
    }

    private static func checkKeyboardHints() {
        let before = CGRect(x: 20, y: 20, width: 80, height: 40)
        expect(
            ScreenSelectionGuidance.keyboardMoveHint(
                before: before,
                after: before.offsetBy(dx: 8, dy: 0),
                requestedDelta: CGPoint(x: 8, y: 0)
            ) == "已移动：右 8pt · Shift+方向键改大小 · Enter 截图",
            "keyboard move hint should report horizontal movement"
        )
        expect(
            ScreenSelectionGuidance.keyboardMoveHint(
                before: before,
                after: before,
                requestedDelta: CGPoint(x: -8, y: 0)
            ) == "已到屏幕边缘 · 反方向移动或拖动内部调整 · Enter 截图",
            "blocked keyboard move should explain edge clamp"
        )
        expect(
            ScreenSelectionGuidance.keyboardResizeHint(
                before: before,
                after: CGRect(x: 12, y: 20, width: 88, height: 40),
                requestedDelta: CGPoint(x: -8, y: 0),
                adjustsLeadingOrBottomEdge: true
            ) == "已调整左边缘：向左 8pt · Enter 截图",
            "leading-edge resize should name the left edge"
        )
        expect(
            ScreenSelectionGuidance.keyboardResizeHint(
                before: before,
                after: CGRect(x: 20, y: 20, width: 80, height: 48),
                requestedDelta: CGPoint(x: 0, y: 8),
                adjustsLeadingOrBottomEdge: false
            ) == "已调整上边缘：向上 8pt · Enter 截图",
            "trailing vertical resize should name the top edge"
        )
        expect(
            ScreenSelectionGuidance.keyboardResizeHint(
                before: before,
                after: before,
                requestedDelta: CGPoint(x: 0, y: -8),
                adjustsLeadingOrBottomEdge: true
            ) == "已到最小尺寸或屏幕边缘 · 反向调整或拖边放大 · Enter 截图",
            "blocked resize should mention minimum size or screen edge"
        )
        expect(
            ScreenSelectionGuidance.keyboardPointHint(
                before: CGPoint(x: 20, y: 20),
                after: CGPoint(x: 20, y: 28),
                requestedDelta: CGPoint(x: 0, y: 8)
            ) == "已移动端点：上 8pt · 继续拖拽或 Enter 截图",
            "endpoint keyboard hint should report vertical movement"
        )
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fputs("error: OCR selection guidance regression\n\(message)\n", stderr)
            exit(1)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "ScreenSelectionGuidance" "$CHECK_PATH"; then
    echo "error: failed to extract OCR selection guidance helpers from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
