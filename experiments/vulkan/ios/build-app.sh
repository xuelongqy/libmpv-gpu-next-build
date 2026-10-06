#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
: "${IOS_MEDIA_DIR:?Set IOS_MEDIA_DIR to private media, named sdr/hdr10/dv-p5-20s.mkv}"
app="$ios_work/IOSSmoke.app"
mkdir -p "$app"
read -r -a flags <<< "$(pkg-config --static --cflags --libs mpv)"
xcrun --sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" \
    -fobjc-arc -Wall -Wextra -Werror -O2 "$ios_dir/smoke.m" "${flags[@]}" \
    -framework UIKit -framework QuartzCore -framework VideoToolbox \
    -framework CoreMedia -framework AVFoundation -lc++ -o "$app/IOSSmoke"
cp "$ios_dir/Info.plist" "$app/Info.plist"
for media in sdr hdr10 dv-p5; do cp "$IOS_MEDIA_DIR/$media-20s.mkv" "$app/"; done
for media in av sync; do
    if [[ -f $IOS_MEDIA_DIR/$media-20s.mkv ]]; then cp "$IOS_MEDIA_DIR/$media-20s.mkv" "$app/"; fi
done
if [[ $platform == device ]]; then
    : "${IOS_PROFILE:?Set IOS_PROFILE to a valid provisioning profile}"
    : "${IOS_SIGNING_IDENTITY:?Set IOS_SIGNING_IDENTITY to the matching signing identity}"
    cp "$IOS_PROFILE" "$app/embedded.mobileprovision"
    security cms -D -i "$IOS_PROFILE" > "$ios_work/profile.plist"
    /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$ios_work/profile.plist" > "$ios_work/entitlements.plist"
    bundle=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
    identifier=$(/usr/libexec/PlistBuddy -c 'Print :application-identifier' "$ios_work/entitlements.plist")
    case $identifier in
        *.\*) identifier="${identifier%\*}$bundle" ;;
        *."$bundle") ;;
        *) echo 'Provisioning profile does not match the app bundle' >&2; exit 2 ;;
    esac
    /usr/libexec/PlistBuddy -c "Set :application-identifier $identifier" "$ios_work/entitlements.plist"
    group=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ios_work/entitlements.plist")
    if [[ $group == *.\* ]]; then
        /usr/libexec/PlistBuddy -c "Set :keychain-access-groups:0 ${group%\*}$bundle" "$ios_work/entitlements.plist"
    fi
    codesign --force --sign "$IOS_SIGNING_IDENTITY" --entitlements "$ios_work/entitlements.plist" "$app"
else
    codesign --force --sign - "$app"
fi
codesign --verify "$app"
shasum -a 256 "$app/IOSSmoke" "$prefix/lib/libmpv.a" "$prefix/lib/libplacebo.a" \
    "$prefix/include/mpv/render_vk.h" "$ios_dir/smoke.m"
echo 'IOS_APP_BUILD=PASS'
