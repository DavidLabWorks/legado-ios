#!/bin/sh
# Build the offline reader's iOS library from a checkout of CrispASR v0.8.55.
set -eu
source_dir=$(cd "${1:?Pass the path to a CrispASR v0.8.55 checkout}" && pwd)
output=${2:?Pass a new output path ending in .xcframework}
test "$(git -C "$source_dir" rev-parse HEAD)" = 0e591b2409e47824a242baae80255d150e9aa0a9
git -C "$source_dir" submodule update --init --depth 1 ggml third_party/c2pa-audio
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Apply the reader runtime patches without modifying the supplied checkout.
patch_dir=$(cd "$(dirname "$0")" && pwd)
git clone -q --local --no-hardlinks "$source_dir" "$work/source"
for dep in ggml third_party/c2pa-audio; do
    rmdir "$work/source/$dep"
    ln -s "$source_dir/$dep" "$work/source/$dep"
done
git -C "$work/source" apply "$patch_dir/cancel-synthesis.patch"
git -C "$work/source" apply "$patch_dir/narration-reference.patch"
git -C "$work/source" apply "$patch_dir/cpu-workers.patch"
for slice in iphoneos-arm64 iphonesimulator-arm64 iphonesimulator-x86_64; do
    platform=${slice%-*}
    arch=${slice#*-}
    build="$work/$slice"
    cmake -S "$work/source" -B "$build" -G Ninja \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$platform" \
        -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY \
        -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF -DGGML_METAL=OFF -DGGML_BLAS=OFF \
        -DGGML_OPENMP=OFF -DCRISPASR_BUILD_TESTS=OFF -DCRISPASR_BUILD_EXAMPLES=OFF \
        -DCRISPASR_BUILD_SERVER=OFF -DCRISPASR_OPUS=OFF -DCRISPASR_AMR=OFF
    cmake --build "$build" --target qwen3_tts --parallel 8
    xcrun libtool -static -o "$build/libQwenSpeech.a" \
        "$build/src/libqwen3_tts.a" "$build/src/libcrispasr-core.a" \
        "$build/ggml/src/libggml.a" "$build/ggml/src/libggml-base.a" "$build/ggml/src/libggml-cpu.a"
done
mkdir "$work/simulator"
xcrun lipo -create "$work/iphonesimulator-arm64/libQwenSpeech.a" "$work/iphonesimulator-x86_64/libQwenSpeech.a" \
    -output "$work/simulator/libQwenSpeech.a"
xcodebuild -create-xcframework -library "$work/iphoneos-arm64/libQwenSpeech.a" \
    -library "$work/simulator/libQwenSpeech.a" -output "$output"
