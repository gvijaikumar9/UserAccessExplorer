function Show-UserAccessExplorer {
    <#
    .SYNOPSIS
        Open the User Access Explorer desktop window.

    .DESCRIPTION
        The window itself lives in gui\Show-UserAccessExplorer.ps1, a standalone
        script that sets up its own STA runspace. Running that file directly is
        fine from a clone, but someone who installed from the PowerShell Gallery
        has no idea where the module landed on disk. This is the discoverable
        entry point: Install-Module, then Show-UserAccessExplorer.

        The window is WPF, so it needs Windows. The engine behind it -
        Get-UserAccess and Get-SiteAccess - runs anywhere PowerShell 7 does.

    .EXAMPLE
        Show-UserAccessExplorer

        Opens the window. Set the Client ID and tenant admin URL behind the gear
        icon on first run, then connect.
    #>
    [CmdletBinding()]
    param()

    if (-not $IsWindows) {
        throw 'The graphical window needs Windows (it is WPF). Use Get-UserAccess or Get-SiteAccess instead - the engine runs anywhere PowerShell 7 does.'
    }

    $gui = Join-Path (Split-Path $PSScriptRoot -Parent) 'gui/Show-UserAccessExplorer.ps1'

    if (-not (Test-Path -LiteralPath $gui)) {
        throw "The GUI script was not found at '$gui'. If this module was installed from the PowerShell Gallery, reinstall it: Install-Module UserAccessExplorer -Force"
    }

    & $gui
}
