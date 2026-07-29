function Get-SiteAccess {
    <#
    .SYNOPSIS
        Show WHO can reach a SharePoint site, and HOW - the site-centric mirror of
        Get-UserAccess, with the access nobody was explicitly given surfaced.

    .DESCRIPTION
        Where Get-UserAccess fixes a user and finds the objects they reach, this
        fixes a site and finds the principals that reach it: every user, SharePoint
        group, Entra group, Everyone claim and sharing link on the site, each
        classified Granted (a named user or group) or Overshared (an Everyone claim
        or a sharing link - access nobody was explicitly given, and exactly what
        Copilot will surface to whoever it reaches).

        A SharePoint group is expanded to a member count, so "who, and how many" is
        answered without one row per person.

        This is an admin tool - reading a site's permissions needs Full Control on it.
        Read-only. Pipe results to Export-Csv or work with them directly.

    .PARAMETER SiteUrl
        A single site to report on.

    .PARAMETER SiteUrls
        Several sites to report on.

    .PARAMETER OversharedOnly
        Return only the Overshared routes - the Everyone claims and sharing links.
        The old name -UnexpectedOnly still works as an alias.

    .PARAMETER ClientId
        Entra ID app registration client ID. Not needed with -UseExistingConnection.

    .EXAMPLE
        Get-SiteAccess -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -ClientId $id -Interactive

    .EXAMPLE
        # Just the oversharing across a set of sites
        Get-SiteAccess -SiteUrls $sites -UseExistingConnection -OversharedOnly
    #>
    [CmdletBinding(DefaultParameterSetName = 'Site')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Site')]
        [string]   $SiteUrl,

        [Parameter(Mandatory, ParameterSetName = 'Sites')]
        [string[]] $SiteUrls,

        [Alias('UnexpectedOnly')]
        [switch]   $OversharedOnly,

        [string]       $ClientId,
        [string]       $Tenant,
        [string]       $CertificatePath,
        [securestring] $CertificatePassword,
        [string]       $Thumbprint,
        [switch]       $Interactive,
        [switch]       $ManagedIdentity,
        [switch]       $UseExistingConnection
    )

    $connectSplat = @{
        ClientId = $ClientId; Tenant = $Tenant
        CertificatePath = $CertificatePath; CertificatePassword = $CertificatePassword
        Thumbprint = $Thumbprint; Interactive = $Interactive
        ManagedIdentity = $ManagedIdentity; UseExistingConnection = $UseExistingConnection
    }

    $targets = switch ($PSCmdlet.ParameterSetName) {
        'Site'  { @($SiteUrl) }
        'Sites' { $SiteUrls }
    }

    $total = @($targets).Count
    $n = 0
    $emitted = 0
    # Sites we could not READ - tracked so an incomplete scan can be told apart from
    # a genuine result, exactly as Get-UserAccess does.
    $skipped = [System.Collections.Generic.List[string]]::new()

    foreach ($site in $targets) {
        $n++
        Write-Progress -Activity "Checking who can reach the site(s)" -Status "$n of $total : $site" `
                       -PercentComplete (($n / [Math]::Max($total,1)) * 100)
        try {
            Connect-IfNeeded -Url $site @connectSplat
            Get-SiteAccessForWeb -WebUrl $site |
                Where-Object { -not $OversharedOnly -or $_.RouteType -eq 'Overshared' } |
                ForEach-Object { $emitted++; $_ }
        }
        catch {
            $skipped.Add($site)
            Write-Warning "Skipped $site : $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Checking who can reach the site(s)" -Completed

    # A skipped site returned nothing because it could not be READ. Surface that as a
    # non-terminating error so a caller can tell an incomplete scan from a clean one.
    if ($skipped.Count -gt 0) {
        $msg = "Scan is INCOMPLETE: $($skipped.Count) of $total site(s) could not be read and were skipped ($($skipped -join ', ')). Results cover only the sites that responded."
        $PSCmdlet.WriteError(
            [System.Management.Automation.ErrorRecord]::new(
                [System.InvalidOperationException]::new($msg),
                'UserAccessExplorer.IncompleteScan',
                [System.Management.Automation.ErrorCategory]::ResourceUnavailable,
                $SiteUrl))
    }

    if ($emitted -eq 0 -and $skipped.Count -eq 0) {
        $what = if ($OversharedOnly) { 'oversharing' } else { 'access' }
        Write-Information "No $what found on the $total site(s) checked." -InformationAction Continue
    }
}
