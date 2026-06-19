#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/TranslationClient.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-stream-parser.XXXXXX")"
CHECK_PATH="$TMP_DIR/TranslationStreamParserCheck.swift"
BINARY_PATH="$TMP_DIR/check_translation_stream_parser"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import Foundation\n\n'
    printf 'private enum TranslationClient {\n'
    awk '
        /^    private static func parseStreamedResponse/ { printing = 1 }
        /^    private static func isStreamedResponse/ { printing = 0 }
        printing {
            sub(/^    private static func/, "    static func")
            print
        }
    ' "$SOURCE_PATH"
    printf '}\n\n'
    awk '
        /^private struct ChatMessage[: ]/ { printing = 1 }
        /^private struct ThinkingConfig[: ]/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private struct ChatCompletionResponse[: ]/ { printing = 1 }
        /^private struct APIErrorResponse[: ]/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^(private )?enum TranslationResponseErrorParser / { printing = 1 }
        /^private struct RequestOptions / { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private struct APIErrorResponse([: ]|$)/ { printing = 1 }
        /^private extension String / { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private extension String / { printing = 1 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
private struct TranslationStreamParserCheck {
    private struct Case {
        let name: String
        let sse: String
        let expected: String?
    }

    private struct ErrorCase {
        let name: String
        let sse: String
        let expectedMessage: String?
    }

    static func main() {
        let cases: [Case] = [
            Case(
                name: "delta content chunks",
                sse: """
                data: {"choices":[{"delta":{"content":"你"}}]}
                data: {"choices":[{"delta":{"content":"好"}}]}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "choices text chunks",
                sse: """
                data: {"choices":[{"text":"你"}]}
                data: {"choices":[{"text":"好"}]}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "message content fallback chunks",
                sse: """
                data: {"choices":[{"message":{"role":"assistant","content":"hello"}}]}
                data: {"choices":[{"text":" world"}]}
                data: [DONE]
                """,
                expected: "hello world"
            ),
            Case(
                name: "choice content chunks",
                sse: """
                data: {"choices":[{"content":"你"}]}
                data: {"choices":[{"content":"好"}]}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "top-level content and text chunks",
                sse: """
                data: {"content":"你"}
                data: {"text":"好"}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "top-level delta string chunks",
                sse: """
                data: {"delta":"你"}
                data: {"delta":"好"}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "top-level delta object text chunks",
                sse: """
                data: {"delta":{"text":"你"}}
                data: {"delta":{"content":"好"}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "top-level message content chunks",
                sse: """
                data: {"message":{"role":"assistant","content":"你"}}
                data: {"message":{"content":"好"}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "ollama response chunks",
                sse: """
                data: {"response":"你"}
                data: {"response":"好"}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "completion chunks",
                sse: """
                data: {"completion":"你"}
                data: {"completion":"好"}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "responses api output text chunks",
                sse: """
                data: {"output_text":"你"}
                data: {"output_text":"好"}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "content block text chunks",
                sse: """
                data: {"content_block":{"text":"你"}}
                data: {"content_block":{"text":"好"}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "array content text chunks",
                sse: """
                data: {"content":[{"type":"text","text":"你"}]}
                data: {"content":[{"type":"output_text","text":"好"}]}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "proxy data envelope choices chunks",
                sse: """
                data: {"event":"message.delta","data":{"choices":[{"delta":{"content":"你"}}]}}
                data: {"event":"message.delta","data":{"choices":[{"delta":{"content":"好"}}]}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "payload envelope delta chunks",
                sse: """
                data: {"payload":{"delta":{"text":"你"}}}
                data: {"payload":{"delta":{"text":"好"}}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "result envelope output text chunks",
                sse: """
                data: {"result":{"output_text":"你"}}
                data: {"result":{"output":{"text":"好"}}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "gemini style candidates parts chunks",
                sse: """
                data: {"candidates":[{"content":{"parts":[{"text":"你"}]}}]}
                data: {"candidates":[{"content":{"parts":[{"text":"好"}]}}]}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "text value object chunks",
                sse: """
                data: {"content":[{"type":"text","text":{"value":"你"}}]}
                data: {"delta":{"content":{"value":"好"}}}
                data: [DONE]
                """,
                expected: "你好"
            ),
            Case(
                name: "role only chunks stay empty",
                sse: """
                data: {"choices":[{"delta":{"role":"assistant"}}]}
                data: [DONE]
                """,
                expected: nil
            ),
            Case(
                name: "metadata envelope stays empty",
                sse: """
                data: {"event":"message_start","data":{"id":"msg_1","type":"message","role":"assistant","model":"example"}}
                data: [DONE]
                """,
                expected: nil
            ),
            Case(
                name: "metadata value outside text slot stays empty",
                sse: """
                data: {"data":{"metadata":{"value":"not translation"},"type":"message_start"}}
                data: [DONE]
                """,
                expected: nil
            )
        ]

        let errorCases: [ErrorCase] = [
            ErrorCase(
                name: "openai error object in stream",
                sse: """
                data: {"error":{"message":"model_not_found: model does not exist","type":"invalid_request_error"}}
                data: [DONE]
                """,
                expectedMessage: "model_not_found: model does not exist"
            ),
            ErrorCase(
                name: "ok false envelope in stream",
                sse: """
                data: {"ok":false,"message":"rate limit exceeded"}
                data: [DONE]
                """,
                expectedMessage: "rate limit exceeded"
            ),
            ErrorCase(
                name: "normal content chunks are not stream errors",
                sse: """
                data: {"choices":[{"delta":{"content":"你"}}]}
                data: {"choices":[{"delta":{"content":"好"}}]}
                data: [DONE]
                """,
                expectedMessage: nil
            )
        ]

        var failures: [String] = []
        for testCase in cases {
            guard let data = testCase.sse.data(using: .utf8) else {
                failures.append("\(testCase.name): failed to encode fixture")
                continue
            }

            let actual = TranslationClient.parseStreamedResponse(from: data)?
                .choices
                .first?
                .message
                .content
            if actual != testCase.expected {
                failures.append(
                    """
                    \(testCase.name)
                    expected: \(String(describing: testCase.expected))
                    actual: \(String(describing: actual))
                    """
                )
            }
        }

        for testCase in errorCases {
            let actual = firstStreamErrorMessage(in: testCase.sse)
            if actual != testCase.expectedMessage {
                failures.append(
                    """
                    \(testCase.name)
                    expected stream error: \(String(describing: testCase.expectedMessage))
                    actual stream error: \(String(describing: actual))
                    """
                )
            }
        }

        if failures.isEmpty {
            print("ok: translation stream parser cases passed (\(cases.count) chunks, \(errorCases.count) stream errors)")
        } else {
            fputs("error: translation stream parser regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }

    private static func firstStreamErrorMessage(in sse: String) -> String? {
        for rawLine in sse.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("data:") else { continue }

            let jsonText = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            guard jsonText != "[DONE]",
                  let jsonData = jsonText.data(using: .utf8) else {
                continue
            }
            if let message = TranslationResponseErrorParser.message(from: jsonData) {
                return message
            }
        }
        return nil
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "parseStreamedResponse" "$CHECK_PATH"; then
    echo "error: failed to extract stream parser from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
