#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/TranslationPanel.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-ocr-preview-quality.XXXXXX")"
CHECK_PATH="$TMP_DIR/OCRPreviewQualityCheck.swift"
BINARY_PATH="$TMP_DIR/check_ocr_preview_quality"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import Foundation\n'
    printf 'import SwiftUI\n'
    printf 'import Darwin\n\n'
    awk '
        /^private struct OCRPreviewQualityHint / { printing = 1 }
        /^private struct OCRPreviewTextEditor/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private enum OCRPreviewParagraphPolisher / { printing = 1 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
private struct OCRPreviewQualityCheck {
    private struct NoiseCase {
        let name: String
        let input: String
        let expectedNoise: Bool
        let expectedHintSnippet: String?
    }

    static func main() {
        let cases: [NoiseCase] = [
            NoiseCase(
                name: "empty result suggests OCR settings",
                input: "",
                expectedNoise: false,
                expectedHintSnippet: "OCR 设置"
            ),
            NoiseCase(
                name: "separator only",
                input: """
                ----
                ————
                ••••
                """,
                expectedNoise: true,
                expectedHintSnippet: "符号"
            ),
            NoiseCase(
                name: "ocr glyph noise",
                input: "╳╳╳",
                expectedNoise: true,
                expectedHintSnippet: "噪声"
            ),
            NoiseCase(
                name: "mixed punctuation with tiny text ratio",
                input: ">>> ~~ !! A",
                expectedNoise: true,
                expectedHintSnippet: "重新框选"
            ),
            NoiseCase(
                name: "normal english sentence",
                input: "Please confirm the OCR preview before translating.",
                expectedNoise: false,
                expectedHintSnippet: nil
            ),
            NoiseCase(
                name: "normal chinese sentence",
                input: "请确认识别文本后再翻译。",
                expectedNoise: false,
                expectedHintSnippet: nil
            ),
            NoiseCase(
                name: "model id is real text",
                input: "gpt-5.4-mini",
                expectedNoise: false,
                expectedHintSnippet: nil
            ),
            NoiseCase(
                name: "api status is real text",
                input: "API 200 OK",
                expectedNoise: false,
                expectedHintSnippet: nil
            ),
            NoiseCase(
                name: "long single line suggests manual line break",
                input: String(repeating: "This OCR result is a very long single line that should be checked at both ends before translation. ", count: 2),
                expectedNoise: false,
                expectedHintSnippet: "Shift+Enter"
            ),
            NoiseCase(
                name: "clipped paragraph suggests reselect",
                input: """
                this paragraph starts in the middle and keeps going across the next OCR line
                without a clear sentence ending or enough surrounding context
                """,
                expectedNoise: false,
                expectedHintSnippet: "Esc/⌘R"
            ),
            NoiseCase(
                name: "multi column warns against blind polish",
                input: """
                Documentation paragraph begins here
                xylophone
                Another documentation paragraph
                quartz
                Third documentation paragraph
                nebula
                """,
                expectedNoise: false,
                expectedHintSnippet: "不要先用 ⌘J"
            ),
            NoiseCase(
                name: "many short lines suggest polish or single column",
                input: """
                File
                Edit
                View
                Navigate
                Search
                This longer status line belongs below
                Another longer status line belongs below
                Help
                Preferences
                Final longer description line
                """,
                expectedNoise: false,
                expectedHintSnippet: "自然段可先按 ⌘J"
            )
        ]

        var failures: [String] = []
        for testCase in cases {
            let stats = OCRPreviewTextStats.make(from: testCase.input)
            if stats.looksLikeNonTextNoise != testCase.expectedNoise {
                failures.append(
                    """
                    \(testCase.name)
                    expected noise: \(testCase.expectedNoise)
                    actual noise: \(stats.looksLikeNonTextNoise)
                    text-like/non-whitespace: \(stats.textLikeCharacterCount)/\(stats.nonWhitespaceCharacterCount)
                    """
                )
            }

            let hint = OCRPreviewQualityHint.make(from: stats)
            if let expectedSnippet = testCase.expectedHintSnippet,
               hint?.text.contains(expectedSnippet) != true {
                failures.append(
                    """
                    \(testCase.name)
                    missing hint snippet: \(expectedSnippet)
                    actual hint: \(hint?.text ?? "<nil>")
                    """
                )
            }
            if testCase.expectedHintSnippet == nil,
               hint?.text.contains("符号、分隔线或 OCR 噪声") == true {
                failures.append(
                    """
                    \(testCase.name)
                    normal text should not show non-text-noise hint
                    actual hint: \(hint?.text ?? "<nil>")
                    """
                )
            }
        }

        let attentionCases: [(name: String, input: String, expected: Bool)] = [
            ("empty OCR result needs attention", "", true),
            ("noise OCR result needs attention", "╳╳╳", true),
            ("very short OCR result needs attention", "OK", true),
            (
                "clipped paragraph needs attention",
                """
                this paragraph starts in the middle and keeps going across the next OCR line
                without a clear sentence ending or enough surrounding context
                """,
                true
            ),
            ("normal sentence does not need warning status", "Please confirm the OCR preview before translating.", false),
            ("model id is not noise but still confirmable", "gpt-5.4-mini", false)
        ]

        for testCase in attentionCases {
            let stats = OCRPreviewTextStats.make(from: testCase.input)
            if stats.needsAttentionBeforeOCRConfirmation != testCase.expected {
                failures.append(
                    """
                    \(testCase.name)
                    expected attention: \(testCase.expected)
                    actual attention: \(stats.needsAttentionBeforeOCRConfirmation)
                    """
                )
            }
        }

        if failures.isEmpty {
            print("ok: OCR preview quality cases passed (\(cases.count) quality, \(attentionCases.count) attention)")
        } else {
            fputs("error: OCR preview quality regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "looksLikeNonTextNoise" "$CHECK_PATH"; then
    echo "error: failed to extract OCR preview quality helpers from $SOURCE_PATH" >&2
    exit 1
fi

if ! awk '/func showOCRPreview/,/func dismiss/' "$SOURCE_PATH" | grep -q 'model.allowsOpenSettings = true'; then
    echo "error: OCR preview should expose settings entry for OCR mode/language recovery" >&2
    exit 1
fi

if ! awk '/func showOCRPreview/,/func dismiss/' "$SOURCE_PATH" | grep -q 'model.openSettingsTitle = "OCR 设置"'; then
    echo "error: OCR preview settings entry should be labeled OCR 设置" >&2
    exit 1
fi

if ! awk '/func showOCRPreview/,/func dismiss/' "$SOURCE_PATH" | grep -q '调整识别语言和模式'; then
    echo "error: empty OCR preview status should suggest OCR language/mode recovery" >&2
    exit 1
fi

if ! awk '/private var ocrPlaceholderText/,/private var ocrKeyboardHintText/' "$SOURCE_PATH" | grep -q 'OCR 语言/模式'; then
    echo "error: empty OCR preview placeholder should mention OCR language/mode settings" >&2
    exit 1
fi

if ! awk '/private var ocrPreviewActions/,/private var metadataText/' "$SOURCE_PATH" | grep -q 'actionButton(model.openSettingsTitle, systemName: "slider.horizontal.3")'; then
    echo "error: OCR preview actions should include the settings button" >&2
    exit 1
fi

if ! awk '/private var ocrPreviewActions/,/private var metadataText/' "$SOURCE_PATH" | grep -q '调整识别模式和识别语言'; then
    echo "error: OCR preview settings button should explain OCR mode/language recovery" >&2
    exit 1
fi

if ! awk '/private var ocrPreviewActions/,/private var metadataText/' "$SOURCE_PATH" | grep -q '\.keyboardShortcut(",", modifiers: \.command)'; then
    echo "error: OCR preview settings button should expose Cmd+comma" >&2
    exit 1
fi

if ! awk '/private struct OCRPreviewTextEditor/,/^private enum OCRPreviewParagraphPolisher/' "$SOURCE_PATH" | grep -q 'let onOpenSettings: () -> Void'; then
    echo "error: OCR preview text editor should receive settings action" >&2
    exit 1
fi

if ! awk '/private struct OCRPreviewTextEditor/,/^private enum OCRPreviewParagraphPolisher/' "$SOURCE_PATH" | grep -q 'case 43'; then
    echo "error: OCR preview text editor should intercept Cmd+comma while focused" >&2
    exit 1
fi

if ! awk '/private struct OCRPreviewTextEditor/,/^private enum OCRPreviewParagraphPolisher/' "$SOURCE_PATH" | grep -q 'onOpenSettings?()'; then
    echo "error: OCR preview text editor Cmd+comma should open settings" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
