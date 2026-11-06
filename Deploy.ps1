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

# ---------- Progress for DISM steps (apply image, add drivers) ----------
# Runs dism.exe and turns its output into a progress bar.
function global:Invoke-DismWithProgress {
    param(
        [string[]]$Arguments,
        [string]$Activity
    )
    $ErrorActionPreference = 'Continue'
    $ProgressPreference = 'Continue'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $Output = New-Object System.Collections.Generic.List[string]
    $Failed = 0
    & "$env:SystemRoot\System32\dism.exe" @Arguments 2>&1 | ForEach-Object {
        $Line = "$_".Trim()
        if (-not $Line) { return }
        $Elapsed = '{0:hh\:mm\:ss}' -f $sw.Elapsed
        if ($Line -match 'Found (\d+) driver package') {
            Write-Host "  $Line"
            $Output.Add($Line)
        }
        elseif ($Line -match 'Installing (\d+) of (\d+)') {
            $Current = [int]$Matches[1]
            $Total = [int]$Matches[2]
            $Pct = [int](($Current / [math]::Max($Total, 1)) * 100)
            $Eta = -1
            if ($Current -gt 1) { $Eta = [int]($sw.Elapsed.TotalSeconds / ($Current - 1) * ($Total - $Current + 1)) }
            $Inf = ''
            if ($Line -match ' - (.+?\.inf)') { $Inf = Split-Path $Matches[1] -Leaf }
            Write-Progress -Activity $Activity -Status ("Driver {0} of {1} - elapsed {2}" -f $Current, $Total, $Elapsed) -CurrentOperation $Inf -PercentComplete $Pct -SecondsRemaining $Eta
            if ($Line -notmatch 'successfully') {
                $Failed++
                Write-Host "  $Line" -ForegroundColor Yellow
            }
        }
        elseif ($Line -match '(\d{1,3}(?:\.\d+)?)%') {
            $Pct = [double]$Matches[1]
            $Eta = -1
            if ($Pct -ge 1) { $Eta = [int]($sw.Elapsed.TotalSeconds * (100 - $Pct) / $Pct) }
            Write-Progress -Activity $Activity -Status ("{0:N1}% - elapsed {1}" -f $Pct, $Elapsed) -PercentComplete ([int][math]::Min($Pct, 100)) -SecondsRemaining $Eta
        }
        else {
            $Output.Add($Line)
        }
    }
    $Code = $LASTEXITCODE
    Write-Progress -Activity $Activity -Completed
    [pscustomobject]@{
        ExitCode = $Code
        Output   = $Output
        Elapsed  = $sw.Elapsed
        Failed   = $Failed
    }
}

# OSDCloud applies the Windows image with Expand-WindowsImage.
# This version runs the same apply through dism.exe so it can show a progress bar.
function global:Expand-WindowsImage {
    [CmdletBinding()]
    param(
        [string]$ApplyPath,
        [string]$ImagePath,
        [uint32]$Index,
        [string]$Name,
        [string]$ScratchDirectory,
        [string]$SplitImageFilePattern,
        [switch]$CheckIntegrity,
        [switch]$Verify,
        [switch]$NoRpFix,
        [switch]$ConfirmTrustedFile,
        [switch]$Compact,
        [switch]$SupportEa,
        [string]$LogPath,
        [string]$LogLevel
    )
    if ($SplitImageFilePattern -or -not $ImagePath -or -not $ApplyPath -or (-not $Index -and -not $Name)) {
        $ProgressPreference = 'Continue'
        return Dism\Expand-WindowsImage @PSBoundParameters
    }
    $DismArgs = @('/Apply-Image', "/ImageFile:$ImagePath", "/ApplyDir:$ApplyPath")
    if ($Index) { $DismArgs += "/Index:$Index" } else { $DismArgs += "/Name:$Name" }
    if ($ScratchDirectory) {
        New-Item -ItemType Directory -Path $ScratchDirectory -Force -ErrorAction SilentlyContinue | Out-Null
        $DismArgs += "/ScratchDir:$ScratchDirectory"
    }
    if ($CheckIntegrity)     { $DismArgs += '/CheckIntegrity' }
    if ($Verify)             { $DismArgs += '/Verify' }
    if ($NoRpFix)            { $DismArgs += '/NoRpFix' }
    if ($ConfirmTrustedFile) { $DismArgs += '/ConfirmTrustedFile' }
    if ($Compact)            { $DismArgs += '/Compact' }
    if ($SupportEa)          { $DismArgs += '/EA' }
    if ($LogPath)            { $DismArgs += "/LogPath:$LogPath" }
    Write-Host "  Applying $(Split-Path $ImagePath -Leaf) to $ApplyPath"
    $Result = Invoke-DismWithProgress -Arguments $DismArgs -Activity "Applying Windows image $(Split-Path $ImagePath -Leaf)"
    if ($Result.ExitCode -ne 0) {
        throw "DISM /Apply-Image failed with exit code $($Result.ExitCode). $(($Result.Output | Select-Object -Last 3) -join ' ')"
    }
    Write-Host ("  Windows image applied in {0:mm\:ss}" -f $Result.Elapsed) -ForegroundColor Green
}

# OSDCloud adds the drivers in C:\Drivers with Use-WindowsUnattend (offline servicing),
# which shows nothing for up to 20 minutes. When the unattend file only lists driver folders,
# this version adds the same folders with dism.exe /Add-Driver /Recurse, which reports
# each driver, so the bar shows "Driver X of Y". Any other unattend file is passed through unchanged.
function global:Use-WindowsUnattend {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$UnattendPath,
        [switch]$Online,
        [switch]$NoRestart,
        [string]$SystemDrive,
        [string]$WindowsDirectory,
        [string]$ScratchDirectory,
        [string]$LogPath,
        [string]$LogLevel
    )
    $DriverPaths = @()
    if ($Path -and -not $Online -and $UnattendPath -and (Test-Path -LiteralPath $UnattendPath)) {
        try {
            [xml]$Xml = Get-Content -LiteralPath $UnattendPath -Raw
            $Passes = @($Xml.unattend.settings)
            if ($Passes.Count -eq 1 -and $Passes[0].pass -eq 'offlineServicing') {
                $Components = @($Passes[0].component)
                $Other = $Components | Where-Object { $_.name -ne 'Microsoft-Windows-PnpCustomizationsNonWinPE' }
                if (-not $Other) {
                    $DriverPaths = @($Components | ForEach-Object { $_.DriverPaths.PathAndCredentials | ForEach-Object { $_.Path } } |
                        Where-Object { $_ } | Select-Object -Unique)
                }
            }
        }
        catch { $DriverPaths = @() }
    }
    if ($DriverPaths.Count -eq 0) {
        $ProgressPreference = 'Continue'
        return Dism\Use-WindowsUnattend @PSBoundParameters
    }
    foreach ($DriverPath in $DriverPaths) {
        if (-not (Test-Path -LiteralPath $DriverPath)) {
            Write-Host "  Driver folder $DriverPath not found. Skipping."
            continue
        }
        $InfCount = (Get-ChildItem -LiteralPath $DriverPath -Filter *.inf -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-Host "  Adding drivers from $DriverPath ($InfCount .inf files)"
        $DismArgs = @("/Image:$Path", '/Add-Driver', "/Driver:$DriverPath", '/Recurse')
        if ($ScratchDirectory) { $DismArgs += "/ScratchDir:$ScratchDirectory" }
        $Result = Invoke-DismWithProgress -Arguments $DismArgs -Activity 'Adding drivers to Windows'
        if ($Result.ExitCode -ne 0 -or $Result.Failed -gt 0) {
            Write-Warning "DISM /Add-Driver finished with exit code $($Result.ExitCode) and $($Result.Failed) driver(s) not added. Windows Update will fill most gaps after setup."
        }
        Write-Host ("  Drivers added in {0:mm\:ss}" -f $Result.Elapsed) -ForegroundColor Green
    }
}

# ---------- Progress for expanding Dell driver packs ----------
# OSDCloud expands Dell packs with Start-Process <pack>.exe /s /e=<folder> -Wait.
# Dell packs don't report their size ahead of time, so this shows MB extracted and time elapsed.
# Every other Start-Process call is passed through unchanged.
function global:Start-Process {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('PSPath', 'Path')]
        [string]$FilePath,
        [Parameter(Position = 1)]
        [Alias('Args')]
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [switch]$Wait,
        [switch]$NoNewWindow,
        [switch]$PassThru,
        [string]$RedirectStandardOutput,
        [string]$RedirectStandardError,
        [string]$RedirectStandardInput,
        [System.Diagnostics.ProcessWindowStyle]$WindowStyle,
        [string]$Verb,
        [switch]$UseNewEnvironment,
        [switch]$LoadUserProfile,
        [System.Management.Automation.PSCredential]$Credential
    )
    $ArgText = "$ArgumentList"
    $Watch = $Wait -and $FilePath -match '\.exe$' -and $ArgText -match '/s\b' -and $ArgText -match '/e="?([^"]+)"?'
    if (-not $Watch) {
        return Microsoft.PowerShell.Management\Start-Process @PSBoundParameters
    }
    $Folder = $Matches[1].Trim()
    $ProgressPreference = 'Continue'
    $Params = @{} + $PSBoundParameters
    $null = $Params.Remove('Wait')
    $Params['PassThru'] = $true
    $Proc = Microsoft.PowerShell.Management\Start-Process @Params
    $Activity = "Expanding $(Split-Path $FilePath -Leaf)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Proc.HasExited) {
        $MB = 0
        if (Test-Path -LiteralPath $Folder) {
            $MB = ((Get-ChildItem -LiteralPath $Folder -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum) / 1MB
        }
        Write-Progress -Activity $Activity -Status ("{0:N0} MB extracted - elapsed {1:hh\:mm\:ss}" -f $MB, $sw.Elapsed)
        Start-Sleep -Seconds 3
    }
    $Proc.WaitForExit()
    Write-Progress -Activity $Activity -Completed
    Write-Host ("  Expanded {0} in {1:mm\:ss}" -f (Split-Path $FilePath -Leaf), $sw.Elapsed) -ForegroundColor Green
    if ($PassThru) { return $Proc }
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
