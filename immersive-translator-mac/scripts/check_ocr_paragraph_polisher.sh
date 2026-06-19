#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/TranslationPanel.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-ocr-polisher.XXXXXX")"
CHECK_PATH="$TMP_DIR/OCRPreviewParagraphPolisherCheck.swift"
BINARY_PATH="$TMP_DIR/check_ocr_paragraph_polisher"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import Foundation\n'
    printf 'import Darwin\n\n'
    awk '
        /^(private )?enum OCRPreviewParagraphPolisher / { printing = 1 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
private struct OCRPreviewParagraphPolisherCheck {
    private struct Case {
        let name: String
        let input: String
        let expected: String
    }

    private struct BoundaryCase {
        let name: String
        let lines: [String]
        let expectedCount: Int
    }

    static func main() {
        let cases: [Case] = [
            Case(
                name: "joins hard-wrapped natural paragraph",
                input: """
                Immersive translation should feel
                fast enough that readers stay
                inside their original flow.
                """,
                expected: "Immersive translation should feel fast enough that readers stay inside their original flow."
            ),
            Case(
                name: "dehyphenates latin line breaks",
                input: """
                The recogn-
                ition preview should avoid noisy joins.
                """,
                expected: "The recognition preview should avoid noisy joins."
            ),
            Case(
                name: "preserves clear hyphenated compound line breaks",
                input: """
                The state-of-the-
                art OCR preview should keep real compound words readable.
                """,
                expected: "The state-of-the-art OCR preview should keep real compound words readable."
            ),
            Case(
                name: "preserves common hyphenated prefix line breaks",
                input: """
                Use non-
                blocking requests when streaming translations.
                """,
                expected: "Use non-blocking requests when streaming translations."
            ),
            Case(
                name: "joins technical tokens without inserting spaces",
                input: """
                Download from https://example.
                com/releases/app.zip and use support@
                example.com for help.
                """,
                expected: "Download from https://example.com/releases/app.zip and use support@example.com for help."
            ),
            Case(
                name: "joins model names and file paths without inserting spaces",
                input: """
                Use gpt-
                5.4-mini with /usr/local/
                bin/translator.
                """,
                expected: "Use gpt-5.4-mini with /usr/local/bin/translator."
            ),
            Case(
                name: "keeps short heading separate from long body",
                input: """
                Usage Notes
                Select a compact region around the text you want to translate so OCR can avoid nearby labels and unrelated columns.
                """,
                expected: """
                Usage Notes

                Select a compact region around the text you want to translate so OCR can avoid nearby labels and unrelated columns.
                """
            ),
            Case(
                name: "keeps repeated sentence-case section anchors as separate blocks",
                input: """
                Release notes
                This update improves OCR preview and keeps translation status readable during slow requests.
                Known issues
                Complex multi-column layouts should still be selected one column at a time.
                """,
                expected: """
                Release notes
                This update improves OCR preview and keeps translation status readable during slow requests.

                Known issues
                Complex multi-column layouts should still be selected one column at a time.
                """
            ),
            Case(
                name: "keeps action label after long message separate",
                input: """
                Open Settings
                The provider returned an authentication error and the API key should be checked before retrying.
                Retry
                """,
                expected: """
                Open Settings
                The provider returned an authentication error and the API key should be checked before retrying.

                Retry
                """
            ),
            Case(
                name: "preserves structured and table-of-contents lines",
                input: """
                1. Enable screen recording
                2. Select the text region
                3. Confirm the OCR preview

                Introduction ........ 1
                OCR workflow ........ 4
                Release checklist ... 9
                """,
                expected: """
                1. Enable screen recording
                2. Select the text region
                3. Confirm the OCR preview

                Introduction ........ 1
                OCR workflow ........ 4
                Release checklist ... 9
                """
            ),
            Case(
                name: "joins wrapped bullet item continuations",
                input: """
                - Capture only the text
                region around the paragraph
                - Press Enter to translate
                """,
                expected: """
                - Capture only the text region around the paragraph
                - Press Enter to translate
                """
            ),
            Case(
                name: "joins bullet continuation after semicolon",
                input: """
                - Show the first translated token earlier;
                keep a clear status visible during slow requests
                - Classify provider errors precisely
                """,
                expected: """
                - Show the first translated token earlier; keep a clear status visible during slow requests
                - Classify provider errors precisely
                """
            ),
            Case(
                name: "joins wrapped numbered cjk item continuations",
                input: """
                1. 框选包含完整段落
                避免截到半行或邻近栏目
                2. 确认 OCR 预览
                """,
                expected: """
                1. 框选包含完整段落避免截到半行或邻近栏目
                2. 确认 OCR 预览
                """
            ),
            Case(
                name: "joins cjk numbered continuation after semicolon",
                input: """
                1. 更早显示首字；
                慢请求给出明确状态
                2. 区分接口错误
                """,
                expected: """
                1. 更早显示首字；慢请求给出明确状态
                2. 区分接口错误
                """
            ),
            Case(
                name: "keeps list item label value lines when label ends strongly",
                input: """
                - Provider:
                openrouter/auto
                - Model:
                openrouter/auto
                """,
                expected: """
                - Provider:
                openrouter/auto
                - Model:
                openrouter/auto
                """
            ),
            Case(
                name: "preserves compact field value pairs",
                input: """
                Provider
                openrouter/auto
                """,
                expected: """
                Provider
                openrouter/auto
                """
            ),
            Case(
                name: "preserves dangling question answer labels while joining answer wraps",
                input: """
                Question:
                How do I configure the provider
                for a local model?
                Answer:
                Use the Ollama preset
                and verify the request.
                """,
                expected: """
                Question:
                How do I configure the provider for a local model?
                Answer:
                Use the Ollama preset and verify the request.
                """
            ),
            Case(
                name: "preserves chinese dangling field labels",
                input: """
                问题：
                如何减少 OCR 跨栏误合并？
                建议：
                只框选单列文本
                并先整理段落。
                """,
                expected: """
                问题：
                如何减少 OCR 跨栏误合并？
                建议：
                只框选单列文本并先整理段落。
                """
            ),
            Case(
                name: "preserves obvious code control flow",
                input: """
                for item in items {
                print(item)
                }
                """,
                expected: """
                for item in items {
                print(item)
                }
                """
            ),
            Case(
                name: "still joins two-line natural phrase",
                input: """
                Release notes
                available online
                """,
                expected: "Release notes available online"
            )
        ]

        let boundaryCases: [BoundaryCase] = [
            BoundaryCase(
                name: "counts compact model field boundary",
                lines: ["Provider", "openrouter/auto"],
                expectedCount: 1
            ),
            BoundaryCase(
                name: "counts compact numeric status boundary",
                lines: ["Latency", "320ms", "Status", "ok"],
                expectedCount: 3
            ),
            BoundaryCase(
                name: "does not count natural short phrase",
                lines: ["Release notes", "available online"],
                expectedCount: 0
            )
        ]

        let separatedAnchorCases: [(name: String, lines: [String], expected: Bool)] = [
            (
                "detects repeated section anchors around long text",
                [
                    "Release notes",
                    "This update improves OCR preview and keeps translation status readable during slow requests.",
                    "Known issues",
                    "Complex multi-column layouts should still be selected one column at a time."
                ],
                true
            ),
            (
                "does not flag normal lowercase hard wraps",
                [
                    "Immersive translation should feel",
                    "fast enough that readers stay",
                    "inside their original flow."
                ],
                false
            ),
            (
                "does not flag short natural phrase",
                ["Release notes", "available online"],
                false
            )
        ]

        let danglingFieldCases: [(name: String, text: String, expected: Bool)] = [
            ("english field label", "Question:", true),
            ("chinese field label", "建议：", true),
            ("long sentence should not be label", "This is a regular sentence that happens to end with a colon:", false),
            ("inline key value stays separate detector", "Provider: openrouter/auto", false)
        ]

        var failures: [String] = []
        for testCase in cases {
            let actual = OCRPreviewParagraphPolisher.polish(testCase.input)
            if actual != testCase.expected {
                failures.append(
                    """
                    \(testCase.name)
                    expected:
                    \(testCase.expected)
                    actual:
                    \(actual)
                    """
                )
            }
        }
        for testCase in boundaryCases {
            let actual = OCRPreviewParagraphPolisher.compactFieldBoundaryCount(in: testCase.lines)
            if actual != testCase.expectedCount {
                failures.append(
                    """
                    \(testCase.name)
                    expected boundary count: \(testCase.expectedCount)
                    actual boundary count: \(actual)
                    """
                )
            }
        }
        for testCase in separatedAnchorCases {
            let actual = OCRPreviewParagraphPolisher.looksLikeSeparatedAnchorBlock(testCase.lines)
            if actual != testCase.expected {
                failures.append(
                    """
                    \(testCase.name)
                    expected separated anchor block: \(testCase.expected)
                    actual separated anchor block: \(actual)
                    """
                )
            }
        }
        for testCase in danglingFieldCases {
            let actual = OCRPreviewParagraphPolisher.looksLikeDanglingFieldLabelLine(testCase.text)
            if actual != testCase.expected {
                failures.append(
                    """
                    \(testCase.name)
                    expected dangling label: \(testCase.expected)
                    actual dangling label: \(actual)
                    """
                )
            }
        }

        if failures.isEmpty {
            print("ok: OCR paragraph polisher cases passed (\(cases.count) polish, \(boundaryCases.count) boundary, \(separatedAnchorCases.count) separated anchor, \(danglingFieldCases.count) dangling field)")
        } else {
            fputs("error: OCR paragraph polisher regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "OCRPreviewParagraphPolisher" "$CHECK_PATH"; then
    echo "error: failed to extract OCRPreviewParagraphPolisher from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
