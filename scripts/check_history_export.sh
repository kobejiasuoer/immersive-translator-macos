#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/TranslationHistoryStore.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-history-export.XXXXXX")"
CHECK_PATH="$TMP_DIR/HistoryExportCheck.swift"
BINARY_PATH="$TMP_DIR/check_history_export"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import AppKit\nimport SwiftUI\nimport UniformTypeIdentifiers\n\n'
    awk '
        /^enum TranslationSource[: ]/ { printing = 1 }
        /^final class TranslationHistoryWindowController/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^private enum HistoryExportFormat[: ]/ { printing = 1 }
        /^struct TranslationHistoryView[: ]/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    cat <<'SWIFT'

@main
@MainActor
private struct HistoryExportCheck {
    static func main() throws {
        let formatter = ISO8601DateFormatter()
        let records: [TranslationRecord] = [
            TranslationRecord(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                createdAt: formatter.date(from: "2026-06-10T08:30:00Z")!,
                original: "Hello, \"world\"\nline two",
                translation: "你好，\"世界\"\n第二行",
                targetLanguage: "简体中文",
                source: .selection,
                isFavorite: true
            ),
            TranslationRecord(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                createdAt: formatter.date(from: "2026-06-10T09:45:00Z")!,
                original: """
                Code fence:
                ```swift
                print("hi")
                ```
                """,
                translation: "代码围栏需要安全导出。",
                targetLanguage: "English",
                source: .screenshotOCR,
                isFavorite: false
            )
        ]

        let store = TranslationHistoryStore()
        var failures: [String] = []

        try checkCSVExportText(store: store, records: records, failures: &failures)
        try checkFileExportAddsCSVExtensionAndBOM(store: store, records: records, failures: &failures)
        try checkJSONExport(store: store, records: records, failures: &failures)
        try checkMarkdownExport(store: store, records: records, failures: &failures)
        try checkPlainTextExport(store: store, records: records, failures: &failures)
        checkFormatURLNormalization(failures: &failures)
        checkDefaultExportFileNames(records: records, failures: &failures)

        if failures.isEmpty {
            print("ok: history export cases passed")
        } else {
            fputs("error: history export regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }

    private static func checkCSVExportText(
        store: TranslationHistoryStore,
        records: [TranslationRecord],
        failures: inout [String]
    ) throws {
        let csv = try store.exportText(records: records, fileExtension: "csv")
        expect(!csv.hasPrefix("\u{FEFF}"), "clipboard CSV text should not include BOM", failures: &failures)
        expect(
            csv.contains("id,created_at,source,target_language,favorite,original,translation"),
            "CSV should include stable header",
            failures: &failures
        )
        expect(
            csv.contains(#""Hello, ""world"""#),
            "CSV should escape commas and quotes in original text",
            failures: &failures
        )
        expect(
            csv.contains(#""你好，""世界"""#),
            "CSV should escape quotes in translated text",
            failures: &failures
        )
        expect(
            csv.contains(",true,"),
            "CSV should preserve favorite=true",
            failures: &failures
        )
        expect(
            csv.contains("截图 OCR"),
            "CSV should use source display names",
            failures: &failures
        )
    }

    private static func checkFileExportAddsCSVExtensionAndBOM(
        store: TranslationHistoryStore,
        records: [TranslationRecord],
        failures: inout [String]
    ) throws {
        let exportURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-export-without-extension")
        let result = try store.export(records: records, to: exportURL)
        expect(
            result.url.pathExtension == "csv",
            "file export without extension should default to .csv",
            failures: &failures
        )
        expect(
            result.formatName == "CSV",
            "file export result should report CSV format",
            failures: &failures
        )
        let data = try Data(contentsOf: result.url)
        expect(
            data.starts(with: Data([0xEF, 0xBB, 0xBF])),
            "CSV file export should include UTF-8 BOM for spreadsheet compatibility",
            failures: &failures
        )
    }

    private static func checkJSONExport(
        store: TranslationHistoryStore,
        records: [TranslationRecord],
        failures: inout [String]
    ) throws {
        let jsonText = try store.exportText(records: records, fileExtension: "json")
        let data = Data(jsonText.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([TranslationRecord].self, from: data)
        expect(decoded == records, "JSON export should round-trip translation records", failures: &failures)
        expect(jsonText.contains(#""isFavorite" : true"#), "JSON should preserve favorites", failures: &failures)
    }

    private static func checkMarkdownExport(
        store: TranslationHistoryStore,
        records: [TranslationRecord],
        failures: inout [String]
    ) throws {
        let markdown = try store.exportText(records: records, fileExtension: "md")
        expect(markdown.contains("# Immersive Translator History"), "Markdown should include title", failures: &failures)
        expect(markdown.contains("- Exported records: 2"), "Markdown should include record count", failures: &failures)
        expect(markdown.contains("- Favorites: 1"), "Markdown should include favorite count", failures: &failures)
        expect(markdown.contains("选中文本 1"), "Markdown should summarize selection source count", failures: &failures)
        expect(markdown.contains("截图 OCR 1"), "Markdown should summarize OCR source count", failures: &failures)
        expect(
            markdown.contains("````\nCode fence:\n```swift"),
            "Markdown should use a longer fence when content contains triple backticks",
            failures: &failures
        )
        expect(
            markdown.contains("## 1. 2026-06-10T08:30:00Z · 选中文本 · 简体中文 · favorite"),
            "Markdown should include stable per-record metadata and favorite marker",
            failures: &failures
        )
    }

    private static func checkPlainTextExport(
        store: TranslationHistoryStore,
        records: [TranslationRecord],
        failures: inout [String]
    ) throws {
        let text = try store.exportText(records: records, fileExtension: "txt")
        expect(text.contains("Immersive Translator History"), "plain text should include title", failures: &failures)
        expect(text.contains("Records: 2"), "plain text should include record count", failures: &failures)
        expect(text.contains("Favorites: 1"), "plain text should include favorite count", failures: &failures)
        expect(text.contains("#1 2026-06-10T08:30:00Z / 选中文本 / 简体中文 / favorite"), "plain text should include favorite metadata", failures: &failures)
        expect(text.contains("Original:\nHello, \"world\"\nline two"), "plain text should preserve original newlines", failures: &failures)
        expect(text.contains("\n---\n"), "plain text should separate records", failures: &failures)
    }

    private static func checkFormatURLNormalization(failures: inout [String]) {
        let baseURL = URL(fileURLWithPath: "/tmp/history-export")
        expect(
            HistoryExportFormat.csv.normalizedURL(for: baseURL).lastPathComponent == "history-export.csv",
            "CSV normalization should append .csv",
            failures: &failures
        )
        expect(
            HistoryExportFormat.markdown.normalizedURL(for: baseURL.appendingPathExtension("txt")).lastPathComponent == "history-export.md",
            "Markdown normalization should replace unrelated extension with .md",
            failures: &failures
        )
        expect(
            HistoryExportFormat.markdown.normalizedURL(for: baseURL.appendingPathExtension("markdown")).lastPathComponent == "history-export.markdown",
            "Markdown normalization should keep accepted .markdown extension",
            failures: &failures
        )
        expect(
            HistoryExportFormat.plainText.normalizedURL(for: baseURL.appendingPathExtension("text")).lastPathComponent == "history-export.text",
            "plain text normalization should keep accepted .text extension",
            failures: &failures
        )
        expect(
            HistoryExportFormat.json.normalizedURL(for: baseURL.appendingPathExtension("csv")).lastPathComponent == "history-export.json",
            "JSON normalization should replace wrong extension with .json",
            failures: &failures
        )
    }

    private static func checkDefaultExportFileNames(
        records: [TranslationRecord],
        failures: inout [String]
    ) {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: "2026-06-10T08:30:00Z")!
        var singleRecord = records[0]
        singleRecord.translation = "API/Key: limits?\nnew line <bad>|ok"

        let singleName = HistoryExportFileName.make(
            fileSuffix: "record",
            records: [singleRecord],
            format: .markdown,
            date: date
        )
        expect(
            singleName.hasPrefix("immersive-translator-record-API-Key-limits-new-line-bad-ok-"),
            "single-record filename should include sanitized content summary: \(singleName)",
            failures: &failures
        )
        expect(singleName.hasSuffix(".md"), "single-record filename should use selected format extension", failures: &failures)
        expect(!singleName.contains("/") && !singleName.contains(":") && !singleName.contains("?"), "single-record filename should remove unsafe separators", failures: &failures)
        expect(!singleName.contains("<") && !singleName.contains(">") && !singleName.contains("|"), "single-record filename should remove shell-unfriendly characters", failures: &failures)

        let multiName = HistoryExportFileName.make(
            fileSuffix: "visible",
            records: records,
            format: .csv,
            date: date
        )
        expect(
            multiName.hasPrefix("immersive-translator-visible-2-items-"),
            "multi-record filename should include record count: \(multiName)",
            failures: &failures
        )
        expect(multiName.hasSuffix(".csv"), "multi-record filename should keep CSV extension", failures: &failures)

        let fallbackName = HistoryExportFileName.make(
            fileSuffix: "selected",
            records: [
                TranslationRecord(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    createdAt: date,
                    original: "\n\t",
                    translation: "",
                    targetLanguage: "English",
                    source: .screenshotOCR,
                    isFavorite: false
                )
            ],
            format: .json,
            date: date
        )
        expect(
            fallbackName.hasPrefix("immersive-translator-selected-截图 OCR-"),
            "empty single-record filename should fall back to source label: \(fallbackName)",
            failures: &failures
        )
        expect(fallbackName.hasSuffix(".json"), "fallback filename should use JSON extension", failures: &failures)
    }

    private static func expect(_ condition: Bool, _ message: String, failures: inout [String]) {
        if !condition {
            failures.append(message)
        }
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "TranslationHistoryStore" "$CHECK_PATH"; then
    echo "error: failed to extract TranslationHistoryStore from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
