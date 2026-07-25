# StrictMode turns silent mistakes into errors during development. It already
# earned its keep on SharingLinkAudit, so it is on from the start here.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (Test-Path $path) {
        Get-ChildItem -Path $path -Filter '*.ps1' -Recurse | ForEach-Object {
            . $_.FullName
        }
    }
}
