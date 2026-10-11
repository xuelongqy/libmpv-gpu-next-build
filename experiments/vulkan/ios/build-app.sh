#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "$0")/common.sh"
probe=false
if [[ $# == 1 && $1 == --metal-import-probe ]]; then probe=true;
elif [[ $# != 0 ]]; then echo 'usage: build-app.sh [--metal-import-probe]' >&2; exit 2; fi
app="$ios_work/IOSSmoke.app"
source_file="$ios_dir/smoke.m"
arc=(-fobjc-arc)
if [[ $probe == true ]]; then
    [[ $platform == device && -n ${IOS_VALIDATION_DIR:-} ]] || {
        echo 'Metal probe requires IOS_PLATFORM=device and IOS_VALIDATION_DIR' >&2; exit 2;
    }
    app="$ios_work/IOSMetalProbe.app"
    source_file="$ios_dir/metal-probe.m"
    arc=()
else
    : "${IOS_MEDIA_DIR:?Set IOS_MEDIA_DIR to private media, named sdr/hdr10/dv-p5-20s.mkv}"
fi
mkdir -p "$app"
if [[ $probe == true ]]; then
    read -r -a flags <<< "$(pkg-config --cflags vulkan)"
    flags+=(-framework Metal -framework Foundation)
else
    read -r -a flags <<< "$(pkg-config --static --cflags --libs mpv)"
fi
if [[ -n ${IOS_VALIDATION_DIR:-} ]]; then
    [[ $platform == device ]] || { echo 'iOS validation currently requires a device build' >&2; exit 2; }
    for name in vulkan VkLayer_khronos_validation MoltenVK; do
        [[ -f $IOS_VALIDATION_DIR/Frameworks/$name.framework/$name ]] || {
            echo "missing validation framework: $name" >&2; exit 2;
        }
    done
    mkdir -p "$app/Frameworks"
    cp -R "$IOS_VALIDATION_DIR/Frameworks/." "$app/Frameworks/"
    cp -R "$IOS_VALIDATION_DIR/vulkan" "$app/"
    loader_flags=()
    for flag in "${flags[@]}"; do
        [[ $flag == -lMoltenVK ]] || loader_flags+=("$flag")
    done
    flags=("${loader_flags[@]}" -DIOS_VULKAN_LOADER -F"$app/Frameworks" -framework vulkan "-Wl,-rpath,@executable_path/Frameworks")
fi
xcrun --sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" \
    "${arc[@]}" -Wall -Wextra -Werror -O2 "$source_file" "${flags[@]}" \
    -framework UIKit -framework QuartzCore -framework VideoToolbox \
    -framework CoreMedia -framework AVFoundation -lc++ -o "$app/IOSSmoke"
cp "$ios_dir/Info.plist" "$app/Info.plist"
if [[ $probe == false ]]; then
    for media in sdr hdr10 dv-p5; do cp "$IOS_MEDIA_DIR/$media-20s.mkv" "$app/"; done
    for media in av sync; do
        if [[ -f $IOS_MEDIA_DIR/$media-20s.mkv ]]; then cp "$IOS_MEDIA_DIR/$media-20s.mkv" "$app/"; fi
    done
fi
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
    if [[ -n ${IOS_VALIDATION_DIR:-} ]]; then
        for framework in "$app/Frameworks/"*.framework; do
            codesign --force --sign "$IOS_SIGNING_IDENTITY" "$framework"
        done
    fi
    codesign --force --sign "$IOS_SIGNING_IDENTITY" --entitlements "$ios_work/entitlements.plist" "$app"
else
    codesign --force --sign - "$app"
fi
if [[ -n ${IOS_VALIDATION_DIR:-} ]]; then codesign --verify --deep --strict "$app";
else codesign --verify "$app"; fi
shasum -a 256 "$app/IOSSmoke" "$prefix/lib/libmpv.a" "$prefix/lib/libplacebo.a" \
    "$prefix/include/mpv/render_vk.h" "$source_file"
echo "IOS_APP_PATH=$app"
echo 'IOS_APP_BUILD=PASS'
