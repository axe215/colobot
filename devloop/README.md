# Dev-цикл: правим на сервере, играем на Windows

Код и сборки живут на сервере, на Windows лежит портативная копия игры, которую
`play.cmd` обновляет и запускает. Устанавливать игру не нужно.

```
сервер:   правка → devloop/dev.sh build → dist/win64 + manifest.txt (sha256 всех файлов)
Windows:  play.cmd → сверка manifest → скачивание только изменённых файлов → colobot.exe
          → после выхода из игры log.txt уходит на сервер в ~/colobot-work/logs/
```

## Где что лежит

| Что | Где |
|---|---|
| Исходники (форк, ветка `custom`) | `~/twoproxy/colobot`, данные — сабмодуль `data` (форк `axe215/colobot-data`, ветка `custom`) |
| Сборки, vcpkg, dist | `~/colobot-work/{build-linux,build-win64,vcpkg,dist}` |
| Логи с Windows | `~/colobot-work/logs/` |
| Скриншоты headless | `~/colobot-work/shots/` |

## Первый запуск на Windows

1. Создать пустую папку, например `C:\Games\ColobotDev`.
2. В PowerShell из этой папки (хост тот же, что в VSCode Remote-SSH):
   ```powershell
   scp <хост>:colobot-work/dist/win64/play.cmd <хост>:colobot-work/dist/win64/play.ps1 .
   .\play.cmd
   ```
3. Скрипт спросит ssh-хост (запомнит в `play.cfg`), скачает игру целиком (~135 МБ) и запустит.
   Рядом с игрой открывается консоль с логом — так задумано (сборка без `COLOBOT_HIDE_CONSOLE`).

Дальше — двойной клик по `play.cmd`. Ключи:

```
play.cmd -Scene missions101   сразу в уровень (категория + глава + номер: missions101, free101, exercises203…)
play.cmd -Menu                в главное меню
play.cmd -NoUpdate            без обновления
play.cmd -Verify              пересчитать хэши, если файлы правились руками
```

Сохранения и `log.txt` лежат внутри папки игры (portable), обновление их не трогает.

## На сервере

```bash
devloop/dev.sh build          # win + linux; только Windows: build win
devloop/dev.sh scene missions101   # что запустит play.cmd без ключей; menu = главное меню
devloop/dev.sh shot missions101    # скриншот Linux-сборки под xvfb → ~/colobot-work/shots/
devloop/dev.sh logs           # последний лог, присланный с Windows
```

Правка уровня, модели, текстуры или CBOT-программы тоже идёт через `dev.sh build`:
часть данных (переводы уровней) генерируется при сборке. Пересобирается только изменённое.

## Git

- `origin` — форк `axe215/*`, `upstream` — `colobot/*`. Обновиться от оригинала:
  `git fetch upstream && git merge upstream/dev` (и то же в `data`).
- Сборка переписывает `.po` в `data` (номера строк в комментариях) — это шум.
  В `data` коммитить конкретные файлы, не `git add -A`.
- Изменили `data` → коммит и push в `data`, затем в корне `git add data` (новый указатель сабмодуля).

## Устройство

- Windows-сборка — кросс-компиляция MinGW-w64 (posix threads) + vcpkg, триплет
  `x64-mingw-static-release`, exe линкуется статически (`-static`), DLL не нужны.
  Настройка с нуля: `devloop/dev.sh setup`.
- `remote.sh` — серверная сторона `play.ps1` (manifest / pack / done), ходит по ssh.
- `play.ps1` публикуется в `dist/win64` с BOM и CRLF (иначе PowerShell 5.1 ломает кириллицу)
  и обновляет сам себя вместе с игрой.
