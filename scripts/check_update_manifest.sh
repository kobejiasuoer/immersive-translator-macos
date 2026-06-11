#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_PATH="$ROOT_DIR/Sources/ImmersiveTranslator/UpdateChecker.swift"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ImmersiveTranslator-update-manifest.XXXXXX")"
CHECK_PATH="$TMP_DIR/UpdateManifestCheck.swift"
BINARY_PATH="$TMP_DIR/check_update_manifest"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

{
    printf 'import CryptoKit\nimport Foundation\nimport Darwin\n\n'
    cat <<'SWIFT'
enum DiagnosticLogger {
    static func log(_ message: String) {}
}

SWIFT
    awk '
        /^enum UpdateCheckError/ { printing = 1 }
        /^enum UpdateChecker/ { printing = 0 }
        printing { print }
    ' "$SOURCE_PATH"
    awk '
        /^enum UpdateChecker/ { printing = 1 }
        printing { print }
    ' "$SOURCE_PATH" \
        | sed \
            -e 's/private static func validateManifest/static func validateManifest/' \
            -e 's/private static func validateManifestURL/static func validateManifestURL/' \
            -e 's/private static func validateVersion/static func validateVersion/' \
            -e 's/private static func validateBuild/static func validateBuild/' \
            -e 's/private static func validateChecksum/static func validateChecksum/' \
            -e 's/private static func validateMinimumSystemVersion/static func validateMinimumSystemVersion/' \
            -e 's/private static func validatePackageSize/static func validatePackageSize/' \
            -e 's/private static func validatePublishedAt/static func validatePublishedAt/'
    cat <<'SWIFT'

@main
private struct UpdateManifestCheck {
    static func main() {
        var failures: [String] = []

        run("valid manifest resolves relative urls", failures: &failures) {
            let manifestURL = URL(string: "https://example.com/releases/update-manifest.json")!
            let manifest = try decodeManifest("""
            {
              "version": "1.2.0",
              "build": "3",
              "minimum_system_version": "13.0",
              "download_url": "ImmersiveTranslator-1.2.0-macOS.zip",
              "size_bytes": 123456,
              "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
              "release_notes_url": "notes/1.2.0.html",
              "published_at": "2026-06-10T12:34:56Z"
            }
            """)
            try UpdateChecker.validateManifest(manifest, manifestURL: manifestURL)
            let result = UpdateCheckResult(
                currentVersion: "1.1.9",
                currentBuild: "2",
                manifestURL: manifestURL,
                manifest: manifest
            )
            expect(result.hasUpdate, "1.2.0 should be newer than 1.1.9")
            expect(result.isSystemCompatible, "13.0 minimum should be compatible with this test host")
            expect(
                result.downloadURL.absoluteString == "https://example.com/releases/ImmersiveTranslator-1.2.0-macOS.zip",
                "relative download URL resolved incorrectly: \(result.downloadURL.absoluteString)"
            )
            expect(
                result.releaseNotesURL?.absoluteString == "https://example.com/releases/notes/1.2.0.html",
                "relative release notes URL resolved incorrectly: \(String(describing: result.releaseNotesURL?.absoluteString))"
            )
        }

        run("newer build on same version", failures: &failures) {
            let manifest = try decodeManifest(validJSON(version: "1.2.0", build: "4"))
            let result = UpdateCheckResult(
                currentVersion: "1.2.0",
                currentBuild: "3",
                manifestURL: URL(string: "https://example.com/update-manifest.json")!,
                manifest: manifest
            )
            expect(result.hasUpdate, "same version with higher build should be an update")
        }

        run("same version older build is not update", failures: &failures) {
            let manifest = try decodeManifest(validJSON(version: "1.2.0", build: "3"))
            let result = UpdateCheckResult(
                currentVersion: "1.2.0",
                currentBuild: "4",
                manifestURL: URL(string: "https://example.com/update-manifest.json")!,
                manifest: manifest
            )
            expect(!result.hasUpdate, "same version with lower build should not be an update")
        }

        expectThrows(
            "https manifest rejects http download",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.insecureManifestURL(let field, let value) = error else {
                    return false
                }
                return field == "download_url" && value == "http://example.com/app.zip"
            },
            operation: {
                let manifest = try decodeManifest(validJSON(downloadURL: "http://example.com/app.zip"))
                try UpdateChecker.validateManifest(
                    manifest,
                    manifestURL: URL(string: "https://example.com/update-manifest.json")!
                )
            }
        )

        expectThrows(
            "https manifest rejects relative http release notes",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.insecureManifestURL(let field, let value) = error else {
                    return false
                }
                return field == "release_notes_url" && value == "http://example.com/notes.html"
            },
            operation: {
                let manifest = try decodeManifest(validJSON(releaseNotesURL: "http://example.com/notes.html"))
                try UpdateChecker.validateManifest(
                    manifest,
                    manifestURL: URL(string: "https://example.com/update-manifest.json")!
                )
            }
        )

        expectThrows(
            "protocol-relative download is rejected",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.invalidManifestURL(let field, let value) = error else {
                    return false
                }
                return field == "download_url" && value == "//example.com/app.zip"
            },
            operation: {
                let manifest = try decodeManifest(validJSON(downloadURL: "//example.com/app.zip"))
                try UpdateChecker.validateManifest(
                    manifest,
                    manifestURL: URL(string: "https://example.com/update-manifest.json")!
                )
            }
        )

        expectThrows(
            "uppercase checksum is rejected",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.invalidManifestField(let field, _, let reason) = error else {
                    return false
                }
                return field == "sha256" && reason.contains("小写十六进制")
            },
            operation: {
                let manifest = try decodeManifest(validJSON(sha256: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"))
                try UpdateChecker.validateManifest(
                    manifest,
                    manifestURL: URL(string: "https://example.com/update-manifest.json")!
                )
            }
        )

        expectThrows(
            "quoted size is rejected during decoding",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.invalidManifestField(let field, let value, let reason) = error else {
                    return false
                }
                return field == "size_bytes" && value == "123" && reason.contains("不要加引号")
            },
            operation: {
                _ = try decodeManifest("""
                {
                  "version": "1.2.0",
                  "build": "3",
                  "download_url": "app.zip",
                  "size_bytes": "123",
                  "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                }
                """)
            }
        )

        expectThrows(
            "bad published_at is rejected",
            failures: &failures,
            expected: { error in
                guard case UpdateCheckError.invalidManifestField(let field, let value, let reason) = error else {
                    return false
                }
                return field == "published_at" && value == "2026/06/10" && reason.contains("ISO-8601")
            },
            operation: {
                let manifest = try decodeManifest(validJSON(publishedAt: "2026/06/10"))
                try UpdateChecker.validateManifest(
                    manifest,
                    manifestURL: URL(string: "https://example.com/update-manifest.json")!
                )
            }
        )

        if failures.isEmpty {
            print("ok: update manifest cases passed")
        } else {
            fputs("error: update manifest regression\n\n\(failures.joined(separator: "\n\n"))\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, failures: inout [String], operation: () throws -> Void) {
        do {
            try operation()
        } catch {
            failures.append("\(name)\nunexpected error: \(error)")
        }
    }

    private static func expectThrows(
        _ name: String,
        failures: inout [String],
        expected: (Error) -> Bool,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            failures.append("\(name)\nexpected an error but operation succeeded")
        } catch {
            if !expected(error) {
                failures.append("\(name)\nunexpected error: \(error)")
            }
        }
    }

    private static func expect(_ condition: Bool, _ message: String) {
        guard condition else {
            fatalError(message)
        }
    }

    private static func decodeManifest(_ json: String) throws -> UpdateManifest {
        try JSONDecoder().decode(UpdateManifest.self, from: Data(json.utf8))
    }

    private static func validJSON(
        version: String = "1.2.0",
        build: String = "3",
        downloadURL: String = "app.zip",
        releaseNotesURL: String? = nil,
        sha256: String = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        publishedAt: String? = "2026-06-10T12:34:56Z"
    ) -> String {
        var fields = [
            #""version": "\#(version)""#,
            #""build": "\#(build)""#,
            #""download_url": "\#(downloadURL)""#,
            #""size_bytes": 123456"#,
            #""sha256": "\#(sha256)""#
        ]
        if let releaseNotesURL {
            fields.append(#""release_notes_url": "\#(releaseNotesURL)""#)
        }
        if let publishedAt {
            fields.append(#""published_at": "\#(publishedAt)""#)
        }
        return "{\(fields.joined(separator: ","))}"
    }
}
SWIFT
} > "$CHECK_PATH"

if ! grep -q "insecureManifestURL" "$CHECK_PATH" || ! grep -q "validateManifest" "$CHECK_PATH"; then
    echo "error: failed to extract update manifest helpers from $SOURCE_PATH" >&2
    exit 1
fi

swiftc -parse-as-library "$CHECK_PATH" -o "$BINARY_PATH"
"$BINARY_PATH"
