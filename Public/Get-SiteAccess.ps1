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

    .PARAMETER ExpandMembers
        Expand every group to one row per person (the group is carried in Via),
        turning the report into the full list of people who can actually reach the
        site. Without it, each group is a single row with a member count. Needs Graph
        GroupMember.Read.All to resolve Entra groups.

    .PARAMETER Deep
        Walk below the site - subsites, then the lists and items that have their OWN
        permissions - and report who can reach each. Only objects that break
        inheritance are examined, which is exactly where oversharing (a sharing link,
        a one-off Everyone grant) lives. Add -IncludeItems to descend to files/items.

    .PARAMETER IncludeItems
        With -Deep, descend to individual items and files. The expensive level: every
        list is paged once to find which items broke inheritance.

    .PARAMETER MaxItemsPerList
        Stop after this many items in any one list (a warning names the list when it
        truncates). 0 (the default) means no cap.

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

        [switch]   $ExpandMembers,

        [switch]   $Deep,
        [switch]   $IncludeItems,
        [int]      $MaxItemsPerList = 0,

        [string]       $ClientId,
        [string]       $Tenant,
        [string]       $CertificatePath,
        [securestring] $CertificatePassword,
        [string]       $Thumbprint,
        [switch]       $Interactive,
        [switch]       $ManagedIdentity,
        [switch]       $UseExistingConnection
    )

    if ($IncludeItems -and -not $Deep) {
        throw "-IncludeItems only means something with -Deep. Add -Deep, or drop -IncludeItems."
    }
    if ($Deep -and $UseExistingConnection) {
        # Each subweb is connected to in turn (PnP v2 dropped -Web), which an existing
        # connection cannot do - every subsite would be silently skipped.
        throw "-Deep cannot be combined with -UseExistingConnection: subsites are connected to individually, so credentials (e.g. -ClientId -Interactive) are required."
    }

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
    # One group -> count/members cache for the whole run: a group on many sites is
    # resolved against Graph once.
    $membershipCache = @{}

    foreach ($site in $targets) {
        $n++
        Write-Progress -Activity "Checking who can reach the site(s)" -Status "$n of $total : $site" `
                       -PercentComplete (($n / [Math]::Max($total,1)) * 100)
        try {
            Connect-IfNeeded -Url $site @connectSplat
            $rows = if ($Deep) {
                Get-SiteAccessDeep -SiteUrl $site -ConnectSplat $connectSplat -IncludeItems:$IncludeItems `
                    -MaxItemsPerList $MaxItemsPerList -MembershipCache $membershipCache -ExpandMembers:$ExpandMembers
            } else {
                Get-SiteAccessForWeb -WebUrl $site -MembershipCache $membershipCache -ExpandMembers:$ExpandMembers
            }
            $rows |
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
