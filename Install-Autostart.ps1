#requires -Version 5.1
<#
.SYNOPSIS
  为 DiskWriteMonitor 安装/移除「登录时自动启动」。

.DESCRIPTION
  优先注册计划任务(登录触发); 如果当前权限不允许操作任务计划程序,
  自动降级为「启动文件夹 + VBS 隐藏启动」方案, 两者效果一致。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Action Install
  powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Action Uninstall
  powershell -ExecutionPolicy Bypass -File .\Install-Autostart.ps1 -Action Status
#>
param(
    [ValidateSet('Install', 'Uninstall', 'Status')]
    [string]$Action = 'Status',
    [string]$Root = $PSScriptRoot,
    [string]$TaskName = '',
    [ValidateSet('Auto', 'Task', 'Startup')]
    [string]$Method = 'Auto',
    [string]$ExePath = ''
)

$ErrorActionPreference = 'Stop'
$configPath = Join-Path $Root 'config.json'
$engine     = Join-Path $Root 'DiskWriteMonitor.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$vbsPath    = Join-Path $startupDir 'DiskWriteMonitor.vbs'
$cmdPath    = Join-Path $startupDir 'DiskWriteMonitor.cmd'

if (-not (Test-Path -LiteralPath $engine)) { throw "找不到引擎脚本: $engine" }
if (-not $TaskName) {
    $TaskName = 'DSH-DiskWriteMonitor'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $j = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.autostart -and $j.autostart.taskName) { $TaskName = $j.autostart.taskName }
        } catch { }
    }
}

$taskLog   = Join-Path $Root 'data\task.out.log'
$runner    = Join-Path $Root 'runner.cmd'
$psArgs    = '-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Root "{2}"' -f $engine, $configPath, $Root
$psArgsRun = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -Root "{2}"' -f $engine, $configPath, $Root

# 用 cmd 包装一层, 把引擎的所有输出和异常都落进 data\task.out.log
function Write-Runner {
    $lines = @(
        '@echo off',
        ('powershell.exe ' + $psArgs + ' >> "{0}" 2>&1' -f $taskLog)
    )
    Set-Content -LiteralPath $runner -Value ($lines -join "`r`n") -Encoding ASCII
}

function Get-EngineState {
    $pidFile = Join-Path $Root 'data\engine.pid'
    if (-not (Test-Path -LiteralPath $pidFile)) { return '未运行' }
    $enginePid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if (Get-Process -Id $enginePid -ErrorAction SilentlyContinue) { return "运行中 (PID $enginePid)" }
    return '进程已退出 (pid 文件残留)'
}

function Install-ViaTask {
    # 有 exe 就优先用 exe --engine, 否则退回 cmd 包装
    if (-not $ExePath) { $ExePath = Join-Path $Root 'DiskWriteMonitor.exe' }
    if (Test-Path -LiteralPath $ExePath) {
        # 一个动作搞定: --autostart = 拉起引擎 + 托盘界面
        $act = New-ScheduledTaskAction -Execute $ExePath -Argument '--autostart' -WorkingDirectory $Root
    } else {
        Write-Runner
        $act = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/c "{0}"' -f $runner) -WorkingDirectory $Root
    }
    $trg = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    # 心跳触发器: 每 10 分钟尝试启动一次; 已在跑时由单实例保护自动忽略
    # 注意: RepetitionDuration 不能用 TimeSpan::MaxValue, 任务计划程序会判为越界, 这里用 3650 天
    $hb = $null
    try {
        $hb = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(2)) `
            -RepetitionInterval (New-TimeSpan -Minutes 10) -RepetitionDuration (New-TimeSpan -Days 3650)
    } catch { $hb = $null }
    $triggers = if ($hb) { @($trg, $hb) } else { @($trg) }
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $act -Trigger $triggers -Settings $set `
        -Principal $principal -Description '磁盘写入监视器 - 登录时启动, 并每 10 分钟心跳拉起' -Force | Out-Null
}

function Install-ViaStartup {
    if (-not (Test-Path -LiteralPath $startupDir)) { New-Item -ItemType Directory -Force -Path $startupDir | Out-Null }
    # VBS 以 0 号窗口模式启动, 完全无窗口闪烁
    $quoted = 'powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""{0}"" -ConfigPath ""{1}"" -Root ""{2}"""' -f $engine, $configPath, $Root
    if ($ExePath -and (Test-Path -LiteralPath $ExePath)) {
    $quoted = '"""' + $ExePath + '"" --autostart"'
    }
    $vbs = @"
' DiskWriteMonitor autostart (hidden window)
Dim sh
Set sh = CreateObject("WScript.Shell")
sh.Run $quoted, 0, False
"@
    Set-Content -LiteralPath $vbsPath -Value $vbs -Encoding ASCII
    # 兜底: 若 VBS 被安全软件拦截, 用户可手动双击这个 cmd
    $cmdTarget = if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { '"' + $ExePath + '" --autostart' } else { 'powershell.exe ' + $psArgs }
    $cmd = @"
@echo off
start "" /min $cmdTarget
"@
    Set-Content -LiteralPath $cmdPath -Value $cmd -Encoding ASCII
}

function Register-TaskViaSchtasks {
    # 不用 CIM, 直接调 schtasks.exe; 同样带 10 分钟心跳
    $action = if ($ExePath -and (Test-Path -LiteralPath $ExePath)) { '"' + $ExePath + '" --autostart' } else { 'cmd.exe /c "' + $runner + '"' }
    $common = @('/create', '/tn', $TaskName, '/tr', $action, '/f', '/rl', 'LIMITED')
    $r = & schtasks.exe @common '/sc', 'onlogon' 2>&1
    if ($LASTEXITCODE -ne 0) { throw ("schtasks 登录触发注册失败: " + ($r -join ' ')) }
    & schtasks.exe @common '/sc', 'minute', '/mo', '10' 2>&1 | Out-Null
}

function Uninstall-All {
    $removed = @()
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($t) {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; $removed += "计划任务 $TaskName" }
        catch { Write-Host "  计划任务删除失败: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    foreach ($f in @($vbsPath, $cmdPath)) {
        if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force; $removed += (Split-Path -Leaf $f) }
    }
    if ($removed.Count -eq 0) { Write-Host '[跳过] 没有找到任何自启动项' -ForegroundColor Yellow }
    else { Write-Host ('[成功] 已移除: ' + ($removed -join ', ')) -ForegroundColor Green }

    $pidFile = Join-Path $Root 'data\engine.pid'
    if (Test-Path -LiteralPath $pidFile) {
        $enginePid = (Get-Content -LiteralPath $pidFile -Raw).Trim()
        if (Get-Process -Id $enginePid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $enginePid -Force -ErrorAction SilentlyContinue
            Write-Host "  已停止正在运行的引擎 PID $enginePid"
        }
        Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'Status' {
        $hasTask = $null -ne (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
        $hasVbs  = Test-Path -LiteralPath $vbsPath

        Write-Host '=== 自启动状态 ===' -ForegroundColor Cyan
        Write-Host ("  计划任务 : {0}" -f $(if ($hasTask) { "已安装 ($TaskName)" } else { '未安装' }))
        Write-Host ("  启动文件夹: {0}" -f $(if ($hasVbs) { "已安装 ($vbsPath)" } else { '未安装' }))
        Write-Host ("  引擎进程 : {0}" -f (Get-EngineState))
        if ($hasTask) {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
            if ($info) { Write-Host ("  上次运行 : {0}  结果 0x{1:X}" -f $info.LastRunTime, $info.LastTaskResult) }
        }
        Write-Host ("  启动目录 : {0}" -f $startupDir)
    }

    'Install' {
        $done = $false
        $how = ''
        if ($Method -ne 'Startup') {
            try {
                Install-ViaTask
                $done = $true; $how = '计划任务 (CIM)'
            } catch {
                Write-Host ("  CIM 方式不可用: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
                try {
                    Register-TaskViaSchtasks
                    $done = $true; $how = '计划任务 (schtasks)'
                } catch {
                    Write-Host ("  schtasks 方式也不可用: {0}" -f $_.Exception.Message) -ForegroundColor DarkYellow
                }
            }
        }
        if ($done) {
            Write-Host "[成功] 已注册计划任务: $TaskName ($how, 登录触发 + 每 10 分钟心跳)" -ForegroundColor Green
        } else {
            if ($Method -eq 'Task') { throw '计划任务方式失败, 且已指定 -Method Task' }
            try {
                Install-ViaStartup
                Write-Host "[成功] 已安装到启动文件夹 (无需管理员权限)" -ForegroundColor Green
                Write-Host ("  {0}" -f $vbsPath)
                Write-Host ("  {0}" -f $cmdPath)
            } catch {
                Write-Host ("[失败] 启动文件夹也写不进去: {0}" -f $_.Exception.Message) -ForegroundColor Red
                Write-Host '  请右键以管理员身份运行本程序, 或手动把它放进「启动」文件夹。' -ForegroundColor Yellow
            }
        }
        Write-Host ''
        Write-Host ("  引擎命令 : {0}" -f $(if ($ExePath) { "$ExePath --engine" } else { "powershell.exe $psArgs" }))
        Write-Host ("  数据目录 : {0}" -f (Join-Path $Root 'data'))
        Write-Host ("  引擎状态 : {0}" -f (Get-EngineState))
    }

    'Uninstall' { Uninstall-All }
}
