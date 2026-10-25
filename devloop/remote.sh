#!/usr/bin/env bash
# Серверная сторона play.ps1, вызывается по ssh с Windows.
#
#   remote.sh manifest       sha256 всех файлов Windows-сборки
#   remote.sh pack           stdin: список путей; собирает их в tar.gz, печатает путь к архиву от $HOME
#   remote.sh done <путь>    удалить отданный архив
set -euo pipefail

WORK=${COLOBOT_WORK:-$HOME/colobot-work}
DIST=$WORK/dist/win64
SYNC=$WORK/sync

case "${1:-}" in
    manifest)
        cat "$DIST/manifest.txt"
        ;;
    pack)
        mkdir -p "$SYNC"
        find "$SYNC" -maxdepth 1 -name 'pack.*' -mmin +120 -delete
        list=$(mktemp "$SYNC/list.XXXXXX")
        trap 'rm -f "$list"' EXIT
        # PowerShell присылает строки с CRLF
        tr -d '\r' | grep -v '^$' > "$list" || true
        if grep -qE '^/|(^|/)\.\.(/|$)' "$list"; then
            echo "pack: в списке путь вне сборки" >&2
            exit 2
        fi
        out=$(mktemp --suffix=.tgz "$SYNC/pack.XXXXXX")
        tar -C "$DIST" --verbatim-files-from -T "$list" -cf - | gzip -1 > "$out"
        echo "${out#"$HOME"/}"
        ;;
    done)
        f="$HOME/${2:?путь к архиву}"
        case "$f" in
            "$SYNC"/pack.*.tgz) rm -f "$f" ;;
        esac
        ;;
    *)
        sed -n '2,7p' "$0" >&2
        exit 1
        ;;
esac
