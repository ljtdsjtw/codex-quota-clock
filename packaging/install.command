#!/bin/zsh
set -eu
destination="${1:-$HOME/Applications/Codex 额度时钟.app}"
destination="${destination:a}"
identity="${QUOTA_SIGN_IDENTITY:-Apple Development}"
if [[ $# -gt 1 || "$destination" != *.app ]]; then
    print -u2 '用法：./install.command [目标路径.app]'
    exit 1
fi
cd "${0:A:h}"
mkdir -p "${destination:h}"
stage=$(mktemp -d "${destination:h}/.quota-clock-install.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
app="$stage/Codex 额度时钟.app"
ext="$app/Contents/PlugIns/QuotaWidget.appex"
mkdir -p "$app/Contents/Resources" "$app/Contents/MacOS" "$ext/Contents/MacOS"
cp guard/quota_guard.py "$app/Contents/Resources/quota_guard.py"
install -m 755 bin/QuotaClock "$app/Contents/MacOS/QuotaClock"
install -m 755 bin/QuotaWidget "$ext/Contents/MacOS/QuotaWidget"
if ! codesign -f -s "$identity" --timestamp=none "$app/Contents/MacOS/QuotaClock"; then
    print -u2 '需要钥匙串中的 Apple Development 证书及对应私钥。可在 Xcode 的 Accounts 设置中创建。'
    exit 1
fi
team=$(codesign -dv "$app/Contents/MacOS/QuotaClock" 2>&1 | sed -n 's/^TeamIdentifier=//p')
if [[ -z "$team" || "$team" == "not set" ]]; then
    print -u2 '小组件的 App Group 需要带 Team ID 的签名证书。'
    exit 1
fi
group="$team.io.github.ljtdsjtw.codex-quota-clock"
python3 - "$app" "$ext" "$stage" "$group" <<'PY'
import plistlib, sys
from pathlib import Path
app, ext, stage = map(Path, sys.argv[1:4])
group = sys.argv[4]
base = dict(CFBundleInfoDictionaryVersion="6.0", CFBundleSupportedPlatforms=["MacOSX"],
            CFBundleVersion="10", CFBundleShortVersionString="1.8", LSMinimumSystemVersion="14.0",
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
# Swap only a fully verified bundle into place on the destination volume.
python3 - "$app" "$destination" <<'PYINSTALL'
import ctypes
import os
import plistlib
import sys
from pathlib import Path

source, target = map(Path, sys.argv[1:])
def bundle_id(app):
    try:
        with (app / "Contents/Info.plist").open("rb") as f:
            return plistlib.load(f).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException):
        return None

if os.path.lexists(target):
    if target.is_symlink() or not target.is_dir() or bundle_id(target) != bundle_id(source):
        sys.exit("目标路径已被其他应用或文件占用，请指定另一个 .app 路径。")
    flag = 2  # RENAME_SWAP
else:
    flag = 4  # RENAME_EXCL

rename = ctypes.CDLL(None, use_errno=True).renamex_np
rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
if rename(os.fsencode(source), os.fsencode(target), flag) != 0:
    sys.exit("安装失败：" + os.strerror(ctypes.get_errno()))
PYINSTALL
print "已安装到 $destination"
