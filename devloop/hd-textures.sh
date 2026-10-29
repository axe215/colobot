#!/usr/bin/env bash
# Собирает мод HDTextures (data/mods/HDTextures) из лучших доступных версий текстур:
#   1. data/mods/AltTextures       — HD-версии от TerranovaTeam
#   2. colobot-hd-raster (bayerchemistry, GPL-3.0) — текстуры, перерисованные вручную
#   3. Real-ESRGAN realesr-animevideov3 x4 — для всего остального размером до 512
# Текстуры больше 512 без готовой HD-версии и данные (relief*, res* — карты высот
# и ресурсов) не трогаются: игра берёт оригиналы.
#
#   devloop/hd-textures.sh <colobot-hd-raster/textures> [realesrgan-dir]
#
# Нейросеть работает через программный Vulkan (lavapipe), ~10–40 с на текстуру.
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
HDPACK=${1:?"путь к colobot-hd-raster/textures"}
ESRGAN=${2:-$HOME/colobot-work/tools/realesrgan}
DATA=$SRC/data/textures
ALT=$SRC/data/mods/AltTextures/textures
OUT=$SRC/data/mods/HDTextures
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Из HD-пака не берём: plant — нет альфа-масок перекраски из PR #1887 и другие листья
# (human берётся с маской из #1887, см. ниже); dirty* — другой рисунок;
# интерфейс и back46 — не лучше оригинала
HDPACK_SKIP='^(objects/plant\.png|dirty[0-9]+\.png|interface/.*|back46\.png)$'
# Данные, а не изображения
NOT_TEXTURE='^((relief|res)[0-9a-z]*\.png|interface/.*)$'

PAD=16
MAX_SOURCE=512

export VK_ICD_FILENAMES=${VK_ICD_FILENAMES:-/usr/share/vulkan/icd.d/lvp_icd.json}
export LP_NUM_THREADS=${LP_NUM_THREADS:-4}

has_alpha() { [[ "$(identify -format '%[channels]' "$1")" == *a ]]; }

upscale() {
    local src=$1 dst=$2 w h
    w=$(identify -format '%w' "$src")
    h=$(identify -format '%h' "$src")

    # Края заворачиваются (текстуры земли бесшовные), после увеличения поля обрезаются
    convert "$src" -alpha off -define distort:viewport=$((w + 2*PAD))x$((h + 2*PAD))-$PAD-$PAD \
        -virtual-pixel tile -filter point -distort SRT 0 +repage "$TMP/in.png"
    (cd "$ESRGAN" && nice -n 15 ./realesrgan-ncnn-vulkan -i "$TMP/in.png" -o "$TMP/out.png" \
        -n realesr-animevideov3-x4 -s 4 -t 128 > /dev/null 2>&1)
    convert "$TMP/out.png" -crop $((w*4))x$((h*4))+$((PAD*4))+$((PAD*4)) +repage "$TMP/rgb.png"

    if has_alpha "$src"; then
        # Альфа (маски перекраски, прозрачность) — обычным увеличением, без «додумывания»
        convert "$src" -alpha extract -filter Lanczos -resize 400% "$TMP/alpha.png"
        convert "$TMP/rgb.png" "$TMP/alpha.png" -alpha off -compose CopyOpacity -composite "$dst"
    else
        cp "$TMP/rgb.png" "$dst"
    fi
}

rm -rf "$OUT/textures"
mkdir -p "$OUT/textures"

count_alt=0 count_hd=0 count_ai=0
while read -r rel; do
    [[ "$rel" =~ $NOT_TEXTURE ]] && continue
    dst="$OUT/textures/$rel"
    mkdir -p "$(dirname "$dst")"

    if [ "$rel" = "objects/human.png" ] && [ -f "$HDPACK/$rel" ]; then
        # Рисунок 2048 из HD-пака + маска перекраски скафандра из PR #1887: раскладка совпадает
        size=$(identify -format '%wx%h' "$HDPACK/$rel")
        convert "$DATA/$rel" -alpha extract -filter Lanczos -resize "$size!" "$TMP/mask.png"
        convert "$HDPACK/$rel" -alpha off "$TMP/mask.png" -compose CopyOpacity -composite "$dst"
        count_hd=$((count_hd + 1))
    elif [ -f "$ALT/$rel" ]; then
        cp "$ALT/$rel" "$dst"
        count_alt=$((count_alt + 1))
    elif [ -f "$HDPACK/$rel" ] && ! [[ "$rel" =~ $HDPACK_SKIP ]]; then
        if has_alpha "$DATA/$rel"; then
            cp "$HDPACK/$rel" "$dst"
        else
            # В HD-паке у части текстур есть почти непрозрачный альфа-канал, которого нет в оригинале
            convert "$HDPACK/$rel" -alpha off "$dst"
        fi
        count_hd=$((count_hd + 1))
    elif [ "$(identify -format '%[fx:max(w,h)]' "$DATA/$rel")" -le $MAX_SOURCE ]; then
        echo "  нейросеть: $rel"
        upscale "$DATA/$rel" "$dst"
        count_ai=$((count_ai + 1))
    fi
done < <(cd "$DATA" && find . -name '*.png' | sed 's|^\./||' | sort)

cat > "$OUT/manifest.txt" <<'EOF'
DisplayName.E text="HD Textures"
Author text="TerranovaTeam (AltTextures), bayerchemistry (colobot-hd-raster), Real-ESRGAN"
Version major=1 minor=0 patch=0
Summary.E text="High resolution textures: hand-made HD versions where they exist, AI upscaled (Real-ESRGAN x4) for the rest."
EOF

echo "AltTextures: $count_alt, HD-пак: $count_hd, нейросеть: $count_ai, всего $(du -sh "$OUT" | cut -f1)"
