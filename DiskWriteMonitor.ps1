#requires -Version 5.1
<#
.SYNOPSIS
  DiskWriteMonitor 引擎 v3 —— 内存只留最近 1 小时, 其余按「保存粒度」滚动落盘。

.DESCRIPTION
  数据流:
    1 秒采样 -------------------------------------------------------------+
      ├─ 环形缓冲(内存, 60 分钟) ----------------------> 10min / 30min / 1h 窗口
      └─ 当前桶(内存) --每当桶走完一个"保存粒度"--> 落盘成 buckets\*.json
                                                    └--> 1天 / 1个月 窗口(读文件)
                     └--每次封桶累加--> lifetime.json ---> 安装至今

  可配置两项:
    persist.granularitySec  保存粒度(桶长): 3600=每小时一个文件, 600=每 10 分钟
    persist.flushSec        保存频率: 未封桶的当前数据多久写一次检查点

.PARAMETER IntervalMs   采样间隔毫秒
.PARAMETER DurationSec  运行时长秒, 0 = 一直运行
.PARAMETER ArchiveOnly  只跑一次归档
.PARAMETER DryRun       归档演练
#>
param(
    [int]$IntervalMs = 0,
    [int]$DurationSec = 0,
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'config.json'),
    [string]$Root = $PSScriptRoot,
    [switch]$ArchiveOnly,
    [switch]$DryRun,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
$script:Root = $Root

# ---------------- 配置 ----------------
$defaults = @{
    sampleIntervalMs = 1000
    dataDir          = 'data'
    historyPoints    = 180
    windowPublishSec = 5
    rawCsv           = $false
    persist          = @{
        granularitySec = 3600
        flushSec       = 300
    }
    archive          = @{
        enabled = $true; checkEverySec = 900; keepMonths = 6
        archiveRoot = 'archive'; watchFolders = @(); olderThanDays = 30
        compress = $true; dryRun = $false; moveInsteadOfZip = $false
    }
}
$cfg = $defaults
if (Test-Path -LiteralPath $ConfigPath) {
    try {
        $loaded = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($k in $loaded.PSObject.Properties.Name) {
            if ($k -in @('persist', 'archive') -and $loaded.$k) {
                foreach ($sk in $loaded.$k.PSObject.Properties.Name) { $cfg[$k][$sk] = $loaded.$k.$sk }
            } elseif ($k -ne 'autostart') { $cfg[$k] = $loaded.$k }
        }
    } catch { Write-Warning "配置读取失败, 使用默认值: $($_.Exception.Message)" }
}
if ($IntervalMs -gt 0) { $cfg.sampleIntervalMs = $IntervalMs }
if ($DryRun) { $cfg.archive.dryRun = $true }
$script:granularitySec = [int]$cfg.persist.granularitySec
$script:intervalMs     = [int]$cfg.sampleIntervalMs
$script:flushSecV      = [double]$cfg.persist.flushSec
$script:configStamp    = if (Test-Path -LiteralPath $ConfigPath) { (Get-Item -LiteralPath $ConfigPath).LastWriteTimeUtc } else { [datetime]::MinValue }
$script:lastConfigCheck = [datetime]::MinValue
$script:granularityDirty = $false
if ($script:granularitySec -lt 10) { $script:granularitySec = 10 }
$script:flushSecV = [double]$cfg.persist.flushSec

function Resolve-RootedPath([string]$p) {
    if ([System.IO.Path]::IsPathRooted($p)) { return $p }
    return (Join-Path $script:Root $p)
}

$dataDir     = Resolve-RootedPath $cfg.dataDir
$archiveRoot = Resolve-RootedPath $cfg.archive.archiveRoot
$bucketDir   = Join-Path $dataDir 'buckets'
$sessionDir  = Join-Path $dataDir 'sessions'
$stateFile   = Join-Path $dataDir 'state.json'
$currentFile = Join-Path $dataDir 'current-session.json'
$lifetimeFile = Join-Path $dataDir 'lifetime.json'
$pidFile     = Join-Path $dataDir 'engine.pid'
$logFile     = Join-Path $dataDir 'engine.log'

foreach ($d in @($dataDir, $archiveRoot, $bucketDir, $sessionDir)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

# 任务计划程序下 TEMP 可能指向不存在/不可写的目录, 会导致 Add-Type 编译失败
foreach ($v in @('TEMP', 'TMP')) {
    $cur = [System.Environment]::GetEnvironmentVariable($v)
    $ok = $false
    if ($cur) {
        try {
            $probe = Join-Path $cur ('.dwm-probe-' + [guid]::NewGuid().ToString('N') + '.tmp')
            Set-Content -LiteralPath $probe -Value 'x' -ErrorAction Stop
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            $ok = $true
        } catch { $ok = $false }
    }
    if (-not $ok) {
        $tmpDir = Join-Path $dataDir 'tmp'
        if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null }
        [System.Environment]::SetEnvironmentVariable($v, $tmpDir)
    }
}

function Write-Log([string]$msg, [string]$level = 'INFO') {
    if ($Quiet -and $level -eq 'INFO' -and $msg -notmatch '引擎') { return }
    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $level, $msg
    Write-Host $line
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 } catch { }
}

function Reload-Config {
    try {
        $j = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.sampleIntervalMs) { $script:intervalMs = [int]$j.sampleIntervalMs }
        if ($j.persist) {
            if ($j.persist.granularitySec) {
                $g = [int]$j.persist.granularitySec
                if ($g -lt 10) { $g = 10 }
                if ($g -ne $script:granularitySec) {
                    $script:granularitySec = $g
                    $script:granularityDirty = $true
                }
            }
            if ($j.persist.flushSec) { $script:flushSecV = [double]$j.persist.flushSec }
        }
        if ($j.archive) {
            foreach ($ak in $j.archive.PSObject.Properties.Name) { $cfg.archive[$ak] = $j.archive.$ak }
        }
        Write-Log ("配置已热更新: 采样 {0}ms, 粒度 {1}s, 检查点 {2}s" -f $script:intervalMs, $script:granularitySec, $script:flushSecV)
    } catch { Write-Log ("配置热更新失败: {0}" -f $_.Exception.Message) 'WARN' }
}

function Get-BucketStart([datetime]$t, [int]$span) {
    $ticks = $t.Ticks
    $step = [int64]$span * [TimeSpan]::TicksPerSecond
    return (New-Object datetime(($ticks - ($ticks % $step))))
}
function Get-BucketKey([datetime]$t) { return $t.ToString('yyyyMMddTHHmmss') }

# ---------------- 归档 ----------------
function Compress-ToZip([string]$sourceFile, [string]$destZip) {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $dir = Split-Path -Parent $destZip
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    if (Test-Path -LiteralPath $destZip) { Remove-Item -LiteralPath $destZip -Force }
    $zip = [System.IO.Compression.ZipFile]::Open($destZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zip, $sourceFile, (Split-Path -Leaf $sourceFile), [System.IO.Compression.CompressionLevel]::Optimal)
    } finally { $zip.Dispose() }
}

function Invoke-Archive {
    $a = $cfg.archive
    if (-not $a.enabled) { return }
    $dry = [bool]$a.dryRun
    $moved = 0; $zipped = 0; $purged = 0; $freed = 0L
    $cutoff = (Get-Date).AddDays(-[double]$a.olderThanDays)

    # 1) 旧桶文件压缩进 archive\buckets\yyyy-MM\
    foreach ($f in @(Get-ChildItem -LiteralPath $bucketDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt $cutoff })) {
        if ($dry) { Write-Log "[DRY] 将归档桶 $($f.Name)" 'ARCH'; $moved++; continue }
        try {
            $destDir = Join-Path (Join-Path $archiveRoot 'buckets') $f.LastWriteTime.ToString('yyyy-MM')
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Compress-ToZip $f.FullName (Join-Path $destDir ($f.Name + '.zip'))
            $freed += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force
            $moved++; $zipped++
        } catch { Write-Log "桶归档失败($($f.Name)): $($_.Exception.Message)" 'WARN' }
    }

    # 2) 旧会话记录压缩
    foreach ($f in @(Get-ChildItem -LiteralPath $sessionDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
                     Where-Object { $_.LastWriteTime -lt $cutoff })) {
        if ($dry) { $moved++; continue }
        try {
            $destDir = Join-Path (Join-Path $archiveRoot 'sessions') $f.LastWriteTime.ToString('yyyy-MM')
            if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
            Compress-ToZip $f.FullName (Join-Path $destDir ($f.Name + '.zip'))
            $freed += $f.Length
            Remove-Item -LiteralPath $f.FullName -Force
            $moved++; $zipped++
        } catch { Write-Log "会话归档失败($($f.Name)): $($_.Exception.Message)" 'WARN' }
    }

    # 3) 观察目录
    foreach ($wf in @($a.watchFolders)) {
        if ([string]::IsNullOrWhiteSpace($wf)) { continue }
        $src = Resolve-RootedPath $wf
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $srcName = (Get-Item -LiteralPath $src).Name
        foreach ($f in @(Get-ChildItem -LiteralPath $src -Recurse -File -ErrorAction SilentlyContinue |
                         Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -notlike "$archiveRoot*" })) {
            $rel = $f.FullName.Substring($src.Length).TrimStart('\')
            $monthDir = Join-Path (Join-Path $archiveRoot $srcName) (Get-Date).ToString('yyyy-MM')
            $parent = Split-Path -Parent $rel
            $destDir = if ($parent) { Join-Path $monthDir $parent } else { $monthDir }
            if ($dry) { $moved++; continue }
            try {
                if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
                if ($a.compress -and -not $a.moveInsteadOfZip) {
                    Compress-ToZip $f.FullName (Join-Path $destDir ($f.Name + '.zip'))
                    Remove-Item -LiteralPath $f.FullName -Force
                    $zipped++
                } else {
                    Move-Item -LiteralPath $f.FullName -Destination (Join-Path $destDir $f.Name) -Force
                }
                $moved++; $freed += $f.Length
            } catch { Write-Log "归档失败($($f.FullName)): $($_.Exception.Message)" 'WARN' }
        }
    }

    # 4) 保留期清理
    if ($a.keepMonths -gt 0) {
        $limitKey = (Get-Date).AddMonths(-[int]$a.keepMonths).ToString('yyyy-MM')
        foreach ($monthDir in @(Get-ChildItem -LiteralPath $archiveRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -match '^\d{4}-\d{2}$' })) {
            if ([string]::CompareOrdinal($monthDir.Name, $limitKey) -ge 0) { continue }
            if ($dry) { $purged++; continue }
            try { Remove-Item -LiteralPath $monthDir.FullName -Recurse -Force; $purged++ }
            catch { Write-Log "清理失败: $($_.Exception.Message)" 'WARN' }
        }
    }

    if ($moved -gt 0 -or $zipped -gt 0 -or $purged -gt 0) {
        Write-Log ("归档{0}: 处理 {1} 个, 压缩 {2} 个, 清理 {3} 个目录, 释放 {4} MB" -f
            $(if ($dry) { '(演练)' } else { '完成' }), $moved, $zipped, $purged, [math]::Round($freed / 1MB, 2)) 'ARCH'
    }
}

if ($ArchiveOnly) { Invoke-Archive; return }

# 单实例保护(1): pid 文件
if (Test-Path -LiteralPath $pidFile) {
    $existing = (Get-Content -LiteralPath $pidFile -Raw).Trim()
    if ($existing -and (Get-Process -Id $existing -ErrorAction SilentlyContinue)) {
        Write-Log "已有引擎在运行 (PID $existing), 本次退出" 'WARN'; return
    }
}

# 单实例保护(2): 命名互斥体, 比 pid 文件可靠(进程被杀后自动释放)
$mutexName = 'Local\DiskWriteMonitorEngine_' + [Math]::Abs($dataDir.ToLowerInvariant().GetHashCode())
$script:engineMutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $script:engineMutex.WaitOne(0)) {
    Write-Log "另一个引擎实例正在运行(互斥体), 本次退出" 'WARN'; return
}

# ---------------- 载入磁盘上的桶(近一小时之外的数据源) ----------------
function Read-JsonFile([string]$path) {
    try { return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

$bucketIndex = @{}     # bucketKey -> @{ start=datetime; programs=@{name=bytes} }
foreach ($f in @(Get-ChildItem -LiteralPath $bucketDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
    $b = Read-JsonFile $f.FullName
    if (-not $b -or -not $b.programs) { continue }
    $map = @{}
    foreach ($pn in $b.programs.PSObject.Properties.Name) { $map[$pn] = [double]$b.programs.$pn }
    $rmap = @{}
    if ($b.reads) { foreach ($pn in $b.reads.PSObject.Properties.Name) { $rmap[$pn] = [double]$b.reads.$pn } }
    $bucketIndex[$f.BaseName] = @{ start = [datetime]::Parse($b.start); programs = $map; reads = $rmap }
}

$lifetime = @{}
$lifetimeRead = @{}
$lifetimeSrc = 'none'
# 依次尝试: 主文件 -> 备份 -> 从历史桶重建。三处都丢才算真丢
foreach ($candidate in @($lifetimeFile, ($lifetimeFile + '.bak'))) {
    if ($lifetimeSrc -ne 'none') { break }
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $lt = Read-JsonFile $candidate
    if (-not $lt) { continue }
    if ($lt.programs) { foreach ($pn in $lt.programs.PSObject.Properties.Name) { $lifetime[$pn] = [double]$lt.programs.$pn } }
    if ($lt.reads) { foreach ($pn in $lt.reads.PSObject.Properties.Name) { $lifetimeRead[$pn] = [double]$lt.reads.$pn } }
    if ($lifetime.Count -gt 0 -or $lifetimeRead.Count -gt 0) { $lifetimeSrc = $candidate }
}
if ($lifetimeSrc -eq 'none' -and (Test-Path -LiteralPath $bucketDir)) {
    $oldBuckets = @(Get-ChildItem -LiteralPath $bucketDir -Filter *.json -File -ErrorAction SilentlyContinue)
    foreach ($f in $oldBuckets) {
        $b = Read-JsonFile $f.FullName
        if (-not $b) { continue }
        if ($b.programs) { foreach ($pn in $b.programs.PSObject.Properties.Name) { $lifetime[$pn] = [double]$lifetime[$pn] + [double]$b.programs.$pn } }
        if ($b.reads) { foreach ($pn in $b.reads.PSObject.Properties.Name) { $lifetimeRead[$pn] = [double]$lifetimeRead[$pn] + [double]$b.reads.$pn } }
    }
    if ($oldBuckets.Count -gt 0) { $lifetimeSrc = 'rebuilt' }
}
if ($lifetimeSrc -eq 'rebuilt') { Write-Log ("lifetime.json 丢失, 已从 {0} 个历史桶重建累计" -f $oldBuckets.Count) }
elseif ($lifetimeSrc -eq 'none') { Write-Log 'lifetime.json 不存在, 视作首次安装' }
elseif ($lifetimeSrc -like '*.bak') { Write-Log 'lifetime.json 损坏, 已用备份恢复' }

# 上次异常退出的检查点 -> 补成正式会话, 并恢复未封桶的那部分
$curBucket = @{}
$curBucketRead = @{}
$bucketStart = Get-BucketStart (Get-Date) $granularitySec
$recoveredTotals = $null
if (Test-Path -LiteralPath $currentFile) {
    $stale = Read-JsonFile $currentFile
    if ($stale -and $stale.sessionId) {
        try {
            if ($stale.bucket -and $stale.bucketStart) {
                $bucketStart = [datetime]::Parse($stale.bucketStart)
                foreach ($pn in $stale.bucket.PSObject.Properties.Name) { $curBucket[$pn] = [double]$stale.bucket.$pn }
                if ($stale.bucketReads) {
                    foreach ($pn in $stale.bucketReads.PSObject.Properties.Name) { $curBucketRead[$pn] = [double]$stale.bucketReads.$pn }
                }
            }
            $rec = [pscustomobject]@{
                sessionId = $stale.sessionId
                startedAt = $stale.startedAt
                endedAt   = (Get-Item -LiteralPath $currentFile).LastWriteTime.ToString('o')
                recovered = $true
                totals    = $stale.totals
            }
            $rec | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath (Join-Path $sessionDir ("{0}.json" -f $rec.sessionId)) -Encoding UTF8
            Write-Log "已恢复上次未正常结束的会话: $($rec.sessionId)" 'WARN'
        } catch { Write-Log "会话恢复失败: $($_.Exception.Message)" 'WARN' }
    }
    Remove-Item -LiteralPath $currentFile -Force -ErrorAction SilentlyContinue
}

# 自身完整性级别: 低完整性(<0x2000)只能看到很少进程, 用于提示用户
$script:integrity = 0x2000
try {
    $who = & whoami.exe /groups 2>$null
    foreach ($wline in $who) {
        if ($wline -match 'S-1-16-(\d+)') { $script:integrity = [int]$Matches[1]; break }
    }
} catch { }

Write-Log "环境 TEMP=$env:TEMP TMP=$env:TMP"; Write-Log ("引擎启动 v3 PID={0} 粒度={1}s 频率={2}s 已加载 {3} 个桶" -f $PID, $script:granularitySec, $script:flushSecV, $bucketIndex.Count)

# ---------------- 采样 ----------------
$src = @'
using System;
using System.Runtime.InteropServices;

public struct IoCounters
{
    public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
    public ulong ReadTransferCount,  WriteTransferCount,  OtherTransferCount;
}

[StructLayout(LayoutKind.Sequential)]
public struct MemCounters
{
    public uint cb;
    public uint PageFaultCount;
    public UIntPtr PeakWorkingSetSize;
    public UIntPtr WorkingSetSize;
    public UIntPtr QuotaPeakPagedPoolUsage;
    public UIntPtr QuotaPagedPoolUsage;
    public UIntPtr QuotaPeakNonPagedPoolUsage;
    public UIntPtr QuotaNonPagedPoolUsage;
    public UIntPtr PagefileUsage;
    public UIntPtr PeakPagefileUsage;
}

[StructLayout(LayoutKind.Sequential)]
public struct MemStatusEx
{
    public uint dwLength;
    public uint dwMemoryLoad;
    public ulong ullTotalPhys;
    public ulong ullAvailPhys;
    public ulong ullTotalPageFile;
    public ulong ullAvailPageFile;
    public ulong ullTotalVirtual;
    public ulong ullAvailVirtual;
    public ulong ullAvailExtendedVirtual;
}

public static class ProcessIo
{
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetProcessIoCounters(IntPtr hProcess, out IoCounters counters);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool CloseHandle(IntPtr h);

    const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;

    public static bool TryGet(int targetPid, out IoCounters c)
    {
        c = default(IoCounters);
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, targetPid);
        if (h == IntPtr.Zero) return false;
        try { return GetProcessIoCounters(h, out c); }
        finally { CloseHandle(h); }
    }

    [DllImport("psapi.dll", SetLastError = true)]
    static extern bool GetProcessMemoryInfo(IntPtr hProcess, out MemCounters counters, uint cb);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GlobalMemoryStatusEx(ref MemStatusEx buffer);

    const uint PROCESS_QUERY_INFORMATION = 0x0400;
    const uint PROCESS_VM_READ = 0x0010;

    // 工作集 + 页文件占用(swap)
    public static bool TryGetMem(int targetPid, out ulong workingSet, out ulong pageFile)
    {
        workingSet = 0; pageFile = 0;
        // 先用受限权限(覆盖绝大多数进程), 失败再要完整权限
        IntPtr h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ, false, targetPid);
        if (h == IntPtr.Zero) h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, false, targetPid);
        if (h == IntPtr.Zero) return false;
        try
        {
            MemCounters mc = new MemCounters();
            mc.cb = (uint)Marshal.SizeOf(typeof(MemCounters));
            if (!GetProcessMemoryInfo(h, out mc, mc.cb)) return false;
            workingSet = (ulong)mc.WorkingSetSize.ToUInt64();
            pageFile = (ulong)mc.PagefileUsage.ToUInt64();
            return true;
        }
        finally { CloseHandle(h); }
    }

    // 系统物理内存 / 提交 / 页文件
    public static bool TryGetSystem(out ulong totalPhys, out ulong availPhys, out ulong totalPage, out ulong availPage, out uint load)
    {
        totalPhys = 0; availPhys = 0; totalPage = 0; availPage = 0; load = 0;
        MemStatusEx ms = new MemStatusEx();
        ms.dwLength = (uint)Marshal.SizeOf(typeof(MemStatusEx));
        if (!GlobalMemoryStatusEx(ref ms)) return false;
        totalPhys = ms.ullTotalPhys; availPhys = ms.ullAvailPhys;
        totalPage = ms.ullTotalPageFile; availPage = ms.ullAvailPageFile;
        load = ms.dwMemoryLoad;
        return true;
    }

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr token);

    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr buf, int len, out int ret);

    // 自身完整性级别: 0x1000=低, 0x2000=中, 0x3000=高。低完整性看不到别的进程
    public static int GetSelfIntegrity()
    {
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(System.Diagnostics.Process.GetCurrentProcess().Handle, 0x0008, out token)) return 0;
        IntPtr buf = IntPtr.Zero;
        try
        {
            buf = Marshal.AllocHGlobal(64);
            int ret = 0;
            if (!GetTokenInformation(token, 25, buf, 64, out ret)) return 0;
            IntPtr sidPtr = Marshal.ReadIntPtr(buf);
            byte[] sid = new byte[32];
            Marshal.Copy(sidPtr, sid, 0, 8);
            int subCount = sid[1];
            if (subCount < 1) return 0;
            return sid[8 + 4 * (subCount - 1)] | (sid[9 + 4 * (subCount - 1)] << 8) | (sid[10 + 4 * (subCount - 1)] << 16) | (sid[11 + 4 * (subCount - 1)] << 24);
        }
        finally { if (buf != IntPtr.Zero) Marshal.FreeHGlobal(buf); CloseHandle(token); }
    }
}

// 专用工作集(任务管理器「内存」列口径): 走 PDH 性能计数器, 一次约 2ms
public static class PrivateMem
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PDH_FMT_COUNTERVALUE { public uint CStatus; public double doubleValue; }

    [StructLayout(LayoutKind.Sequential)]
    public struct PDH_FMT_COUNTERVALUE_ITEM { public IntPtr szName; public PDH_FMT_COUNTERVALUE FmtValue; }

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhOpenQuery(string szDataSource, IntPtr dwUserData, out IntPtr phQuery);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhAddCounter(IntPtr hQuery, string szFullCounterPath, IntPtr dwUserData, out IntPtr phCounter);

    [DllImport("pdh.dll")]
    static extern uint PdhCollectQueryData(IntPtr hQuery);

    [DllImport("pdh.dll")]
    static extern uint PdhCloseQuery(IntPtr hQuery);

    [DllImport("pdh.dll", CharSet = CharSet.Unicode)]
    static extern uint PdhGetFormattedCounterArray(IntPtr hCounter, uint dwFormat, ref uint lpdwBufferSize, out uint lpdwItemCount, IntPtr ItemBuffer);

    const uint PDH_FMT_DOUBLE = 0x00000200;
    const uint PDH_MORE_DATA = 0x800007D2;

    static IntPtr query = IntPtr.Zero;
    static IntPtr counter = IntPtr.Zero;

    static void EnsureOpen()
    {
        if (query != IntPtr.Zero) return;
        uint rc = PdhOpenQuery(null, IntPtr.Zero, out query);
        if (rc != 0) { query = IntPtr.Zero; return; }
        rc = PdhAddCounter(query, "\\Process(*)\\Working Set - Private", IntPtr.Zero, out counter);
        if (rc != 0) { PdhCloseQuery(query); query = IntPtr.Zero; counter = IntPtr.Zero; return; }
        PdhCollectQueryData(query);
    }

    public static System.Collections.Generic.Dictionary<string, double> Read()
    {
        var result = new System.Collections.Generic.Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        EnsureOpen();
        if (query == IntPtr.Zero) return result;
        if (PdhCollectQueryData(query) != 0) return result;

        uint size = 0; uint count = 0;
        uint rc = PdhGetFormattedCounterArray(counter, PDH_FMT_DOUBLE, ref size, out count, IntPtr.Zero);
        if (rc != PDH_MORE_DATA && rc != 0) return result;
        if (size == 0) return result;

        IntPtr buf = Marshal.AllocHGlobal((int)size);
        try
        {
            rc = PdhGetFormattedCounterArray(counter, PDH_FMT_DOUBLE, ref size, out count, buf);
            if (rc != 0) return result;
            int itemSize = Marshal.SizeOf(typeof(PDH_FMT_COUNTERVALUE_ITEM));
            for (int i = 0; i < count; i++)
            {
                IntPtr p = new IntPtr(buf.ToInt64() + (long)i * itemSize);
                PDH_FMT_COUNTERVALUE_ITEM item = (PDH_FMT_COUNTERVALUE_ITEM)Marshal.PtrToStructure(p, typeof(PDH_FMT_COUNTERVALUE_ITEM));
                if (item.szName == IntPtr.Zero) continue;
                string name = Marshal.PtrToStringUni(item.szName);
                if (string.IsNullOrEmpty(name)) continue;
                if (name.Equals("_Total", StringComparison.OrdinalIgnoreCase)) continue;
                if (name.Equals("Idle", StringComparison.OrdinalIgnoreCase)) continue;
                int hash = name.IndexOf('#');
                if (hash > 0) name = name.Substring(0, hash);
                double v = item.FmtValue.doubleValue;
                if (v <= 0) continue;
                double old;
                if (result.TryGetValue(name, out old)) result[name] = old + v;
                else result[name] = v;
            }
        }
        finally { Marshal.FreeHGlobal(buf); }
        return result;
    }
}
'@
if (-not ('ProcessIo' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

$seen        = @{}
$totalsRead  = @{}
$procPaths   = @{}
$ring        = New-Object System.Collections.Queue     # 最近 60 分钟: @{t;n;b;rb}
$ringLimit   = 3600
$totals      = @{}                                      # 本次会话累计
$history     = New-Object System.Collections.Generic.List[object]
$runStart    = Get-Date
$sessionId   = $runStart.ToString('yyyyMMdd-HHmmss')
$intervalSec = [double]$cfg.sampleIntervalMs / 1000.0
$historyPoints = [int]$cfg.historyPoints

$lastPublish = [datetime]::MinValue
$script:lastUiCheck = [datetime]::MinValue
$script:uiActive = $false
$lastFlush   = [datetime]::MinValue
$lastArchive = [datetime]::MinValue

Set-Content -LiteralPath $pidFile -Value $PID -Encoding ASCII

function Save-Lifetime {
    $o = @{}; $ro = @{}
    foreach ($k in $lifetime.Keys) { $o[$k] = [long]$lifetime[$k] }
    foreach ($k in $lifetimeRead.Keys) { $ro[$k] = [long]$lifetimeRead[$k] }
    $json = [pscustomobject]@{ updatedAt = (Get-Date).ToString('o'); programs = $o; reads = $ro } |
        ConvertTo-Json -Depth 4 -Compress
    # 原子写: 先写 .tmp 再替换, 并把好的上一版留成 .bak
    $tmp = $lifetimeFile + '.tmp'
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $lifetimeFile) {
        Copy-Item -LiteralPath $lifetimeFile -Destination ($lifetimeFile + '.bak') -Force -ErrorAction SilentlyContinue
    }
    Move-Item -LiteralPath $tmp -Destination $lifetimeFile -Force
}

function Flush-Bucket([datetime]$start, [hashtable]$data, [hashtable]$rdata) {
    if ($data.Count -eq 0 -and $rdata.Count -eq 0) { return }
    $key = Get-BucketKey $start
    $o = @{}; $ro = @{}
    foreach ($k in $data.Keys) {
        $o[$k] = [long]$data[$k]
        $lifetime[$k] = [double]$lifetime[$k] + $data[$k]
    }
    if ($rdata) {
        foreach ($k in $rdata.Keys) {
            $ro[$k] = [long]$rdata[$k]
            $lifetimeRead[$k] = [double]$lifetimeRead[$k] + $rdata[$k]
        }
    }
    $obj = [pscustomobject]@{
        start       = $start.ToString('o')
        end         = $start.AddSeconds($granularitySec).ToString('o')
        granularity = $granularitySec
        programs    = $o
        reads       = $ro
    }
    $path = Join-Path $bucketDir ("{0}.json" -f $key)
    $obj | ConvertTo-Json -Depth 5 -Compress | Set-Content -LiteralPath $path -Encoding UTF8
    $map = @{}; $rmap = @{}
    foreach ($k in $data.Keys) { $map[$k] = [double]$data[$k] }
    if ($rdata) { foreach ($k in $rdata.Keys) { $rmap[$k] = [double]$rdata[$k] } }
    $bucketIndex[$key] = @{ start = $start; programs = $map; reads = $rmap }
    Save-Lifetime
    Write-Log ("封桶 {0} -> {1} 个程序, 写 {2:N1} MB / 读 {3:N1} MB" -f $start.ToString('HH:mm:ss'), $data.Count,
        (($data.Values | Measure-Object -Sum).Sum / 1MB), (($rdata.Values | Measure-Object -Sum).Sum / 1MB))
}

function Save-Checkpoint([bool]$final = $false, [string]$endedAt = '') {
    if ($final) {
        $t = @{}
        foreach ($pn in $totals.Keys) { $t[$pn] = [long]$totals[$pn] }
        $obj = [pscustomobject]@{
            sessionId = $sessionId
            startedAt = $runStart.ToString('o')
            endedAt   = $endedAt
            recovered = $false
            totals    = $t
        }
        $out = Join-Path $sessionDir ("{0}.json" -f $sessionId)
        $obj | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $out -Encoding UTF8
        return $out
    }
    $b = @{}
    foreach ($pn in $curBucket.Keys) { $b[$pn] = [long]$curBucket[$pn] }
    $rb = @{}
    foreach ($pn in $curBucketRead.Keys) { $rb[$pn] = [long]$curBucketRead[$pn] }
    $obj = [pscustomobject]@{
        sessionId   = $sessionId
        startedAt   = $runStart.ToString('o')
        updatedAt   = (Get-Date).ToString('o')
        bucketStart = $bucketStart.ToString('o')
        bucket      = $b
        bucketReads = $rb
        totals      = $totals
    }
    $tmp = "$currentFile.tmp"
    $obj | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $currentFile -Force
}

function Add-Sum($sums, [string]$name, [double]$w, [double]$r) {
    if (-not $sums.ContainsKey($name)) { $sums[$name] = @{ w = 0.0; r = 0.0 } }
    $sums[$name].w += $w
    $sums[$name].r += $r
}

function Get-RingSums([double]$seconds) {
    $cut = (Get-Date).AddSeconds(-$seconds)
    $sums = @{}
    foreach ($e in $ring) {
        if ($e.t -lt $cut) { continue }
        Add-Sum $sums $e.n $e.b $e.rb
    }
    return $sums
}

function Get-DiskSums([double]$seconds) {
    # 近一小时之外: 从磁盘桶 + 当前未封桶的数据求和
    $cut = (Get-Date).AddSeconds(-$seconds)
    $sums = @{}
    foreach ($k in $bucketIndex.Keys) {
        $b = $bucketIndex[$k]
        if ($b.start -lt $cut) { continue }
        foreach ($pn in $b.programs.Keys) {
            $rv = 0.0
            if ($b.reads -and $b.reads.ContainsKey($pn)) { $rv = [double]$b.reads[$pn] }
            Add-Sum $sums $pn ([double]$b.programs[$pn]) $rv
        }
        # 只有读没有写的程序
        if ($b.reads) {
            foreach ($pn in $b.reads.Keys) {
                if (-not $b.programs.ContainsKey($pn)) { Add-Sum $sums $pn 0.0 ([double]$b.reads[$pn]) }
            }
        }
    }
    if ($bucketStart -ge $cut) {
        foreach ($pn in $curBucket.Keys) {
            $rv = 0.0
            if ($curBucketRead.ContainsKey($pn)) { $rv = [double]$curBucketRead[$pn] }
            Add-Sum $sums $pn ([double]$curBucket[$pn]) $rv
        }
        foreach ($pn in $curBucketRead.Keys) {
            if (-not $curBucket.ContainsKey($pn)) { Add-Sum $sums $pn 0.0 ([double]$curBucketRead[$pn]) }
        }
    }
    return $sums
}

function ConvertTo-TopList($sums, [int]$top = 15) {
    $arr = New-Object System.Collections.Generic.List[object]
    foreach ($k in $sums.Keys) {
        $v = $sums[$k]
        $path = ''
        if ($procPaths.ContainsKey($k)) { $path = $procPaths[$k] }
        $arr.Add([pscustomobject]@{
            name  = $k
            bytes = [long]$v.w
            rbytes = [long]$v.r
            path  = $path
        })
    }
    return @($arr | Sort-Object @{ Expression = { $_.bytes + $_.rbytes }; Descending = $true } | Select-Object -First $top)
}

try {
    while ($true) {
        # 单次采样异常不应结束整个引擎: 捕获后继续下一轮
        try {
        $now = Get-Date
        if ($DurationSec -gt 0 -and ($now - $runStart).TotalSeconds -ge $DurationSec) { break }

        # 配置热更新(每 3 秒看一次 config.json 的修改时间)
        if (($now - $script:lastConfigCheck).TotalSeconds -ge 3) {
            $script:lastConfigCheck = $now
            try {
                $stamp = (Get-Item -LiteralPath $ConfigPath -ErrorAction Stop).LastWriteTimeUtc
                if ($stamp -ne $script:configStamp) {
                    $script:configStamp = $stamp
                    Reload-Config
                }
            } catch { }
        }

        # 粒度被改过: 先把当前桶按旧粒度封口, 再按新粒度重新对齐
        if ($script:granularityDirty) {
            $script:granularityDirty = $false
            if ($curBucket.Count -gt 0 -or $curBucketRead.Count -gt 0) { Flush-Bucket $bucketStart $curBucket $curBucketRead }
            $curBucket = @{}
            $curBucketRead = @{}
            $bucketStart = Get-BucketStart $now $script:granularitySec
            Write-Log ("按新粒度重新对齐桶: {0} 秒" -f $script:granularitySec)
        }

        # 桶边界: 先封掉上一桶(数据卸载到磁盘), 再开新桶
        $wantStart = Get-BucketStart $now $script:granularitySec
        if ($wantStart -gt $bucketStart) {
            Flush-Bucket $bucketStart $curBucket $curBucketRead
            $curBucket = @{}
            $curBucketRead = @{}
            $bucketStart = $wantStart
        }

        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
            $procId = $p.Id
            try { $start = $p.StartTime; $procName = $p.ProcessName } catch { continue }
            $c = New-Object IoCounters
            if (-not [ProcessIo]::TryGet($procId, [ref]$c)) { continue }
            $key = "$procId|$($start.Ticks)"
            $totalW = [double]$c.WriteTransferCount
            $totalR = [double]$c.ReadTransferCount
            $deltaW = if ($seen.ContainsKey($key)) { [math]::Max(0, $totalW - $seen[$key][0]) } else { 0 }
            $deltaR = if ($seen.ContainsKey($key)) { [math]::Max(0, $totalR - $seen[$key][1]) } else { 0 }
            $seen[$key] = @($totalW, $totalR)

            # 记下程序的可执行路径(给看板取图标用)
            if (-not $procPaths.ContainsKey($procName)) {
                try { $pp = $p.Path } catch { $pp = '' }
                if ($pp) { $procPaths[$procName] = $pp }
            }
            $ws = 0L; $pf = 0L
            [void][ProcessIo]::TryGetMem($procId, [ref]$ws, [ref]$pf)
            $rows.Add([pscustomobject]@{ Key = $key; Process = $procName; Pid = $procId; Delta = $deltaW; RDelta = $deltaR; WS = $ws; PF = $pf })
        }
        $alive = @{}
        foreach ($r in $rows) { $alive[$r.Key] = $true }
        foreach ($k in @($seen.Keys)) { if (-not $alive.ContainsKey($k)) { $seen.Remove($k) } }

        # 专用工作集: 任务管理器口径, 一次约 2ms
        try { $script:privateWs = [PrivateMem]::Read() } catch { $script:privateWs = @{} }

        # 内存按程序聚合(同一软件多个进程相加)
        $memNow = @{}
        foreach ($r in $rows) {
            if ($r.WS -le 0 -and $r.PF -le 0) { continue }
            $nm = $r.Process
            if (-not $memNow.ContainsKey($nm)) { $memNow[$nm] = @{ ws = [long]0; pf = [long]0 } }
            $memNow[$nm].ws += $r.WS
            $memNow[$nm].pf += $r.PF
        }

        $rate = 0.0
        $rrate = 0.0
        $active = @($rows | Where-Object { $_.Delta -gt 0 -or $_.RDelta -gt 0 })
        foreach ($r in $active) {
            $rate += $r.Delta
            $rrate += $r.RDelta
            $n = $r.Process
            if ($r.Delta -gt 0) {
                $curBucket[$n] = [double]$curBucket[$n] + $r.Delta
                $totals[$n] = [double]$totals[$n] + $r.Delta
            }
            if ($r.RDelta -gt 0) {
                $curBucketRead[$n] = [double]$curBucketRead[$n] + $r.RDelta
                $totalsRead[$n] = [double]$totalsRead[$n] + $r.RDelta
            }
            $ring.Enqueue([pscustomobject]@{ t = $now; n = $n; b = [double]$r.Delta; rb = [double]$r.RDelta })
        }
        $rate = $rate / $intervalSec
        $rrate = $rrate / $intervalSec

        $cutRing = $now.AddSeconds(-$ringLimit)
        while ($ring.Count -gt 0 -and $ring.Peek().t -lt $cutRing) { [void]$ring.Dequeue() }

            $history.Add([pscustomobject]@{ t = [math]::Round(($now - $runStart).TotalSeconds, 1); ts = $now.ToString('HH:mm:ss'); rate = [math]::Round($rate, 0); rrate = [math]::Round($rrate, 0) })
        while ($history.Count -gt $historyPoints) { $history.RemoveAt(0) }

        # 有看板打开时按采样间隔发布(界面就能跟着采样刷新); 没看板时降到 30 秒一次, 减少自身写盘
        if (($now - $script:lastUiCheck).TotalSeconds -ge 5) {
            $script:lastUiCheck = $now
            $script:uiActive = $false
            try {
                $uiTick = Join-Path $dataDir 'ui.tick'
                if (Test-Path -LiteralPath $uiTick) {
                    $age = ($now - (Get-Item -LiteralPath $uiTick).LastWriteTime).TotalSeconds
                    if ($age -lt 15) { $script:uiActive = $true }
                }
            } catch { }
        }
        $publishEvery = if ($script:uiActive) { [Math]::Max(0.4, $script:intervalMs / 1000.0) } else { 30.0 }

        if (($now - $lastPublish).TotalSeconds -ge $publishEvery) {
            $lastPublish = $now
            $w10 = Get-RingSums 600
            $w30 = Get-RingSums 1800
            $w60 = Get-RingSums 3600
            $w1d = Get-DiskSums 86400
            $w1mo = Get-DiskSums (86400 * 30)

            # 先把所有桶(含当前未封桶)按小时和按天聚合一次
            $hourAgg = @{}; $dayAgg = @{}; $hourAggR = @{}; $dayAggR = @{}
            $addAgg = {
                param($startTime, $sumW, $sumR)
                $hk = $startTime.ToString('yyyy-MM-ddTHH')
                $dk = $startTime.ToString('yyyy-MM-dd')
                $hourAgg[$hk]  = [double]$hourAgg[$hk] + $sumW
                $dayAgg[$dk]   = [double]$dayAgg[$dk] + $sumW
                $hourAggR[$hk] = [double]$hourAggR[$hk] + $sumR
                $dayAggR[$dk]  = [double]$dayAggR[$dk] + $sumR
            }
            foreach ($k in $bucketIndex.Keys) {
                $b = $bucketIndex[$k]
                $sW = 0.0; $sR = 0.0
                foreach ($pn in $b.programs.Keys) { $sW += $b.programs[$pn] }
                if ($b.reads) { foreach ($pn in $b.reads.Keys) { $sR += $b.reads[$pn] } }
                & $addAgg $b.start $sW $sR
            }
            $curSumW = 0.0; $curSumR = 0.0
            foreach ($pn in $curBucket.Keys) { $curSumW += $curBucket[$pn] }
            foreach ($pn in $curBucketRead.Keys) { $curSumR += $curBucketRead[$pn] }
            if (($curSumW + $curSumR) -gt 0) { & $addAgg $bucketStart $curSumW $curSumR }

            $hourly = New-Object System.Collections.Generic.List[object]
            for ($i = 23; $i -ge 0; $i--) {
                $h = $now.AddHours(-$i)
                $hourly.Add([pscustomobject]@{ label = $h.ToString('HH:00'); bytes = [long][double]$hourAgg[$h.ToString('yyyy-MM-ddTHH')]; rbytes = [long][double]$hourAggR[$h.ToString('yyyy-MM-ddTHH')] })
            }
            $daily = New-Object System.Collections.Generic.List[object]
            for ($i = 29; $i -ge 0; $i--) {
                $d = $now.Date.AddDays(-$i)
                $daily.Add([pscustomobject]@{ label = $d.ToString('MM-dd'); bytes = [long][double]$dayAgg[$d.ToString('yyyy-MM-dd')]; rbytes = [long][double]$dayAggR[$d.ToString('yyyy-MM-dd')] })
            }
            # 安装至今 = 已封桶累计 + 当前未封桶(避免刚封完桶时快照偏小)
            $ltSums = @{}
            foreach ($k in $lifetime.Keys) {
                if (-not $ltSums.ContainsKey($k)) { $ltSums[$k] = @{ w = 0.0; r = 0.0 } }
                $ltSums[$k].w += $lifetime[$k]
            }
            foreach ($k in $lifetimeRead.Keys) {
                if (-not $ltSums.ContainsKey($k)) { $ltSums[$k] = @{ w = 0.0; r = 0.0 } }
                $ltSums[$k].r += $lifetimeRead[$k]
            }
            foreach ($pn in $curBucket.Keys) {
                if (-not $ltSums.ContainsKey($pn)) { $ltSums[$pn] = @{ w = 0.0; r = 0.0 } }
                $ltSums[$pn].w += $curBucket[$pn]
            }
            foreach ($pn in $curBucketRead.Keys) {
                if (-not $ltSums.ContainsKey($pn)) { $ltSums[$pn] = @{ w = 0.0; r = 0.0 } }
                $ltSums[$pn].r += $curBucketRead[$pn]
            }

            $memList = New-Object System.Collections.Generic.List[object]
            $seenNames = @{}
            foreach ($k in @($script:privateWs.Keys)) { $seenNames[$k] = $true }
            foreach ($k in $memNow.Keys) { $seenNames[$k] = $true }
            foreach ($k in $seenNames.Keys) {
                $mpath = ''
                if ($procPaths.ContainsKey($k)) { $mpath = $procPaths[$k] }
                $pws = 0L
                if ($script:privateWs.ContainsKey($k)) { $pws = [long]$script:privateWs[$k] }
                $totWs = 0L; $pfv = 0L
                if ($memNow.ContainsKey($k)) { $totWs = [long]$memNow[$k].ws; $pfv = [long]$memNow[$k].pf }
                if ($pws -le 0) { $pws = $totWs }
                if ($pws -le 0) { continue }
                $memList.Add([pscustomobject]@{ name = $k; pws = $pws; ws = $totWs; pf = $pfv; path = $mpath })
            }
            $memTop = @($memList | Sort-Object pws -Descending | Select-Object -First 12)

            $tp = [uint64]0; $ap = [uint64]0; $tpf = [uint64]0; $apf = [uint64]0; $load = 0
            [void][ProcessIo]::TryGetSystem([ref]$tp, [ref]$ap, [ref]$tpf, [ref]$apf, [ref]$load)
            $commitUsed = [long]([double]$tpf - [double]$apf)
            $usedPhys = [long]([double]$tp - [double]$ap)
            $pageCap = [long]([double]$tpf - [double]$tp)
            if ($pageCap -lt 0) { $pageCap = 0 }
            $sysMem = [pscustomobject]@{
                loadPct      = [int]$load
                totalPhys    = [long]$tp
                availPhys    = [long]$ap
                usedPhys     = [long]$usedPhys
                pageCapacity = [long]$pageCap
                commitUsed   = [long]$commitUsed
                commitLimit  = [long]$tpf
                integrity   = [int]$script:integrity
            }

            $state = [pscustomobject]@{
                ts           = $now.ToString('o')
                uptimeSec    = [math]::Round(($now - $runStart).TotalSeconds, 1)
                sessionId    = $sessionId
                totalRate    = [math]::Round($rate, 0)
                totalReadRate = [math]::Round($rrate, 0)
                processCount = $rows.Count
                activeCount  = $active.Count
                granularity  = $granularitySec
                history      = @($history | Select-Object -Last 120)
                hourly24     = $hourly.ToArray()
                daily30      = $daily.ToArray()
                windows      = [pscustomobject]@{
                    m10 = ConvertTo-TopList $w10 15
                    m30 = ConvertTo-TopList $w30 15
                    h1  = ConvertTo-TopList $w60 15
                    d1  = ConvertTo-TopList $w1d 15
                    mo1 = ConvertTo-TopList $w1mo 15
                    all = ConvertTo-TopList $ltSums 15
                }
                paths = $procPaths
                memory = $memTop
                sysmem = $sysMem
                current = [pscustomobject]@{
                    startedAt = $runStart.ToString('o')
                    totals    = ConvertTo-TopList $totals 10
                    reads     = ConvertTo-TopList $totalsRead 10
                }
            }
            # 心跳: 看板/排查用, 能区分"卡住"和"进程已死"
            try {
                Set-Content -LiteralPath (Join-Path $dataDir 'engine.heartbeat') `
                    -Value ("{0}|{1}" -f $now.ToString('o'), $PID) -Encoding ASCII
            } catch { }

            $tmp = "$stateFile.tmp"
            $state | ConvertTo-Json -Depth 6 -Compress | Set-Content -LiteralPath $tmp -Encoding UTF8
            Move-Item -LiteralPath $tmp -Destination $stateFile -Force
        }

        if (($now - $lastFlush).TotalSeconds -ge $script:flushSecV) {
            $lastFlush = $now
            try { Save-Checkpoint $false | Out-Null } catch { Write-Log "检查点失败: $($_.Exception.Message)" 'WARN' }
        }

        if ($cfg.archive.enabled -and ($now - $lastArchive).TotalSeconds -ge [double]$cfg.archive.checkEverySec) {
            $lastArchive = $now
            try { Invoke-Archive } catch { Write-Log "归档异常: $($_.Exception.Message)" 'WARN' }
        }

        } catch {
            Write-Log ("本轮采样异常(已跳过并继续): [{0}] {1}" -f $_.Exception.GetType().Name, $_.Exception.Message) 'WARN'
        }
        Start-Sleep -Milliseconds $script:intervalMs
    }
}
catch {
    Write-Log ("采样循环异常退出: [{0}] {1}" -f $_.Exception.GetType().Name, $_.Exception.Message) 'ERROR'
    Write-Log ("位置: {0}" -f $_.InvocationInfo.PositionMessage) 'ERROR'
    try {
        $_.Exception.ToString() | Set-Content -LiteralPath (Join-Path $dataDir 'engine.crash.log') -Encoding UTF8
        Write-Log "完整异常已写入 engine.crash.log" 'ERROR'
    } catch { }
}
finally {
    try {
        if ($curBucket.Count -gt 0 -or $curBucketRead.Count -gt 0) { Flush-Bucket $bucketStart $curBucket $curBucketRead }
        $out = Save-Checkpoint $true ((Get-Date).ToString('o'))
        Remove-Item -LiteralPath $currentFile -Force -ErrorAction SilentlyContinue
        Write-Log ("会话封账: {0} ({1:N1} KB)" -f (Split-Path -Leaf $out), ((Get-Item -LiteralPath $out).Length / 1KB))
    } catch { Write-Log "封账失败: $($_.Exception.Message)" 'WARN' }
    try { Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue } catch { }
    try { $script:engineMutex.ReleaseMutex(); $script:engineMutex.Dispose() } catch { }
}
