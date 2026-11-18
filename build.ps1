#requires -Version 5.1
<#
  一键构建 DiskWriteMonitor.exe
  依赖: Windows 自带的 .NET Framework 编译器 csc.exe (无需 Visual Studio)
#>
param(
    [string]$Root = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

# 找 csc.exe
$csc = $null
foreach ($p in @(
    "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe",
    "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319\csc.exe"
)) {
    if (Test-Path -LiteralPath $p) { $csc = $p; break }
}
if (-not $csc) { throw '找不到 csc.exe（需要 .NET Framework 4.x）' }
Write-Host "编译器: $csc" -ForegroundColor Cyan

# 确保脚本是 UTF-8 with BOM（PowerShell 5.1 读中文必需）
$bom = New-Object System.Text.UTF8Encoding($true)
foreach ($f in @('DiskWriteMonitor.ps1', 'DiskWriteDashboard.ps1', 'Install-Autostart.ps1')) {
    $path = Join-Path $Root $f
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        Write-Host "补 BOM: $f" -ForegroundColor Yellow
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($path, $text, $bom)
    }
    # 语法检查
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errs)
    if ($errs.Count) {
        $errs | Select-Object -First 5 | ForEach-Object { "  L$($_.Extent.StartLineNumber): $($_.Message)" }
        throw "语法错误: $f"
    }
}

$out = Join-Path $Root 'DiskWriteMonitor.exe'
if (Test-Path $out) { Remove-Item $out -Force }

$args = @(
    '/nologo', '/target:winexe', '/optimize+', '/platform:anycpu',
    "/out:$out",
    "/win32icon:$(Join-Path $Root 'src\app.ico')",
    "/resource:$(Join-Path $Root 'DiskWriteMonitor.ps1'),EngineScript",
    "/resource:$(Join-Path $Root 'DiskWriteDashboard.ps1'),DashboardScript",
    "/resource:$(Join-Path $Root 'Install-Autostart.ps1'),InstallerScript",
    "/resource:$(Join-Path $Root 'config.default.json'),DefaultConfig",
    "/resource:$(Join-Path $Root 'src\app.ico'),AppIcon",
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Drawing.dll',
    (Join-Path $Root 'src\Launcher.cs'),
    (Join-Path $Root 'src\AssemblyInfo.cs')
)
& $csc @args
if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }

"构建完成: $out ($([math]::Round((Get-Item $out).Length / 1KB, 1)) KB)" | Write-Host -ForegroundColor Green
