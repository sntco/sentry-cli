#!/bin/bash
# D232: signed preview updates retain ad-hoc binaries; no Apple identity claim.
set -euo pipefail
fail() { echo "Sentry: $*" >&2; exit 1; }
version=${1:-}
automatic=false
[[ "$version" != --automatic ]] || automatic=true
[[ $# -le 1 && ( -z "$version" || "$version" == --automatic || "$version" == --uninstall || "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ) ]] || fail 'Usage: bash install.sh [VERSION | --uninstall]'
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
shopt -s nullglob dotglob
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || fail 'This preview requires Apple silicon macOS.'
os_version=$(sw_vers -productVersion)
[[ ${os_version%%.*} -ge 27 ]] || fail 'This preview requires macOS 27 or later.'
[[ "$HOME" == /* && "$HOME" != *$'\n'* && "$HOME" != *'/../'* && "$HOME" != */.. ]] || fail 'HOME must be an absolute canonical path.'
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
state="$root/state"
state_path=''
agent="$HOME/Library/LaunchAgents/co.sentry.cli.preview.updater.plist"
label=co.sentry.cli.preview.updater
[[ "$version" != --uninstall || -e "$root" || -L "$root" ]] || fail 'No preview installation found; nothing removed.'
directory "$HOME"
directory "$HOME/.local"; directory "$HOME/.local/bin"
directory "$HOME/.local/share"; directory "$root"
lock="$root/install.lock"
if ! mkdir -m 700 "$lock" 2>/dev/null; then
    [[ "$automatic" != true ]] || exit 0
    fail "Another install is active, or an interrupted install needs inspection: $lock"
fi
temporary=''
cleanup() { [[ -z "$temporary" ]] || rm -rf "$temporary"; rmdir "$lock"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
temporary=$(mktemp -d "$root/.install.XXXXXXXX")
fetch() {
    curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --connect-timeout 15 --max-time 120 --max-filesize "$3" "$1" -o "$2"
}
owned_file() {
    [[ -f "$1" && ! -L "$1" && $(stat -f '%u:%l' "$1") == "$UID:1" ]] || fail "Unsafe file preserved: $1"
}
cat > "$temporary/channel-public.pem" <<'SENTRY_CHANNEL_PUBLIC_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAqlBTDdfLKUL8ntV3t3U4
yJ6mPCW1pFLOtPwbSDWM71KRHzbajU933Np1bFwsBvhQAwGvnGII4MVrv2NUni7R
FbN0uTLqozPpQN5caFU4ViOFDnPVrSuhfWlOlAD3b+3wnXCVx+/SgcIc5fny+n0O
puUM79dGcWdvg2ocHSl6e2B9OaUkzszoPBy++/XylY+mp4NujCD0hZfaf3xU4Yxf
SQvasAgvGAfmSHwpc2zjw/jDCGEacR9WLJf2I+7QD7rS/Js5iPZtQp737W+Ir8Gk
aLXYb/PgDB3vEnAsIBbXcdosVyRgpkNIjIcy1gqdlb8TOxtCS86SjzJ+M22dOrUJ
7rWkDYC6ionGm/iSBGT9VDOswesyR3Y1Abuqq4+Am0yNfxRIICl3VKbUjzKn+LxB
6zRTjQrrJxeeeIjJ9duZwd/vYRJ5CjeNrc40Gqj1dZaC2G3fLrgymXo0Ui5iHV//
s+/X+dljXazSCoorUqwu+goUd2rUvde5ia2T1RbG8HpTAgMBAAE=
-----END PUBLIC KEY-----
SENTRY_CHANNEL_PUBLIC_KEY
verify_channel() {
    owned_file "$1"; owned_file "$2"
    [[ $(stat -f '%z' "$1") -le 2048 && $(stat -f '%z' "$2") -le 1024 ]] || fail 'Oversized update metadata.'
    /usr/bin/openssl dgst -sha256 -verify "$temporary/channel-public.pem" -signature "$2" "$1" >/dev/null 2>&1 || fail 'Invalid update publisher signature.'
}
version_pattern='^(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})\.(0|[1-9][0-9]{0,5})$'
read_channel() {
    channel=()
    while IFS= read -r line; do channel+=("$line"); done < "$1"
    [[ ${#channel[@]} == 6 && ${channel[0]} == sentry-preview-channel-v1 && ${channel[1]} =~ ^[1-9][0-9]{0,8}$ && ${channel[2]} =~ $version_pattern && ${channel[3]} =~ ^[0-9a-f]{64}$ && ${channel[4]} =~ ^[0-9a-f]{64}$ && ${channel[5]} =~ ^[1-9][0-9]{9}$ ]] || fail 'Malformed update channel.'
}
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
path_begin='# >>> Sentry CLI PATH >>>'
path_line='case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
path_end='# <<< Sentry CLI PATH <<<'
profile_file() {
    local file=$1 action=$2
    [[ "$file" == "$HOME"/* && "$file" != *'/../'* && "$file" != *$'\n'* ]] || fail 'Unsafe shell configuration path.'
    case "$file" in */.zshenv|*/.zprofile|*/.zshrc|*/.bashrc|*/.bash_profile|*/.bash_login|*/.profile) ;; *) fail 'Unknown shell configuration preserved.';; esac
    directory "${file%/*}"
    if [[ -e "$file" || -L "$file" ]]; then
        owned_file "$file"
        mode=$(stat -f '%Lp' "$file")
        (( (8#$mode & 0022) == 0 )) || fail 'Shared-writable shell configuration preserved.'
    else
        [[ "$action" == add ]] || return 0
        : > "$file"
    fi
    # Reject edited or duplicate managed blocks before touching shell content.
    awk -v begin="$path_begin" -v line="$path_line" -v end="$path_end" '
      $0==begin {if(state!=0 || ++blocks>1) exit 2; state=1; next}
      state==1 {if($0!=line) exit 2; state=2; next}
      state==2 {if($0!=end) exit 2; state=0; next}
      $0==end {exit 2}
      END {if(state!=0) exit 2}' "$file" || fail 'Edited Sentry PATH block preserved; inspection required.'
    if [[ "$action" == check ]]; then return; fi
    local output; output=$(mktemp "${file%/*}/.sentry-path.XXXXXXXX")
    if [[ "$action" == remove ]]; then
        awk -v begin="$path_begin" -v end="$path_end" '$0==begin {skip=1;next} $0==end {skip=0;next} !skip {print}' "$file" > "$output"
    elif ! grep -Fxq "$path_begin" "$file"; then
        cat "$file" > "$output"
        printf '\n%s\n%s\n%s\n' "$path_begin" "$path_line" "$path_end" >> "$output"
    else
        rm "$output"; return
    fi
    chmod "$(stat -f '%Lp' "$file")" "$output"
    mv -f "$output" "$file"
}
xml() { printf '%s' "$1" | sed 's/\&/\&amp;/g;s/</\&lt;/g;s/>/\&gt;/g'; }
job_loaded() {
    local status
    if launchctl print "gui/$UID/$label" >/dev/null 2>&1; then return 0; else status=$?; fi
    [[ "$status" == 113 ]] || fail 'Updater job state is unknown; preserved.'
    return 1
}
validate_generation() {
    local path=$1 relative digest actual item
    relative=${path#"$root"/}
    [[ "$path" == "$root"/state-* && "$relative" =~ ^state-[1-9][0-9]{0,8}-[0-9a-f]{64}$ ]] || fail 'Unknown updater generation preserved.'
    [[ -d "$path" && ! -L "$path" ]] || fail 'Missing updater generation; preserved.'
    directory "$path"
    for item in "$path"/*; do
        [[ -e "$item" || -L "$item" ]] || continue
        case "${item##*/}" in current.txt|current.sig|update.sh|profiles.txt|agent.sha256) owned_file "$item";; sentry) ;; *) fail "Unknown updater file preserved: $item";; esac
    done
    for item in current.txt current.sig update.sh profiles.txt agent.sha256; do owned_file "$path/$item"; done
    verify_channel "$path/current.txt" "$path/current.sig"
    read_channel "$path/current.txt"
    actual=$(shasum -a 256 "$path/current.txt")
    [[ "$relative" == "state-${channel[1]}-${actual%% *}" ]] || fail 'Updater generation identity mismatch.'
    actual=$(shasum -a 256 "$path/update.sh")
    [[ ${actual%% *} == "${channel[4]}" ]] || fail 'Changed updater preserved.'
    [[ $(stat -f '%z' "$path/profiles.txt") -le 16384 && $(stat -f '%z' "$path/agent.sha256") == 65 ]] || fail 'Invalid updater ownership record.'
    [[ $(cat "$path/agent.sha256") =~ ^[0-9a-f]{64}$ ]] || fail 'Invalid updater configuration identity.'
    [[ -L "$path/sentry" && $(readlink "$path/sentry") == "$root/release-${channel[2]}-${channel[3]}/sentry" ]] || fail 'Updater executable identity mismatch.'
    verify_release "$(readlink "$path/sentry")"
}
running=${BASH_SOURCE[0]:-}
for item in "$root"/*; do
    if [[ "$item" == "$lock" || "$item" == "$temporary" || "$item" == "$state" || "$item" == "$root"/state-* || "$item" == "$root"/release-* ]]; then continue; fi
    if [[ "$item" == "$root"/.bootstrap.* && "$item" == "$running" ]]; then owned_file "$item"; continue; fi
    fail "Unrecognized installation file preserved: $item"
done
if [[ -e "$state" || -L "$state" ]]; then
    [[ -L "$state" ]] || fail 'Unknown updater state preserved.'
    state_path=$(readlink "$state")
    validate_generation "$state_path"
fi
if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" ]] || fail "Existing non-Sentry executable preserved: $link"
    previous=$(readlink "$link")
    if [[ "$previous" == "$state/sentry" ]]; then
        [[ -n "$state_path" ]] || fail 'Missing active updater generation.'
    else
        verify_release "$previous"
    fi
fi
if [[ "$version" == --uninstall ]]; then
    shopt -s nullglob dotglob
    releases=("$root"/release-*)
    generations=("$root"/state-*)
    for item in "$root"/*; do
        [[ "$item" == "$lock" || "$item" == "$temporary" || "$item" == "$state" || "$item" == "$root"/release-* || "$item" == "$root"/state-* ]] || fail "Unrecognized file preserved: $item"
    done
    for release in "${releases[@]}"; do
        verify_release "$release/sentry"
        for item in "$release"/*; do
            case "${item##*/}" in sentry|SHA256SUMS|download.sha256) owned_file "$item";; *) fail "Unrecognized file preserved: $item";; esac
        done
    done
    # Include unactivated generations: an interrupted setup can have edited profiles.
    profiles=()
    for generation in "${generations[@]}"; do
        validate_generation "$generation"
        count=0
        while IFS= read -r file; do
            ((count+=1)); [[ $count -le 8 ]] || fail 'Invalid profile ownership record.'
            profile_file "$file" check; profiles+=("$file")
        done < "$generation/profiles.txt"
    done
    if [[ -e "$agent" || -L "$agent" ]]; then
        owned_file "$agent"
        actual=$(shasum -a 256 "$agent"); recognized=false
        for generation in "${generations[@]}"; do
            [[ ${actual%% *} != "$(cat "$generation/agent.sha256")" ]] || recognized=true
        done
        [[ "$recognized" == true ]] || fail 'Unknown updater configuration preserved.'
        if job_loaded; then launchctl bootout "gui/$UID/$label" || fail 'Could not unload updater; nothing removed.'; fi
        rm "$agent"
    elif job_loaded; then
        fail 'Unknown updater job preserved.'
    fi
    for file in "${profiles[@]}"; do profile_file "$file" remove; done
    [[ ! -L "$link" ]] || rm "$link"
    [[ ! -L "$state" ]] || rm "$state"
    for generation in "${generations[@]}"; do
        rm "$generation/current.txt" "$generation/current.sig" "$generation/update.sh" "$generation/profiles.txt" "$generation/agent.sha256" "$generation/sentry"
        rmdir "$generation"
    done
    for release in "${releases[@]}"; do
        rm "$release/sentry"
        for item in "$release/SHA256SUMS" "$release/download.sha256"; do [[ ! -e "$item" && ! -L "$item" ]] || rm "$item"; done
        rmdir "$release"
    done
    echo 'Uninstalled CLI and automatic updater. App, vault and unrelated shell settings preserved.'
    exit 0
fi
fetch https://sntco.github.io/sentry-cli/current.txt "$temporary/current.txt" 2048
fetch https://sntco.github.io/sentry-cli/current.sig "$temporary/current.sig" 1024
verify_channel "$temporary/current.txt" "$temporary/current.sig"
read_channel "$temporary/current.txt"
[[ ${channel[5]} -gt $(date +%s) ]] || fail 'Update metadata expired; installation preserved.'
if [[ -n "$state_path" ]]; then
    previous_sequence=$(sed -n '2p' "$state_path/current.txt")
    previous_version=$(sed -n '3p' "$state_path/current.txt")
    [[ ${channel[1]} -ge "$previous_sequence" ]] || fail 'Update rollback refused.'
    IFS=. read -r -a old_components <<< "$previous_version"
    IFS=. read -r -a new_components <<< "${channel[2]}"
    for index in 0 1 2; do
        (( 10#${new_components[$index]} >= 10#${old_components[$index]} )) || fail 'Preview version downgrade refused.'
        (( 10#${new_components[$index]} == 10#${old_components[$index]} )) || break
    done
    if [[ ${channel[2]} == "$previous_version" ]]; then
        [[ ${channel[3]} == "$(sed -n '4p' "$state_path/current.txt")" ]] || fail 'Immutable release binary changed.'
    fi
    if [[ ${channel[1]} == "$previous_sequence" ]]; then
        cmp -s "$state_path/current.txt" "$temporary/current.txt" || fail 'Update revision reused with different contents.'
    fi
fi
[[ -z "$version" || "$version" == --automatic || "$version" == "${channel[2]}" ]] || fail 'Only the current signed preview is installable.'
version=${channel[2]}
running=${BASH_SOURCE[0]:-}
installer_digest=''
[[ ! -f "$running" ]] || installer_digest=$(shasum -a 256 "$running")
if [[ ${installer_digest%% *} != "${channel[4]}" ]]; then
    fetch "https://github.com/sntco/sentry-cli/releases/download/preview-v$version/install.sh" "$temporary/installer.sh" 131072
    installer_digest=$(shasum -a 256 "$temporary/installer.sh")
    [[ ${installer_digest%% *} == "${channel[4]}" ]] || fail 'Installer update checksum mismatch.'
    next=$(mktemp "$root/.bootstrap.XXXXXXXX")
    cp "$temporary/installer.sh" "$next"
    rm -rf "$temporary"; temporary=''; rmdir "$lock"
    trap 'rm -f "$next"' EXIT
    /bin/bash "$next" "$version"
    exit $?
fi
base="https://github.com/sntco/sentry-cli/releases/download/preview-v$version"
echo 'Sentry CLI preview: ad-hoc signed; not notarized or Apple publisher-verified.' >&2
fetch "$base/SHA256SUMS" "$temporary/download.sha256" 1024
checksum=$(cat "$temporary/download.sha256")
[[ "$checksum" =~ ^([0-9a-f]{64})[[:space:]][[:space:]]sentry-macos-arm64$ ]] || fail 'Invalid download checksum file.'
expected=${BASH_REMATCH[1]}
[[ "$expected" == "${channel[3]}" ]] || fail 'Release checksum differs from signed publisher metadata.'
fetch "$base/sentry-macos-arm64" "$temporary/sentry" 67108864
printf '%s  sentry\n' "$expected" > "$temporary/SHA256SUMS"
(cd "$temporary" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail 'Download checksum mismatch.'
codesign --verify --strict "$temporary/sentry" || fail 'Invalid executable signature.'
signature=$(codesign -dv --verbose=4 "$temporary/sentry" 2>&1)
[[ $'\n'"$signature"$'\n' == *$'\nSignature=adhoc\n'* && $'\n'"$signature"$'\n' == *$'\nIdentifier=co.sentry.sentry.cli.preview\n'* ]] || fail 'Wrong preview signing identity.'
header=$(od -An -tx1 -N12 "$temporary/sentry" | tr -d '[:space:]')
[[ "$header" == cffaedfe0c00000100000000 ]] || fail 'Wrong executable architecture.'
chmod 755 "$temporary/sentry"
release="$root/release-$version-$expected"
if [[ -e "$release" || -L "$release" ]]; then verify_release "$release/sentry"; else
    mkdir -m 700 "$temporary/payload"
    mv "$temporary/sentry" "$temporary/SHA256SUMS" "$temporary/download.sha256" "$temporary/payload/"
    mv "$temporary/payload" "$release"
fi
# D232: every edited profile remains owned by each immutable update generation.
profiles=()
if [[ -n "$state_path" ]]; then
    while IFS= read -r file; do profiles+=("$file"); done < "$state_path/profiles.txt"
    [[ ${#profiles[@]} -ge 1 && ${#profiles[@]} -le 8 ]] || fail 'Invalid profile ownership record.'
else
    bash_login="$HOME/.bash_profile"
    if [[ ! -e "$bash_login" && ! -L "$bash_login" ]]; then
        if [[ -e "$HOME/.bash_login" || -L "$HOME/.bash_login" ]]; then bash_login="$HOME/.bash_login"
        elif [[ -e "$HOME/.profile" || -L "$HOME/.profile" ]]; then bash_login="$HOME/.profile"; fi
    fi
    profiles=("${ZDOTDIR:-$HOME}/.zshenv" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc" "$bash_login" "$HOME/.bashrc")
fi
for file in "${profiles[@]}"; do profile_file "$file" check; done
directory "$HOME/Library"; directory "$HOME/Library/LaunchAgents"
cat > "$temporary/agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>/usr/bin/env</string><string>-i</string><string>HOME=$(xml "$HOME")</string><string>PATH=/usr/bin:/bin:/usr/sbin:/sbin</string><string>/bin/bash</string><string>--noprofile</string><string>--norc</string><string>$(xml "$state/update.sh")</string><string>--automatic</string></array>
<key>RunAtLoad</key><true/><key>StartInterval</key><integer>86400</integer>
<key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$temporary/agent.plist" >/dev/null || fail 'Invalid updater configuration.'
if [[ -e "$agent" || -L "$agent" ]]; then
    owned_file "$agent"
    cmp -s "$agent" "$temporary/agent.plist" || fail 'Existing updater configuration differs; preserved.'
elif job_loaded; then
    fail 'An unrelated updater job already uses this name.'
fi
metadata_digest=$(shasum -a 256 "$temporary/current.txt")
generation="$root/state-${channel[1]}-${metadata_digest%% *}"
mkdir -m 700 "$temporary/generation"
cp "$temporary/current.txt" "$temporary/current.sig" "$temporary/generation/"
cp "$running" "$temporary/generation/update.sh"
actual=$(shasum -a 256 "$temporary/generation/update.sh")
[[ ${actual%% *} == "${channel[4]}" ]] || fail 'Installer source changed during setup.'
chmod 700 "$temporary/generation/update.sh"
printf '%s\n' "${profiles[@]}" > "$temporary/generation/profiles.txt"
actual=$(shasum -a 256 "$temporary/agent.plist")
printf '%s\n' "${actual%% *}" > "$temporary/generation/agent.sha256"
ln -s "$release/sentry" "$temporary/generation/sentry"
if [[ -e "$generation" || -L "$generation" ]]; then
    validate_generation "$generation"
    cmp -s "$generation/profiles.txt" "$temporary/generation/profiles.txt" || fail 'Updater profile ownership changed.'
else
    mv "$temporary/generation" "$generation"
fi
# Retain an unactivated generation if setup fails; it records every owned edit.
for file in "${profiles[@]}"; do profile_file "$file" add; done
if [[ ! -e "$agent" ]]; then
    agent_stage=$(mktemp "$HOME/Library/LaunchAgents/.sentry-updater.XXXXXXXX")
    cp "$temporary/agent.plist" "$agent_stage"
    mv -f "$agent_stage" "$agent"
fi
if ! job_loaded; then
    launchctl bootstrap "gui/$UID" "$agent" || fail 'Automatic updater registration failed; CLI activation withheld.'
fi
ln -s "$generation" "$temporary/state"
# One atomic pointer commits binary, signed metadata, updater and ownership together.
mv -fh "$temporary/state" "$state"
if [[ ! -L "$link" || $(readlink "$link") != "$state/sentry" ]]; then
    ln -s "$state/sentry" "$temporary/link"
    mv -f "$temporary/link" "$link"
fi
echo "Installed $version: $link"
echo 'Automatic updates enabled. Open a new terminal if sentry is not found in this one.'
echo 'Run sentry --help to get started.'
