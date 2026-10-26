#!/usr/bin/env bash
# Dev-цикл Colobot на сервере: сборка Linux + Windows (MinGW-кросс), публикация для play.ps1.
#
#   dev.sh setup                     первичная настройка: vcpkg, тулчейн, configure обеих сборок
#   dev.sh build [win|linux|all]     собрать, установить в dist/, обновить manifest (по умолчанию all)
#   dev.sh publish                   только пересчитать manifest Windows-сборки
#   dev.sh scene [missions101|free101|menu|-ключи...]   что запустит play.ps1 (без аргумента: показать)
#   dev.sh shot <сцена|menu> [сек] [файл.png]           скриншот Linux-сборки под xvfb (RES=3440x1440)
#   dev.sh logs [N]                  N-й с конца лог, присланный play.ps1 (по умолчанию последний)
set -euo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${COLOBOT_WORK:-$HOME/colobot-work}
DIST_WIN=$WORK/dist/win64
DIST_LINUX=$WORK/dist/linux
# Сервер общий (на нём живут чужие сервисы): половина ядер, низкий приоритет CPU и диска.
JOBS=${JOBS:-4}
MIN_FREE_GB=${MIN_FREE_GB:-3}
QUIET=(nice -n 15 ionice -c 3)

# Полностью статический exe: зависимости статических SDL2/SDL2_ttf, которые CMake проекта
# добавляет только для MSVC (COLOBOT_MSVC_STATIC_RUNTIME), + стандартный набор CMake для MinGW.
WIN_STATIC_LIBS="-L$WORK/build-win64/vcpkg_installed/x64-mingw-static-release/lib
    -lfreetype -lbz2 -lbrotlidec-static -lbrotlicommon-static -lpng16 -lzlib
    -lwinmm -limm32 -lversion -lsetupapi -lcfgmgr32 -ldxguid -lws2_32
    -lkernel32 -luser32 -lgdi32 -lwinspool -lshell32 -lole32 -loleaut32 -luuid -lcomdlg32 -ladvapi32"
WIN_STATIC_LIBS=$(echo $WIN_STATIC_LIBS)

COMMON_OPTS=(-G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo
    -DCMAKE_C_COMPILER_LAUNCHER=ccache -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
    -DPORTABLE=ON -DPORTABLE_SAVES=ON -DCBOT_STATIC=ON)

cmd_setup() {
    mkdir -p "$WORK/logs" "$WORK/sync" "$WORK/shots"
    if [ ! -d "$WORK/vcpkg" ]; then
        git clone -q https://github.com/microsoft/vcpkg.git "$WORK/vcpkg"
        "$WORK/vcpkg/bootstrap-vcpkg.sh" -disableMetrics
    fi
    # MinGW из Ubuntu должен быть posix-вариантом (std::thread):
    #   update-alternatives --set x86_64-w64-mingw32-g{cc,++} /usr/bin/x86_64-w64-mingw32-g{cc,++}-posix
    cat > "$WORK/toolchain-win64.cmake" <<'EOF'
# Кросс-сборка Colobot под Windows x64 с Linux-хоста (MinGW-w64, posix threads).
# Подключается как VCPKG_CHAINLOAD_TOOLCHAIN_FILE поверх vcpkg.cmake.
set(VCPKG_TARGET_ARCHITECTURE x64)
include(${CMAKE_CURRENT_LIST_DIR}/vcpkg/scripts/toolchains/mingw.cmake)
EOF
    cmake -S "$SRC" -B "$WORK/build-linux" "${COMMON_OPTS[@]}" \
        -DCOLOBOT_APPIMAGE_BASEPATH_OVERRIDE=ON -DTESTS=ON -DTOOLS=ON -DDESKTOP=OFF \
        -DCMAKE_INSTALL_PREFIX="$DIST_LINUX"
    cmake -S "$SRC" -B "$WORK/build-win64" "${COMMON_OPTS[@]}" \
        -DCMAKE_TOOLCHAIN_FILE="$WORK/vcpkg/scripts/buildsystems/vcpkg.cmake" \
        -DVCPKG_CHAINLOAD_TOOLCHAIN_FILE="$WORK/toolchain-win64.cmake" \
        -DVCPKG_TARGET_TRIPLET=x64-mingw-static-release -DVCPKG_HOST_TRIPLET=x64-linux \
        "-DVCPKG_INSTALL_OPTIONS=--clean-after-build" \
        -DGLEW_STATIC=ON -DSNDFILE_STATIC=ON -DTESTS=OFF -DTOOLS=OFF \
        -DDESKTOP=ON `# под Windows это только colobot.rc с иконкой, без него configure падает` \
        -DCMAKE_EXE_LINKER_FLAGS=-static \
        "-DCMAKE_CXX_STANDARD_LIBRARIES=$WIN_STATIC_LIBS" \
        -DCMAKE_INSTALL_PREFIX="$DIST_WIN"
}

check_disk() {
    local free_gb
    free_gb=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')
    if [ "$free_gb" -lt "$MIN_FREE_GB" ]; then
        echo "На диске свободно ${free_gb} ГБ (< ${MIN_FREE_GB} ГБ) — сборку не запускаю." >&2
        exit 1
    fi
}

build_linux() {
    "${QUIET[@]}" cmake --build "$WORK/build-linux" -j"$JOBS"
    cmake --install "$WORK/build-linux" > /dev/null
}

build_win() {
    "${QUIET[@]}" cmake --build "$WORK/build-win64" -j"$JOBS"
    cmake --install "$WORK/build-win64" --strip > /dev/null
    cmd_publish
}

cmd_build() {
    check_disk
    case "${1:-all}" in
        win)   build_win ;;
        linux) build_linux ;;
        all)   build_win; build_linux ;;
        *)     echo "build: win|linux|all" >&2; exit 1 ;;
    esac
}

# Скрипты для Windows кладутся рядом с игрой, чтобы play.ps1 обновлял сам себя.
# play.ps1 — с BOM: PowerShell 5.1 без BOM читает файл как ANSI и ломает кириллицу.
cmd_publish() {
    mkdir -p "$DIST_WIN"
    { printf '\xEF\xBB\xBF'; sed 's/\r\?$/\r/' "$SRC/devloop/play.ps1"; } > "$DIST_WIN/play.ps1"
    sed 's/\r\?$/\r/' "$SRC/devloop/play.cmd" > "$DIST_WIN/play.cmd"
    [ -f "$DIST_WIN/launch.txt" ] || write_launch ""
    (cd "$DIST_WIN" && find . -type f ! -name 'manifest.txt*' -print0 | LC_ALL=C sort -z \
        | xargs -0 sha256sum | sed 's#  \./#  #' > manifest.txt.new && mv manifest.txt.new manifest.txt)
    echo "опубликовано: $(wc -l < "$DIST_WIN/manifest.txt") файлов, $(du -sh "$DIST_WIN" | cut -f1)"
}

write_launch() {
    printf '# Аргументы colobot.exe для play.ps1 (меняется через dev.sh scene). Пусто = главное меню.\r\n%s\r\n' "$1" \
        > "$DIST_WIN/launch.txt"
}

cmd_scene() {
    if [ $# -eq 0 ]; then
        cat "$DIST_WIN/launch.txt"
        return
    fi
    case "$1" in
        menu) write_launch "" ;;
        -*)   write_launch "$*" ;;
        *)    write_launch "-runscene $*" ;;
    esac
    cmd_publish
}

cmd_shot() {
    local scene=${1:?"сцена, например missions101 (или menu)"}
    local sec=${2:-30}
    local out=${3:-$WORK/shots/$scene-$(date +%Y%m%d-%H%M%S).png}
    local res=${RES:-1280x720}
    local args=(-resolution "$res")
    [ "$scene" = menu ] || args+=(-runscene "$scene")
    mkdir -p "$(dirname "$out")"
    LP_NUM_THREADS=2 LIBGL_ALWAYS_SOFTWARE=1 SDL_AUDIODRIVER=dummy ALSOFT_DRIVERS=null nice -n 15 \
        xvfb-run -a -s "-screen 0 ${res}x24" bash -c '
            dir=$1 out=$2 sec=$3; shift 3
            cd "$dir"
            ./colobot "$@" > "$out.log" 2>&1 & pid=$!
            sleep "$sec"
            xwd -root -silent | convert xwd:- "$out"
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
        ' _ "$DIST_LINUX" "$out" "$sec" "${args[@]}"
    echo "$out"
}

cmd_logs() {
    local n=${1:-1}
    local f
    f=$(ls -t "$WORK/logs"/*.txt 2>/dev/null | sed -n "${n}p")
    [ -n "$f" ] || { echo "логов пока нет ($WORK/logs)" >&2; exit 1; }
    echo "== $f"
    cat "$f"
}

cmd=${1:-}
shift || true
case "$cmd" in
    setup|build|publish|scene|shot|logs) "cmd_$cmd" "$@" ;;
    *) sed -n '2,10p' "$0"; exit 1 ;;
esac
