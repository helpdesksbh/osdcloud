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

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest -Uri $WimUrl -OutFile "$Dir\boot.wim" -UseBasicParsing
Invoke-WebRequest -Uri $SdiUrl -OutFile "$Dir\boot.sdi" -UseBasicParsing

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
