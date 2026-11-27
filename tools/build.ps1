<#
build.ps1 - Builds the Connect IQ apps of the project for the watch.

Usage (from the project folder):
    powershell -ExecutionPolicy Bypass -File tools\build.ps1 multi
    powershell -ExecutionPolicy Bypass -File tools\build.ps1 full delta batch
    powershell -ExecutionPolicy Bypass -File tools\build.ps1          # all

In VS Code it is run by the "Build" task (Ctrl+Shift+B), which asks for the variant.

A variant is a folder variants\<name>\ with <name>.jungle: a new folder is
built without touching this script. The output is bin\<name>.prg.

No machine path is written here. Each one is looked up in this order:

  SDK     -Sdk, then the SDK active in Garmin's SDK Manager
          (%APPDATA%\Garmin\ConnectIQ\current-sdk.cfg)
  Java    -JavaHome, then CIQ_JAVA_HOME (the task puts the VS Code
          monkeyC.javaPath setting there), then JAVA_HOME, then java on the PATH
  Key     -Key, then CIQ_DEVELOPER_KEY (the task: monkeyC.developerKeyPath),
          then %USERPROFILE%\.garmin\developer_key

Exits with 1 if a build fails.
#>
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]] $Variant = @(),
    [string] $Device = 'fr255',
    [string] $Sdk,
    [string] $JavaHome,
    [string] $Key
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

function First-Set([string[]] $values) {
    foreach ($v in $values) { if ($v) { return $v.Trim() } }
    return $null
}

# --- SDK ---
if (-not $Sdk) {
    $cfg = Join-Path $env:APPDATA 'Garmin\ConnectIQ\current-sdk.cfg'
    if (Test-Path $cfg) { $Sdk = (Get-Content $cfg -Raw).Trim() }
}
$jar = if ($Sdk) { Join-Path $Sdk 'bin\monkeybrains.jar' } else { $null }
if (-not $jar -or -not (Test-Path $jar)) {
    throw "Connect IQ SDK not found. Install and activate it with the SDK Manager, or pass -Sdk <SDK folder>."
}

# --- Java ---
$JavaHome = First-Set @($JavaHome, $env:CIQ_JAVA_HOME, $env:JAVA_HOME)
$java = $null
if ($JavaHome) {
    # monkeyC.javaPath and JAVA_HOME point to the JDK root; bin\ is accepted too.
    foreach ($c in @((Join-Path $JavaHome 'bin\java.exe'), (Join-Path $JavaHome 'java.exe'))) {
        if (Test-Path $c) { $java = $c; break }
    }
} else {
    $cmd = Get-Command java -ErrorAction SilentlyContinue
    if ($cmd) { $java = $cmd.Source }
}
if (-not $java) {
    throw "Java not found. Set monkeyC.javaPath in VS Code or JAVA_HOME, or put java on the PATH."
}

# --- Key ---
$Key = First-Set @($Key, $env:CIQ_DEVELOPER_KEY, (Join-Path $env:USERPROFILE '.garmin\developer_key'))
if (-not (Test-Path $Key)) {
    throw "Developer key not found ($Key). Create it with 'Monkey C: Generate a Developer Key' or pass -Key <file>."
}

# --- Variants ---
$known = @(Get-ChildItem (Join-Path $root 'variants') -Directory |
    Where-Object { Test-Path (Join-Path $_.FullName "$($_.Name).jungle") } |
    ForEach-Object { $_.Name })
# "-File" passes "full,delta" as a single string: it is split on the commas.
$names = @($Variant | ForEach-Object { $_ -split ',' } | Where-Object { $_ } | ForEach-Object { $_.ToLower() })
if ($names.Count -eq 0 -or $names -contains 'all') { $names = $known }
$unknown = @($names | Where-Object { $known -notcontains $_ })
if ($unknown.Count -gt 0) {
    throw "Unknown variant: $($unknown -join ', '). Available: $($known -join ', ')."
}

Write-Host "SDK     $Sdk"
Write-Host "Java    $java"
Write-Host "Key     $Key"
Write-Host "Device  $Device"

$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force $bin | Out-Null

# From here on, compiler warnings on stderr must not stop the script.
$ErrorActionPreference = 'Continue'
$failed = @()
foreach ($n in $names) {
    $out = Join-Path $bin "$n.prg"
    $jungle = Join-Path $root "variants\$n\$n.jungle"
    Write-Host ""
    Write-Host "=== $n -> bin\$n.prg"
    # -Dfile.encoding=UTF-8 in quotes: without them, PowerShell splits it on the dot.
    & $java '-Xms1g' '-Dfile.encoding=UTF-8' -jar $jar -o $out -f $jungle -y $Key -d $Device -w
    if ($LASTEXITCODE -ne 0) { $failed += $n }
}

Write-Host ""
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')"
    exit 1
}
Write-Host "OK: $($names -join ', ')"
