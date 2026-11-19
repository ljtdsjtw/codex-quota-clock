#!/bin/zsh
set -eu
cd "${0:A:h}"
destination="${1:-$HOME/Applications/Codex 额度时钟.app}"
identity="${QUOTA_SIGN_IDENTITY:-Apple Development}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
app="$stage/Codex 额度时钟.app"
ext="$app/Contents/PlugIns/QuotaWidget.appex"
mkdir -p "$app/Contents/MacOS" "$ext/Contents/MacOS"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun swiftc -O -parse-as-library App.swift Panel.swift Quota.swift Shared.swift Ticker.swift History.swift LiveFee.swift ImpactAmount.swift -o "$app/Contents/MacOS/QuotaClock"
xcrun swiftc -O -parse-as-library -application-extension -Xlinker -e -Xlinker _NSExtensionMain Widget.swift Shared.swift Ticker.swift -o "$ext/Contents/MacOS/QuotaWidget"
codesign -f -s "$identity" --timestamp=none "$app/Contents/MacOS/QuotaClock"
team=$(codesign -dv "$app/Contents/MacOS/QuotaClock" 2>&1 | sed -n 's/^TeamIdentifier=//p')
[[ -n "$team" && "$team" != "not set" ]]
group="$team.io.github.ljtdsjtw.codex-quota-clock"
python3 - "$app" "$ext" "$stage" "$group" <<'PY'
import plistlib, sys
from pathlib import Path
app, ext, stage = map(Path, sys.argv[1:4])
group = sys.argv[4]
base = dict(CFBundleInfoDictionaryVersion="6.0", CFBundleSupportedPlatforms=["MacOSX"],
            CFBundleVersion="9", CFBundleShortVersionString="1.7", LSMinimumSystemVersion="14.0",
            CFBundleDevelopmentRegion="zh_CN", QuotaGroup=group)
bundle = "io.github.ljtdsjtw.codex-quota-clock"
def write(path, data):
    path.write_bytes(plistlib.dumps(data))
write(app/"Contents/Info.plist", dict(base, CFBundleExecutable="QuotaClock",
      CFBundleIdentifier=bundle, CFBundlePackageType="APPL", CFBundleName="Codex 额度时钟",
      NSHighResolutionCapable=True))
write(ext/"Contents/Info.plist", dict(base, CFBundleExecutable="QuotaWidget",
      CFBundleIdentifier=bundle+".widget", CFBundlePackageType="XPC!", CFBundleName="QuotaWidget",
      CFBundleDisplayName="Codex 周额度", NSExtension={"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"}))
ent = {"com.apple.security.application-groups":[group]}
write(stage/"host.entitlements", ent)
write(stage/"widget.entitlements", dict(ent, **{"com.apple.security.app-sandbox":True}))
PY
codesign -f -s "$identity" --timestamp=none --entitlements "$stage/widget.entitlements" "$ext"
codesign -f -s "$identity" --timestamp=none --entitlements "$stage/host.entitlements" "$app"
codesign --verify --deep --strict "$app"
mkdir -p "${destination:h}"
ditto "$app" "$destination"
codesign --verify --deep --strict "$destination"
