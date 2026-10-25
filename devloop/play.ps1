<#
.SYNOPSIS
  Dev-цикл Colobot: подтянуть с сервера изменённые файлы и запустить игру.
.DESCRIPTION
  Сравнивает manifest.txt на сервере (sha256 всех файлов сборки) с тем, что уже
  скачано, забирает только отличающиеся файлы одним архивом и запускает игру.
  После выхода из игры отправляет log.txt на сервер (~/colobot-work/logs/).

    play.cmd                      обновить и запустить то, что задано на сервере (launch.txt)
    play.cmd -Scene missions101   запустить конкретный уровень
    play.cmd -Menu                запустить в главное меню
    play.cmd -NoUpdate            запустить без обновления
    play.cmd -NoLaunch            только обновить
    play.cmd -NoWait              не ждать выхода из игры (лог не отправится)
    play.cmd -Verify              пересчитать хэши локальных файлов (если правил руками или что-то побилось)
#>
[CmdletBinding()]
param(
    [string]$Scene,
    [switch]$Menu,
    [switch]$NoUpdate,
    [switch]$NoLaunch,
    [switch]$NoWait,
    [switch]$Verify
)

$ErrorActionPreference = 'Stop'
$OutputEncoding = New-Object System.Text.UTF8Encoding $false
$Root = $PSScriptRoot
$CfgPath = Join-Path $Root 'play.cfg'
$StatePath = Join-Path $Root '.manifest.local'

$Cfg = [ordered]@{ SshHost = ''; RemoteScript = 'twoproxy/colobot/devloop/remote.sh'; LogDir = 'colobot-work/logs' }
if (Test-Path -LiteralPath $CfgPath) {
    foreach ($line in Get-Content -LiteralPath $CfgPath) {
        if ($line -match '^\s*([A-Za-z]+)\s*=\s*(.*?)\s*$') { $Cfg[$Matches[1]] = $Matches[2] }
    }
}
if (-not $Cfg.SshHost) {
    $Cfg.SshHost = Read-Host 'SSH-хост сервера (как в VSCode Remote-SSH: алиас из ~/.ssh/config или devuser@адрес)'
    $Cfg.Keys | ForEach-Object { '{0}={1}' -f $_, $Cfg[$_] } | Set-Content -LiteralPath $CfgPath -Encoding ASCII
}
$SshOpts = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15')

function Invoke-Remote {
    param([string]$Command, [string[]]$InputLines)
    $remote = "bash $($Cfg.RemoteScript) $Command"
    if ($InputLines) { $out = $InputLines | & ssh @SshOpts $Cfg.SshHost $remote }
    else { $out = & ssh @SshOpts $Cfg.SshHost $remote }
    if ($LASTEXITCODE -ne 0) { throw "ssh $($Cfg.SshHost) '$remote' завершился с кодом $LASTEXITCODE" }
    return $out
}

function Read-Manifest {
    param([string[]]$Lines)
    $map = @{}
    foreach ($line in $Lines) {
        # формат sha256sum: <64 hex><два пробела><путь>
        if ($line.Length -gt 66) { $map[$line.Substring(66)] = $line.Substring(0, 64) }
    }
    return $map
}

function Stop-Game {
    $procs = Get-Process -Name colobot -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase) }
    foreach ($p in $procs) {
        Write-Host 'Закрываю запущенную игру...'
        $null = $p.CloseMainWindow()
        if (-not $p.WaitForExit(3000)) { $p.Kill(); $p.WaitForExit() }
    }
}

function Update-Game {
    Write-Host "Сверяю файлы с сервером $($Cfg.SshHost)..."
    $remote = Read-Manifest (Invoke-Remote 'manifest')
    if ($remote.Count -eq 0) { throw 'Сервер вернул пустой manifest: сборка ещё не опубликована?' }

    if ((Test-Path -LiteralPath $StatePath) -and -not $Verify) {
        $local = Read-Manifest (Get-Content -LiteralPath $StatePath)
    } else {
        $local = @{}
        foreach ($rel in $remote.Keys) {
            $full = Join-Path $Root $rel
            if (Test-Path -LiteralPath $full -PathType Leaf) {
                $local[$rel] = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    }

    $need = @(foreach ($rel in $remote.Keys) {
        if ($local[$rel] -ne $remote[$rel] -or -not (Test-Path -LiteralPath (Join-Path $Root $rel) -PathType Leaf)) { $rel }
    })
    $gone = @(foreach ($rel in $local.Keys) { if (-not $remote.ContainsKey($rel)) { $rel } })

    foreach ($rel in $gone) {
        $full = Join-Path $Root $rel
        if (Test-Path -LiteralPath $full) { Remove-Item -LiteralPath $full -Force }
    }

    if ($need.Count -gt 0) {
        Write-Host "Скачиваю изменённых файлов: $($need.Count)"
        $need | Sort-Object | Select-Object -First 15 | ForEach-Object { Write-Host "  $_" }
        if ($need.Count -gt 15) { Write-Host "  ... и ещё $($need.Count - 15)" }
        $pack = (Invoke-Remote 'pack' $need | Select-Object -Last 1).Trim()
        $tmp = Join-Path $env:TEMP ('colobot-sync-{0}.tgz' -f [guid]::NewGuid().ToString('N'))
        try {
            & scp -q @SshOpts "$($Cfg.SshHost):$pack" $tmp
            if ($LASTEXITCODE -ne 0) { throw "scp завершился с кодом $LASTEXITCODE" }
            & tar -xzf $tmp -C $Root
            if ($LASTEXITCODE -ne 0) { throw "tar завершился с кодом $LASTEXITCODE" }
        } finally {
            Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
            Invoke-Remote "done $pack" | Out-Null
        }
    } else {
        Write-Host 'Всё актуально.'
    }
    if ($gone.Count -gt 0) { Write-Host "Удалено устаревших файлов: $($gone.Count)" }

    # Состояние записываем только после успешной распаковки
    $lines = foreach ($rel in $remote.Keys) { '{0}  {1}' -f $remote[$rel], $rel }
    Set-Content -LiteralPath $StatePath -Value $lines -Encoding UTF8
}

function Send-Log {
    param([int]$ExitCode)
    $log = @('log.txt', 'saves\log.txt') | ForEach-Object { Join-Path $Root $_ } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Sort-Object { (Get-Item -LiteralPath $_).LastWriteTime } -Descending | Select-Object -First 1
    if (-not $log) { Write-Host 'log.txt не найден, отправлять нечего.'; return }
    $name = '{0:yyyyMMdd-HHmmss}-{1}-exit{2}.txt' -f (Get-Date), $env:COMPUTERNAME, $ExitCode
    & scp -q @SshOpts $log "$($Cfg.SshHost):$($Cfg.LogDir)/$name"
    if ($LASTEXITCODE -eq 0) { Write-Host "Лог отправлен на сервер: $name" }
    else { Write-Warning 'Не удалось отправить лог.' }
}

function Start-Game {
    $exe = Join-Path $Root 'colobot.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Нет $exe : запусти без -NoUpdate" }

    $gameArgs = @()
    if ($Scene) {
        $gameArgs = @('-runscene', $Scene)
    } elseif (-not $Menu) {
        $launch = Join-Path $Root 'launch.txt'
        if (Test-Path -LiteralPath $launch) {
            $line = Get-Content -LiteralPath $launch |
                Where-Object { $_.Trim() -and -not $_.TrimStart().StartsWith('#') } | Select-Object -First 1
            if ($line) { $gameArgs = @($line.Trim() -split '\s+') }
        }
    }

    Write-Host ('Запускаю: colobot.exe {0}' -f ($gameArgs -join ' '))
    $startArgs = @{ FilePath = $exe; WorkingDirectory = $Root; PassThru = $true }
    if ($gameArgs.Count -gt 0) { $startArgs.ArgumentList = $gameArgs }
    $proc = Start-Process @startArgs
    $null = $proc.Handle  # без этого ExitCode после выхода бывает пустым
    if ($NoWait) { return }

    Write-Host 'Игра запущена. Когда выйдешь из неё, лог уйдёт на сервер.'
    $proc.WaitForExit()
    Send-Log $proc.ExitCode
}

try {
    Stop-Game
    if (-not $NoUpdate) { Update-Game }
    if (-not $NoLaunch) { Start-Game }
} catch {
    Write-Host ''
    Write-Host "Ошибка: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Message -match 'ssh|scp') {
        Write-Host "Проверь, что 'ssh $($Cfg.SshHost)' из PowerShell заходит на сервер без пароля. Хост задаётся в play.cfg."
    }
    exit 1
}
