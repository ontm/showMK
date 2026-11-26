#!/bin/zsh
# 安装到 ~/Applications 并注册开机自启（LaunchAgent）
set -euo pipefail
ROOT="${0:A:h}"
DEST="$HOME/Applications/showMK.app"
LABEL="local.rokulab.btstatusbar"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

"$ROOT/build.sh" >/dev/null

pkill -f "showMK.app/Contents/MacOS/showMK" 2>/dev/null || true
mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$DEST"
cp -R "$ROOT/showMK.app" "$DEST"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/Contents/MacOS/showMK</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 部分环境（沙箱 / 非图形会话）不允许在当前会话 bootstrap，
# 此时 LaunchAgent 仍会在下次登录时由 launchd 自动加载。
launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || \
    print -u2 -- "提示：当前会话未能注册 launchd 服务，重启后会自动加载。"
open -a "$DEST"

printf '已安装：%s\n已注册开机自启：%s\n' "$DEST" "$PLIST"
