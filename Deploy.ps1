Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force

$CurrentOS = 'Windows 11 25H2 x64'
$PilotOS   = 'Windows 11 26H2 x64'
$PilotSerials = @()

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
