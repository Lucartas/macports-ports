#!/bin/sh
set -eu

app=${1:?installed app path required}
signer=${2:?user signing script required}
identity=${3:?code-signing identity required}
bundle_id=${4:?bundle identifier required}
team_id=${5:?team identifier required}

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
    echo "MacPass-devel signing hook must run as root during activation." >&2
    exit 1
fi
[ -d "$app" ] || { echo "Installed app not found: $app" >&2; exit 1; }

console_user=$(/usr/bin/stat -f '%Su' /dev/console)
case "$console_user" in
    root|loginwindow|_mbsetupuser|"")
        echo "No logged-in desktop user is available to access the signing keychain." >&2
        exit 1
        ;;
esac
console_uid=$(/usr/bin/id -u "$console_user")
console_home=$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory | /usr/bin/awk '{print $2}')
[ -d "$console_home/Library/Developer/Xcode/UserData/Provisioning Profiles" ] || {
    echo "Xcode provisioning profiles not found for $console_user." >&2
    exit 1
}

work_root=$(/usr/bin/mktemp -d /private/tmp/macpass-devel-sign.XXXXXX)
user_work="$work_root/user-work"
staged_app="$user_work/MacPass.app"
signed_app="$work_root/Signed.app"
new_app="${app}.new"
backup="/private/tmp/MacPass-devel-unsigned-$(/bin/date '+%Y%m%d-%H%M%S').app"
trap '/bin/rm -rf "$work_root"; [ ! -e "$new_app" ] || /bin/rm -rf "$new_app"' EXIT HUP INT TERM

/bin/chmod 755 "$work_root"
/bin/mkdir "$user_work"
/usr/sbin/chown "$console_user":staff "$user_work"
/bin/chmod 700 "$user_work"
/usr/bin/ditto "$app" "$staged_app"
/usr/sbin/chown -R "$console_user":staff "$staged_app"

/bin/launchctl asuser "$console_uid" /usr/bin/sudo -u "$console_user" -H \
    /bin/sh "$signer" "$staged_app" \
    "$console_home/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "$identity" "$bundle_id" "$team_id"

# Take ownership back before validating and installing the signed bundle.
/bin/mv "$staged_app" "$signed_app"
/usr/sbin/chown -R root:wheel "$signed_app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$signed_app"
actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$signed_app/Contents/Info.plist")
[ "$actual_bundle_id" = "$bundle_id" ] || { echo "Unexpected bundle ID: $actual_bundle_id" >&2; exit 1; }
signature_info=$(/usr/bin/codesign -dv --verbose=2 "$signed_app" 2>&1 || true)
actual_team_id=$(printf '%s\n' "$signature_info" | /usr/bin/sed -n 's/^TeamIdentifier=//p')
[ "$actual_team_id" = "$team_id" ] || { echo "Unexpected signing team: $actual_team_id" >&2; exit 1; }

/usr/bin/ditto "$signed_app" "$new_app"
/usr/sbin/chown -R root:wheel "$new_app"
/usr/bin/codesign --verify --deep --strict "$new_app"
/usr/bin/ditto "$app" "$backup"
swap_backup="${app}.previous-$$"
if ! /bin/mv "$app" "$swap_backup"; then
    echo "Could not move the active app aside before replacement." >&2
    exit 1
fi
if ! /bin/mv "$new_app" "$app"; then
    /bin/mv "$swap_backup" "$app"
    exit 1
fi
if ! /usr/bin/codesign --verify --deep --strict "$app"; then
    /bin/rm -rf "$app"
    /bin/mv "$swap_backup" "$app"
    exit 1
fi
/bin/rm -rf "$swap_backup"

echo "Installed Touch ID-enabled MacPass-devel; unsigned backup: $backup"
