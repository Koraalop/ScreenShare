$ErrorActionPreference = "SilentlyContinue"

function Get-FileSignatureStatus {
    param (
        [string[]]$FilePath
    )

    $fileExists = Test-Path -Path $FilePath -PathType Leaf
    $signatureStatus = "Signature Status: Unknown"

    if ($fileExists) {
        $authenticity = (Get-AuthenticodeSignature -FilePath $FilePath).Status
        switch ($authenticity) {
            "Valid" { $signatureStatus = "Valid Signature" }
            "NotSigned" { $signatureStatus = "Unsigned File" }
            "HashMismatch" { $signatureStatus = "Signature Hash Mismatch" }
            "NotTrusted" { $signatureStatus = "Not Trusted Signature" }
            "UnknownError" { $signatureStatus = "Unknown Signature Error" }
        }
    } else {
        $signatureStatus = "File Not Found"
    }

    return $signatureStatus
}

Clear-Host

Write-Host ""
Write-Host "╔════════════════════════════════════════════╗" -ForegroundColor DarkMagenta
Write-Host "║   ░██████╗░██████╗░░░░░░██████╗░██╗░░██╗   ║" -ForegroundColor DarkMagenta
Write-Host "║   ██╔════╝██╔════╝░░░░░░██╔══██╗██║░██╔╝   ║" -ForegroundColor DarkMagenta
Write-Host "║   ╚█████╗░╚█████╗░█████╗██████╔╝█████═╝░   ║" -ForegroundColor DarkMagenta
Write-Host "║   ░╚═══██╗░╚═══██╗╚════╝██╔══██╗██╔═██╗░   ║" -ForegroundColor DarkMagenta
Write-Host "║   ██████╔╝██████╔╝░░░░░░██║░░██║██║░╚██╗   ║" -ForegroundColor DarkMagenta
Write-Host "║   ╚═════╝░╚═════╝░░░░░░░╚═╝░░╚═╝╚═╝░░╚═╝   ║" -ForegroundColor DarkMagenta
Write-Host "╚════════════════════════════════════════════╝" -ForegroundColor DarkMagenta
Write-Host ""
Write-Host "   Developed by Koraalop (Koralop) and reqoan." -ForegroundColor Magenta
Write-Host "   https://github.com/Koraalop" -ForegroundColor Magenta
Write-Host "   https://github.com/Reqoan" -ForegroundColor Magenta
Write-Host ""

do {
    Write-Host "Select an option:"
    Write-Host "1. Bam View"
    Write-Host "2. View Enabled Services"
    Write-Host "3. View Disabled Services"
    Write-Host "0. Exit"
    Write-Host ""

    $choice = Read-Host "Enter 1, 2, 3, or 0 to exit"

    if ($choice -eq "1") {
        Write-Host "Bam View selected" -ForegroundColor Green

        function Check-Admin {
            $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
            return $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
        }

        if (-not (Check-Admin)) {
            Write-Warning "Admin permissions required..."
            Start-Sleep -Seconds 10
            Exit
        }

        $stopwatch = [Diagnostics.Stopwatch]::StartNew()

        if (-not (Get-PSDrive -Name HKLM -PSProvider Registry)) {
            Try {
                New-PSDrive -Name HKLM -PSProvider Registry -Root HKEY_LOCAL_MACHINE
            } Catch {
                Write-Warning "Error mounting HKEY_LOCAL_MACHINE"
            }
        }

        $bamPaths = @("HKLM:\SYSTEM\CurrentControlSet\Services\bam", "HKLM:\SYSTEM\CurrentControlSet\Services\bam\state")
        $bamUsers = @("bam", "bam\State")

        Try {
            $userSettings = foreach ($user in $bamUsers) {
                Get-ChildItem -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$user\UserSettings" | Select-Object -ExpandProperty PSChildName
            }
        } Catch {
            Write-Warning "Error parsing BAM key. Likely unsupported Windows version."
            Exit
        }

        $timezoneInfo = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation"
        $userTimeZone = $timezoneInfo.TimeZoneKeyName
        $userBias = $timezoneInfo.ActiveTimeBias
        $userDaylightBias = $timezoneInfo.DaylightBias

        $bamEntries = foreach ($userSid in $userSettings) {
            foreach ($path in $bamPaths) {
                $bamItems = Get-Item -Path "$path\UserSettings\$userSid" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Property

                Write-Host -ForegroundColor DarkBlue "----------------------------"
                Write-Host -ForegroundColor Cyan "Bam-Path: $path\UserSettings\$userSid"
                Write-Host -ForegroundColor DarkBlue "----------------------------"

                foreach ($item in $bamItems) {
                    $itemValue = Get-ItemProperty -Path "$path\UserSettings\$userSid" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $item
                    if ($itemValue.Length -eq 24) {
                        $hexValue = [System.BitConverter]::ToString($itemValue[7..0]) -replace "-", ""
                        $localTime = Get-Date ([DateTime]::FromFileTime([Convert]::ToInt64($hexValue, 16))) -Format "yyyy-MM-dd HH:mm:ss"
                        $utcTime = Get-Date ([DateTime]::FromFileTimeUtc([Convert]::ToInt64($hexValue, 16))) -Format "yyyy-MM-dd HH:mm:ss"
                        $userAdjustedTime = (Get-Date ([DateTime]::FromFileTimeUtc([Convert]::ToInt64($hexValue, 16))).AddMinutes($userBias) -Format "yyyy-MM-dd HH:mm:ss")

                        $userAccount = try {
                            $sid = New-Object System.Security.Principal.SecurityIdentifier($userSid)
                            $sid.Translate([System.Security.Principal.NTAccount]).Value
                        } Catch {
                            ""
                        }

                        $filePath = if ($item -match '\d{1}') { Join-Path -Path "C:" -ChildPath $item.Substring(23) } else { "" }
                        $signature = if ($filePath) { Get-FileSignatureStatus -FilePath $filePath } else { "" }

                        [PSCustomObject]@{
                            'Execution Time (Local)' = $localTime
                            'Execution Time (UTC)' = $utcTime
                            'User Adjusted Time' = $userAdjustedTime
                            'File Path' = $filePath
                            'File Signature' = $signature
                            'User' = $userAccount
                            'SID' = $userSid
                            'Registry Path' = $path
                        }
                    }
                }
            }
        }

        $bamEntries | Out-GridView -PassThru -Title "Extracted Entries ($($bamEntries.Count)) - User Time Zone: $userTimeZone"

        $stopwatch.Stop()
        $elapsedTime = $stopwatch.Elapsed.TotalMinutes
        Write-Host ""
        Write-Host " [Rekoral] Elapsed Time: $elapsedTime Minutes" -ForegroundColor Green

    }
    elseif ($choice -eq "2") {
        Write-Host "View Enabled Services selected" -ForegroundColor Green

        Get-Service | Where-Object { $_.StartType -eq 'Automatic' } | ForEach-Object {
            $service = $_
            Write-Host -ForegroundColor DarkRed "----------------------------"
            Write-Host -ForegroundColor Red "Name: $($service.Name)"
            Write-Host -ForegroundColor DarkYellow "Status: $($service.Status)"
            Write-Host -ForegroundColor DarkRed "----------------------------"
        }

        Write-Host "Press Enter to return to the menu..."
        Read-Host
    }
    elseif ($choice -eq "3") {
        Write-Host "View Disabled Services selected" -ForegroundColor Green

        Get-Service | Where-Object { $_.StartType -eq 'Disabled' } | ForEach-Object {
            $service = $_
            Write-Host -ForegroundColor DarkRed "----------------------------"
            Write-Host -ForegroundColor Red "Name: $($service.Name)"
            Write-Host -ForegroundColor DarkYellow "Status: $($service.Status)"
            Write-Host -ForegroundColor DarkRed "----------------------------"
        }

        Write-Host "Press Enter to return to the menu..."
        Read-Host
    }
    elseif ($choice -eq "0") {
        Write-Host "Exiting..." -ForegroundColor Green
        Exit
    }
    else {
        Write-Host "Invalid selection. Please choose 1, 2, 3, or 0 to exit." -ForegroundColor Red
    }
} while ($true)
