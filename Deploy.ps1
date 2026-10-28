Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

# ================= Settings =================
$CurrentOS    = 'Windows 11 25H2 x64'
$PilotOS      = 'Windows 11 26H2 x64'
$PilotSerials = @()

$MinBatteryPercent = 70    # flag batteries below this % of original capacity
$MaxDiskWearPercent = 80   # flag drives that have used this much of their rated life
$MaxDiskTempC      = 70    # flag drives running hotter than this
$MinMemoryGB       = 8     # flag less installed memory than this
# ============================================

# ---------- Hardware health check (runs before anything is wiped) ----------
$Flags  = New-Object System.Collections.Generic.List[string]
$Report = New-Object System.Collections.Generic.List[string]
function Add-Line { param([string]$Text) $Report.Add($Text); Write-Host "  $Text" }
function Add-Flag { param([string]$Text) $Flags.Add($Text); $Report.Add("FLAG: $Text"); Write-Host "  FLAG: $Text" -ForegroundColor Red }

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
    $Disks = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.BusType -notin 'USB', 'File Backed Virtual' }
    if (-not $Disks) { Add-Flag 'No internal disk detected.' }
    foreach ($Disk in $Disks) {
        $SizeGB = [math]::Round($Disk.Size / 1GB)
        Add-Line "Disk:   $($Disk.FriendlyName), $SizeGB GB, health: $($Disk.HealthStatus)"
        if ("$($Disk.HealthStatus)" -ne 'Healthy') { Add-Flag "Disk '$($Disk.FriendlyName)' reports health: $($Disk.HealthStatus)." }
        try {
            $Rel = $Disk | Get-StorageReliabilityCounter -ErrorAction Stop
            Add-Line ("        wear: {0}%, temp: {1} C, uncorrected read errors: {2}" -f $Rel.Wear, $Rel.Temperature, $Rel.ReadErrorsUncorrected)
            if ($Rel.Wear -ge $MaxDiskWearPercent) { Add-Flag "Disk has used $($Rel.Wear)% of its rated life." }
            if ($Rel.Temperature -gt $MaxDiskTempC) { Add-Flag "Disk temperature is $($Rel.Temperature) C." }
            if ($Rel.ReadErrorsUncorrected -gt 0) { Add-Flag "Disk has $($Rel.ReadErrorsUncorrected) uncorrected read errors." }
        }
        catch { Add-Line '        wear/temperature/errors: not reported by this drive' }
    }
}
catch { Add-Line 'Disk:   could not check (storage tools not available in this boot image)' }

# Battery (laptops only)
if ($IsLaptop) {
    try {
        $Full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity
        $Design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity
        if ($Full -and $Design) {
            $Pct = [math]::Round(($Full / $Design) * 100)
            Add-Line "Battery: $Pct% of original capacity"
            if ($Pct -lt $MinBatteryPercent) { Add-Flag "Battery is at $Pct% of its original capacity (threshold $MinBatteryPercent%)." }
        }
        else { Add-Line 'Battery: capacity not reported' }
    }
    catch {
        if (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) { Add-Line 'Battery: present, capacity not reported' }
        else { Add-Flag 'No battery detected on a laptop.' }
    }
}

# Camera (laptops only; detects the device, cannot show video in WinPE)
if ($IsLaptop) {
    try {
        $Cameras = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            $_.PNPClass -in 'Camera', 'Image' -or
            $_.Name -match 'camera|webcam' -or
            ($_.CompatibleID -match 'USB\\Class_0E') -or
            ($_.HardwareID -match 'USB\\Class_0E')
        }
        if ($Cameras) { Add-Line "Camera: detected ($(@($Cameras).Count) device(s))" }
        else { Add-Flag 'No camera detected. Check the camera after Windows is installed (some newer cameras only show up once Windows drivers load).' }
    }
    catch { Add-Line 'Camera: could not check' }
}

Write-Host '========================================================' -ForegroundColor Cyan

# Save the report to the USB (if one is connected)
$UsbRoot = Get-PSDrive -PSProvider FileSystem |
    Where-Object { Test-Path "$($_.Root)OSDCloud" } |
    Select-Object -First 1 -ExpandProperty Root
if ($UsbRoot) {
    try {
        $LogDir = Join-Path $UsbRoot 'OSDCloud\Logs'
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
        $LogFile = Join-Path $LogDir ("Health-{0}-{1}.txt" -f $Serial, (Get-Date -Format 'yyyy-MM-dd_HHmm'))
        $Report | Set-Content -Path $LogFile -Encoding UTF8
        Write-Host "Report saved to $LogFile"
    }
    catch { Write-Host 'Could not save the report to the USB.' -ForegroundColor Yellow }
}

# Prompt the tech if anything was flagged
if ($Flags.Count -gt 0) {
    Write-Host ''
    Write-Host "$($Flags.Count) problem(s) found. Nothing has been erased yet." -ForegroundColor Red
    do {
        $Answer = (Read-Host 'Type Y to continue and reimage anyway, or N to stop').Trim().ToUpper()
    } until ($Answer -in 'Y', 'N')
    if ($Answer -eq 'N') {
        Write-Host ''
        Write-Host 'Stopped. The laptop has NOT been wiped.' -ForegroundColor Yellow
        Write-Host 'Note the problems in the Jitbit ticket. To go back to Windows, remove any USB and type: wpeutil reboot' -ForegroundColor Yellow
        exit
    }
    Write-Host 'Continuing at the tech''s request.' -ForegroundColor Yellow
}
else {
    Write-Host 'No problems found. Continuing.' -ForegroundColor Green
}

# ---------- Deployment ----------
$Serial = (Get-CimInstance Win32_BIOS).SerialNumber.Trim()
if ($PilotSerials -contains $Serial) { $OS = $PilotOS } else { $OS = $CurrentOS }

$Wim = Get-PSDrive -PSProvider FileSystem |
    ForEach-Object { Get-ChildItem "$($_.Root)OSDCloud\OS" -Filter *.wim -ErrorAction SilentlyContinue } |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

$Global:MyOSDCloud = [ordered]@{
    WindowsUpdate         = [bool]$true
    WindowsUpdateDrivers  = [bool]$true
    WindowsDefenderUpdate = [bool]$true
    Restart               = [bool]$true
}

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
