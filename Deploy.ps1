Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# ================= Settings =================
$CurrentOS    = 'Windows 11 25H2 x64'
$PilotOS      = 'Windows 11 26H2 x64'
$PilotSerials = @()

$MinBatteryPercent  = 70   # flag batteries below this % of original capacity
$MaxDiskWearPercent = 80   # flag drives that have used this much of their rated life
$MaxDiskTempC       = 70   # flag drives running hotter than this
$MinMemoryGB        = 8    # flag less installed memory than this
$global:ProgressMinSizeMB = 500  # show a progress bar for any file copy at least this large
# ============================================

# ---------- Progress bar for large file copies ----------
# OSDCloud copies the USB image with Copy-Item, which shows no progress.
# This function takes the place of Copy-Item for this session. Files at or above
# $ProgressMinSizeMB are copied with a progress bar (percent, MB/s, time left).
# Everything else is passed straight to the normal Copy-Item.
function global:Copy-Item {
    [CmdletBinding(DefaultParameterSetName = 'Path', SupportsShouldProcess)]
    param(
        [Parameter(ParameterSetName = 'Path', Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [string[]]$Path,
        [Parameter(ParameterSetName = 'LiteralPath', ValueFromPipelineByPropertyName)]
        [Alias('PSPath', 'LP')]
        [string[]]$LiteralPath,
        [Parameter(Position = 1)]
        [string]$Destination,
        [switch]$Container,
        [switch]$Force,
        [string]$Filter,
        [string[]]$Include,
        [string[]]$Exclude,
        [switch]$Recurse,
        [switch]$PassThru
    )
    process {
        $ProgressPreference = 'Continue'
        $src = $null
        if ($Destination -and -not $Recurse -and -not $Filter -and -not $Include -and -not $Exclude) {
            if ($LiteralPath -and $LiteralPath.Count -eq 1) {
                $src = Microsoft.PowerShell.Management\Get-Item -LiteralPath $LiteralPath[0] -Force -ErrorAction SilentlyContinue
            }
            elseif ($Path -and $Path.Count -eq 1) {
                $src = Microsoft.PowerShell.Management\Get-Item -Path $Path[0] -Force -ErrorAction SilentlyContinue
            }
        }
        if ($src -is [System.IO.FileInfo] -and $src.Length -ge ($global:ProgressMinSizeMB * 1MB)) {
            $destFile = $Destination
            if ((Test-Path -LiteralPath $Destination -PathType Container) -or $Destination.EndsWith('\')) {
                $destFile = Join-Path $Destination $src.Name
            }
            $destDir = Split-Path $destFile -Parent
            if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
                New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            }
            $activity = "Copying $($src.Name)"
            $total = $src.Length
            $buffer = New-Object byte[] (8MB)
            $in = [System.IO.File]::OpenRead($src.FullName)
            $out = [System.IO.File]::Create($destFile)
            try {
                $copied = 0
                $last = 0
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    $out.Write($buffer, 0, $read)
                    $copied += $read
                    if (($sw.ElapsedMilliseconds - $last) -ge 1000 -or $copied -eq $total) {
                        $last = $sw.ElapsedMilliseconds
                        $mbps = ($copied / 1MB) / [math]::Max($sw.Elapsed.TotalSeconds, 0.1)
                        $eta = if ($mbps -gt 0) { [int](($total - $copied) / 1MB / $mbps) } else { -1 }
                        $pct = [int](($copied / $total) * 100)
                        $status = "{0}% - {1:N0} of {2:N0} MB - {3:N1} MB/s" -f $pct, ($copied / 1MB), ($total / 1MB), $mbps
                        Write-Progress -Activity $activity -Status $status -PercentComplete $pct -SecondsRemaining $eta
                    }
                }
            }
            finally {
                $in.Close()
                $out.Close()
            }
            Write-Progress -Activity $activity -Completed
            Write-Host ("Copied {0} ({1:N0} MB) in {2:mm\:ss}" -f $src.Name, ($total / 1MB), $sw.Elapsed) -ForegroundColor Green
            if ($PassThru) { Microsoft.PowerShell.Management\Get-Item -LiteralPath $destFile }
            return
        }
        Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
    }
}

# ---------- Hardware health check (runs before anything is wiped) ----------
$Flags  = New-Object System.Collections.Generic.List[string]
$Report = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text) $Report.Add($Text); Write-Host "  $Text" }
function Add-Flag { param([string]$Text) $Flags.Add($Text); $Report.Add("FLAG: $Text"); Write-Host "  FLAG: $Text" -ForegroundColor Red }

function Save-HealthReport {
    param([string]$Decision)
    $UsbRoot = Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'X' -and (Test-Path "$($_.Root)OSDCloud") } |
        Select-Object -First 1
    if (-not $UsbRoot) { return }
    $LogDir = "$($UsbRoot.Root)OSDCloud\Logs"
    New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
    $File = Join-Path $LogDir ("Health-{0}-{1}.txt" -f $Serial, (Get-Date -Format 'yyyy-MM-dd-HHmm'))
    $Lines = @("Hardware Health Check - $(Get-Date)") + $Report + @('', "Result: $Decision")
    $Lines | Set-Content -Path $File -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host "  Report saved to $File"
}

Write-Host ''
Write-Host '================ HARDWARE HEALTH CHECK ================' -ForegroundColor Cyan

# Device info
$CS     = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$BIOS   = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
$Serial = "$($BIOS.SerialNumber)".Trim()
Add-Line "Model:  $($CS.Manufacturer) $($CS.Model)"
Add-Line "Serial: $Serial"
Add-Line "BIOS:   $($BIOS.SMBIOSBIOSVersion)"

$Chassis  = (Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes
$IsLaptop = [bool]($Chassis | Where-Object { $_ -in 8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32 })
Add-Line ("Type:   {0}" -f $(if ($IsLaptop) { 'Laptop' } else { 'Desktop' }))

# Memory
try {
    $MemGB = [math]::Round(((Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum) / 1GB)
    Add-Line "Memory: $MemGB GB"
    if ($MemGB -lt $MinMemoryGB) { Add-Flag "Only $MemGB GB of memory detected (expected at least $MinMemoryGB GB). A module may be failed or unseated." }
}
catch { Add-Line 'Memory: could not check' }

# Disk
try {
    $Disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { "$($_.BusType)" -notin 'USB', 'File Backed Virtual' }
    if (-not $Disks) { Add-Flag 'No internal disk detected.' }
    foreach ($Disk in $Disks) {
        $SizeGB = [math]::Round($Disk.Size / 1GB)
        Add-Line "Disk:   $($Disk.FriendlyName), $SizeGB GB, health: $($Disk.HealthStatus)"
        if ("$($Disk.HealthStatus)" -ne 'Healthy') { Add-Flag "Disk '$($Disk.FriendlyName)' reports health: $($Disk.HealthStatus)." }
        try {
            $Rel = $Disk | Get-StorageReliabilityCounter -ErrorAction Stop
            if ($null -ne $Rel.Wear) {
                Add-Line "        Wear: $($Rel.Wear)% of rated life used"
                if ($Rel.Wear -ge $MaxDiskWearPercent) { Add-Flag "Disk has used $($Rel.Wear)% of its rated life (limit $MaxDiskWearPercent%)." }
            }
            else { Add-Line '        Wear: could not check' }
            if ($Rel.Temperature) {
                Add-Line "        Temperature: $($Rel.Temperature) C"
                if ($Rel.Temperature -gt $MaxDiskTempC) { Add-Flag "Disk is running at $($Rel.Temperature) C (limit $MaxDiskTempC C)." }
            }
            else { Add-Line '        Temperature: could not check' }
            if ($null -ne $Rel.ReadErrorsUncorrected) {
                Add-Line "        Uncorrected read errors: $($Rel.ReadErrorsUncorrected)"
                if ($Rel.ReadErrorsUncorrected -gt 0) { Add-Flag "Disk has $($Rel.ReadErrorsUncorrected) uncorrected read errors." }
            }
        }
        catch { Add-Line '        Wear, temperature, errors: could not check' }
    }
}
catch { Add-Line 'Disk:   could not check' }

# Battery (laptops only)
if ($IsLaptop) {
    try {
        $Design = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop
        $Full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
        if (-not $Design -or -not $Full) {
            Add-Flag 'No battery found.'
        }
        else {
            $DesignCap = ($Design | Measure-Object -Property DesignedCapacity -Sum).Sum
            $FullCap   = ($Full | Measure-Object -Property FullChargedCapacity -Sum).Sum
            if ($DesignCap -gt 0) {
                $BattPct = [math]::Round(($FullCap / $DesignCap) * 100)
                Add-Line "Battery: $BattPct% of original capacity"
                if ($BattPct -lt $MinBatteryPercent) { Add-Flag "Battery holds only $BattPct% of its original capacity (limit $MinBatteryPercent%)." }
            }
            else { Add-Line 'Battery: could not check' }
        }
    }
    catch { Add-Line 'Battery: could not check' }
}

# Camera (laptops only)
if ($IsLaptop) {
    try {
        $Cams = Get-CimInstance Win32_PnPEntity -ErrorAction Stop |
            Where-Object { $_.PNPClass -in 'Camera', 'Image' -or $_.Name -match 'camera|webcam' }
        if ($Cams) { Add-Line "Camera: $(($Cams | Select-Object -First 1).Name)" }
        else { Add-Flag 'No camera detected.' }
    }
    catch { Add-Line 'Camera: could not check' }
}

# Result and tech prompt
Write-Host ''
if ($Flags.Count -eq 0) {
    Write-Host '  No problems found. Continuing.' -ForegroundColor Green
    Save-HealthReport -Decision 'No problems found. Reimage continued.'
}
else {
    Write-Host "  $($Flags.Count) problem(s) found. Nothing has been erased yet." -ForegroundColor Yellow
    do {
        $Answer = (Read-Host '  Type Y to continue and reimage anyway, or N to stop').Trim().ToUpper()
    } until ($Answer -in 'Y', 'N')
    if ($Answer -eq 'N') {
        Save-HealthReport -Decision 'Problems found. Tech stopped the reimage.'
        Write-Host ''
        Write-Host '  Reimage stopped. Nothing was erased.' -ForegroundColor Yellow
        Write-Host '  Note the problem in Jitbit, remove any USB, then type: wpeutil reboot' -ForegroundColor Yellow
        exit
    }
    Save-HealthReport -Decision 'Problems found. Tech chose to continue.'
}
Write-Host '=======================================================' -ForegroundColor Cyan
Write-Host ''

# ---------- Pick the Windows version ----------
if ($PilotSerials -contains $Serial) { $OS = $PilotOS } else { $OS = $CurrentOS }

# ---------- Look for a patched image on the USB ----------
$Wim = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Get-ChildItem "$($_.Root)OSDCloud\OS" -Filter *.wim -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# ---------- OSDCloud options ----------
$Global:MyOSDCloud = [ordered]@{
    Restart               = [bool]$true
    WindowsUpdate         = [bool]$true
    WindowsUpdateDrivers  = [bool]$true
    WindowsDefenderUpdate = [bool]$true
}

# ---------- Start the install ----------
if ($Wim) {
    Write-Host "Using USB image $($Wim.Name)"
    $Global:MyOSDCloud.ImageFileItem     = $Wim
    $Global:MyOSDCloud.ImageFileName     = $Wim.Name
    $Global:MyOSDCloud.ImageFileFullName = $Wim.FullName
    $Global:MyOSDCloud.OSImageIndex      = 1
    $Global:MyOSDCloud.ClearDiskConfirm  = [bool]$false
    $Global:MyOSDCloud.ZTI               = [bool]$true
    Invoke-OSDCloud
}
else {
    Write-Host "No USB image found. Serial $Serial will receive $OS from Microsoft"
    Start-OSDCloud -OSName $OS -OSEdition Enterprise -OSLanguage en-us -OSActivation Volume -ZTI
}
