Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public class WinAPI
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern uint QueryDosDevice(string lpDeviceName, StringBuilder lpTargetPath, int ucchMax);
}
"@

function Get-DevicePath {
    param (
        [string]$Device
    )

    $BufferSize = 1024
    $Buffer = New-Object Text.StringBuilder $BufferSize
    $result = [WinAPI]::QueryDosDevice($Device, $Buffer, $BufferSize)

    if ($result -eq 0) {
        return $null
    }
    return $Buffer.ToString()
}

function Get-DriveLetter {
    param (
        [string]$DevicePath,
        [hashtable]$DevicePaths
    )
    $DevicePaths.GetEnumerator() | Where-Object { $_.Value -eq $DevicePath } | Select-Object -ExpandProperty Key
}

$DevicePaths = @{}
$Disks = Get-WmiObject -Class Win32_LogicalDisk | Select-Object -ExpandProperty DeviceID
foreach ($Disk in $Disks) {
    $DevicePaths[$Disk] = Get-DevicePath -Device $Disk
}

function Get-SignatureInfo {
    param (
        [string]$FilePath
    )
    $FileExists = Test-Path -Path $FilePath
    $Signature = Get-AuthenticodeSignature -FilePath $FilePath -ErrorAction SilentlyContinue
    $Status = "Unknown Error"

    if ($FileExists) {
        switch ($Signature.Status) {
            "Valid" { $Status = "Valid Signature" }
            "NotSigned" { $Status = "Not Signed" }
            "HashMismatch" { $Status = "Malicious Signature (HashMismatch)" }
            "NotTrusted" { $Status = "Malicious Signature (NotTrusted)" }
            "UnknownError" { $Status = "Unknown Error" }
        }
    } else {
        $Status = "File Not Found"
    }

    return [PSCustomObject]@{
        "Status" = $Status
        "Signer" = $Signature.SignerCertificate.Subject
        "IsOSFile" = $Signature.IsOSBinary
    }
}

Clear-Host
$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

if (!(Get-PSDrive -Name HKLM -PSProvider Registry)) {
    try {
        New-PSDrive -Name HKLM -PSProvider Registry -Root HKEY_LOCAL_MACHINE
    } catch {
        Write-Warning "Error mounting HKEY_LOCAL_MACHINE"
    }
}

$BAMVersions = @("bam", "bam\State")
$Users = @()

try {
    foreach ($BAMVersion in $BAMVersions) {
        $Users += Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$BAMVersion\UserSettings\" | Select-Object -ExpandProperty PSChildName
    }
} catch {
    Write-Warning "Error accessing BAM registry. Unsupported Windows ver?"
}

$RegistryPaths = @("HKLM:\SYSTEM\CurrentControlSet\Services\bam\", "HKLM:\SYSTEM\CurrentControlSet\Services\bam\state\")
$TimeZoneInfo = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"
$UserTime = $TimeZoneInfo.TimeZoneKeyName
$UserBias = $TimeZoneInfo.ActiveTimeBias
$UserDaylight = $TimeZoneInfo.DaylightBias

$BAMEntries = @()

foreach ($User in $Users) {
    foreach ($RegistryPath in $RegistryPaths) {
        Write-Progress -Id 1 -Activity "Processing $RegistryPath"
        $UserSettings = Get-Item -Path "$RegistryPath\UserSettings\$User" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property

        foreach ($Setting in $UserSettings) {
            $SettingData = Get-ItemProperty -Path "$RegistryPath\UserSettings\$User" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $Setting
            Write-Progress -Id 2 -Activity "Processing SID: $User" -Status "Processing Entry $($SettingData.Length)"

            if ($SettingData.Length -eq 24) {
                $Hex = [System.BitConverter]::ToString($SettingData[7..0]) -replace "-", ""
                $LocalTime = Get-Date ([DateTime]::FromFileTime([Convert]::ToInt64($Hex, 16))) -Format "yyyy-MM-dd HH:mm:ss"
                $UtcTime = Get-Date ([DateTime]::FromFileTimeUtc([Convert]::ToInt64($Hex, 16))) -Format "yyyy-MM-dd HH:mm:ss"
                $BiasAdjustedTime = Get-Date ([DateTime]::FromFileTimeUtc([Convert]::ToInt64($Hex, 16))).AddMinutes($UserBias) -Format "yyyy-MM-dd HH:mm:ss tt"

                $DevicePath = if ($Setting -match "\\Device\\HarddiskVolume\d+") {
                    $Matched = $Matches[0]
                    $DriveLetter = Get-DriveLetter -DevicePath $Matched -DevicePaths $DevicePaths
                    $Setting.Replace($Matched, $DriveLetter)
                } else {
                    $Setting
                }

                $Signature = if ($Setting -match "\\Device\\HarddiskVolume\d+") {
                    Get-SignatureInfo -FilePath $DevicePath
                }

                $BAMEntries += [PSCustomObject]@{
                    "Local Time" = $LocalTime
                    "UTC Time" = $UtcTime
                    "User Time" = $BiasAdjustedTime
                    "Path" = $DevicePath
                    "Signature Status" = $Signature.Status
                    "OS File" = $Signature.IsOSFile
                    "Signature Subject" = $Signature.Signer
                    "User" = $User
                    "Registry Path" = "$RegistryPath\UserSettings\$User"
                }
            }
        }
    }
}

$SortedEntries = $BAMEntries | Sort-Object -Property "UTC Time" -Descending

$SortedEntries | Out-GridView -PassThru -Title "BAM Entries: $($SortedEntries.Count) - TimeZone: $UserTime"

$Stopwatch.Stop()
$ElapsedTime = $Stopwatch.Elapsed.TotalMinutes
Write-Host "Elapsed Time: $ElapsedTime Minutes" -ForegroundColor Red