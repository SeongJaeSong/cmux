#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_XCODE_APP="$TMP_DIR/Xcode-beta.app"
FAKE_DEVELOPER_DIR="$FAKE_XCODE_APP/Contents/Developer"
FAKE_CLANG="$FAKE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"

mkdir -p "$(dirname "$FAKE_CLANG")"
cat > "$FAKE_CLANG" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0"
printf '%s\n' "$*"
EOF
chmod +x "$FAKE_CLANG"

output="$(
  DEVELOPER_DIR="$FAKE_XCODE_APP" \
    "$ROOT_DIR/scripts/clang-xcodebuild-wrapper.sh" -E -dM -v -x c /dev/null
)"

clang_path="$(printf '%s\n' "$output" | sed -n '1p')"
clang_args="$(printf '%s\n' "$output" | sed -n '2p')"

if [[ "$clang_path" != "$FAKE_CLANG" ]]; then
  echo "FAIL: expected wrapper to normalize app-bundle DEVELOPER_DIR to $FAKE_CLANG"
  exit 1
fi

if grep -Fq -- " -v " <<<" $clang_args "; then
  echo "FAIL: wrapper should continue stripping -v from clang macro-dump probes"
  exit 1
fi

if ! grep -Fq -- "-dM" <<<"$clang_args"; then
  echo "FAIL: wrapper should preserve -dM for clang macro-dump probes"
  exit 1
fi

echo "PASS: clang wrapper normalizes app-bundle DEVELOPER_DIR paths"
