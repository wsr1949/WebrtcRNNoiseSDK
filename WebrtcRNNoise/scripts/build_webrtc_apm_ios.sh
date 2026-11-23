#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
THIRD_PARTY_DIR="$ROOT_DIR/ThirdParty"
DEPOT_TOOLS_DIR="${DEPOT_TOOLS_DIR:-$THIRD_PARTY_DIR/depot_tools}"
DEPOT_TOOLS_GIT_URL="${DEPOT_TOOLS_GIT_URL:-https://chromium.googlesource.com/chromium/tools/depot_tools.git}"
WEBRTC_CHECKOUT_DIR="${WEBRTC_CHECKOUT_DIR:-$THIRD_PARTY_DIR/webrtc-ios}"
WEBRTC_SRC_DIR="$WEBRTC_CHECKOUT_DIR/src"
WRAPPER_SRC_DIR="$ROOT_DIR/WebRTCAPMWrapper"
WRAPPER_DST_DIR="$WEBRTC_SRC_DIR/modules/audio_processing/webrtc_apm_wrapper"
OUT_ROOT="${WEBRTC_APM_OUT_ROOT:-$ROOT_DIR/build/webrtc-apm}"
VENDOR_DIR="$ROOT_DIR/Vendor/WebRTCAPM"
MIN_FREE_GB="${MIN_FREE_GB:-35}"
WEBRTC_APM_SKIP_SYNC="${WEBRTC_APM_SKIP_SYNC:-0}"
CHECK_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --check-only)
      CHECK_ONLY=1
      ;;
    -h|--help)
      cat <<EOF
Usage: $0 [--check-only]

Builds a small static WebRTC AudioProcessing wrapper for iOS.

Output:
  $VENDOR_DIR/WebRTCAPM.xcframework

Environment variables:
  DEPOT_TOOLS_DIR       Default: $DEPOT_TOOLS_DIR
  DEPOT_TOOLS_GIT_URL   Default: $DEPOT_TOOLS_GIT_URL
  WEBRTC_CHECKOUT_DIR   Default: $WEBRTC_CHECKOUT_DIR
  WEBRTC_APM_OUT_ROOT   Default: $OUT_ROOT
  MIN_FREE_GB           Default: $MIN_FREE_GB
  WEBRTC_APM_SKIP_SYNC   Default: $WEBRTC_APM_SKIP_SYNC

This still needs a WebRTC source checkout, but the final linked product is
only the APM wrapper static library instead of the full WebRTC framework.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $arg" >&2
      exit 2
      ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

free_gb() {
  python3 - "$ROOT_DIR" <<'PY'
import os
import sys
stat = os.statvfs(sys.argv[1])
print((stat.f_bavail * stat.f_frsize) // (1024 ** 3))
PY
}

require_tool python3
require_tool git
require_tool xcodebuild
require_tool xcrun

AVAILABLE_GB="$(free_gb)"
echo "Available disk space: ${AVAILABLE_GB}GB"
if (( AVAILABLE_GB < MIN_FREE_GB )); then
  echo "Need at least ${MIN_FREE_GB}GB free before syncing/building WebRTC APM." >&2
  echo "Set MIN_FREE_GB to override only if you already have a complete WebRTC checkout." >&2
  exit 1
fi

if (( CHECK_ONLY == 1 )); then
  echo "Prerequisite check passed."
  exit 0
fi

mkdir -p "$THIRD_PARTY_DIR" "$WEBRTC_CHECKOUT_DIR"

if [[ ! -x "$DEPOT_TOOLS_DIR/fetch" ]]; then
  echo "Cloning depot_tools into $DEPOT_TOOLS_DIR"
  rm -rf "$DEPOT_TOOLS_DIR"
  git clone "$DEPOT_TOOLS_GIT_URL" "$DEPOT_TOOLS_DIR"
fi

export PATH="$DEPOT_TOOLS_DIR:$PATH"

if [[ ! -x "$DEPOT_TOOLS_DIR/.cipd_bin/vpython3" ]]; then
  echo "Bootstrapping depot_tools CIPD binaries"
  "$DEPOT_TOOLS_DIR/ensure_bootstrap"
  if [[ ! -x "$DEPOT_TOOLS_DIR/.cipd_bin/vpython3" ]]; then
    echo "depot_tools bootstrap did not produce .cipd_bin/vpython3." >&2
    echo "Check access to chrome-infra-packages.appspot.com and rerun." >&2
    exit 1
  fi
fi

require_tool fetch
require_tool gclient

if [[ ! -d "$WEBRTC_SRC_DIR" ]]; then
  echo "Fetching WebRTC iOS source into $WEBRTC_CHECKOUT_DIR"
  (
    cd "$WEBRTC_CHECKOUT_DIR"
    fetch --nohooks webrtc_ios
  )
fi

if [[ "$WEBRTC_APM_SKIP_SYNC" != "1" ]]; then
  echo "Syncing WebRTC dependencies with shallow history and without hooks"
  (
    cd "$WEBRTC_SRC_DIR"
    gclient sync --nohooks --no-history --shallow -j1 --force
  )
else
  echo "Skipping gclient sync because WEBRTC_APM_SKIP_SYNC=1"
fi

if python3 -c 'import certifi' >/dev/null 2>&1; then
  CERTIFI_BUNDLE="$(python3 -c 'import certifi; print(certifi.where())')"
  export SSL_CERT_FILE="${SSL_CERT_FILE:-$CERTIFI_BUNDLE}"
  export REQUESTS_CA_BUNDLE="${REQUESTS_CA_BUNDLE:-$CERTIFI_BUNDLE}"
fi

echo "Ensuring Chromium clang toolchain"
(
  cd "$WEBRTC_SRC_DIR"
  python3 tools/clang/scripts/update.py
)

echo "Copying wrapper target into WebRTC checkout"
rm -rf "$WRAPPER_DST_DIR"
mkdir -p "$WRAPPER_DST_DIR"
ditto "$WRAPPER_SRC_DIR" "$WRAPPER_DST_DIR"

if ! /usr/bin/grep -q 'webrtc_apm_wrapper_build' "$WEBRTC_SRC_DIR/BUILD.gn"; then
  cat >> "$WEBRTC_SRC_DIR/BUILD.gn" <<'EOF'

# Local target for the WebRTCAPM C wrapper.
group("webrtc_apm_wrapper_build") {
  deps = [ "//modules/audio_processing/webrtc_apm_wrapper" ]
}
EOF
fi

build_one() {
  local name="$1"
  local target_cpu="$2"
  local target_environment="$3"
  local out_dir="$OUT_ROOT/out_$name"
  local ninja_target="obj/modules/audio_processing/webrtc_apm_wrapper/libwebrtc_apm_wrapper.a"
  local lib_path="$out_dir/$ninja_target"
  local gn_bin="$WEBRTC_SRC_DIR/buildtools/mac/gn"
  local ninja_bin="$WEBRTC_SRC_DIR/third_party/ninja/ninja"

  echo "Generating GN build: $name"
  (
    cd "$WEBRTC_SRC_DIR"
    "$gn_bin" gen "$out_dir" --args="
target_os=\"ios\"
target_cpu=\"$target_cpu\"
target_environment=\"$target_environment\"
is_debug=false
is_component_build=false
rtc_include_tests=false
rtc_build_examples=false
rtc_build_tools=false
rtc_enable_protobuf=false
rtc_rust=false
use_custom_libcxx=false
treat_warnings_as_errors=false
ios_enable_code_signing=false
use_rtti=false
enable_iterator_debugging=false
"
  )

  echo "Building WebRTC APM wrapper: $name"
  "$ninja_bin" -C "$out_dir" "$ninja_target"

  if [[ ! -f "$lib_path" ]]; then
    echo "Expected library not found: $lib_path" >&2
    exit 1
  fi

  echo "$lib_path"
}

archive_full() {
  local thin_lib="$1"
  local output_lib="$2"
  local response_file="$3"
  local ar_bin="$WEBRTC_SRC_DIR/third_party/llvm-build/Release+Asserts/bin/llvm-ar"

  "$ar_bin" t "$thin_lib" > "$response_file"
  "$ar_bin" rcs "$output_lib" "@$response_file"
}

STAGING_DIR="$OUT_ROOT/xcframework-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/headers" "$STAGING_DIR/lib/iphoneos" "$STAGING_DIR/lib/iphonesimulator" "$STAGING_DIR/lib/tmp"
cp "$WRAPPER_SRC_DIR/include/WebRTCAPM.h" "$STAGING_DIR/headers/WebRTCAPM.h"

DEVICE_LIB="$(build_one ios_arm64 arm64 device | tail -n 1)"
SIM_ARM64_LIB="$(build_one sim_arm64 arm64 simulator | tail -n 1)"
SIM_X64_LIB="$(build_one sim_x64 x64 simulator | tail -n 1)"

archive_full "$DEVICE_LIB" "$STAGING_DIR/lib/iphoneos/libwebrtc_apm.a" "$STAGING_DIR/lib/tmp/device.rsp"
xcrun --sdk iphoneos ranlib "$STAGING_DIR/lib/iphoneos/libwebrtc_apm.a"

archive_full "$SIM_ARM64_LIB" "$STAGING_DIR/lib/tmp/libwebrtc_apm_sim_arm64.a" "$STAGING_DIR/lib/tmp/sim_arm64.rsp"
archive_full "$SIM_X64_LIB" "$STAGING_DIR/lib/tmp/libwebrtc_apm_sim_x64.a" "$STAGING_DIR/lib/tmp/sim_x64.rsp"
xcrun lipo -create "$STAGING_DIR/lib/tmp/libwebrtc_apm_sim_arm64.a" "$STAGING_DIR/lib/tmp/libwebrtc_apm_sim_x64.a" \
  -output "$STAGING_DIR/lib/iphonesimulator/libwebrtc_apm.a"
xcrun --sdk iphonesimulator ranlib "$STAGING_DIR/lib/iphonesimulator/libwebrtc_apm.a"

mkdir -p "$VENDOR_DIR"
rm -rf "$VENDOR_DIR/WebRTCAPM.xcframework" "$VENDOR_DIR/include" "$VENDOR_DIR/lib"
xcodebuild -create-xcframework \
  -library "$STAGING_DIR/lib/iphoneos/libwebrtc_apm.a" -headers "$STAGING_DIR/headers" \
  -library "$STAGING_DIR/lib/iphonesimulator/libwebrtc_apm.a" -headers "$STAGING_DIR/headers" \
  -output "$VENDOR_DIR/WebRTCAPM.xcframework"

rm -rf "$STAGING_DIR"

cat <<EOF

WebRTC APM wrapper is ready:
  $VENDOR_DIR/WebRTCAPM.xcframework

Link the xcframework in your target and add Other Linker Flags: -lc++
EOF
