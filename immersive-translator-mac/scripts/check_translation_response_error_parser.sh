#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/TranslationClient.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-response-error-parser.XXXXXX")"
CHECK_PATH="$TMP_DIR/TranslationResponseErrorParserCheck.swift"
BINARY_PATH="$TMP_DIR/check_translation_response_error_parser"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import Foundation\n\n'
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
private struct TranslationResponseErrorParserCheck {
    private struct Case {
        let name: String
        let json: String
        let expectedMessage: String?
    }

    static func main() {
        let cases: [Case] = [
            Case(
                name: "openai error object",
                json: #"{"error":{"message":"model_not_found: model does not exist","type":"invalid_request_error"}}"#,
                expectedMessage: "model_not_found: model does not exist"
            ),
            Case(
                name: "openai empty message falls back to code",
                json: #"{"error":{"message":"","code":"permission_denied"}}"#,
                expectedMessage: "permission_denied"
            ),
            Case(
                name: "errors array",
                json: #"{"errors":[{"message":"insufficient_quota: out of credits"}]}"#,
                expectedMessage: "insufficient_quota: out of credits"
            ),
            Case(
                name: "ok false envelope",
                json: #"{"ok":false,"message":"rate limit exceeded"}"#,
                expectedMessage: "rate limit exceeded"
            ),
            Case(
                name: "success false nested detail",
                json: #"{"success":false,"detail":{"reason":"API key is invalid"}}"#,
                expectedMessage: "API key is invalid"
            ),
            Case(
                name: "object error envelope",
                json: #"{"object":"error","code":"permission_denied"}"#,
                expectedMessage: "permission_denied"
            ),
            Case(
                name: "unknown success json is not an error",
                json: #"{"ok":true,"data":[]}"#,
                expectedMessage: nil
            ),
            Case(
                name: "chat completions success is not an error",
                json: #"{"choices":[{"message":{"role":"assistant","content":"你好"}}]}"#,
                expectedMessage: nil
            )
        ]

        var failures: [String] = []
        for testCase in cases {
            guard let data = testCase.json.data(using: .utf8) else {
                failures.append("\(testCase.name): failed to encode fixture")
                continue
            }
            let actual = TranslationResponseErrorParser.message(from: data)
            if actual != testCase.expectedMessage {
                failures.append(
                    """
                    \(testCase.name)
                    expected: \(String(describing: testCase.expectedMessage))
                    actual: \(String(describing: actual))
                    """
                )
            }
        }

        if failures.isEmpty {
            print("ok: translation response error parser cases passed (\(cases.count))")
        } else {
            fputs("error: translation response error parser regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "TranslationResponseErrorParser" "$CHECK_PATH"; then
    echo "error: failed to extract TranslationResponseErrorParser from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
