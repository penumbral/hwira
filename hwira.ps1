<#
.SYNOPSIS
    Minimal real-time hardware monitor for LLM workloads.
#>

[CmdletBinding()]
param(
    [ValidateSet(1,3,5,15)]
    [int]$RefreshInterval = 1,
    [int]$SparkLength     = 12,
    [int]$BarWidth        = 24,
    [int]$BenchSize       = 256
)

$ErrorActionPreference = 'SilentlyContinue'
try { $Host.UI.RawUI.WindowTitle = 'Hwira Monitor' } catch {}

# ------------------------------------------------------------------ palette
$P = @{
    H1   = 'DarkGray'    # main title + header meta
    H2   = 'DarkBlue'    # block headers (Memory, NVIDIA GPU N, ...)
    Lbl  = 'Gray'
    Val  = 'White'
    Bar  = 'Blue'        # progress bar fill — same family as trend
    BarD = 'DarkGray'
    Dim  = 'DarkGray'
    Acc  = 'Blue'        # active toggle brackets, sparkline
}

# ------------------------------------------------------------------ toggles
$Show = @{
    Bench  = $false
    Detail = $false
    Static = $false
    Bar    = $true
    Trend  = $true
}
$RefreshOptions = @(1, 3, 5, 15)
$RefreshIdx     = [array]::IndexOf($RefreshOptions, $RefreshInterval)
if ($RefreshIdx -lt 0) { $RefreshIdx = 0; $RefreshInterval = $RefreshOptions[0] }

# ------------------------------------------------------------------ history
$Hist = @{}
function Add-Sample {
    param([string]$K,[double]$V)
    if (-not $Hist.ContainsKey($K)) {
        $Hist[$K] = New-Object 'System.Collections.Generic.List[double]'
    }
    $l = $Hist[$K]; [void]$l.Add($V)
    while ($l.Count -gt $SparkLength) { $l.RemoveAt(0) }
}
function Get-Prev { param([string]$K)
    if ($Hist.ContainsKey($K) -and $Hist[$K].Count -ge 2) {
        $Hist[$K][$Hist[$K].Count - 2]
    } else { 0 }
}
function Get-Spark { param([string]$K)
    if (-not $Hist.ContainsKey($K) -or $Hist[$K].Count -eq 0) {
        return (' ' * $SparkLength)
    }
    $d  = $Hist[$K]
    $ch = '▁','▂','▃','▄','▅','▆','▇','█'
    $mn = ($d | Measure-Object -Minimum).Minimum
    $mx = ($d | Measure-Object -Maximum).Maximum
    $r  = $mx - $mn; if ($r -le 0) { $r = 1 }
    $body = -join ($d | ForEach-Object {
        $i = [int][math]::Floor((($_ - $mn)/$r)*7)
        if ($i -lt 0){$i=0}; if ($i -gt 7){$i=7}; $ch[$i]
    })
    if ($body.Length -lt $SparkLength) {
        (' ' * ($SparkLength - $body.Length)) + $body
    } else { $body }
}

# ================================================================== render
$script:FirstRender     = $true
$script:RenderLines     = 0
$script:PrevRenderLines = 0
$script:TermW           = 80
$script:OriginY         = 0

function Start-Frame {
    try { $script:TermW = [Console]::WindowWidth } catch { $script:TermW = 120 }
    $script:RenderLines = 0

    $needClear = $script:FirstRender
    if (-not $needClear) {
        try {
            [Console]::SetCursorPosition(0, $script:OriginY)
        } catch {
            # buffer scrolled past saved origin — rebuild from scratch
            $needClear = $true
        }
    }
    if ($needClear) {
        Clear-Host
        try { $script:OriginY = [Console]::CursorTop } catch { $script:OriginY = 0 }
        $script:FirstRender     = $false
        $script:PrevRenderLines = 0
    }
}
function End-Frame {
    $blank = ' ' * [math]::Max(0, $script:TermW - 1)
    while ($script:RenderLines -lt $script:PrevRenderLines) {
        Write-Host $blank
        $script:RenderLines++
    }
    $script:PrevRenderLines = $script:RenderLines
}
function Out-Line {
    param([array]$Segs)
    $used = 0
    $maxW = [math]::Max(0, $script:TermW - 1)
    foreach ($s in $Segs) {
        $t = $s.Text
        # truncate to remaining width so terminal never wraps a tracked row
        if ($used + $t.Length -gt $maxW) {
            $t = $t.Substring(0, [math]::Max(0, $maxW - $used))
        }
        if ($t.Length -gt 0) {
            if ($s.Color) { Write-Host $t -ForegroundColor $s.Color -NoNewline }
            else          { Write-Host $t -NoNewline }
            $used += $t.Length
        }
        if ($used -ge $maxW) { break }
    }
    $pad = $maxW - $used
    if ($pad -gt 0) { Write-Host (' ' * $pad) -NoNewline }
    Write-Host ''
    $script:RenderLines++
}
function Out-Blank {
    $maxW = [math]::Max(0, $script:TermW - 1)
    Write-Host (' ' * $maxW)
    $script:RenderLines++
}

# ------------------------------------------------------------------ helpers
function New-Bar { param([double]$Pct,[int]$W=$BarWidth)
    $Pct = [math]::Max(0,[math]::Min(100,$Pct))
    $f = [int][math]::Round(($Pct/100)*$W)
    [pscustomobject]@{ Full=('█'*$f); Empty=('░'*($W-$f)) }
}
function Fmt-Delta { param([double]$Now,[double]$Prev)
    $d=$Now-$Prev; $s=if($d -ge 0){'+'}else{''}; ('{0}{1:N1}' -f $s,$d)
}
function Write-Header { param([string]$Text)
    Out-Blank
    Out-Line @(@{Text="  $Text"; Color=$P.H2})
}
function Write-Metric {
    param(
        [string]$Label,
        [double]$Pct,
        [string]$ValText,
        [string]$HistKey,
        [double]$TrendValue = [double]::NaN
    )
    $sampleVal = if ([double]::IsNaN($TrendValue)) { $Pct } else { $TrendValue }
    Add-Sample $HistKey $sampleVal
    $segs = @( @{Text=("  {0,-10} " -f $Label); Color=$P.Lbl} )
    if ($Show.Bar) {
        $bar = New-Bar $Pct
        $segs += @{Text=$bar.Full;  Color=$P.Bar}
        $segs += @{Text=$bar.Empty; Color=$P.BarD}
        $segs += @{Text=(' {0,5:N1}% ' -f $Pct); Color=$P.Val}
    }
    if ($Show.Trend) {
        $prev  = Get-Prev $HistKey
        $delta = Fmt-Delta $sampleVal $prev
        $spark = Get-Spark $HistKey
        $segs += @{Text=('Δ{0,-7}' -f $delta); Color=$P.Dim}
        $segs += @{Text=(' ' + $spark + '  '); Color=$P.Acc}
    } else {
        $segs += @{Text='  '; Color=$null}
    }
    $segs += @{Text=$ValText; Color=$P.Val}
    Out-Line $segs
}
function Write-NaRow { param([string]$Label,[string]$Note='n/a')
    Out-Line @(
        @{Text=("  {0,-10} " -f $Label); Color=$P.Lbl},
        @{Text=$Note;                    Color=$P.Dim}
    )
}
function Write-Toggle-Seg {
    param([string]$Key,[string]$Name,[bool]$On)
    if ($On) {
        $bracketCol = $P.Acc   # Blue
        $nameCol    = $P.Val   # White
    } else {
        $bracketCol = $P.Dim   # DarkGray
        $nameCol    = $P.Dim   # DarkGray
    }
    return @(
        @{Text=('[{0}] ' -f $Key); Color=$bracketCol},
        @{Text=$Name;              Color=$nameCol}
    )
}

# ================================================================== STATIC
$CimSession = New-CimSession

function Get-StaticInfo {
    $os   = Get-CimInstance Win32_OperatingSystem -CimSession $CimSession
    $cpu  = Get-CimInstance Win32_Processor -CimSession $CimSession | Select-Object -First 1
    $mem  = @(Get-CimInstance Win32_PhysicalMemory -CimSession $CimSession)
    $disk = @(Get-CimInstance Win32_DiskDrive -CimSession $CimSession)
    $vid  = @(Get-CimInstance Win32_VideoController -CimSession $CimSession |
              Where-Object { $_.Name -notmatch 'Basic|Remote|Mirror|Meta' })

    $typeMap = @{20='DDR';21='DDR2';22='DDR2-FB';24='DDR3';26='DDR4';30='LPDDR4';34='DDR5';35='LPDDR5'}
    $first   = $mem | Select-Object -First 1
    $tCode   = [int]$first.SMBIOSMemoryType
    $ramType = if ($typeMap.ContainsKey($tCode)) { $typeMap[$tCode] } else { "T$tCode" }
    $ramTot  = [math]::Round((($mem | Measure-Object Capacity -Sum).Sum)/1GB,0)

    [pscustomobject]@{
        OS    = "$($os.Caption)  $($os.Version) (build $($os.BuildNumber))"
        CPU   = "$($cpu.Name.Trim())  —  $($cpu.NumberOfCores)C / $($cpu.NumberOfLogicalProcessors)T  @ $([math]::Round($cpu.MaxClockSpeed/1000,2)) GHz"
        RAM   = "$ramTot GB  $ramType @ $($first.Speed) MHz  × $($mem.Count) stick(s)"
        Disks = $disk | ForEach-Object {
                    "$($_.Model.Trim())  $([math]::Round($_.Size/1GB,0)) GB  [$($_.InterfaceType)]" }
        GPUs  = $vid  | ForEach-Object { "$($_.Name)  drv $($_.DriverVersion)" }
        HasIntelGpu = [bool]($vid | Where-Object { $_.Name -match 'Intel' })
    }
}

function Test-AIRuntime {
    $r = [ordered]@{}
    $nvDrv = $null
    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        $v = & nvidia-smi --query-gpu=driver_version --format=csv,noheader,nounits 2>$null |
             Select-Object -First 1
        if ($v) { $nvDrv = [double]($v -replace '\..*$','') }
    }
    $r['NVIDIA Driver'] = if ($null -ne $nvDrv) {
        if ($nvDrv -ge 551) { "v$nvDrv  (OK, >=551)" } else { "v$nvDrv  (update needed, <551)" }
    } else { '— not detected' }

    if (Get-Command nvcc -ErrorAction SilentlyContinue) {
        $t = (& nvcc --version 2>$null) -join ' '
        $r['CUDA Toolkit'] = if ($t -match 'release ([\d\.]+)') { "v$($Matches[1])" } else { 'nvcc present' }
    } elseif ($env:CUDA_PATH) {
        $r['CUDA Toolkit'] = "CUDA_PATH=$env:CUDA_PATH"
    } else { $r['CUDA Toolkit'] = '— not found' }

    $cudnn = $false
    $candidates = @($env:CUDA_PATH,
                    "$env:ProgramFiles\NVIDIA\CUDNN",
                    "$env:ProgramFiles\NVIDIA GPU Computing Toolkit\CUDA")
    foreach ($p in $candidates) {
        if ($p -and (Test-Path $p) -and
            (Get-ChildItem $p -Recurse -Filter 'cudnn*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1)) {
            $cudnn = $true; break
        }
    }
    $r['cuDNN'] = if ($cudnn) { 'installed' } else { '— not found' }
    $r['DirectML'] = if (Test-Path "$env:SystemRoot\System32\DirectML.dll") { 'system dll present' } else { '— not found' }

    if (Get-Command python -ErrorAction SilentlyContinue) {
        $ov = & python -c "import onnxruntime as o;print(o.__version__)" 2>$null
        $r['ONNX Runtime'] = if ($ov) { "python pkg v$ov" } else { '— not in python env' }
    } else { $r['ONNX Runtime'] = 'python not found' }

    $r
}

# ============================================== PERF-COUNTERS w/ localization
$script:CounterDefs = @(
    [pscustomobject]@{Key='cpu';   EnCat='Processor';         EnCnt='% Processor Time';         Instance='_Total';        Aggr='last'},
    [pscustomobject]@{Key='diskR'; EnCat='PhysicalDisk';      EnCnt='Disk Read Bytes/sec';      Instance='_Total';        Aggr='last'},
    [pscustomobject]@{Key='diskW'; EnCat='PhysicalDisk';      EnCnt='Disk Write Bytes/sec';     Instance='_Total';        Aggr='last'},
    [pscustomobject]@{Key='netD';  EnCat='Network Interface'; EnCnt='Bytes Received/sec';       Instance='*';             Aggr='sum'; IsNet=$true},
    [pscustomobject]@{Key='netU';  EnCat='Network Interface'; EnCnt='Bytes Sent/sec';           Instance='*';             Aggr='sum'; IsNet=$true},
    [pscustomobject]@{Key='gpu3D'; EnCat='GPU Engine';        EnCnt='Utilization Percentage';   Instance='*engtype_3D*';  Aggr='sum'}
)

$script:NetExcludeRx = 'Loopback|isatap|Teredo|Pseudo-Interface|Microsoft (Wi-Fi Direct |Hosted Network |Kernel Debug |Failover )|Hyper-V|WAN Miniport|QoS Packet Scheduler|WFP'

function Initialize-PerfCounters {
    $nameToIdx = @{}
    $idxToLoc  = @{}
    $ok        = $false
    try {
        $en = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\009' `
               -Name Counter -ErrorAction Stop).Counter
        $lc = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib\CurrentLanguage' `
               -Name Counter -ErrorAction Stop).Counter
        for ($i = 0; $i + 1 -lt $en.Count; $i += 2) {
            $nm = $en[$i+1]
            if ($nm) {
                $k = $nm.ToLower()
                if (-not $nameToIdx.ContainsKey($k)) { $nameToIdx[$k] = $en[$i] }
            }
        }
        for ($i = 0; $i + 1 -lt $lc.Count; $i += 2) {
            if ($lc[$i+1]) { $idxToLoc[$lc[$i]] = $lc[$i+1] }
        }
        $ok = $true
    } catch { }

    foreach ($d in $script:CounterDefs) {
        $locCat = $d.EnCat
        $locCnt = $d.EnCnt
        if ($ok) {
            $ic = $nameToIdx[$d.EnCat.ToLower()]
            $in = $nameToIdx[$d.EnCnt.ToLower()]
            if ($ic -and $idxToLoc.ContainsKey($ic)) { $locCat = $idxToLoc[$ic] }
            if ($in -and $idxToLoc.ContainsKey($in)) { $locCnt = $idxToLoc[$in] }
        }
        $d | Add-Member -Force NotePropertyName LocCat  -NotePropertyValue $locCat
        $d | Add-Member -Force NotePropertyName LocCnt  -NotePropertyValue $locCnt
        $d | Add-Member -Force NotePropertyName LocCatL -NotePropertyValue $locCat.ToLower()
        $d | Add-Member -Force NotePropertyName LocCntL -NotePropertyValue $locCnt.ToLower()
        $d | Add-Member -Force NotePropertyName Path    -NotePropertyValue ("\{0}({1})\{2}" -f $locCat,$d.Instance,$locCnt)
    }
    $ok
}

function Get-PerfSnapshot {
    $out = [ordered]@{ cpu=0; diskR=0; diskW=0; netD=0; netU=0; gpu3D=0 }
    $paths = $script:CounterDefs.Path
    try {
        $cs = (Get-Counter -Counter $paths -ErrorAction SilentlyContinue).CounterSamples
        if (-not $cs) { return [pscustomobject]$out }
        foreach ($s in $cs) {
            if ($s.Path -notmatch '^\\\\[^\\]+\\([^\\(]+)(?:\(([^)]*)\))?\\(.+)$') { continue }
            $sCat = $Matches[1].ToLower()
            $sCnt = $Matches[3].ToLower()
            $sInst = $s.InstanceName
            foreach ($d in $script:CounterDefs) {
                if ($sCat -ne $d.LocCatL -or $sCnt -ne $d.LocCntL) { continue }
                if ($d.IsNet -and $sInst -and ($sInst -match $script:NetExcludeRx)) { break }
                switch ($d.Aggr) {
                    'last' { $out[$d.Key]  = [double]$s.CookedValue }
                    'sum'  { $out[$d.Key] += [double]$s.CookedValue }
                }
                break
            }
        }
        if ($out.gpu3D -gt 100) { $out.gpu3D = 100 }
    } catch {}
    [pscustomobject]$out
}

# ================================================================== METRICS
function Get-CpuTemp {
    try {
        $t = Get-CimInstance -Namespace root/wmi -ClassName MSAcpi_ThermalZoneTemperature `
             -CimSession $CimSession -ErrorAction Stop | Select-Object -First 1
        if ($t) { return [math]::Round(($t.CurrentTemperature / 10) - 273.15, 0) }
    } catch {}
    $null
}
function Get-CpuPower {
    try {
        $paths = @('\Power Meter(*)\Power')
        $s = (Get-Counter -Counter $paths -ErrorAction Stop).CounterSamples |
             Where-Object { $_.InstanceName -match 'CPU|Package|Proc' } | Select-Object -First 1
        if ($s) { return [math]::Round($s.CookedValue,1) }
    } catch {}
    $null
}
function Get-MemInfo {
    $os = Get-CimInstance Win32_OperatingSystem -CimSession $CimSession
    $tot  = [double]$os.TotalVisibleMemorySize
    $free = [double]$os.FreePhysicalMemory
    $usedGB = [math]::Round(($tot-$free)/1MB,2)
    $totGB  = [math]::Round($tot/1MB,2)
    [pscustomobject]@{
        UsedGB=$usedGB; TotalGB=$totGB
        Pct=if($totGB -gt 0){($usedGB/$totGB)*100}else{0}
    }
}
function Get-NvidiaGpus {
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { return @() }
    $q='index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit'
    $out = & nvidia-smi --query-gpu=$q --format=csv,noheader,nounits 2>$null
    $list = @()
    foreach ($ln in $out) {
        $p = $ln -split ',\s*'
        if ($p.Count -lt 8) { continue }
        $list += [pscustomobject]@{
            Idx=[int]$p[0]; Name=$p[1]
            Load=[double]$p[2]
            VUsed=[math]::Round([double]$p[3]/1024,2)
            VTot =[math]::Round([double]$p[4]/1024,2)
            Temp=[double]$p[5]
            PwrD=[double]$p[6]; PwrL=[double]$p[7]
        }
    }
    $list
}

# ================================================================== BENCH
$script:BenchPS     = $null
$script:BenchHandle = $null
$script:BenchStart  = $null
$script:LastBenchMs = 0

$benchScript = {
    param($N)
    $a = New-Object 'double[,]' $N,$N
    $b = New-Object 'double[,]' $N,$N
    $c = New-Object 'double[,]' $N,$N
    for ($i=0; $i -lt $N; $i++) {
        for ($j=0; $j -lt $N; $j++) {
            $a[$i,$j] = [math]::Sin($i*0.013 + $j*0.027)
            $b[$i,$j] = [math]::Cos($i*0.031 - $j*0.011)
        }
    }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    for ($i=0; $i -lt $N; $i++) {
        for ($j=0; $j -lt $N; $j++) {
            $s = 0.0
            for ($k=0; $k -lt $N; $k++) { $s += $a[$i,$k] * $b[$k,$j] }
            $c[$i,$j] = $s
        }
    }
    $sw.Stop()
    ,[math]::Round($sw.Elapsed.TotalMilliseconds, 1)
}
function Start-BenchAsync {
    if ($script:BenchPS) { return }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($benchScript.ToString()).AddArgument($BenchSize)
    $script:BenchPS     = $ps
    $script:BenchHandle = $ps.BeginInvoke()
    $script:BenchStart  = Get-Date
}
function Poll-BenchAsync {
    if ($script:BenchPS -and $script:BenchHandle.IsCompleted) {
        try {
            $res = $script:BenchPS.EndInvoke($script:BenchHandle)
            if ($res -and $res.Count -gt 0) {
                $v = $res[$res.Count - 1]
                $script:LastBenchMs = [double]$v
            }
        } catch {}
        try { $script:BenchPS.Dispose() } catch {}
        $script:BenchPS = $null; $script:BenchHandle = $null; $script:BenchStart = $null
        return $true
    }
    $false
}
function Stop-BenchAsync {
    if ($script:BenchPS) {
        try { $script:BenchPS.Stop()    } catch {}
        try { $script:BenchPS.Dispose() } catch {}
        $script:BenchPS = $null; $script:BenchHandle = $null; $script:BenchStart = $null
    }
}

# ================================================================== KEYS
function Handle-Keys {
    $changed = $false
    while ([Console]::KeyAvailable) {
        $k = [Console]::ReadKey($true)
        switch ($k.Key) {
            'B' {
                $script:Show.Bench = -not $script:Show.Bench
                if ($script:Show.Bench) { Start-BenchAsync } else { Stop-BenchAsync }
                $changed = $true
            }
            'D' { $script:Show.Detail = -not $script:Show.Detail; $changed = $true }
            'S' { $script:Show.Static = -not $script:Show.Static; $changed = $true }
            'P' { $script:Show.Bar    = -not $script:Show.Bar;    $changed = $true }
            'T' { $script:Show.Trend  = -not $script:Show.Trend;  $changed = $true }
            'R' {
                $script:RefreshIdx = ($script:RefreshIdx + 1) % $script:RefreshOptions.Count
                $script:RefreshInterval = $script:RefreshOptions[$script:RefreshIdx]
                $changed = $true
            }
        }
    }
    try {
        if ([Console]::WindowWidth -ne $script:TermW) {
            $script:FirstRender = $true
            $script:PrevRenderLines = 0
            $changed = $true
        }
    } catch {}
    $changed
}

# ================================================================== RENDER
function Render {
    Start-Frame

    Out-Line @(
        @{Text='  HWIRA LLM HARDWARE MONITOR'; Color=$P.H1},
        @{Text=("   " + (Get-Date -Format 'HH:mm:ss') +
                "   refresh ${RefreshInterval}s"); Color=$P.Dim}
    )

    $perf = Get-PerfSnapshot

    $gpus = Get-NvidiaGpus
    foreach ($g in $gpus) {
        Write-Header ("NVIDIA GPU {0}  {1}" -f $g.Idx, $g.Name)
        $k = "gpu$($g.Idx)"

        Write-Metric -Label 'Load'  -Pct $g.Load `
            -ValText ('{0:N0} %' -f $g.Load) -HistKey "${k}_load"

        $vramPct = if ($g.VTot -gt 0) { ($g.VUsed/$g.VTot)*100 } else { 0 }
        Write-Metric -Label 'VRAM'  -Pct $vramPct `
            -ValText ('{0:N2} / {1:N2} GB' -f $g.VUsed,$g.VTot) `
            -HistKey "${k}_vram" -TrendValue $g.VUsed

        $tempPct = [math]::Min(100, ($g.Temp/95)*100)
        Write-Metric -Label 'Temp'  -Pct $tempPct `
            -ValText ('{0:N0} °C' -f $g.Temp) `
            -HistKey "${k}_temp" -TrendValue $g.Temp

        $pwrPct = if ($g.PwrL -gt 0) { ($g.PwrD/$g.PwrL)*100 } else { 0 }
        Write-Metric -Label 'Power' -Pct $pwrPct `
            -ValText ('{0:N1} / {1:N0} W' -f $g.PwrD,$g.PwrL) `
            -HistKey "${k}_pwr"  -TrendValue $g.PwrD
    }

    if ($Static.HasIntelGpu) {
        Write-Header 'GPU 3D Engine'
        Write-Metric -Label 'Load' -Pct $perf.gpu3D `
            -ValText ('{0:N1} %' -f $perf.gpu3D) -HistKey 'igpu_load'
    }

    Write-Header 'Memory'
    $m = Get-MemInfo
    Write-Metric -Label 'RAM' -Pct $m.Pct `
        -ValText ('{0:N2} / {1:N2} GB' -f $m.UsedGB,$m.TotalGB) `
        -HistKey 'ram' -TrendValue $m.UsedGB

    if ($Show.Bench) {
        if (Poll-BenchAsync) { Start-BenchAsync }
        Write-Header ("PS Matmul  N={0}" -f $BenchSize)

        $valText =
            if ($script:LastBenchMs -gt 0 -and -not $script:BenchStart) {
                '{0} ms' -f $script:LastBenchMs
            } elseif ($script:BenchStart -and $script:LastBenchMs -gt 0) {
                $el = ((Get-Date) - $script:BenchStart).TotalSeconds
                '{0} ms   (next: running {1:N1}s...)' -f $script:LastBenchMs,$el
            } elseif ($script:BenchStart) {
                $el = ((Get-Date) - $script:BenchStart).TotalSeconds
                'running {0:N1}s...' -f $el
            } else { '—' }

        $benchPct = [math]::Min(100, ($script:LastBenchMs/5000)*100)
        Write-Metric -Label 'matmul' -Pct $benchPct `
            -ValText $valText `
            -HistKey 'bench' -TrendValue $script:LastBenchMs
    }

    if ($Show.Detail) {
        Write-Header 'CPU'
        Write-Metric -Label 'Load' -Pct $perf.cpu `
            -ValText ('{0:N1} %' -f $perf.cpu) -HistKey 'cpu_load'

        $ct = Get-CpuTemp
        if ($null -ne $ct) {
            Write-Metric -Label 'Temp' -Pct ([math]::Min(100,($ct/95)*100)) `
                -ValText ('{0:N0} °C' -f $ct) -HistKey 'cpu_temp' -TrendValue $ct
        } else { Write-NaRow 'Temp' 'thermal sensor unavailable' }

        $cp = Get-CpuPower
        if ($null -ne $cp) {
            Write-Metric -Label 'Power' -Pct ([math]::Min(100,($cp/150)*100)) `
                -ValText ('{0:N1} W' -f $cp) -HistKey 'cpu_pwr' -TrendValue $cp
        } else { Write-NaRow 'Power' 'power meter unavailable' }

        Write-Header 'Disk I/O'
        $rMB = [math]::Round($perf.diskR/1MB,2)
        $wMB = [math]::Round($perf.diskW/1MB,2)
        Write-Metric -Label 'Read'  -Pct ([math]::Min(100,($rMB/500)*100)) `
            -ValText ('{0:N2} MB/s' -f $rMB) -HistKey 'disk_r' -TrendValue $rMB
        Write-Metric -Label 'Write' -Pct ([math]::Min(100,($wMB/500)*100)) `
            -ValText ('{0:N2} MB/s' -f $wMB) -HistKey 'disk_w' -TrendValue $wMB

        Write-Header 'Network'
        $dMB = [math]::Round($perf.netD/1MB,2)
        $uMB = [math]::Round($perf.netU/1MB,2)
        Write-Metric -Label 'Down' -Pct ([math]::Min(100,($dMB/125)*100)) `
            -ValText ('{0:N2} MB/s' -f $dMB) -HistKey 'net_d' -TrendValue $dMB
        Write-Metric -Label 'Up'   -Pct ([math]::Min(100,($uMB/125)*100)) `
            -ValText ('{0:N2} MB/s' -f $uMB) -HistKey 'net_u' -TrendValue $uMB
    }

    if ($Show.Static) {
        Write-Header 'System'
        Out-Line @(@{Text=('  OS    ' + $Static.OS);  Color=$P.Lbl})
        Out-Line @(@{Text=('  CPU   ' + $Static.CPU); Color=$P.Lbl})
        Out-Line @(@{Text=('  RAM   ' + $Static.RAM); Color=$P.Lbl})
        foreach ($d in $Static.Disks) { Out-Line @(@{Text=('  DISK  ' + $d); Color=$P.Lbl}) }
        foreach ($g in $Static.GPUs)  { Out-Line @(@{Text=('  GPU   ' + $g); Color=$P.Lbl}) }

        Write-Header 'AI Runtime'
        foreach ($k in $Runtime.Keys) {
            Out-Line @(@{Text=('  {0,-14} {1}' -f $k,$Runtime[$k]); Color=$P.Lbl})
        }
    }

    Out-Blank
    $hints  = @(@{Text='  '; Color=$null})
    $hints += Write-Toggle-Seg 'B' 'Bench'        $Show.Bench
    $hints += @{Text='   '; Color=$null}
    $hints += Write-Toggle-Seg 'D' 'CPU/Disk/Net' $Show.Detail
    $hints += @{Text='   '; Color=$null}
    $hints += Write-Toggle-Seg 'S' 'Static'       $Show.Static
    $hints += @{Text='   '; Color=$null}
    $hints += Write-Toggle-Seg 'P' 'Bars'         $Show.Bar
    $hints += @{Text='   '; Color=$null}
    $hints += Write-Toggle-Seg 'T' 'Trend'        $Show.Trend
    $hints += @{Text='   '; Color=$null}
    $hints += @{Text='[R] ';                    Color=$P.Acc}
    $hints += @{Text=("${RefreshInterval}s");   Color=$P.Val}
    Out-Line $hints
    Out-Line @(@{Text='  [Ctrl+C] exit'; Color=$P.Dim})

    End-Frame
}

# ================================================================== MAIN
Clear-Host
Write-Host ''
Write-Host '  HWIRA LLM HW MONITOR — initializing' -ForegroundColor DarkGray
Write-Host ''
Write-Host '  · collecting static system inventory (CPU, RAM, disks, GPUs)...' -ForegroundColor DarkGray
$Static  = Get-StaticInfo
Write-Host '  · probing AI runtime stack (NVIDIA driver, CUDA, cuDNN, DirectML, ONNX)...' -ForegroundColor DarkGray
$Runtime = Test-AIRuntime
Write-Host '  · translating performance counters for current UI language...' -ForegroundColor DarkGray
$xlatOk = Initialize-PerfCounters
if (-not $xlatOk) {
    Write-Host '    (translation table unavailable, falling back to English paths)' -ForegroundColor DarkGray
}
Write-Host '  · priming perf-counter samples...' -ForegroundColor DarkGray
[void](Get-Counter -Counter $script:CounterDefs.Path -ErrorAction SilentlyContinue)

try { [Console]::CursorVisible = $false } catch {}
try {
    Render
    $nextTick = (Get-Date).AddSeconds($RefreshInterval)
    while ($true) {
        $keyChanged = Handle-Keys
        $now = Get-Date
        if ($keyChanged -or $now -ge $nextTick) {
            Render
            $nextTick = (Get-Date).AddSeconds($RefreshInterval)
        }
        Start-Sleep -Milliseconds 80
    }
} finally {
    try { [Console]::CursorVisible = $true } catch {}
    Stop-BenchAsync
    try { Remove-CimSession $CimSession } catch {}
}