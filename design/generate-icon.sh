#!/bin/zsh
set -eu
root="${0:A:h:h}"
png="$root/design/showMK-icon-outline.png"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
icons="$tmp/showMK.iconset"
mkdir -p "$icons" "$root/Resources"
for size in 16 32 128 256 512; do
    for scale in 1 2; do
        pixels=$((size * scale))
        suffix=''
        if (( scale == 2 )); then suffix='@2x'; fi
        out="$icons/icon_${size}x${size}${suffix}.png"
        if (( pixels == 1024 )); then cp "$png" "$out"; else sips -z "$pixels" "$pixels" "$png" --out "$out" >/dev/null; fi
    done
done
iconutil -c icns "$icons" -o "$tmp/showMK.icns"
mv "$tmp/showMK.icns" "$root/Resources/showMK.icns"
