function Get-SiteAccessForWeb {
    <#
        Site-centric engine for one already-connected web: report every principal
        that can reach the web itself, and how. A thin wrapper over
        Get-SiteAccessRowsForObject (the shared per-securable walk) - the deep engine
        calls that same walk for subsites, lists and items.

        Assumes Connect-PnPOnline has already run for this web.
    #>
    param(
        [Parameter(Mandatory)] [string] $WebUrl,
        [string]    $ObjectKind = 'Site',
        [hashtable] $MembershipCache = @{},
        [switch]    $ExpandMembers
    )

    $web = Invoke-WithRetry -Because 'Get-PnPWeb' -Action { Get-PnPWeb }

    $webTitle = Get-PnPProperty -ClientObject $web -Property Title
    if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $WebUrl }

    Get-SiteAccessRowsForObject -Object $web -SiteUrl $WebUrl -SiteTitle $webTitle `
        -ObjectKind $ObjectKind -ObjectTitle $webTitle -ObjectUrl $WebUrl `
        -PermUrl "$WebUrl/_layouts/15/user.aspx" `
        -MembershipCache $MembershipCache -ExpandMembers:$ExpandMembers
}
