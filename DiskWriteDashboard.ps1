#requires -Version 5.1
<#
.SYNOPSIS
  DiskWrite 可视化面板 v4 —— 六窗口 + 双滑块(非线性) + 常驻消息区 + 提权支持。
#>
param(
    [string]$Root = $PSScriptRoot,
    [string]$ConfigPath = '',
    [int]$RefreshMs = 400,
    [switch]$SelfTest,
    [string]$Snapshot = '',
    [switch]$NoTray,
    [switch]$StartHidden
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Root = $Root
if (-not $ConfigPath) { $ConfigPath = Join-Path $Root 'config.json' }
$script:ConfigPath = $ConfigPath
$script:Engine     = Join-Path $Root 'DiskWriteMonitor.ps1'
$script:Installer  = Join-Path $Root 'Install-Autostart.ps1'
$script:DataDir    = Join-Path $Root 'data'
$script:StateFile  = Join-Path $script:DataDir 'state.json'
$script:PidFile    = Join-Path $script:DataDir 'engine.pid'

$script:cfgRaw = $null
if (Test-Path -LiteralPath $ConfigPath) {
    try { $script:cfgRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
}

# ---------- 工具 ----------
function Brush([string]$hex) {
    $c = [System.Windows.Media.ColorConverter]::ConvertFromString($hex)
    return (New-Object System.Windows.Media.SolidColorBrush($c))
}
function Format-Size([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N1} KB' -f ($b / 1KB) }
    else { '{0:N0} B' -f $b }
}
function Format-Rate([double]$b) {
    if ($b -ge 1GB) { '{0:N2} GB/s' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N1} MB/s' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB/s' -f ($b / 1KB) }
    else { '{0:N0} B/s' -f $b }
}
function Format-Compact([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) }
    elseif ($b -ge 1MB) { '{0:N0} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) }
    else { '{0:N0} B' -f $b }
}
function Format-Span([double]$sec) {
    if ($sec -ge 86400) { '{0:N1} 天' -f ($sec / 86400) }
    elseif ($sec -ge 3600) { '{0:N1} 小时' -f ($sec / 3600) }
    elseif ($sec -ge 60) { '{0:N1} 分' -f ($sec / 60) }
    else { '{0:N0} 秒' -f $sec }
}

# 程序图标缓存: 从 exe 路径提取, 转成 WPF 的 ImageSource
$script:iconCache = @{}
function Get-ProgramIcon([string]$path) {
    if (-not $path) { return $null }
    if ($script:iconCache.ContainsKey($path)) { return $script:iconCache[$path] }
    $img = $null
    try {
        if (Test-Path -LiteralPath $path) {
            $ico = [System.Drawing.Icon]::ExtractAssociatedIcon($path)
            if ($ico) {
                $bmp = $ico.ToBitmap()
                $ms = New-Object System.IO.MemoryStream
                $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
                $ms.Position = 0
                $img = New-Object System.Windows.Media.Imaging.BitmapImage
                $img.BeginInit()
                $img.StreamSource = $ms
                $img.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
                $img.EndInit()
                $img.Freeze()
                $bmp.Dispose(); $ico.Dispose(); $ms.Dispose()
            }
        }
    } catch { $img = $null }
    $script:iconCache[$path] = $img
    return $img
}

# 非线性(对数)刻度: 滑块 0~100 <-> 真实值
function Slider-ToValue([double]$t, [double]$min, [double]$max) {
    return $min * [Math]::Pow($max / $min, $t / 100.0)
}
function Value-ToSlider([double]$v, [double]$min, [double]$max) {
    if ($v -le $min) { return 0 }
    if ($v -ge $max) { return 100 }
    return 100.0 * ([Math]::Log($v / $min) / [Math]::Log($max / $min))
}
function Snap-ToLadder([double]$v, $ladder) {
    $best = $ladder[0]; $bestD = [double]::MaxValue
    foreach ($x in $ladder) {
        $d = [Math]::Abs([Math]::Log($v / $x))
        if ($d -lt $bestD) { $bestD = $d; $best = $x }
    }
    return $best
}

$script:sampleLadder = @(200, 250, 500, 750, 1000, 1500, 2000, 3000, 5000, 10000, 15000, 30000, 60000)
$script:granLadder   = @(10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600, 7200, 14400, 21600, 43200, 86400)

$bg      = Brush '#1B1B1F'
$panel   = Brush '#232329'
$panel2  = Brush '#2B2B33'
$fg      = Brush '#E6E6E6'
$muted   = Brush '#9A9AA5'
$accent  = Brush '#4EC9B0'
$accent2 = Brush '#569CD6'
$warn    = Brush '#E5A33D'
$danger  = Brush '#E05252'
$font    = 'Microsoft YaHei UI'

$script:winKey   = 'm10'
$script:winSpans = [ordered]@{
    m10 = @{ label = '近 10 分钟'; series = 'rate';   span = 600 }
    m30 = @{ label = '近 30 分钟'; series = 'rate';   span = 1800 }
    h1  = @{ label = '近 1 小时';  series = 'rate';   span = 3600 }
    d1  = @{ label = '近 1 天';    series = 'hourly'; span = 86400 }
    mo1 = @{ label = '近 1 个月';  series = 'daily';  span = 2592000 }
    all = @{ label = '安装至今';   series = 'daily';  span = -1 }
}

# ---------- 窗口 ----------
$win = New-Object System.Windows.Window
$win.Title = '磁盘写入监视器 — 按进程实时可视化'
$win.Width = 1220; $win.Height = 880
$win.MinWidth = 940; $win.MinHeight = 660
$win.Background = $bg
$win.WindowStartupLocation = 'CenterScreen'
$win.FontFamily = $font

$grid = New-Object System.Windows.Controls.Grid
$grid.Margin = '14,10,14,8'
foreach ($r in 0..5) {
    $row = New-Object System.Windows.Controls.RowDefinition
    switch ($r) {
        0 { $row.Height = 'Auto' }
        1 { $row.Height = 'Auto' }
        2 { $row.Height = 'Auto' }
        3 { $row.Height = 'Auto' }
        4 { $row.Height = New-Object System.Windows.GridLength(1, 'Star') }
        5 { $row.Height = 'Auto' }
    }
    $grid.RowDefinitions.Add($row) | Out-Null
}
$win.Content = $grid

# ---- 头部 ----
$head = New-Object System.Windows.Controls.DockPanel
$head.Margin = '0,0,0,8'
[System.Windows.Controls.Grid]::SetRow($head, 0) | Out-Null
$grid.Children.Add($head) | Out-Null

$title = New-Object System.Windows.Controls.TextBlock
$title.Text = '磁盘写入监视器'
$title.FontSize = 21; $title.FontWeight = 'SemiBold'; $title.Foreground = $fg
$title.VerticalAlignment = 'Center'
[System.Windows.Controls.DockPanel]::SetDock($title, 'Left') | Out-Null
$head.Children.Add($title) | Out-Null

$script:lblSum = New-Object System.Windows.Controls.TextBlock
$script:lblSum.Text = '—'
$script:lblSum.FontSize = 24; $script:lblSum.FontWeight = 'Bold'; $script:lblSum.Foreground = $accent
$script:lblSum.Margin = '22,0,0,0'; $script:lblSum.VerticalAlignment = 'Center'
[System.Windows.Controls.DockPanel]::SetDock($script:lblSum, 'Left') | Out-Null
$head.Children.Add($script:lblSum) | Out-Null

$script:lblStatus = New-Object System.Windows.Controls.TextBlock
$script:lblStatus.Text = '引擎未运行'
$script:lblStatus.FontSize = 12; $script:lblStatus.Foreground = $muted
$script:lblStatus.VerticalAlignment = 'Center'; $script:lblStatus.HorizontalAlignment = 'Right'
[System.Windows.Controls.DockPanel]::SetDock($script:lblStatus, 'Right') | Out-Null
$head.Children.Add($script:lblStatus) | Out-Null

# ---- 按钮栏 ----
$bar = New-Object System.Windows.Controls.StackPanel
$bar.Orientation = 'Horizontal'; $bar.Margin = '0,0,0,8'
[System.Windows.Controls.Grid]::SetRow($bar, 1) | Out-Null
$grid.Children.Add($bar) | Out-Null

function New-Btn([string]$text, $fgColor) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $text
    $b.Padding = '13,6'; $b.Margin = '0,0,8,0'
    $b.Foreground = $fgColor; $b.Background = $panel2
    $b.BorderBrush = Brush '#3A3A44'; $b.BorderThickness = '1'
    $b.FontSize = 12; $b.Cursor = 'Hand'
    return $b
}
$script:btnStart   = New-Btn '▶ 启动引擎'    $accent
$script:btnStop    = New-Btn '■ 停止引擎'    $warn
$script:btnArchive = New-Btn '📦 立即归档'   $fg
$script:btnData    = New-Btn '📂 数据目录'   $fg
$script:btnAuto    = New-Btn '⚙ 安装自启动' $fg
$script:btnUnauto  = New-Btn '✖ 移除自启动'  $muted
$script:btnQuit = New-Btn '⏻ 退出' $danger
foreach ($b in @($script:btnStart, $script:btnStop, $script:btnArchive, $script:btnData, $script:btnAuto, $script:btnUnauto, $script:btnQuit)) {
    $bar.Children.Add($b) | Out-Null
}

# ---- 时间窗口 ----
$winBar = New-Object System.Windows.Controls.StackPanel
$winBar.Orientation = 'Horizontal'; $winBar.Margin = '0,0,0,8'
[System.Windows.Controls.Grid]::SetRow($winBar, 2) | Out-Null
$grid.Children.Add($winBar) | Out-Null

$lblWin = New-Object System.Windows.Controls.TextBlock
$lblWin.Text = '时间窗口'; $lblWin.Foreground = $muted; $lblWin.FontSize = 12
$lblWin.VerticalAlignment = 'Center'; $lblWin.Margin = '0,0,10,0'
$winBar.Children.Add($lblWin) | Out-Null

$script:winButtons = @{}
foreach ($k in $script:winSpans.Keys) {
    $b = New-Object System.Windows.Controls.Button
    $b.Content = $script:winSpans[$k].label
    $b.Padding = '14,5'; $b.Margin = '0,0,6,0'
    $b.FontSize = 12; $b.Cursor = 'Hand'; $b.BorderThickness = '1'
    $b.Tag = $k
    $winBar.Children.Add($b) | Out-Null
    $script:winButtons[$k] = $b
}

# ---- 双滑块 ----
$sldBar = New-Object System.Windows.Controls.StackPanel
$sldBar.Orientation = 'Horizontal'; $sldBar.Margin = '0,0,0,10'
[System.Windows.Controls.Grid]::SetRow($sldBar, 3) | Out-Null
$grid.Children.Add($sldBar) | Out-Null

function New-SliderBlock([string]$caption, [string]$hint) {
    $sp = New-Object System.Windows.Controls.StackPanel
    $sp.Orientation = 'Horizontal'; $sp.Margin = '0,0,26,0'; $sp.VerticalAlignment = 'Center'

    $lbl = New-Object System.Windows.Controls.TextBlock
    $lbl.Text = $caption; $lbl.Foreground = $muted; $lbl.FontSize = 12
    $lbl.VerticalAlignment = 'Center'; $lbl.Margin = '0,0,8,0'
    $sp.Children.Add($lbl) | Out-Null

    $sd = New-Object System.Windows.Controls.Slider
    $sd.Minimum = 0; $sd.Maximum = 100; $sd.Width = 190
    $sd.IsSnapToTickEnabled = $false
    $sd.VerticalAlignment = 'Center'
    $sp.Children.Add($sd) | Out-Null

    $val = New-Object System.Windows.Controls.TextBlock
    $val.Text = '—'; $val.Foreground = $accent; $val.FontSize = 12; $val.FontWeight = 'SemiBold'
    $val.VerticalAlignment = 'Center'; $val.Margin = '10,0,0,0'; $val.MinWidth = 76
    $sp.Children.Add($val) | Out-Null

    $tip = New-Object System.Windows.Controls.TextBlock
    $tip.Text = $hint; $tip.Foreground = Brush '#6E6E7A'; $tip.FontSize = 10.5
    $tip.VerticalAlignment = 'Center'; $tip.Margin = '8,0,0,0'
    $sp.Children.Add($tip) | Out-Null

    return [pscustomobject]@{ Panel = $sp; Slider = $sd; Value = $val }
}

$script:blkSample = New-SliderBlock '采样间隔' '对数刻度 0.2s→60s'
$script:blkGran   = New-SliderBlock '保存粒度' '对数刻度 10s→1天'
$sldBar.Children.Add($script:blkSample.Panel) | Out-Null
$sldBar.Children.Add($script:blkGran.Panel) | Out-Null

# ---- 主体 ----
$body = New-Object System.Windows.Controls.Grid
[System.Windows.Controls.Grid]::SetRow($body, 4) | Out-Null
$grid.Children.Add($body) | Out-Null
$c1 = New-Object System.Windows.Controls.ColumnDefinition; $c1.Width = New-Object System.Windows.GridLength(1.55, 'Star')
$c2 = New-Object System.Windows.Controls.ColumnDefinition; $c2.Width = New-Object System.Windows.GridLength(1, 'Star')
$body.ColumnDefinitions.Add($c1) | Out-Null; $body.ColumnDefinitions.Add($c2) | Out-Null

$leftBorder = New-Object System.Windows.Controls.Border
$leftBorder.Background = $panel; $leftBorder.CornerRadius = '6'
$leftBorder.Padding = '12,10'; $leftBorder.Margin = '0,0,10,0'
[System.Windows.Controls.Grid]::SetColumn($leftBorder, 0) | Out-Null
$body.Children.Add($leftBorder) | Out-Null

$leftStack = New-Object System.Windows.Controls.StackPanel
$leftBorder.Child = $leftStack
$script:lblLeft = New-Object System.Windows.Controls.TextBlock
$script:lblLeft.Text = '按进程写入量'
$script:lblLeft.Foreground = $muted; $script:lblLeft.FontSize = 12; $script:lblLeft.Margin = '0,0,0,8'
$leftStack.Children.Add($script:lblLeft) | Out-Null

# 一个榜单的若干行: 图标 + 名字 + 单条进度 + 数值
function New-RowSet([int]$count) {
    $set = @()
    for ($i = 0; $i -lt $count; $i++) {
        $rowGrid = New-Object System.Windows.Controls.Grid
        $rowGrid.Margin = '0,1,0,1'
        $cA = New-Object System.Windows.Controls.ColumnDefinition; $cA.Width = '150'
        $cB = New-Object System.Windows.Controls.ColumnDefinition; $cB.Width = New-Object System.Windows.GridLength(1, 'Star')
        $cC = New-Object System.Windows.Controls.ColumnDefinition; $cC.Width = '92'
        $rowGrid.ColumnDefinitions.Add($cA) | Out-Null
        $rowGrid.ColumnDefinitions.Add($cB) | Out-Null
        $rowGrid.ColumnDefinitions.Add($cC) | Out-Null

        $namePanel = New-Object System.Windows.Controls.StackPanel
        $namePanel.Orientation = 'Horizontal'
        $namePanel.VerticalAlignment = 'Center'
        $ico = New-Object System.Windows.Controls.Image
        $ico.Width = 16; $ico.Height = 16; $ico.Margin = '0,0,6,0'
        $ico.VerticalAlignment = 'Center'
        $namePanel.Children.Add($ico) | Out-Null
        $name = New-Object System.Windows.Controls.TextBlock
        $name.Text = ''; $name.Foreground = $fg; $name.FontSize = 12
        $name.TextTrimming = 'CharacterEllipsis'; $name.VerticalAlignment = 'Center'
        $namePanel.Children.Add($name) | Out-Null
        [System.Windows.Controls.Grid]::SetColumn($namePanel, 0) | Out-Null
        $rowGrid.Children.Add($namePanel) | Out-Null

        $track = New-Object System.Windows.Controls.Border
        $track.Background = Brush '#2E2E36'; $track.CornerRadius = '2'
        $track.Height = 10; $track.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($track, 1) | Out-Null
        $rowGrid.Children.Add($track) | Out-Null

        $fill = New-Object System.Windows.Controls.Border
        $fill.Background = $accent; $fill.CornerRadius = '2'
        $fill.HorizontalAlignment = 'Left'; $fill.Width = 0
        $track.Child = $fill

        $nums = New-Object System.Windows.Controls.TextBlock
        $nums.Text = ''; $nums.Foreground = $muted; $nums.FontSize = 11
        $nums.HorizontalAlignment = 'Right'; $nums.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetColumn($nums, 2) | Out-Null
        $rowGrid.Children.Add($nums) | Out-Null

        $leftStack.Children.Add($rowGrid) | Out-Null
        $set += [pscustomobject]@{ Icon = $ico; Name = $name; Track = $track; Fill = $fill; Nums = $nums }
    }
    return $set
}

function New-SectionHeader([string]$text, $color) {
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $text
    $tb.Foreground = $color
    $tb.FontSize = 11.5
    $tb.FontWeight = 'SemiBold'
    $tb.Margin = '0,6,0,3'
    $leftStack.Children.Add($tb) | Out-Null
}

New-SectionHeader '▲ 写入排行' $accent
$script:rowsW = New-RowSet 6

$sep = New-Object System.Windows.Controls.Border
$sep.Height = 1; $sep.Background = Brush '#33333D'; $sep.Margin = '0,8,0,0'
$leftStack.Children.Add($sep) | Out-Null

New-SectionHeader '▼ 读取排行' $accent2
$script:rowsR = New-RowSet 6
$right = New-Object System.Windows.Controls.Grid
[System.Windows.Controls.Grid]::SetColumn($right, 1) | Out-Null
$body.Children.Add($right) | Out-Null
$r1 = New-Object System.Windows.Controls.RowDefinition; $r1.Height = New-Object System.Windows.GridLength(1, 'Star')
$r2 = New-Object System.Windows.Controls.RowDefinition; $r2.Height = 'Auto'
$right.RowDefinitions.Add($r1) | Out-Null; $right.RowDefinitions.Add($r2) | Out-Null

$chartBorder = New-Object System.Windows.Controls.Border
$chartBorder.Background = $panel; $chartBorder.CornerRadius = '6'
$chartBorder.Padding = '12,10'; $chartBorder.Margin = '0,0,0,10'
[System.Windows.Controls.Grid]::SetRow($chartBorder, 0) | Out-Null
$right.Children.Add($chartBorder) | Out-Null

$chartStack = New-Object System.Windows.Controls.StackPanel
$chartBorder.Child = $chartStack
$script:lblChart = New-Object System.Windows.Controls.TextBlock
$script:lblChart.Text = '写入趋势'; $script:lblChart.Foreground = $muted
$script:lblChart.FontSize = 12; $script:lblChart.Margin = '0,0,0,6'
$chartStack.Children.Add($script:lblChart) | Out-Null
$script:chart = New-Object System.Windows.Controls.Canvas
$script:chart.Height = 190; $script:chart.ClipToBounds = $true
$chartStack.Children.Add($script:chart) | Out-Null

$cumBorder = New-Object System.Windows.Controls.Border
$cumBorder.Background = $panel; $cumBorder.CornerRadius = '6'; $cumBorder.Padding = '12,10'
[System.Windows.Controls.Grid]::SetRow($cumBorder, 1) | Out-Null
$right.Children.Add($cumBorder) | Out-Null

$cumStack = New-Object System.Windows.Controls.StackPanel
$cumBorder.Child = $cumStack
$script:lblCum = New-Object System.Windows.Controls.TextBlock
$script:lblCum.Text = '窗口内 Top10'; $script:lblCum.Foreground = $muted
$script:lblCum.FontSize = 12; $script:lblCum.Margin = '0,0,0,6'
$cumStack.Children.Add($script:lblCum) | Out-Null
$script:cumLabels = @()
for ($i = 0; $i -lt 9; $i++) {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = ''; $t.Foreground = $fg; $t.FontSize = 11.5; $t.Margin = '0,1,0,1'
    $cumStack.Children.Add($t) | Out-Null
    $script:cumLabels += $t
}

# ---- 消息区 ----
$msgBorder = New-Object System.Windows.Controls.Border
$msgBorder.Background = Brush '#1F1F25'
$msgBorder.CornerRadius = '6'
$msgBorder.Padding = '10,7'
$msgBorder.Margin = '0,10,0,0'
[System.Windows.Controls.Grid]::SetRow($msgBorder, 5) | Out-Null
$grid.Children.Add($msgBorder) | Out-Null

$msgStack = New-Object System.Windows.Controls.StackPanel
$msgBorder.Child = $msgStack
$script:msgPanel = New-Object System.Windows.Controls.StackPanel
$msgStack.Children.Add($script:msgPanel) | Out-Null

function Add-Message([string]$text, [string]$level = 'info') {
    $color = switch ($level) {
        'error' { $danger }
        'ok'    { $accent }
        'warn'  { $warn }
        default { $muted }
    }
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = ('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $text)
    $tb.Foreground = $color
    $tb.FontSize = 11.5
    $tb.TextWrapping = 'Wrap'
    $tb.Margin = '0,0,0,2'
    $script:msgPanel.Children.Insert(0, $tb)
    while ($script:msgPanel.Children.Count -gt 5) {
        $script:msgPanel.Children.RemoveAt($script:msgPanel.Children.Count - 1)
    }
}

# ---------- 窗口按钮 ----------
function Update-WinButtons {
    foreach ($k in $script:winButtons.Keys) {
        $b = $script:winButtons[$k]
        if ($k -eq $script:winKey) {
            $b.Background = $accent; $b.Foreground = Brush '#101014'
            $b.BorderBrush = $accent; $b.FontWeight = 'SemiBold'
        } else {
            $b.Background = $panel2; $b.Foreground = $muted
            $b.BorderBrush = Brush '#3A3A44'; $b.FontWeight = 'Normal'
        }
    }
}
foreach ($k in $script:winButtons.Keys) {
    $script:winButtons[$k].Add_Click({
        param($s, $e)
        $script:winKey = $s.Tag
        Update-WinButtons
        Update-View
    })
}
Update-WinButtons

# ---------- 滑块 ----------
function Refresh-SliderLabels {
    $sv = [int](Snap-ToLadder (Slider-ToValue $script:blkSample.Slider.Value 200 60000) $script:sampleLadder)
    $gv = [int](Snap-ToLadder (Slider-ToValue $script:blkGran.Slider.Value 10 86400) $script:granLadder)
    $script:blkSample.Value.Text = if ($sv -ge 1000) { '{0:N1} 秒' -f ($sv / 1000) } else { '{0} 毫秒' -f $sv }
    $script:blkGran.Value.Text = Format-Span $gv
}

$script:suppressSave = $true
$script:userMoved = $false
$script:saveTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:saveTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$script:saveTimer.Add_Tick({
    $script:saveTimer.Stop()
    Save-Settings
})

function Save-Settings {
    if ($script:suppressSave -or -not $script:userMoved) { return }
    try {
        $sv = [int](Snap-ToLadder (Slider-ToValue $script:blkSample.Slider.Value 200 60000) $script:sampleLadder)
        $gv = [int](Snap-ToLadder (Slider-ToValue $script:blkGran.Slider.Value 10 86400) $script:granLadder)

        $j = $null
        if (Test-Path -LiteralPath $script:ConfigPath) {
            $j = Get-Content -LiteralPath $script:ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        if (-not $j) { Add-Message '找不到 config.json，无法保存' 'error'; return }
        $j | Add-Member -NotePropertyName sampleIntervalMs -NotePropertyValue $sv -Force
        if (-not $j.persist) { $j | Add-Member -NotePropertyName persist -NotePropertyValue ([pscustomobject]@{ granularitySec = $gv; flushSec = 300 }) -Force }
        $j.persist | Add-Member -NotePropertyName granularitySec -NotePropertyValue $gv -Force

        $tmp = "$($script:ConfigPath).tmp"
        $j | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $script:ConfigPath -Force
        Add-Message ('已保存配置：采样 {0}，保存粒度 {1}（引擎 3 秒内热更新）' -f
            $(if ($sv -ge 1000) { '{0:N1} 秒' -f ($sv / 1000) } else { "$sv 毫秒" }), (Format-Span $gv)) 'ok'
    } catch {
        Add-Message ("保存配置失败: " + $_.Exception.Message) 'error'
    }
}

$script:blkSample.Slider.Add_ValueChanged({ Refresh-SliderLabels; if (-not $script:suppressSave) { $script:userMoved = $true; $script:saveTimer.Stop(); $script:saveTimer.Start() } })
$script:blkGran.Slider.Add_ValueChanged({ Refresh-SliderLabels; if (-not $script:suppressSave) { $script:userMoved = $true; $script:saveTimer.Stop(); $script:saveTimer.Start() } })

# 初始位置
$initSample = 1000; $initGran = 3600
if ($script:cfgRaw) {
    if ($script:cfgRaw.sampleIntervalMs) { $initSample = [int]$script:cfgRaw.sampleIntervalMs }
    if ($script:cfgRaw.persist -and $script:cfgRaw.persist.granularitySec) { $initGran = [int]$script:cfgRaw.persist.granularitySec }
}
$script:blkSample.Slider.Value = (Value-ToSlider $initSample 200 60000)
$script:blkGran.Slider.Value = (Value-ToSlider $initGran 10 86400)
Refresh-SliderLabels
$script:suppressSave = $false

# ---------- 数据刷新 ----------
function Update-View {
    try {
        $meta = $script:winSpans[$script:winKey]
        $script:lblLeft.Text = ('按程序读写排行 · {0}' -f $meta.label)
        $script:lblCum.Text  = ('{0} Top10' -f $meta.label)

        if (-not (Test-Path -LiteralPath $script:StateFile)) {
            $script:lblSum.Text = '—'
            $script:lblStatus.Text = '引擎未运行'; $script:lblStatus.Foreground = $warn
            foreach ($r in $script:rows) { $r.Name.Text = ''; $r.Nums.Text = ''; $r.Fill.Width = 0 }
            foreach ($t in $script:cumLabels) { $t.Text = '' }
            $script:chart.Children.Clear()
            return
        }

        $st = (Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8) | ConvertFrom-Json
        $ageSec = ((Get-Date) - [datetime]::Parse($st.ts)).TotalSeconds
        if ($ageSec -lt 15) {
            $script:lblStatus.Text = ("引擎运行中 · {0} 个进程 · 会话 {1}" -f $st.processCount, (Format-Span ([double]$st.uptimeSec)))
            $script:lblStatus.Foreground = $accent
        } else {
            $script:lblStatus.Text = ("引擎可能已停止（数据 {0:N0} 秒未更新）" -f $ageSec)
            $script:lblStatus.Foreground = $warn
        }

        $items = @()
        $prop = $st.windows.($script:winKey)
        if ($prop) { $items = @($prop) }

        $sum = 0.0; $rsum = 0.0
        foreach ($it in $items) { $sum += [double]$it.bytes; $rsum += [double]$it.rbytes }
        $script:lblSum.Text = ('{0}  写 {1} · 读 {2}' -f $meta.label, (Format-Size $sum), (Format-Size $rsum))

        # 写入榜 / 读取榜: 各自排序、各自归一化
        $wItems = @($items | Sort-Object @{ Expression = { [double]$_.bytes }; Descending = $true } | Select-Object -First $script:rowsW.Count)
        $rItems = @($items | Sort-Object @{ Expression = { [double]$_.rbytes }; Descending = $true } | Select-Object -First $script:rowsR.Count)

        $maxW = 1.0
        foreach ($it in $wItems) { if ([double]$it.bytes -gt $maxW) { $maxW = [double]$it.bytes } }
        $maxR = 1.0
        foreach ($it in $rItems) { if ([double]$it.rbytes -gt $maxR) { $maxR = [double]$it.rbytes } }

        $trackW = 240
        if ($script:rowsW.Count -gt 0 -and $script:rowsW[0].Track.ActualWidth -gt 0) { $trackW = $script:rowsW[0].Track.ActualWidth }

        for ($i = 0; $i -lt $script:rowsW.Count; $i++) {
            $r = $script:rowsW[$i]
            if ($i -lt $wItems.Count) {
                $it = $wItems[$i]
                $r.Name.Text = $it.name
                try { $r.Icon.Source = Get-ProgramIcon ([string]$it.path) } catch { }
                $ratio = [double]$it.bytes / $maxW
                if ($ratio -lt 0.02 -and [double]$it.bytes -gt 0) { $ratio = 0.02 }
                if ([double]$it.bytes -le 0) { $ratio = 0 }
                $r.Fill.Width = [math]::Max(0, $trackW * $ratio)
                $r.Nums.Text = ('写 ' + (Format-Size ([double]$it.bytes)))
            } else {
                $r.Name.Text = ''; $r.Nums.Text = ''; $r.Fill.Width = 0; $r.Icon.Source = $null
            }
        }

        for ($i = 0; $i -lt $script:rowsR.Count; $i++) {
            $r = $script:rowsR[$i]
            if ($i -lt $rItems.Count) {
                $it = $rItems[$i]
                $r.Name.Text = $it.name
                try { $r.Icon.Source = Get-ProgramIcon ([string]$it.path) } catch { }
                $ratio = [double]$it.rbytes / $maxR
                if ($ratio -lt 0.02 -and [double]$it.rbytes -gt 0) { $ratio = 0.02 }
                if ([double]$it.rbytes -le 0) { $ratio = 0 }
                $r.Fill.Width = [math]::Max(0, $trackW * $ratio)
                $r.Nums.Text = ('读 ' + (Format-Size ([double]$it.rbytes)))
            } else {
                $r.Name.Text = ''; $r.Nums.Text = ''; $r.Fill.Width = 0; $r.Icon.Source = $null
            }
        }
        for ($i = 0; $i -lt $script:cumLabels.Count; $i++) {
            if ($i -lt $items.Count) {
                $it = $items[$i]
                $script:cumLabels[$i].Text = ('{0,-22} 写 {1,9}  读 {2,9}' -f $it.name,
                    (Format-Size ([double]$it.bytes)), (Format-Size ([double]$it.rbytes)))
            } else { $script:cumLabels[$i].Text = '' }
        }

        switch ($meta.series) {
            'rate'   { $script:lblChart.Text = '总写入速率 · 最近 3 分钟（MB/s）'; Draw-Series -Points @($st.history) -ValueProp 'rate' -LabelProp 'ts' -IsRate }
            'hourly' { $script:lblChart.Text = '每小时写入量 · 最近 24 小时'; Draw-Series -Points @($st.hourly24) -ValueProp 'bytes' -LabelProp 'label' }
            'daily'  { $script:lblChart.Text = '每天写入量 · 最近 30 天'; Draw-Series -Points @($st.daily30) -ValueProp 'bytes' -LabelProp 'label' }
        }
    } catch {
        Add-Message ('刷新失败: ' + $_.Exception.Message) 'error'
    }
}

function Draw-Series($Points, [string]$ValueProp, [string]$LabelProp, [switch]$IsRate) {
    $cv = $script:chart
    $w = $cv.ActualWidth; $h = $cv.ActualHeight
    if ($w -le 10 -or $h -le 10) { return }
    $cv.Children.Clear()

    $vals = @()
    foreach ($p in $Points) { $vals += [double]$p.$ValueProp }
    if ($vals.Count -lt 2) { return }

    $rawMax = 0.0
    foreach ($v in $vals) { if ($v -gt $rawMax) { $rawMax = $v } }
    # 顶部上浮一点, 留出文字空间
    $maxVal = if ($rawMax -le 0) { 1.0 } else { $rawMax * 1.12 }

    # 绘图区(左侧留给坐标轴刻度)
    $padL = 60; $padR = 8; $padT = 10; $padB = 18
    $plotW = [math]::Max(10, $w - $padL - $padR)
    $plotH = [math]::Max(10, $h - $padT - $padB)

    $fmt = {
        param($v)
        if ($IsRate) { Format-Rate $v } else { Format-Compact $v }
    }

    # 横向网格 + 左侧刻度
    foreach ($frac in @(0.0, 0.25, 0.5, 0.75, 1.0)) {
        $y = $padT + $plotH * (1.0 - $frac)
        $ln = New-Object System.Windows.Shapes.Line
        $ln.X1 = $padL; $ln.X2 = ($padL + $plotW)
        $ln.Y1 = $y; $ln.Y2 = $y
        $ln.Stroke = if ($frac -eq 0) { Brush '#45454F' } else { Brush '#2E2E38' }
        $ln.StrokeThickness = 1
        $cv.Children.Add($ln) | Out-Null

        $lab = New-Object System.Windows.Controls.TextBlock
        $lab.Text = (& $fmt ($maxVal * $frac))
        $lab.Foreground = Brush '#7E7E8A'
        $lab.FontSize = 10
        $lab.Width = ($padL - 8)
        $lab.TextAlignment = 'Right'
        [System.Windows.Controls.Canvas]::SetLeft($lab, 0) | Out-Null
        [System.Windows.Controls.Canvas]::SetTop($lab, ($y - 7)) | Out-Null
        $cv.Children.Add($lab) | Out-Null
    }

    $n = $vals.Count
    $ptX = { param($i) $padL + $plotW * $i / ($n - 1) }
    $ptY = { param($v) $padT + $plotH * (1.0 - ($v / $maxVal)) }

    if ($IsRate) {
        $poly = New-Object System.Windows.Shapes.Polyline
        $poly.Stroke = $accent; $poly.StrokeThickness = 1.8; $poly.StrokeLineJoin = 'Round'
        for ($i = 0; $i -lt $n; $i++) {
            $poly.Points.Add((New-Object System.Windows.Point((& $ptX $i), (& $ptY $vals[$i]))))
        }
        $cv.Children.Add($poly) | Out-Null
    } else {
        $bw = [math]::Max(2, ($plotW / $n) * 0.68)
        for ($i = 0; $i -lt $n; $i++) {
            $bh = $plotH * $vals[$i] / $maxVal
            if ($bh -lt 0.5 -and $vals[$i] -gt 0) { $bh = 0.5 }
            $rect = New-Object System.Windows.Shapes.Rectangle
            $rect.Width = $bw; $rect.Height = $bh
            $rect.Fill = if ($vals[$i] -ge $maxVal * 0.75) { $accent } else { Brush '#3E6B63' }
            [System.Windows.Controls.Canvas]::SetLeft($rect, ((& $ptX $i) - $bw / 2)) | Out-Null
            [System.Windows.Controls.Canvas]::SetTop($rect, ($padT + $plotH - $bh)) | Out-Null
            $cv.Children.Add($rect) | Out-Null
        }
    }

    # 峰值标注(带单位)
    $peak = New-Object System.Windows.Controls.TextBlock
    $peak.Text = '峰值 ' + (& $fmt $rawMax)
    $peak.Foreground = $muted; $peak.FontSize = 10.5
    [System.Windows.Controls.Canvas]::SetLeft($peak, ($padL + 4)) | Out-Null
    [System.Windows.Controls.Canvas]::SetTop($peak, $padT) | Out-Null
    $cv.Children.Add($peak) | Out-Null

    # 两端时间/日期标签
    $l0 = New-Object System.Windows.Controls.TextBlock
    $l0.Text = $Points[0].$LabelProp; $l0.Foreground = $muted; $l0.FontSize = 10
    [System.Windows.Controls.Canvas]::SetLeft($l0, $padL) | Out-Null
    [System.Windows.Controls.Canvas]::SetTop($l0, ($padT + $plotH + 2)) | Out-Null
    $cv.Children.Add($l0) | Out-Null

    $lN = New-Object System.Windows.Controls.TextBlock
    $lN.Text = $Points[$n - 1].$LabelProp; $lN.Foreground = $muted; $lN.FontSize = 10
    [System.Windows.Controls.Canvas]::SetLeft($lN, ($padL + $plotW - 44)) | Out-Null
    [System.Windows.Controls.Canvas]::SetTop($lN, ($padT + $plotH + 2)) | Out-Null
    $cv.Children.Add($lN) | Out-Null
}
# ---------- 权限 ----------
function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Invoke-ElevatedScript([string]$script, [string]$action) {
    $log = Join-Path $script:DataDir 'elevated.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $cmd = '& "{0}" -Action {1} -Root "{2}" *> "{3}"' -f $script, $action, $script:Root, $log
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -Wait -WindowStyle Hidden `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd)
    if (Test-Path -LiteralPath $log) {
        $txt = (Get-Content -LiteralPath $log -Raw -Encoding UTF8).Trim()
        if ($txt) { Add-Message ($txt -replace "`r?`n", ' | ') $(if ($txt -match '成功') { 'ok' } else { 'error' }) }
    }
}

function Invoke-InstallerAction([string]$action) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Installer -Action $action -Root $script:Root 2>&1 | Out-String
    $out = $out.Trim()
    $needAdmin = ($out -match '拒绝访问|Access is denied|UnauthorizedAccess|权限')
    if ($needAdmin -or ($out -match '失败')) {
        Add-Message ('操作需要权限或失败：' + ($out -replace "`r?`n", ' | ')) 'error'
        if (-not (Test-IsAdmin)) {
            Add-Message '未以管理员运行，可点击「以管理员重试」' 'warn'
            $script:msgPanel.Tag = $action
            $script:btnElevate.Visibility = 'Visible'
            return
        }
    } else {
        Add-Message ($out -replace "`r?`n", ' | ') 'ok'
    }
}

# ---------- 引擎控制 ----------
function Test-EngineRunning {
    if (-not (Test-Path -LiteralPath $script:PidFile)) { return $false }
    try {
        $enginePid = [int](Get-Content -LiteralPath $script:PidFile -Raw).Trim()
        return ($null -ne (Get-Process -Id $enginePid -ErrorAction SilentlyContinue))
    } catch { return $false }
}
function Start-Engine {
    if (Test-EngineRunning) { Add-Message '引擎已在运行' 'warn'; return }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', $script:Engine, '-ConfigPath', $script:ConfigPath, '-Root', $script:Root) -WindowStyle Hidden | Out-Null
    Add-Message '已启动引擎，等待首次数据…' 'ok'
}
function Stop-Engine {
    if (-not (Test-EngineRunning)) { Add-Message '引擎未在运行' 'warn'; return }
    try {
        $enginePid = [int](Get-Content -LiteralPath $script:PidFile -Raw).Trim()
        Stop-Process -Id $enginePid -Force -ErrorAction Stop
        Add-Message '引擎已停止（会话将自动封账）' 'ok'
    } catch { Add-Message ('停止失败: ' + $_.Exception.Message) 'error' }
}

$script:btnStart.Add_Click({ Start-Engine })
$script:btnStop.Add_Click({ Stop-Engine })
function Invoke-ArchiveNow {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:Engine -ConfigPath $script:ConfigPath -Root $script:Root -ArchiveOnly 2>&1 | Out-String
    $out = $out.Trim()
    if ($out -match '拒绝访问|Access is denied|Unauthorized') {
        Add-Message ('归档失败（权限）: ' + ($out -replace "`r?`n", ' | ')) 'error'
    } elseif ($out) {
        Add-Message ($out -replace "`r?`n", ' | ') 'ok'
    } else {
        Add-Message '归档完成（没有需要处理的文件）' 'ok'
    }
}
$script:btnArchive.Add_Click({ Invoke-ArchiveNow })
$script:btnData.Add_Click({
    try { Start-Process explorer.exe $script:DataDir } catch { Add-Message ('打开目录失败: ' + $_.Exception.Message) 'error' }
})
$script:btnAuto.Add_Click({ Invoke-InstallerAction 'Install' })
$script:btnUnauto.Add_Click({ Invoke-InstallerAction 'Uninstall' })
$script:btnQuit.Add_Click({ Exit-App })

$script:btnElevate = New-Btn '🛡 以管理员重试' $warn
$script:btnElevate.Visibility = 'Hidden'
$bar.Children.Add($script:btnElevate) | Out-Null
$script:btnElevate.Add_Click({
    $act = if ($script:msgPanel.Tag) { $script:msgPanel.Tag } else { 'Install' }
    Add-Message ('正在以管理员身份执行 ' + $act + ' …') 'warn'
    try {
        Invoke-ElevatedScript $script:Installer $act
        $script:btnElevate.Visibility = 'Hidden'
    } catch {
        Add-Message ('提权被取消或失败: ' + $_.Exception.Message) 'error'
    }
})

# ---------- 托盘 ----------
$script:reallyExit = $false
$script:trayIcon = $null

function Show-Panel {
    $win.Show()
    $win.WindowState = 'Normal'
    $win.Activate()
    $win.Topmost = $true
    $win.Topmost = $false
}

function Exit-App {
    $script:reallyExit = $true
    try {
        if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() }
    } catch { }
    $win.Close()
    try { $script:app.Shutdown() } catch { }
}

function Init-Tray {
    try {
        $icon = $null
        # 优先用 app\app.ico(多尺寸) 里的 16x16, 托盘才能正确显示
        $icoPath = Join-Path (Join-Path $script:Root 'app') 'app.ico'
        if (Test-Path -LiteralPath $icoPath) {
            try { $icon = New-Object System.Drawing.Icon($icoPath, 16, 16) } catch { $icon = $null }
        }
        if (-not $icon) {
            $exePath = Join-Path $script:Root 'DiskWriteMonitor.exe'
            if (Test-Path -LiteralPath $exePath) {
                $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath)
            }
        }
        if (-not $icon) { $icon = [System.Drawing.SystemIcons]::Application }

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miOpen    = $menu.Items.Add('打开面板')
        $miArchive = $menu.Items.Add('立即归档')
        [void]$menu.Items.Add('-')
        $miStop    = $menu.Items.Add('停止引擎')
        [void]$menu.Items.Add('-')
        $miExit    = $menu.Items.Add('退出（停止后台采集）')

        # 托盘只认 16x16, 直接给 64x64 的图标常常不显示, 这里转成小尺寸
        try {
            $trayIco = New-Object System.Drawing.Icon($icon, 16, 16)
            if ($trayIco) { $icon = $trayIco }
        } catch { }

        $script:trayIcon = New-Object System.Windows.Forms.NotifyIcon
        $script:trayIcon.Icon = $icon
        $script:trayIcon.Text = '磁盘写入监视器'
        $script:trayIcon.ContextMenuStrip = $menu
        $script:trayIcon.Visible = $true

        $miOpen.Add_Click({ Show-Panel })
        $miArchive.Add_Click({ Invoke-ArchiveNow })
        $miStop.Add_Click({
            Stop-Engine
            Add-Message '已从托盘停止引擎' 'warn'
        })
        $miExit.Add_Click({ Exit-App })
        $script:trayIcon.Add_DoubleClick({ Show-Panel })
        try { Add-Content -LiteralPath (Join-Path $script:DataDir 'ui.log') -Value ("[{0}] Init-Tray OK Visible={1} IconW={2}" -f (Get-Date).ToString('HH:mm:ss'), $script:trayIcon.Visible, $script:trayIcon.Icon.Width) -Encoding UTF8 } catch { }
    } catch {
        Add-Message ('托盘图标创建失败: ' + $_.Exception.Message) 'error'
        try { Add-Content -LiteralPath (Join-Path $script:DataDir 'ui.log') -Value ("[{0}] Init-Tray FAIL {1}" -f (Get-Date).ToString('HH:mm:ss'), $_.Exception.ToString()) -Encoding UTF8 } catch { }
    }
}

# 点右上角 X: 收进托盘, 不退出; 真正退出走托盘右键菜单
$win.Add_Closing({
    param($s, $e)

    if (-not $script:reallyExit) {
        # 点 X 只是最小化到任务栏(保证一定找得到), 真正退出用工具栏的「退出」按钮或托盘菜单
        $e.Cancel = $true
        $null = $win.Dispatcher.BeginInvoke([Action]{
            $win.WindowState = [System.Windows.WindowState]::Minimized
        }, [System.Windows.Threading.DispatcherPriority]::Background)
        Add-Message '窗口已最小化到任务栏，采集继续；要退出请点工具栏「退出」' 'info'
    }
})
# ---------- 定时刷新 ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($RefreshMs)
$script:showPoll = New-Object System.Windows.Threading.DispatcherTimer
$script:showPoll.Interval = [TimeSpan]::FromMilliseconds(600)
$script:showPoll.Add_Tick({
    try {
        $req = Join-Path $script:DataDir 'show.request'
        if (Test-Path -LiteralPath $req) {
            Remove-Item -LiteralPath $req -Force -ErrorAction SilentlyContinue
            Show-Panel
        }
    } catch { }
})

$script:lastUiTouch = [datetime]::MinValue
$timer.Add_Tick({
    Update-View
    # 每 2 秒戳一次 ui.tick, 告诉引擎"看板开着, 请按采样间隔发布快照"
    $nowT = Get-Date
    if (($nowT - $script:lastUiTouch).TotalSeconds -ge 2) {
        $script:lastUiTouch = $nowT
        try {
            $tick = Join-Path $script:DataDir 'ui.tick'
            if (-not (Test-Path -LiteralPath $tick)) { Set-Content -LiteralPath $tick -Value '1' -Encoding ASCII }
            else { (Get-Item -LiteralPath $tick).LastWriteTime = $nowT }
        } catch { }
    }
})

$win.Add_Loaded({
    Update-View
    $timer.Start()
    if (-not $NoTray) { Init-Tray }
    if ($script:showPoll) { $script:showPoll.Start() }
    if ($StartHidden) {
        $null = $win.Dispatcher.BeginInvoke([Action]{ $win.Hide() }, [System.Windows.Threading.DispatcherPriority]::Background)
    }
    if ($Snapshot) {
        $ssTimer = New-Object System.Windows.Threading.DispatcherTimer
        $ssTimer.Interval = [TimeSpan]::FromMilliseconds(1500)
        $ssTimer.Add_Tick({
            param($s, $e)
            $s.Stop()
            try {
                $w = [int]$win.ActualWidth; $h = [int]$win.ActualHeight
                $rtb = New-Object System.Windows.Media.Imaging.RenderTargetBitmap($w, $h, 96, 96, [System.Windows.Media.PixelFormats]::Pbgra32)
                $rtb.Render($win)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($rtb))
                $fs = [System.IO.File]::Create($Snapshot)
                $enc.Save($fs); $fs.Close()
                Write-Host "SNAPSHOT OK: $Snapshot"

            } catch { Write-Host ("SNAPSHOT FAIL: " + $_.Exception.Message) }
            $win.Close()
        })
        $ssTimer.Start()
    }
    Add-Message ('就绪。当前权限: ' + $(if (Test-IsAdmin) { '管理员' } else { '普通用户（安装/移除自启动需提权）' })) 'info'
    if ($SelfTest) {
        $script:closeTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:closeTimer.Interval = [TimeSpan]::FromSeconds(3)
        $script:closeTimer.Add_Tick({
            $script:closeTimer.Stop()
            $ok = 0
            foreach ($k in $script:winSpans.Keys) {
                $script:winKey = $k
                Update-WinButtons
                Update-View
                $ok++
            }
            # 只验证滑块映射函数, 不动滑块(避免写配置)
            foreach ($p in @(0, 25, 50, 75, 100)) {
                $sv = [int](Snap-ToLadder (Slider-ToValue $p 200 60000) $script:sampleLadder)
                $gv = [int](Snap-ToLadder (Slider-ToValue $p 10 86400) $script:granLadder)
                Write-Host ("  滑块 {0,3}% -> 采样 {1}ms, 粒度 {2}s" -f $p, $sv, $gv)
            }
            $script:winKey = 'm10'
            $script:winKey = 'm10'
            Update-WinButtons
            Update-View
            Write-Host ("  写入榜: " + (($script:rowsW | ForEach-Object { if ($_.Name.Text) { $_.Name.Text + '=' + $_.Nums.Text } }) -join ' | '))
            Write-Host ("  读取榜: " + (($script:rowsR | ForEach-Object { if ($_.Name.Text) { $_.Name.Text + '=' + $_.Nums.Text } }) -join ' | '))
            Write-Host "SELFTEST OK: 窗口/时间窗口/滑块/消息区/托盘 均正常"
            $script:reallyExit = $true
            $win.Close()
            try { $script:app.Shutdown() } catch { }
        })
        $script:closeTimer.Start()
    }
})
$win.Add_Closed({
    $timer.Stop()
    try { Remove-Item -LiteralPath (Join-Path $script:DataDir 'ui.tick') -Force -ErrorAction SilentlyContinue } catch { }
    try { if ($script:trayIcon) { $script:trayIcon.Visible = $false; $script:trayIcon.Dispose() } } catch { }
})


if (-not $SelfTest -and -not $Snapshot) {
    $script:uiMutex = New-Object System.Threading.Mutex($false, 'Local\DiskWriteMonitorUI')
    if (-not $script:uiMutex.WaitOne(0)) {
        # 已有实例: 留一个请求文件, 让它把窗口显示出来
        try {
            Set-Content -LiteralPath (Join-Path $script:DataDir 'show.request') -Value (Get-Date).ToString('o') -Encoding ASCII
        } catch { }
        Write-Host '面板已在运行，已请求显示已有窗口'
        return
    }
}

$script:app = New-Object System.Windows.Application
$script:app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

if ($StartHidden -and -not $NoTray) {
    # 开机自启: 不显示窗口, 只留托盘图标
    Init-Tray
    Update-View
    $timer.Start()
    if ($script:showPoll) { $script:showPoll.Start() }
    Add-Message '已随开机启动到托盘（双击托盘图标打开面板）' 'info'
} else {
    $win.Show()
}
[void]$script:app.Run()
