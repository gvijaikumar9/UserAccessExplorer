function Get-UserAccess {
    <#
    .SYNOPSIS
        Show what a user can access on one or more SharePoint sites, and HOW -
        grouped so the access they were never explicitly given stands out.

    .DESCRIPTION
        For each site, this reports the user's effective access and attributes it
        to a route: a SharePoint group, a direct grant, or an Everyone claim. Each
        route is classified Expected (they are a member / were granted it) or
        Unexpected (an Everyone claim - access they were never explicitly given,
        which is exactly what Copilot will surface).

        This is an admin tool. Reading a site's permissions needs Full Control on
        that site - a Contributor cannot see this. Run it as a Site Owner / Site
        Collection Admin, or with an app that has the rights.

        Read-only. Pipe the results to Export-UserAccessReport or Export-Csv.

    .PARAMETER User
        The user to report on, as a UPN (jane@contoso.com).

    .PARAMETER SiteUrl
        A single site to check.

    .PARAMETER SiteUrls
        Several sites to check.

    .PARAMETER UnexpectedOnly
        Return only the Unexpected routes - the access the user was never
        explicitly given.

    .PARAMETER Deep
        Walk below the site: subsites, then lists and libraries that have their
        own permissions. Add -IncludeItems to go all the way to individual files
        and items.

        Only objects that BREAK inheritance are examined - everything else
        already has its parent's answer - so the cost is proportional to how
        much the site has been shared, not to how big it is.

        Deep scans also find SHARING LINKS, which a normal scan cannot: an
        organisation-wide link grants no per-user permission at all, so it is
        invisible to "what can this user do here". It is found by asking what
        links an object carries and whether this user is in the audience.

    .PARAMETER IncludeItems
        With -Deep, descend to individual items and files. This is the expensive
        level: every list must be paged once to find which items broke
        inheritance. Measured between 4ms and 28ms per item, so a 100,000-item
        library is roughly 7 to 47 minutes. Use it on sites you care about, not
        across a whole tenant.

    .PARAMETER MaxItemsPerList
        Stop after this many items in any one list. A warning naming the list is
        emitted whenever this truncates, so partial results are never silent.
        0 (the default) means no cap.

    .PARAMETER ClientId
        Entra ID app registration client ID. Not needed with -UseExistingConnection.

    .EXAMPLE
        Get-UserAccess -User jane@contoso.com -SiteUrl "https://contoso.sharepoint.com/sites/Sales" -ClientId $id -Interactive

    .EXAMPLE
        Get-UserAccess -User jane@contoso.com -SiteUrls $sites -UseExistingConnection -UnexpectedOnly

    .EXAMPLE
        # Everything Jane can reach across the tenant, worst routes first
        Get-UserAccess -User jane@contoso.com -TenantWide `
            -TenantAdminUrl "https://contoso-admin.sharepoint.com" -ClientId $id -Interactive

    .EXAMPLE
        # All the way down - subsites, lists, and individual files - including
        # documents Jane can open through a sharing link she was never granted.
        Get-UserAccess -User jane@contoso.com -SiteUrl $site -ClientId $id -Interactive `
            -Deep -IncludeItems -UnexpectedOnly
    #>
    [CmdletBinding(DefaultParameterSetName = 'Site')]
    param(
        [Parameter(Mandatory)]
        [string]   $User,

        [Parameter(Mandatory, ParameterSetName = 'Site')]
        [string]   $SiteUrl,

        [Parameter(Mandatory, ParameterSetName = 'Sites')]
        [string[]] $SiteUrls,

        [Parameter(Mandatory, ParameterSetName = 'Tenant')]
        [switch]   $TenantWide,

        [Parameter(ParameterSetName = 'Tenant')]
        [string]   $TenantAdminUrl,

        [switch]   $UnexpectedOnly,

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

    $connectSplat = @{
        ClientId = $ClientId; Tenant = $Tenant
        CertificatePath = $CertificatePath; CertificatePassword = $CertificatePassword
        Thumbprint = $Thumbprint; Interactive = $Interactive
        ManagedIdentity = $ManagedIdentity; UseExistingConnection = $UseExistingConnection
    }

    $userLogin = ConvertTo-ClaimLogin -User $User

    if ($IncludeItems -and -not $Deep) {
        throw "-IncludeItems only means something with -Deep. Add -Deep, or drop -IncludeItems."
    }
    if ($Deep -and $UseExistingConnection) {
        # Each subweb is connected to in turn (PnP v2 dropped -Web), which an
        # existing connection cannot do - every subsite would be silently
        # skipped. Require real credentials so the whole tree is actually walked.
        throw "-Deep cannot be combined with -UseExistingConnection: subsites are connected to individually, so credentials (e.g. -ClientId -Interactive) are required."
    }
    if ($Deep -and $PSCmdlet.ParameterSetName -eq 'Tenant') {
        # Not blocked - an admin may genuinely want this - but they should know
        # what they are starting. Item level across a tenant can run for hours.
        Write-Warning "-Deep across an entire tenant walks every subsite and list of every site. This can run for a very long time. Consider -SiteUrls with the sites you actually care about."
    }

    $targets = switch ($PSCmdlet.ParameterSetName) {
        'Site'   { @($SiteUrl) }
        'Sites'  { $SiteUrls }
        'Tenant' {
            $null = $TenantWide
            if (-not $TenantAdminUrl) { throw "-TenantWide needs -TenantAdminUrl." }
            if ($UseExistingConnection) {
                throw "-UseExistingConnection cannot be combined with -TenantWide: each site is connected to in turn, so real credentials are required."
            }
            Connect-IfNeeded -Url $TenantAdminUrl @connectSplat
            Write-Verbose "Enumerating tenant sites..."
            (Invoke-WithRetry -Because 'Get-PnPTenantSite' -Action { Get-PnPTenantSite }) |
                Where-Object {
                    # Skip redirect stubs and the OneDrive/MySite host - the latter
                    # is not a content site and hangs on permission checks.
                    $_.Template -notlike 'REDIRECT*' -and
                    $_.Template -notlike 'SPSMSITEHOST*' -and
                    $_.Url -notlike '*-my.sharepoint.com*'
                } |
                Select-Object -ExpandProperty Url
        }
    }

    $total = @($targets).Count
    $n = 0
    $emitted = 0

    foreach ($site in $targets) {
        $n++
        Write-Progress -Activity "Checking $User's access" -Status "$n of $total : $site" `
                       -PercentComplete (($n / [Math]::Max($total,1)) * 100)
        try {
            Connect-IfNeeded -Url $site @connectSplat

            $rows =
                if ($Deep) {
                    Get-UserAccessDeep -SiteUrl $site -UserLogin $userLogin `
                        -ConnectSplat $connectSplat -IncludeItems:$IncludeItems `
                        -MaxItemsPerList $MaxItemsPerList
                } else {
                    Get-UserAccessForSite -SiteUrl $site -UserLogin $userLogin
                }

            $rows |
                Where-Object { -not $UnexpectedOnly -or $_.RouteType -eq 'Unexpected' } |
                ForEach-Object { $emitted++; $_ }
        }
        catch {
            Write-Warning "Skipped $site : $($_.Exception.Message)"
        }
    }

    Write-Progress -Activity "Checking $User's access" -Completed

    if ($emitted -eq 0) {
        $what = if ($UnexpectedOnly) { 'unexpected access' } else { 'access' }
        Write-Information "$User has no $what on the $total site(s) checked." -InformationAction Continue
    }
}
