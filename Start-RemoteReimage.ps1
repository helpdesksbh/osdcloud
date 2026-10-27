Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$WimUrl = 'https://github.com/helpdesksbh/osdcloud/releases/latest/download/boot.wim'
$SdiUrl = 'https://github.com/helpdesksbh/osdcloud/releases/latest/download/boot.sdi'
$Dir    = 'C:\OSDCloud-Boot'

# Safety check: don't reimage a device that was just reimaged.
# To override (for testing), set OSDCLOUD_FORCE=1 before running.
$Installed = (Get-CimInstance Win32_OperatingSystem).InstallDate
if ($Installed -gt (Get-Date).AddHours(-24)) {
    if ($env:OSDCLOUD_FORCE -eq '1') {
        Write-Output 'Windows was installed in the last 24 hours, but OSDCLOUD_FORCE=1 is set. Continuing.'
    }
    else {
        Write-Output 'Windows was installed in the last 24 hours. Skipping to prevent a reimage loop.'
        Write-Output 'To override for testing, see "Override the 24-hour check" in the OSDCloud Web and GitHub Maintenance Guide.'
        exit 0
    }
}

New-Item -Path $Dir -ItemType Directory -Force | Out-Null

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

# Show which release will be used (informational only)
try {
    $Release = Invoke-RestMethod -Uri 'https://api.github.com/repos/helpdesksbh/osdcloud/releases/latest' -UseBasicParsing
    Write-Output "Using boot image release $($Release.tag_name)"
}
catch {
    # Not fatal: GitHub limits these lookups, and the downloads below may still work.
    Write-Output 'Could not confirm the latest release (GitHub may be rate-limiting, or no release is marked as latest). Trying the download anyway...'
}

# Download a file, trying three methods. GitHub release files redirect to
# release-assets.githubusercontent.com, which web filters sometimes block or interrupt.
function Get-BootFile {
    param([string]$Url, [string]$OutFile)
    $Name = Split-Path $OutFile -Leaf
    Remove-Item -Path $OutFile -Force -ErrorAction SilentlyContinue
    Write-Output "Downloading $Name..."
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
        return
    }
    catch { Write-Output "  Standard download failed: $($_.Exception.Message) Trying curl..." }
    & curl.exe -L --fail --retry 3 --retry-delay 5 -sS -o $OutFile $Url
    if ($LASTEXITCODE -eq 0) { return }
    Write-Output "  curl failed (exit code $LASTEXITCODE). Trying BITS..."
    try {
        Start-BitsTransfer -Source $Url -Destination $OutFile
        return
    }
    catch { Write-Output "  BITS failed: $($_.Exception.Message)" }
    Write-Error "Could not download $Name. Check that this laptop can reach github.com and release-assets.githubusercontent.com (a web filter may be blocking it)."
    exit 1
}

Get-BootFile -Url $WimUrl -OutFile "$Dir\boot.wim"
Get-BootFile -Url $SdiUrl -OutFile "$Dir\boot.sdi"

if (-not (Test-Path "$Dir\boot.wim") -or (Get-Item "$Dir\boot.wim").Length -lt 100MB) {
    Write-Error 'boot.wim download failed. Stopping.'
    exit 1
}

bcdedit /delete '{ramdiskoptions}' /f 2>$null | Out-Null
bcdedit /create '{ramdiskoptions}' /d 'OSDCloud Ramdisk' | Out-Null
bcdedit /set '{ramdiskoptions}' ramdisksdidevice partition=C:
bcdedit /set '{ramdiskoptions}' ramdisksdipath \OSDCloud-Boot\boot.sdi

$Create = bcdedit /create /d 'OSDCloud' /application osloader
$Guid = [regex]::Match($Create, '\{[0-9a-fA-F-]+\}').Value
if (-not $Guid) { Write-Error 'Could not create boot entry.'; exit 1 }

bcdedit /set $Guid device "ramdisk=[C:]\OSDCloud-Boot\boot.wim,{ramdiskoptions}"
bcdedit /set $Guid osdevice "ramdisk=[C:]\OSDCloud-Boot\boot.wim,{ramdiskoptions}"
bcdedit /set $Guid path \windows\system32\boot\winload.efi
bcdedit /set $Guid systemroot \windows
bcdedit /set $Guid winpe yes
bcdedit /set $Guid detecthal yes
bcdedit /bootsequence $Guid

Suspend-BitLocker -MountPoint 'C:' -RebootCount 1 -ErrorAction SilentlyContinue

Restart-Computer -Force
