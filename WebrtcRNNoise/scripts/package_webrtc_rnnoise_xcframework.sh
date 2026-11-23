#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SDK_PROJECT="$ROOT_DIR/WebrtcRNNoiseSDK/WebrtcRNNoiseSDK.xcodeproj"
SCHEME="WebrtcRNNoise"
CONFIGURATION="Release"
OUTPUT_DIR="${OUTPUT_DIR:-$ROOT_DIR/Dist}"
BUILD_ROOT="$ROOT_DIR/build/sdk-package"
ARCH_IOS="$BUILD_ROOT/archives/ios/WebrtcRNNoise.xcarchive"
ARCH_SIM="$BUILD_ROOT/archives/sim/WebrtcRNNoise.xcarchive"
FRAMEWORK_NAME="WebrtcRNNoise.xcframework"
XCFRAMEWORK_OUT="$OUTPUT_DIR/$FRAMEWORK_NAME"

REBUILD_DEPS=0
SKIP_DEPS=0
MAKE_ZIP=0
CHECK_ONLY=0
CLEAN=0

usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Build a distributable dynamic WebrtcRNNoise.xcframework (Embed & Sign in host apps).

Output:
  $XCFRAMEWORK_OUT

Options:
  --rebuild-deps   Force rebuild Vendor/RNNoise and Vendor/WebRTCAPM
  --skip-deps      Do not build dependencies (assume Vendor is up to date)
  --configuration  Release or Debug (default: Release)
  --output DIR     Output directory (default: $ROOT_DIR/Dist)
  --zip            Also create \$OUTPUT_DIR/WebrtcRNNoise.xcframework.zip
  --clean          Remove \$BUILD_ROOT before building
  --check-only     Verify tools and Vendor paths, then exit
  -h, --help       Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild-deps) REBUILD_DEPS=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --configuration) CONFIGURATION="$2"; shift 2 ;;
    --output) OUTPUT_DIR="$2"; XCFRAMEWORK_OUT="$OUTPUT_DIR/$FRAMEWORK_NAME"; shift 2 ;;
    --zip) MAKE_ZIP=1; shift ;;
    --clean) CLEAN=1; shift ;;
    --check-only) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required tool: $1" >&2
    exit 1
  fi
}

require_tool xcodebuild
require_tool xcrun

RN_VENDOR="$ROOT_DIR/Vendor/RNNoise/RNNoise.xcframework"
APM_VENDOR="$ROOT_DIR/Vendor/WebRTCAPM/WebRTCAPM.xcframework"

if [[ ! -d "$SDK_PROJECT" ]]; then
  echo "SDK project not found: $SDK_PROJECT" >&2
  exit 1
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "SDK project: $SDK_PROJECT"
  echo "RNNoise vendor: $RN_VENDOR ($([ -d "$RN_VENDOR" ] && echo OK || echo MISSING))"
  echo "WebRTCAPM vendor: $APM_VENDOR ($([ -d "$APM_VENDOR" ] && echo OK || echo MISSING))"
  exit 0
fi

build_deps_if_needed() {
  if [[ "$SKIP_DEPS" -eq 1 ]]; then
    if [[ ! -d "$RN_VENDOR" || ! -d "$APM_VENDOR" ]]; then
      echo "--skip-deps set but Vendor xcframeworks are missing." >&2
      exit 1
    fi
    return
  fi

  if [[ "$REBUILD_DEPS" -eq 1 || ! -d "$RN_VENDOR" ]]; then
    echo "Building RNNoise..."
    "$ROOT_DIR/scripts/build_rnnoise_ios.sh"
  fi

  if [[ "$REBUILD_DEPS" -eq 1 || ! -d "$APM_VENDOR" ]]; then
    echo "Building WebRTC APM wrapper..."
    "$ROOT_DIR/scripts/build_webrtc_apm_ios.sh"
  fi
}

build_deps_if_needed

if [[ "$CLEAN" -eq 1 ]]; then
  rm -rf "$BUILD_ROOT"
fi

mkdir -p "$OUTPUT_DIR" "$BUILD_ROOT/archives/ios" "$BUILD_ROOT/archives/sim"
rm -rf "$XCFRAMEWORK_OUT"

COMMON_FLAGS=(
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=
  SKIP_INSTALL=NO
  BUILD_LIBRARY_FOR_DISTRIBUTION=YES
  ONLY_ACTIVE_ARCH=NO
)

echo "Archiving for iOS device ($CONFIGURATION)..."
xcodebuild archive \
  -project "$SDK_PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCH_IOS" \
  "${COMMON_FLAGS[@]}"

echo "Archiving for iOS Simulator ($CONFIGURATION)..."
xcodebuild archive \
  -project "$SDK_PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -destination 'generic/platform=iOS Simulator' \
  -archivePath "$ARCH_SIM" \
  "${COMMON_FLAGS[@]}"

IOS_FRAMEWORK="$ARCH_IOS/Products/Library/Frameworks/WebrtcRNNoise.framework"
SIM_FRAMEWORK="$ARCH_SIM/Products/Library/Frameworks/WebrtcRNNoise.framework"

if [[ ! -d "$IOS_FRAMEWORK" || ! -d "$SIM_FRAMEWORK" ]]; then
  echo "Archive did not produce expected frameworks:" >&2
  echo "  $IOS_FRAMEWORK" >&2
  echo "  $SIM_FRAMEWORK" >&2
  exit 1
fi

echo "Creating xcframework..."
xcodebuild -create-xcframework \
  -framework "$IOS_FRAMEWORK" \
  -framework "$SIM_FRAMEWORK" \
  -output "$XCFRAMEWORK_OUT"

echo ""
echo "Built: $XCFRAMEWORK_OUT"
echo "Public headers:"
find "$XCFRAMEWORK_OUT" -path '*/Headers/*.h' | sort | sed 's/^/  /'

if [[ "$MAKE_ZIP" -eq 1 ]]; then
  ZIP_PATH="$OUTPUT_DIR/WebrtcRNNoise.xcframework.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$XCFRAMEWORK_OUT" "$ZIP_PATH"
  echo "Zip: $ZIP_PATH"
fi

echo ""
echo "Integrate: drag WebrtcRNNoise.xcframework into your app target → Embed & Sign"
echo "Import:    #import <WebrtcRNNoise/WRNNoiseProcessor.h>"
