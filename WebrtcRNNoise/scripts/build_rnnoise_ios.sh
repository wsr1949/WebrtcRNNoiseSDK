#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT_DIR/ThirdParty/rnnoise-src"
VENDOR_DIR="$ROOT_DIR/Vendor/RNNoise"
STAGING_DIR="$ROOT_DIR/build/rnnoise/xcframework-staging"

if [[ ! -d "$SRC_DIR/src" ]]; then
  echo "RNNoise source not found at $SRC_DIR" >&2
  exit 1
fi

SOURCES=(
  "$SRC_DIR/src/denoise.c"
  "$SRC_DIR/src/celt_lpc.c"
  "$SRC_DIR/src/kiss_fft.c"
  "$SRC_DIR/src/pitch.c"
  "$SRC_DIR/src/rnn.c"
  "$SRC_DIR/src/rnn_data.c"
  "$SRC_DIR/src/rnn_reader.c"
)

build_arch() {
  local sdk="$1"
  local arch="$2"
  local platform_dir="$3"
  local min_flag="$4"
  local build_dir="$ROOT_DIR/build/rnnoise/$platform_dir-$arch"
  local arch_lib="$build_dir/librnnoise.a"

  rm -rf "$build_dir"
  mkdir -p "$build_dir"

  local objects=()
  for src in "${SOURCES[@]}"; do
    local obj="$build_dir/$(basename "${src%.c}").o"
    xcrun --sdk "$sdk" clang \
      -arch "$arch" \
      "$min_flag" \
      -O3 \
      -DNDEBUG \
      -DHAVE_STDINT_H \
      -DRNNOISE_BUILD \
      -I"$SRC_DIR/include" \
      -I"$SRC_DIR/src" \
      -c "$src" \
      -o "$obj"
    objects+=("$obj")
  done

  xcrun --sdk "$sdk" ar rcs "$arch_lib" "${objects[@]}"
  xcrun --sdk "$sdk" ranlib "$arch_lib"
  echo "$arch_lib"
}

rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR/headers" "$STAGING_DIR/lib/iphoneos" "$STAGING_DIR/lib/iphonesimulator"
cp "$SRC_DIR/include/rnnoise.h" "$STAGING_DIR/headers/rnnoise.h"

DEVICE_LIB="$(build_arch iphoneos arm64 iphoneos -miphoneos-version-min=13.0 | tail -n 1)"
cp "$DEVICE_LIB" "$STAGING_DIR/lib/iphoneos/librnnoise.a"
xcrun --sdk iphoneos ranlib "$STAGING_DIR/lib/iphoneos/librnnoise.a"

SIM_ARM64_LIB="$(build_arch iphonesimulator arm64 iphonesimulator -mios-simulator-version-min=13.0 | tail -n 1)"
SIM_X86_64_LIB="$(build_arch iphonesimulator x86_64 iphonesimulator -mios-simulator-version-min=13.0 | tail -n 1)"
xcrun lipo -create "$SIM_ARM64_LIB" "$SIM_X86_64_LIB" \
  -output "$STAGING_DIR/lib/iphonesimulator/librnnoise.a"
xcrun --sdk iphonesimulator ranlib "$STAGING_DIR/lib/iphonesimulator/librnnoise.a"

mkdir -p "$VENDOR_DIR"
rm -rf "$VENDOR_DIR/RNNoise.xcframework" "$VENDOR_DIR/include" "$VENDOR_DIR/lib"
xcodebuild -create-xcframework \
  -library "$STAGING_DIR/lib/iphoneos/librnnoise.a" -headers "$STAGING_DIR/headers" \
  -library "$STAGING_DIR/lib/iphonesimulator/librnnoise.a" -headers "$STAGING_DIR/headers" \
  -output "$VENDOR_DIR/RNNoise.xcframework"

rm -rf "$STAGING_DIR"
echo "Built $VENDOR_DIR/RNNoise.xcframework"
