#!/bin/sh
set -eu

app=${1:?app bundle path required}
profile_dir=${2:?provisioning profile directory required}
identity=${3:?code-signing identity required}
bundle_id=${4:?bundle identifier required}
team_id=${5:?team identifier required}

if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    echo "Run the signing step as the logged-in user, not root." >&2
    exit 1
fi

actual_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")
if [ "$actual_bundle_id" != "$bundle_id" ]; then
    echo "Bundle ID is $actual_bundle_id; expected $bundle_id." >&2
    exit 1
fi

tmpdir=$(/usr/bin/mktemp -d "${TMPDIR:-/private/tmp}/macpass-profile.XXXXXX")
trap '/bin/rm -rf "$tmpdir"' EXIT HUP INT TERM
decoded="$tmpdir/profile.plist"
best_profile=
best_expiration=0

for profile in "$profile_dir"/*.provisionprofile; do
    [ -f "$profile" ] || continue
    if ! /usr/bin/security cms -D -i "$profile" -o "$decoded" 2>/dev/null; then
        continue
    fi

    profile_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$decoded" 2>/dev/null || true)
    profile_team_id=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$decoded" 2>/dev/null || true)
    profile_group=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups:0' "$decoded" 2>/dev/null || true)
    expiration=$(/usr/libexec/PlistBuddy -c 'Print :ExpirationDate' "$decoded" 2>/dev/null || true)

    [ "$profile_bundle_id" = "$team_id.$bundle_id" ] || continue
    [ "$profile_team_id" = "$team_id" ] || continue
    [ "$profile_group" = "$team_id.*" ] || continue

    expiration_epoch=$(/bin/date -j -f '%a %b %d %T %Z %Y' "$expiration" '+%s' 2>/dev/null || echo 0)
    [ "$expiration_epoch" -gt "$(/bin/date '+%s')" ] || continue
    if [ "$expiration_epoch" -gt "$best_expiration" ]; then
        best_profile=$profile
        best_expiration=$expiration_epoch
    fi
done

if [ -z "$best_profile" ]; then
    echo "No unexpired Xcode profile authorizes $team_id.$bundle_id and $team_id.*." >&2
    echo "Refresh the MacPass profile in Xcode, then run port install again." >&2
    exit 1
fi

entitlements="$tmpdir/MacPass.entitlements"
cat > "$entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key>
  <string>$team_id.$bundle_id</string>
  <key>com.apple.developer.team-identifier</key>
  <string>$team_id</string>
  <key>com.apple.security.automation.apple-events</key>
  <true/>
  <key>com.apple.security.cs.disable-library-validation</key>
  <true/>
  <key>keychain-access-groups</key>
  <array>
    <string>$team_id.$bundle_id</string>
  </array>
</dict>
</plist>
EOF

/bin/cp "$best_profile" "$app/Contents/embedded.provisionprofile"
/usr/bin/codesign --force --sign "$identity" --options runtime \
    --timestamp=none --generate-entitlement-der \
    --entitlements "$entitlements" "$app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$app"

echo "Signed $app with the matching Xcode profile."
