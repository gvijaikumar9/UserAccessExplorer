<#
    Publishes UserAccessExplorer to the PowerShell Gallery from a staging copy.

    Publish-Module packages the WHOLE folder it is given, so publishing the repo
    directly would ship dev\ (diagnostic scripts, seeded test data, verification
    .txt output, a generated admin-access.html report) and tests\ to every user.
    This stages only what belongs in the package.

    Usage:
        .\Publish-ToGallery.ps1                 # stage + validate only
        .\Publish-ToGallery.ps1 -Publish -ApiKey '<gallery key>'

    The Gallery key belongs to the gvijaikumar9 account - the same one that owns
    SharingLinkAudit. Generate or copy it from
    https://www.powershellgallery.com/account/apikeys
#>
[CmdletBinding()]
param(
    [switch]$Publish,
    [string]$ApiKey
)

$ErrorActionPreference = 'Stop'

$src   = $PSScriptRoot
$stage = Join-Path ([IO.Path]::GetTempPath()) 'UAE-publish\UserAccessExplorer'

# ---- stage -------------------------------------------------------------------
$stageRoot = Split-Path $stage -Parent
if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$rootFiles = 'UserAccessExplorer.psd1', 'UserAccessExplorer.psm1', 'README.md', 'LICENSE'
$folders   = 'Public', 'Private', 'gui'

foreach ($f in $rootFiles) {
    $path = Join-Path $src $f
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing expected file: $f" }
    Copy-Item -LiteralPath $path -Destination $stage
}
foreach ($d in $folders) {
    $path = Join-Path $src $d
    if (-not (Test-Path -LiteralPath $path)) { throw "Missing expected folder: $d" }
    Copy-Item -LiteralPath $path -Destination $stage -Recurse
}

Write-Host "`nStaged to: $stage" -ForegroundColor Cyan
Get-ChildItem $stage -Recurse -File |
    Select-Object @{n = 'File'; e = { $_.FullName.Substring($stage.Length + 1) } },
                  @{n = 'KB';   e = { [math]::Round($_.Length / 1KB, 1) } } |
    Format-Table -AutoSize

# ---- validate ----------------------------------------------------------------
$manifest = Join-Path $stage 'UserAccessExplorer.psd1'
$info = Test-ModuleManifest -Path $manifest
Write-Host "Manifest OK - version $($info.Version)" -ForegroundColor Green

# Import into a child process so this session is not left holding the module.
$exported = pwsh -NoProfile -Command "
    Import-Module '$manifest' -Force
    (Get-Command -Module UserAccessExplorer).Name -join ','
"
Write-Host "Exported commands: $exported" -ForegroundColor Green

foreach ($expected in 'Get-UserAccess', 'Get-SiteAccess', 'Export-UserAccessReport', 'Show-UserAccessExplorer') {
    if ($exported -notmatch [regex]::Escape($expected)) {
        throw "Expected command '$expected' is not exported. Check FunctionsToExport in the manifest."
    }
}
Write-Host 'All four commands export correctly.' -ForegroundColor Green

# ---- publish -----------------------------------------------------------------
if (-not $Publish) {
    Write-Host "`nDry run complete. Nothing was published." -ForegroundColor Yellow
    Write-Host "To publish:  .\Publish-ToGallery.ps1 -Publish -ApiKey '<gallery key>'" -ForegroundColor Yellow
    return
}

if (-not $ApiKey) { throw 'Provide -ApiKey when using -Publish.' }

Publish-Module -Path $stage -NuGetApiKey $ApiKey -Verbose
Write-Host "`nPublished. It takes a few minutes to appear at" -ForegroundColor Green
Write-Host 'https://www.powershellgallery.com/packages/UserAccessExplorer' -ForegroundColor Green
