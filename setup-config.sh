#!/bin/sh
set -eu

PREF_PATH="/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"
if [ -d "/var/jb/var/mobile/Library/Preferences" ]; then
    PREF_PATH="/var/jb/var/mobile/Library/Preferences/com.murkaska.virtualcampro.plist"
fi
TEMP_PREF_PATH="${PREF_PATH}.tmp.$$"
STREAM_URL="${1:-}"
PREFERRED_FPS="${2:-60}"

cleanup() {
    rm -f "$TEMP_PREF_PATH"
}

validate_stream_url() {
    vc_url=$1
    case "$vc_url" in
        http://?*|https://?*) ;;
        *)
            echo "The URL must start with http:// or https://" >&2
            return 1
            ;;
    esac
    if [ "${#vc_url}" -gt 4096 ]; then
        echo "The URL must not exceed 4096 characters" >&2
        return 1
    fi
    case "$vc_url" in
        *'#'*|*[[:space:]]*)
            echo "The URL must not contain a fragment or whitespace" >&2
            return 1
            ;;
    esac
    vc_remainder=${vc_url#*://}
    vc_authority=${vc_remainder%%/*}
    vc_authority=${vc_authority%%\?*}
    if [ -z "$vc_authority" ] || [ "$vc_authority" != "${vc_authority#*@}" ]; then
        echo "The URL must contain a host and must not contain credentials" >&2
        return 1
    fi
    case "$vc_authority" in
        *[A-Za-z0-9]*) return 0 ;;
        *)
            echo "The URL authority does not contain a valid host" >&2
            return 1
            ;;
    esac
}

validate_preferred_fps() {
    vc_fps=$1
    case "$vc_fps" in
        ''|*[!0-9]*)
            echo "FPS must be an integer from 1 through 240" >&2
            return 1
            ;;
    esac
    if [ "$vc_fps" -lt 1 ] || [ "$vc_fps" -gt 240 ]; then
        echo "FPS must be an integer from 1 through 240" >&2
        return 1
    fi
}

if [ "$STREAM_URL" = "--self-test" ]; then
    if ! validate_stream_url "http://192.168.1.10:8888/live.mjpg" >/dev/null 2>&1 ||
       validate_stream_url "file:///var/mobile/test" >/dev/null 2>&1 ||
       validate_stream_url "http://user:password@192.168.1.10/live.mjpg" >/dev/null 2>&1 ||
       validate_stream_url "http://192.168.1.10/live.mjpg#fragment" >/dev/null 2>&1 ||
       validate_stream_url "http:///missing-host" >/dev/null 2>&1 ||
       ! validate_preferred_fps "240" >/dev/null 2>&1 ||
       validate_preferred_fps "241" >/dev/null 2>&1; then
        echo "VirtualCamPro configuration validation self-test failed" >&2
        exit 70
    fi
    echo "VirtualCamPro configuration validation self-test passed"
    exit 0
fi

if [ -z "$STREAM_URL" ]; then
    printf 'HTTP/HTTPS HLS or MJPEG URL: '
    IFS= read -r STREAM_URL
fi

if ! validate_stream_url "$STREAM_URL"; then
    exit 64
fi

if ! validate_preferred_fps "$PREFERRED_FPS"; then
    exit 64
fi

ESCAPED_URL=$(printf '%s' "$STREAM_URL" | sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g")

umask 077
trap cleanup EXIT HUP INT TERM
mkdir -p "$(dirname "$PREF_PATH")"
cat > "$TEMP_PREF_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>enabled</key>
    <true/>
    <key>sourceType</key>
    <integer>0</integer>
    <key>streamURL</key>
    <string>${ESCAPED_URL}</string>
    <key>preferredFPS</key>
    <integer>${PREFERRED_FPS}</integer>
    <key>sourceRotation</key>
    <integer>0</integer>
    <key>mirrorSource</key>
    <false/>
    <key>maximumPixelDimension</key>
    <integer>1920</integer>
    <key>jpegQuality</key>
    <real>1.0</real>
    <key>aspectFill</key>
    <true/>
    <key>holdLastFrame</key>
    <true/>
    <key>staleFrameTimeout</key>
    <real>8.0</real>
</dict>
</plist>
EOF

if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$TEMP_PREF_PATH" >/dev/null
fi
chmod 600 "$TEMP_PREF_PATH"
if [ "$(id -u)" -eq 0 ]; then
    chown mobile:mobile "$TEMP_PREF_PATH"
fi
mv -f "$TEMP_PREF_PATH" "$PREF_PATH"
trap - EXIT HUP INT TERM

if command -v notifyutil >/dev/null 2>&1; then
    notifyutil -p com.murkaska.virtualcampro/preferences.changed
fi

echo "Saved VirtualCamPro configuration to $PREF_PATH"
echo "Local-file FPS limit: $PREFERRED_FPS (network streams follow the sender)"
echo "Restart Camera and mediaserverd if they do not reload automatically."
