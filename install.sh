#!/bin/bash
# D232 preview channel: ad-hoc signing is not an Apple publisher identity.
set -euo pipefail
fail() { echo "Sentry: $*" >&2; exit 1; }
version=${1:-}
[[ $# == 1 && ( "$version" == --uninstall || "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ) ]] || fail 'Usage: bash install.sh VERSION | --uninstall'
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'This preview requires Apple silicon macOS.'
os_version=$(sw_vers -productVersion)
[[ ${os_version%%.*} -ge 27 ]] || fail 'This preview requires macOS 27 or later.'
[[ "$HOME" == /* && "$HOME" != *$'\n'* && "$HOME" != *'/../'* && "$HOME" != */.. ]] || fail 'HOME must be an absolute canonical path.'

# Refuse redirected or shared-writable parents before creating installation paths.
directory() {
    local path=$1 parent
    [[ ! -L "$path" ]] || fail "Symlink directory refused: $path"
    if [[ ! -e "$path" ]]; then
        parent=${path%/*}; [[ -n "$parent" ]] || parent=/
        directory "$parent"
        mkdir -m 700 "$path"
    fi
    [[ -d "$path" ]] || fail "Not a directory: $path"
    [[ $(cd "$path" && pwd -P) == "$path" ]] || fail "Redirected directory refused: $path"
    [[ $(stat -f '%u' "$path") == "$UID" ]] || fail "Directory must belong to you: $path"
    local mode; mode=$(stat -f '%Lp' "$path")
    (( (8#$mode & 0022) == 0 )) || fail "Shared-writable directory refused: $path"
}
root="$HOME/.local/share/sentry-cli"
link="$HOME/.local/bin/sentry"
if [[ "$version" == --uninstall && ! -e "$root" && ! -L "$root" ]]; then
    fail 'No preview installation found; nothing removed.'
fi
directory "$HOME/.local"
directory "$HOME/.local/bin"
directory "$HOME/.local/share"
directory "$HOME/.local/share/sentry-cli"
lock="$root/install.lock"
mkdir -m 700 "$lock" 2>/dev/null || fail "Another install is active, or an interrupted install needs inspection: $lock"
temporary=''
cleanup() { [[ -z "$temporary" ]] || rm -rf "$temporary"; rmdir "$lock"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
temporary=$(mktemp -d "$root/.install.XXXXXXXX")
verify_release() {
    local path=$1 relative digest actual
    relative=${path#"$root"/}
    [[ "$path" == "$root"/release-*/sentry && "$relative" != */*/* ]] || fail 'Existing unrelated symlink preserved.'
    directory "${path%/*}"
    [[ -f "$path" && ! -L "$path" && $(stat -f '%u:%l' "$path") == "$UID:1" ]] || fail 'Existing executable is not a single owned regular file.'
    digest=${relative%/sentry}; digest=${digest##*-}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail 'Existing release has an invalid identity.'
    actual=$(shasum -a 256 "$path"); actual=${actual%% *}
    [[ "$actual" == "$digest" ]] || fail 'Existing installation changed; refusing replacement or removal.'
}
if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" ]] || fail "Existing non-Sentry executable preserved: $link"
    previous=$(readlink "$link")
    verify_release "$previous"
fi
if [[ "$version" == --uninstall ]]; then
    # Preflight every retained version before deleting anything; preserve foreign files.
    shopt -s nullglob dotglob
    releases=("$root"/release-*)
    for item in "$root"/*; do
        [[ "$item" == "$lock" || "$item" == "$temporary" || "$item" == "$root"/release-* ]] || fail "Unrecognized file preserved: $item"
    done
    for release in "${releases[@]}"; do
        verify_release "$release/sentry"
        for item in "$release"/*; do
            [[ "$item" == "$release/sentry" || "$item" == "$release/SHA256SUMS" || "$item" == "$release/download.sha256" ]] || fail "Unrecognized file preserved: $item"
            [[ -f "$item" && ! -L "$item" && $(stat -f '%u:%l' "$item") == "$UID:1" ]] || fail "Unrecognized metadata type preserved: $item"
        done
    done
    [[ ! -L "$link" ]] || rm "$link"
    for release in "${releases[@]}"; do
        rm "$release/sentry"
        for item in "$release/SHA256SUMS" "$release/download.sha256"; do
            [[ ! -e "$item" && ! -L "$item" ]] || rm "$item"
        done
        rmdir "$release"
    done
    echo 'Uninstalled preview CLI. App, vault and shell configuration preserved.'
    exit 0
fi
base="https://github.com/sntco/sentry-cli/releases/download/preview-v$version"
echo 'Sentry CLI preview: ad-hoc signed; not notarized or Apple publisher-verified.' >&2
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fSL --connect-timeout 15 --max-time 120 --max-filesize 1024 "$base/SHA256SUMS" -o "$temporary/download.sha256"
checksum=$(cat "$temporary/download.sha256")
[[ "$checksum" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]sentry-macos-arm64$ ]] || fail 'Invalid download checksum file.'
expected=${BASH_REMATCH[1]}
curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fSL --connect-timeout 15 --max-time 120 --max-filesize 67108864 "$base/sentry-macos-arm64" -o "$temporary/sentry"
printf '%s  sentry\n' "$expected" > "$temporary/SHA256SUMS"
(cd "$temporary" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail 'Download checksum mismatch.'
codesign --verify --strict "$temporary/sentry" || fail 'Invalid executable signature.'
signature=$(codesign -dv --verbose=4 "$temporary/sentry" 2>&1)
[[ $'\n'"$signature"$'\n' == *$'\nSignature=adhoc\n'* && $'\n'"$signature"$'\n' == *$'\nIdentifier=co.sentry.sentry.cli.preview\n'* ]] || fail 'Wrong preview signing identity.'
[[ $(lipo -archs "$temporary/sentry") == arm64 ]] || fail 'Wrong executable architecture.'
chmod 755 "$temporary/sentry"
release="$root/release-$version-$expected"
if [[ -e "$release" || -L "$release" ]]; then
    verify_release "$release/sentry"
else
    mv "$temporary" "$release"
    temporary=''
fi
[[ -z "$temporary" ]] || rm -rf "$temporary"
temporary=$(mktemp -d "$root/.link.XXXXXXXX")
ln -s "$release/sentry" "$temporary/sentry"
# Atomic symlink replacement leaves already running CLI processes untouched.
mv -f "$temporary/sentry" "$link"
echo "Installed $version: $link"
echo 'Add ~/.local/bin to your PATH if needed. Run sentry --version.'
echo 'To update, run this installer with the newer preview version.'
