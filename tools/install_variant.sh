#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
usage: tools/install_variant.sh [--package PKG | --variant NAME] [--preload] [--no-build] [--no-install] [--out PATH]

Builds the release APK from the current tree, renames it to another package and installs it
next to the officially signed com.droiddeck.launcher.

  --package PKG   package name to install as (default: DROIDDECK_VARIANT_PACKAGE)
  --variant NAME  variant from tools/release/variants.txt (default when no package is set: antutu)
  --preload       rebuild assets/linuxfs/libblsession.so in the Docker cross image first
  --no-build      reuse app/build/outputs/apk/release/app-release.apk
  --no-install    stop after signing
  --out PATH      signed APK path (default: $TMPDIR/droiddeck-<package>.apk)

Settings are read from ~/.config/droiddeck/variant.env when it exists:
  DROIDDECK_VARIANT_PACKAGE   default package
  DROIDDECK_SIGNING_KEYSTORE  PKCS12 keystore to sign with (default: keystore/testkey.p12)
  DROIDDECK_SIGNING_ALIAS     key alias in that keystore
  DROIDDECK_SIGNING_PASSWORD  its password, or
  DROIDDECK_SIGNING_KEYCHAIN  macOS Keychain service holding it (account: droiddeck)
EOF
}

die() { echo "error: $*" >&2; exit 1; }

repo_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

config="${XDG_CONFIG_HOME:-${HOME}/.config}/droiddeck/variant.env"
# shellcheck source=/dev/null
[[ -f "${config}" ]] && . "${config}"

package=${DROIDDECK_VARIANT_PACKAGE:-}
variant=
preload=0
build=1
install=1
out=
while [[ $# -gt 0 ]]; do
    case "$1" in
        --package) [[ $# -ge 2 ]] || die "--package needs a name"; package=$2; variant=; shift 2 ;;
        --package=*) package=${1#*=}; variant=; shift ;;
        --variant) [[ $# -ge 2 ]] || die "--variant needs a name"; variant=$2; package=; shift 2 ;;
        --variant=*) variant=${1#*=}; package=; shift ;;
        --preload) preload=1; shift ;;
        --no-build) build=0; shift ;;
        --no-install) install=0; shift ;;
        --out) [[ $# -ge 2 ]] || die "--out needs a path"; out=$2; shift 2 ;;
        --out=*) out=${1#*=}; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ ${preload} -eq 0 || ${build} -eq 1 ]] || die "--preload needs a build; drop --no-build"

P=com.droiddeck.launcher
if [[ -n "${package}" ]]; then
    pkg=${package}
else
    variant=${variant:-antutu}
    pkg=$(awk -v v="${variant}" '!/^#/ && $1 == v { print $2 }' tools/release/variants.txt)
    [[ -n "${pkg}" ]] || die "no variant '${variant}' in tools/release/variants.txt"
fi
[[ "${pkg}" =~ ^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$ ]] || die "'${pkg}' is not a package name"
[[ "${pkg}" != "${P}" ]] || die "${P} would replace the officially signed install"
out=${out:-"${TMPDIR:-/tmp}/droiddeck-${pkg}.apk"}

keystore=${DROIDDECK_SIGNING_KEYSTORE:-${repo_root}/keystore/testkey.p12}
if [[ -n "${DROIDDECK_SIGNING_KEYSTORE:-}" ]]; then
    [[ -f "${keystore}" ]] || die "signing keystore ${keystore} not found"
    alias=${DROIDDECK_SIGNING_ALIAS:?set DROIDDECK_SIGNING_ALIAS for ${keystore}}
    if [[ -z "${DROIDDECK_SIGNING_PASSWORD:-}" ]]; then
        [[ -n "${DROIDDECK_SIGNING_KEYCHAIN:-}" ]] || die "set DROIDDECK_SIGNING_PASSWORD or DROIDDECK_SIGNING_KEYCHAIN"
        DROIDDECK_SIGNING_PASSWORD=$(security find-generic-password -a droiddeck -s "${DROIDDECK_SIGNING_KEYCHAIN}" -w) \
            || die "no Keychain item '${DROIDDECK_SIGNING_KEYCHAIN}'"
    fi
else
    alias=testkey
    DROIDDECK_SIGNING_PASSWORD=android
fi
export DROIDDECK_SIGNING_PASSWORD
mkdir -p "$(dirname -- "${out}")"

sdk_dir=${ANDROID_HOME:-${ANDROID_SDK_ROOT:-"${HOME}/Library/Android/sdk"}}
export ANDROID_HOME=${sdk_dir} ANDROID_SDK_ROOT=${sdk_dir}
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}

build_tools=
while IFS= read -r dir; do
    [[ -x "${dir}/aapt" && -x "${dir}/zipalign" && -x "${dir}/apksigner" ]] && { build_tools=${dir}; break; }
done < <(find "${sdk_dir}/build-tools" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -rV)
[[ -n "${build_tools}" ]] || die "no build-tools with aapt, zipalign and apksigner under ${sdk_dir}"

apk=${repo_root}/app/build/outputs/apk/release/app-release.apk

if [[ ${preload} -eq 1 ]]; then
    . "${repo_root}/tools/docker_platform.sh"
    echo "==> Rebuilding libblsession.so in ${DROIDDECK_BUILD_IMAGE}"
    docker run --rm --platform "${DROIDDECK_DOCKER_PLATFORM}" --user "$(id -u):$(id -g)" \
        -v "${repo_root}:/src" -w /src "${DROIDDECK_BUILD_IMAGE}" sh -c '
            set -e
            aarch64-linux-gnu-gcc -shared -fPIC -O2 -Wall -pthread \
                -o app/src/main/assets/linuxfs/libblsession.so tools/linuxfs/preload/*.c -ldl
            aarch64-linux-gnu-strip --strip-unneeded app/src/main/assets/linuxfs/libblsession.so
            READELF=aarch64-linux-gnu-readelf bash tools/linuxfs/check-preloads.sh app/src/main/assets/linuxfs'
fi

if [[ ${build} -eq 1 ]]; then
    ndk_version=${DROIDDECK_NDK_VERSION:-}
    if [[ -z "${ndk_version}" ]]; then
        ndk_path=$(find "${sdk_dir}/ndk" -mindepth 2 -maxdepth 2 -name source.properties -exec dirname {} \; 2>/dev/null \
            | sort -V | tail -1)
        ndk_version=${ndk_path##*/}
    fi
    [[ -n "${ndk_version}" && -d "${sdk_dir}/ndk/${ndk_version}" ]] \
        || die "no Android NDK under ${sdk_dir}/ndk; set DROIDDECK_NDK_VERSION"

    echo "==> Recording runtime inputs"
    python3 tools/release/runtime_inputs.py record
    echo "==> Building release APK (NDK ${ndk_version})"
    ./gradlew assembleRelease --console=plain -PndkVersion="${ndk_version}"
    python3 tools/release/check_session_assets.py "${apk}"
    python3 tools/release/runtime_inputs.py apk "${apk}"
fi
[[ -f "${apk}" ]] || die "APK not found at ${apk}"

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

echo "==> Renaming ${P} to ${pkg}"
python3 tools/release/axml_rename.py "${apk}" "${work}/renamed.apk" \
    "${P}=${pkg}" "${P}.androidx-startup=${pkg}.androidx-startup" "${P}.logs=${pkg}.logs" \
    "${P}.pairingguide=${pkg}.pairingguide" "${P}.pin=${pkg}.pin" \
    "${P}.documents=${pkg}.documents" "${P}.home=${pkg}.home" "${P}.agent=${pkg}.agent" \
    "${P}.vr_recovery=${pkg}.vr_recovery" "${P}.dualscreen=${pkg}.dualscreen" "${P}.typing=${pkg}.typing" \
    "${P}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION=${pkg}.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION"
got=$("${build_tools}/aapt" dump badging "${work}/renamed.apk" | sed -n "s/^package: name='\([^']*\)'.*/\1/p")
[[ "${got}" = "${pkg}" ]] || die "the renamed apk says package '${got}', not '${pkg}'"
tree=$("${build_tools}/aapt" dump xmltree "${work}/renamed.apk" AndroidManifest.xml)
if grep -E 'android:(authorities|taskAffinity)' <<<"${tree}" | grep -F "\"${P}."; then
    die "the manifest still names ${P} in an authority or task"
fi

echo "==> Signing with ${keystore} (${alias})"
"${build_tools}/zipalign" -p -f 4 "${work}/renamed.apk" "${work}/aligned.apk"
"${build_tools}/apksigner" sign \
    --ks "${keystore}" --ks-type PKCS12 --ks-pass env:DROIDDECK_SIGNING_PASSWORD \
    --ks-key-alias "${alias}" --key-pass env:DROIDDECK_SIGNING_PASSWORD \
    --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true --v4-signing-enabled false \
    --out "${out}" "${work}/aligned.apk"
rm -f "${out}.idsig"
"${build_tools}/apksigner" verify --min-sdk-version 26 "${out}" >/dev/null || die "${out} does not verify"
echo "Signed ${pkg}: ${out}"

if [[ ${install} -eq 1 ]]; then
    adb_bin=${ADB:-${sdk_dir}/platform-tools/adb}
    [[ -x "${adb_bin}" ]] || die "adb not found at ${adb_bin}; set ADB or ANDROID_HOME"
    serial=$(python3 tools/adb_device.py --adb "${adb_bin}")
    echo "==> Installing on ${serial}"
    "${adb_bin}" -s "${serial}" install -r "${out}"
fi

cat <<EOF

Package: ${pkg}
Drive it with: DROIDDECK_PACKAGE=${pkg} tools/droiddeckctl <command>
EOF
