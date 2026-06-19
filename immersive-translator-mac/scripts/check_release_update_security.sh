#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package_release.sh"

failures=()

run_case() {
    local name="$1"
    local expected_status="$2"
    local expected_text="$3"
    shift 3

    local output
    local exit_code
    set +e
    output="$(env CHECK_ONLY=1 "$@" "$PACKAGE_SCRIPT" 0.1.0 2>&1)"
    exit_code=$?
    set -e

    if (( expected_status == 0 )); then
        if (( exit_code != 0 )); then
            failures+=("$name\nexpected success but exited $exit_code\n$output")
            return
        fi
    elif (( exit_code == 0 )); then
        failures+=("$name\nexpected failure but preflight passed\n$output")
        return
    fi

    if [[ "$output" != *"$expected_text"* ]]; then
        failures+=("$name\nexpected output to contain: $expected_text\n$output")
    fi
}

run_case \
    "reject https manifest with http download" \
    1 \
    "update download_url would be rejected by the app" \
    APP_UPDATE_MANIFEST_URL="https://example.com/update-manifest.json" \
    RELEASE_DOWNLOAD_URL="http://example.com/app.zip"

run_case \
    "reject https manifest with uppercase http download" \
    1 \
    "update download_url would be rejected by the app" \
    APP_UPDATE_MANIFEST_URL="HTTPS://example.com/update-manifest.json" \
    RELEASE_DOWNLOAD_URL="HTTP://example.com/app.zip"

run_case \
    "reject https manifest with http release notes" \
    1 \
    "update release_notes_url would be rejected by the app" \
    APP_UPDATE_MANIFEST_URL="https://example.com/update-manifest.json" \
    RELEASE_NOTES_URL="http://example.com/notes"

run_case \
    "reject https manifest with http base url" \
    1 \
    "generated update download_url would be rejected by the app" \
    APP_UPDATE_MANIFEST_URL="https://example.com/update-manifest.json" \
    RELEASE_BASE_URL="http://example.com/releases"

run_case \
    "allow relative update assets with https manifest" \
    0 \
    "release preflight passed" \
    APP_UPDATE_MANIFEST_URL="https://example.com/update-manifest.json" \
    RELEASE_DOWNLOAD_URL="ImmersiveTranslator-0.1.0-macOS.zip" \
    RELEASE_NOTES_URL="notes/0.1.0.html"

run_case \
    "allow explicit https download overriding http base url" \
    0 \
    "RELEASE_BASE_URL is HTTP but RELEASE_DOWNLOAD_URL overrides it" \
    APP_UPDATE_MANIFEST_URL="https://example.com/update-manifest.json" \
    RELEASE_BASE_URL="http://example.com/releases" \
    RELEASE_DOWNLOAD_URL="https://cdn.example.com/app.zip"

run_case \
    "allow custom minimum system version" \
    0 \
    "APP_MINIMUM_SYSTEM_VERSION format looks usable" \
    APP_MINIMUM_SYSTEM_VERSION="14.0"

run_case \
    "reject invalid minimum system version" \
    1 \
    "APP_MINIMUM_SYSTEM_VERSION must look like 13.0 or 14.5.1" \
    APP_MINIMUM_SYSTEM_VERSION="macOS 14"

run_case \
    "warn when notarized gatekeeper assessment is skipped" \
    1 \
    "SKIP_SPCTL_ASSESS=1 skips Gatekeeper assessment" \
    NOTARIZE=1 \
    SKIP_SPCTL_ASSESS=1

if ! grep -q "release zip app failed Gatekeeper assessment" "$PACKAGE_SCRIPT"; then
    failures+=("release zip Gatekeeper assessment\nexpected package_release.sh to fail if the final zip app is rejected by spctl")
fi

if ! grep -q "gatekeeper:" "$PACKAGE_SCRIPT"; then
    failures+=("release artifact summary\nexpected package_release.sh to report whether Gatekeeper assessment ran for the zip app")
fi

if ! grep -q "LSMinimumSystemVersion" "$ROOT_DIR/scripts/build_app.sh"; then
    failures+=("minimum system version plist\nexpected build_app.sh to write LSMinimumSystemVersion into Info.plist")
fi

if ! grep -q "APP_MINIMUM_SYSTEM_VERSION=.*13.0" "$ROOT_DIR/scripts/build_app.sh"; then
    failures+=("minimum system version default\nexpected build_app.sh to support APP_MINIMUM_SYSTEM_VERSION with a 13.0 default")
fi

if ! grep -q "APP_MINIMUM_SYSTEM_VERSION=.*13.0" "$PACKAGE_SCRIPT"; then
    failures+=("minimum system version propagation\nexpected package_release.sh to pass APP_MINIMUM_SYSTEM_VERSION to build_app.sh")
fi

if ! grep -q "Info.plist minimum system version mismatch" "$PACKAGE_SCRIPT"; then
    failures+=("minimum system version zip validation\nexpected package_release.sh to validate zip app LSMinimumSystemVersion")
fi

if (( ${#failures[@]} == 0 )); then
    print "ok: release update security preflight cases passed"
else
    print -u2 "error: release update security preflight regression"
    print -u2
    for failure in "${failures[@]}"; do
        print -u2 "$failure"
        print -u2
    done
    exit 1
fi
