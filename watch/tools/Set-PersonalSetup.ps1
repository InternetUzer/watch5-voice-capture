# Creates an ignored rawfile for a PRIVATE watch build. Never prints the API key.
# Run in Windows PowerShell; enter WATCH_API_KEY at the masked prompt.
[CmdletBinding()]
param([switch]$Remove)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$rawDir = Join-Path $projectRoot 'entry\src\main\resources\rawfile'
$profilePath = Join-Path $rawDir 'personal-setup.json'
if ($Remove) {
    if (Test-Path -LiteralPath $profilePath) { Remove-Item -LiteralPath $profilePath }
    Write-Host 'Personal profile removed. Clean/rebuild before sharing a new HAP.'
    exit 0
}

$publicConfig = Get-Content -LiteralPath (Join-Path $projectRoot 'config\companion-release.json') -Raw | ConvertFrom-Json
if ($publicConfig.phoneBundle -cne 'ru.technadzor.app' -or $publicConfig.phoneFingerprint -cnotmatch '^[A-F0-9]{64}$') {
    throw 'Invalid companion certificate configuration.'
}
New-Item -ItemType Directory -Path $rawDir -Force | Out-Null

# Check the ignore rule before ever writing a secret.
& git -C $projectRoot check-ignore -q -- 'entry/src/main/resources/rawfile/personal-setup.json'
if ($LASTEXITCODE -ne 0) { throw 'Personal profile is not ignored by Git. Update the branch first.' }

Write-Host 'This creates a PRIVATE HAP containing your API key. Do not distribute it.'
Write-Host ('Companion: ' + $publicConfig.phoneBundle + ' / APK ' + $publicConfig.apkVersion)
$secureKey = Read-Host 'Paste WATCH_API_KEY (value only, without quotes)' -AsSecureString
$keyPointer = [IntPtr]::Zero
$tempPath = $profilePath + '.tmp'
try {
    $keyPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureKey)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($keyPointer)
    if ($apiKey.Length -lt 16 -or $apiKey.Length -gt 512 -or $apiKey -cnotmatch '^[\x21-\x7e]+$' -or
        $apiKey.StartsWith('WATCH_API_KEY=') -or $apiKey.StartsWith('y0_') -or
        $apiKey.Contains('"') -or $apiKey.Contains("'")) {
        throw 'Invalid key format. Enter only WATCH_API_KEY, not an OAuth token or the whole env line.'
    }
    $profile = [ordered]@{
        version = 1
        id = [guid]::NewGuid().ToString()
        endpoint = 'https://voice.metalcarcase.ru/v1/recordings'
        key = $apiKey
        phoneBundle = $publicConfig.phoneBundle
        phoneFingerprint = $publicConfig.phoneFingerprint
    }
    $json = $profile | ConvertTo-Json
    # Restrict access before writing plaintext (Windows/NTFS only).
    [IO.File]::WriteAllText($tempPath, '')
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl.SetOwner($identity)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $tempPath -AclObject $acl
    [IO.File]::WriteAllText($tempPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $profilePath -Force
    Write-Host 'Ready. Run the watch app in DevEco; server key and companion fingerprint import on launch.'
    Write-Host 'Wear Engine registration/App ID and a verified v2 server are still required.'
} finally {
    if ($keyPointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($keyPointer) }
    if ($null -ne $secureKey) { $secureKey.Dispose() }
    $apiKey = $null; $json = $null; $profile = $null
    if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath }
}
