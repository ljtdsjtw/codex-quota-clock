#!/bin/zsh
set -eu
release=false
if [[ "${1:-}" == "--release" ]]; then
    [[ $# == 2 && "$2" == *.zip ]] || { print -u2 '用法：./build.sh --release 输出文件.zip'; exit 1; }
    release=true
    output="${2:a}"
else
    [[ $# -le 1 ]] || { print -u2 '用法：./build.sh [目标路径.app]'; exit 1; }
    destination="${1:-$HOME/Applications/Codex 额度时钟.app}"
    destination="${destination:a}"
fi

cd "${0:A:h}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
kit="$stage/CodexQuotaClock"
mkdir -p "$kit/bin" "$kit/guard"
cp -p packaging/install.command "$kit/"
cp guard/quota_guard.py "$kit/guard/"

compile() {
    local out="$2" triple="${1}-apple-macos14.0"
    mkdir -p "$out"
    xcrun swiftc -O -target "$triple" -parse-as-library App.swift Panel.swift ProtectionPanel.swift \
        Protection.swift Quota.swift Shared.swift Ticker.swift History.swift LiveFee.swift ImpactAmount.swift \
        -o "$out/QuotaClock"
    xcrun swiftc -O -target "$triple" -parse-as-library -application-extension -Xlinker -e \
        -Xlinker _NSExtensionMain Widget.swift Shared.swift Ticker.swift -o "$out/QuotaWidget"
}

if [[ "$release" == true ]]; then
    compile arm64 "$stage/arm64"
    compile x86_64 "$stage/x86_64"
    for binary in QuotaClock QuotaWidget; do
        xcrun lipo -create "$stage/arm64/$binary" "$stage/x86_64/$binary" -output "$kit/bin/$binary"
        xcrun lipo "$kit/bin/$binary" -verify_arch arm64 x86_64
    done
    cp LICENSE "$kit/"
    cp packaging/INSTALL.md "$kit/"
    mkdir -p "${output:h}"
    ditto -c -k --norsrc --noextattr --noacl --keepParent "$kit" "$output"
else
    compile "$(uname -m)" "$kit/bin"
    "$kit/install.command" "$destination"
fi
