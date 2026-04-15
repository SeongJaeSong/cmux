#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

FAKE_BIN_DIR="$TMP_DIR/bin"
FAKE_XCODE_APP="$TMP_DIR/Xcode-beta.app"
FAKE_DEVELOPER_DIR="$FAKE_XCODE_APP/Contents/Developer"
FAKE_DEFAULT_CLANG="$FAKE_DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
FAKE_TOOLCHAIN_CLANG="$FAKE_DEVELOPER_DIR/Toolchains/swift-latest.xctoolchain/usr/bin/clang"

mkdir -p "$FAKE_BIN_DIR" "$(dirname "$FAKE_DEFAULT_CLANG")" "$(dirname "$FAKE_TOOLCHAIN_CLANG")"
cat > "$FAKE_DEFAULT_CLANG" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0"
printf '%s\n' "$*"
EOF
chmod +x "$FAKE_DEFAULT_CLANG"

cat > "$FAKE_TOOLCHAIN_CLANG" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$0"
printf '%s\n' "$*"
EOF
chmod +x "$FAKE_TOOLCHAIN_CLANG"

cat > "$FAKE_BIN_DIR/xcrun" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != "--find" || "${2:-}" != "clang" ]]; then
  echo "FAIL: unexpected xcrun invocation: $*" >&2
  exit 1
fi

developer_dir="${DEVELOPER_DIR:-}"
developer_dir="${developer_dir%/}"
if [[ "$developer_dir" == *.app ]]; then
  developer_dir="${developer_dir}/Contents/Developer"
fi

toolchain="${TOOLCHAINS:-XcodeDefault}"
case "$toolchain" in
  swift-latest)
    printf '%s\n' "${developer_dir}/Toolchains/swift-latest.xctoolchain/usr/bin/clang"
    ;;
  *)
    printf '%s\n' "${developer_dir}/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
    ;;
esac
EOF
chmod +x "$FAKE_BIN_DIR/xcrun"

default_output="$(
  PATH="$FAKE_BIN_DIR:/usr/bin:/bin" \
    DEVELOPER_DIR="$FAKE_XCODE_APP" \
    "$ROOT_DIR/scripts/clang-xcodebuild-wrapper.sh" -E -dM -v -x c /dev/null
)"

toolchain_output="$(
  PATH="$FAKE_BIN_DIR:/usr/bin:/bin" \
    DEVELOPER_DIR="$FAKE_XCODE_APP" \
    TOOLCHAINS="swift-latest" \
    "$ROOT_DIR/scripts/clang-xcodebuild-wrapper.sh" -E -dM -v -x c /dev/null
)"

default_clang_path="$(printf '%s\n' "$default_output" | sed -n '1p')"
default_clang_args="$(printf '%s\n' "$default_output" | sed -n '2p')"
toolchain_clang_path="$(printf '%s\n' "$toolchain_output" | sed -n '1p')"
toolchain_clang_args="$(printf '%s\n' "$toolchain_output" | sed -n '2p')"

if [[ "$default_clang_path" != "$FAKE_DEFAULT_CLANG" ]]; then
  echo "FAIL: expected wrapper to normalize app-bundle DEVELOPER_DIR to $FAKE_DEFAULT_CLANG"
  exit 1
fi

if [[ "$toolchain_clang_path" != "$FAKE_TOOLCHAIN_CLANG" ]]; then
  echo "FAIL: expected wrapper to resolve clang from the selected TOOLCHAINS entry"
  exit 1
fi

if grep -Fq -- " -v " <<<" $default_clang_args "; then
  echo "FAIL: wrapper should continue stripping -v from clang macro-dump probes"
  exit 1
fi

if grep -Fq -- " -v " <<<" $toolchain_clang_args "; then
  echo "FAIL: wrapper should strip -v even when TOOLCHAINS selects a custom clang"
  exit 1
fi

if ! grep -Fq -- "-dM" <<<"$default_clang_args"; then
  echo "FAIL: wrapper should preserve -dM for default clang macro-dump probes"
  exit 1
fi

if ! grep -Fq -- "-dM" <<<"$toolchain_clang_args"; then
  echo "FAIL: wrapper should preserve -dM for clang macro-dump probes"
  exit 1
fi

echo "PASS: clang wrapper normalizes DEVELOPER_DIR and respects TOOLCHAINS"
