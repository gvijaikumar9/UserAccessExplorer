function Get-UserAccessForSite {
    <#
        The engine, for one already-connected site. Answers two questions and joins
        them: CAN the user access this site and at what level (effective
        permissions), and HOW - attributed to each route, classified Expected
        (member / direct grant) or Unexpected (an Everyone claim they were never
        explicitly given).

        Assumes Connect-PnPOnline has already run for this site.
    #>
    param(
        [Parameter(Mandatory)] [string] $SiteUrl,
        [Parameter(Mandatory)] [string] $UserLogin
    )

    $web = Invoke-WithRetry -Because 'Get-PnPWeb' -Action { Get-PnPWeb }
    $ctx = Get-PnPContext

    # 1. definitive: what can they actually do here?
    $perms = $web.GetUserEffectivePermissions($UserLogin)
    Invoke-WithRetry -Because 'effective permissions' -Action { $ctx.ExecuteQuery() }

    $level =
        if     ($perms.Value.Has('FullMask') -or $perms.Value.Has('ManagePermissions')) { 'Full Control' }
        elseif ($perms.Value.Has('EditListItems'))  { 'Edit' }
        elseif ($perms.Value.Has('ViewListItems'))  { 'Read' }
        else                                        { 'None' }

    if ($level -eq 'None') { return }   # no effective access here - nothing to report

    # 2. how - attribute the access to routes
    $assignments = Invoke-WithRetry -Because 'role assignments' -Action {
        Get-PnPProperty -ClientObject $web -Property RoleAssignments
    }

    foreach ($ra in $assignments) {
        $member = Get-PnPProperty -ClientObject $ra -Property Member

        # Load the sub-properties EXPLICITLY. Get-PnPProperty -Property Member loads
        # the object but leaves LoginName/Title/PrincipalType lazily loaded, so under
        # StrictMode an unloaded one throws "property cannot be found". Loading each
        # here makes it deterministic.
        $mLogin = Get-PnPProperty -ClientObject $member -Property LoginName
        $mTitle = Get-PnPProperty -ClientObject $member -Property Title
        $mType  = Get-PnPProperty -ClientObject $member -Property PrincipalType

        if (Test-SystemGroup $mTitle) { continue }

        $roles = (Get-PnPProperty -ClientObject $ra -Property RoleDefinitionBindings |
                    ForEach-Object { $_.Name }) -join ', '

        $route = $null; $routeType = $null

        if (Test-EveryoneClaim $mLogin $mTitle) {
            $route = "Everyone claim ($mTitle)"
            $routeType = 'Unexpected'
        }
        elseif ($mType -eq 'User' -and $mLogin -eq $UserLogin) {
            $route = 'Direct grant'
            $routeType = 'Expected'
        }
        elseif ($mType -eq 'SharePointGroup') {
            $mem = @(Invoke-WithRetry -Because "members of $mTitle" -Action {
                Get-PnPGroupMember -Group $mTitle -ErrorAction SilentlyContinue
            })
            # Iterate, do NOT do $mem.LoginName. On an EMPTY group $mem is @(),
            # and @().LoginName throws under StrictMode exactly like $null.LoginName.
            # Where-Object over an empty array is simply falsy - no property access
            # on the collection itself.
            if ($mem | Where-Object { $_.LoginName -eq $UserLogin }) {
                $route = "SharePoint group '$mTitle'"
                $routeType = 'Expected'
            }
        }
        elseif ($mType -eq 'SecurityGroup') {
            # An Entra security or M365 group. The user might be in it; confirming
            # membership needs Graph, which the tenant-wide path does. On a single
            # site we flag it rather than claim certainty.
            $route = "Entra group '$mTitle' (membership unconfirmed)"
            $routeType = 'Expected'
        }

        if ($route) {
            # Clean UPN for display, not the i:0#.f|membership| claims login.
            $userDisplay = ($UserLogin -split '\|')[-1]
            # Some sites (the root collection) return an empty title - fall back
            # to the URL so no row is blank.
            $webTitle = Get-PnPProperty -ClientObject $web -Property Title
            if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $SiteUrl }

            [pscustomobject]@{
                User            = $userDisplay
                SiteUrl         = $SiteUrl
                SiteTitle       = $webTitle
                EffectiveAccess = $level          # the user's OVERALL access here
                GrantedVia      = $route
                RouteType       = $routeType       # Expected | Unexpected
                Permission      = $roles           # what THIS route grants
            }
        }
    }
}
