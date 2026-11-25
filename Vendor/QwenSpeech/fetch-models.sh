#!/bin/sh
# Restore the compact model bundle used by the offline reader.
set -eu
cd "$(dirname "$0")"
model_host=${HF_ENDPOINT:-https://huggingface.co}
talker_sha=e4af69223cc2d9d7e9d8f658127c1fac470d693ea37848f84c9580d83a7b18b8
codec_sha=15613cabeac27f0f1edcd10bee8e649a56c14c22df7f734da421267fb7391e2b
matches() {
    [ -f "$1" ] && printf '%s  %s\n' "$2" "$1" | shasum -a 256 -c - >/dev/null 2>&1
}
if matches Models/talker.gguf "$talker_sha" && matches Models/codec.gguf "$codec_sha"; then
    exit 0
fi
work=$(mktemp -d "$PWD/.prepare.XXXXXX")
trap 'rm -rf "$work"' EXIT
download() {
    curl --fail --location --retry 2 "$1" -o "$2"
    matches "$2" "$3" || { echo "Checksum mismatch: $2" >&2; exit 1; }
}
source_model() {
    if matches "Models/$1" "$2"; then
        ln "Models/$1" "$work/$1"
    else
        download "$model_host/$3" "$work/$1" "$2"
    fi
}
source_model talker.gguf 5227dcbc4df7c5533341d111cc469fa491a48e722b23dd10f553181b52dff2d9 cstr/qwen3-tts-0.6b-customvoice-GGUF/resolve/main/qwen3-tts-12hz-0.6b-customvoice-q8_0.gguf
source_model codec.gguf 70dc95dbfdd9aa5d9d406236ff771d061bf17b0cda02a72513953355606e719b cstr/qwen3-tts-tokenizer-12hz-GGUF/resolve/main/qwen3-tts-tokenizer-12hz.gguf
quantizer=${CRISPASR_QUANTIZE:-}
if [ -z "$quantizer" ]; then
    download https://github.com/CrispStrobe/CrispASR/releases/download/v0.8.55/crispasr-macos-arm64.tar.gz "$work/tools.tgz" 859b22e9af4114633ddd8d6d02d6ed4c88288fa9fe908306d9c9c93deac00ef2
    tar -xzf "$work/tools.tgz" -C "$work"
    quantizer="$work/crispasr-macos-arm64/crispasr-quantize"
fi
"$quantizer" "$work/talker.gguf" "$work/talker-q4.gguf" q4_k --tensor-type 'talker\.token_embd_text\.weight=q3_k' \
    --tensor-type 'code_pred\.output\..*\.weight=q5_k'
"$quantizer" "$work/codec.gguf" "$work/codec-q4.gguf" q4_k
python3 -m venv "$work/venv"
"$work/venv/bin/pip" install 'gguf==0.17.1'
"$work/venv/bin/python" decoder-only.py "$work/codec-q4.gguf" "$work/decoder.gguf"
matches "$work/talker-q4.gguf" "$talker_sha" && matches "$work/decoder.gguf" "$codec_sha" || {
    echo "Compact model checksums do not match." >&2; exit 1;
}
mv "$work/talker-q4.gguf" Models/talker.gguf
mv "$work/decoder.gguf" Models/codec.gguf
