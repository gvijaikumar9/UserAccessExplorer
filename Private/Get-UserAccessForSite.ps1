function Get-UserAccessForSite {
    <#
        The engine, for one already-connected site. Answers two questions and joins
        them: CAN the user access this site and at what level (effective
        permissions), and HOW - attributed to each route, classified Granted
        (member / direct grant) or Overshared (an Everyone claim they were never
        explicitly given).

        Assumes Connect-PnPOnline has already run for this site.
    #>
    param(
        [Parameter(Mandatory)] [string] $SiteUrl,
        [Parameter(Mandatory)] [string] $UserLogin,
        # Per-scan (user,group) -> membership cache, shared across sites.
        [hashtable] $MembershipCache = @{}
    )

    # Clean UPN for display and for the Graph membership check, not the
    # i:0#.f|membership| claims login.
    $userDisplay = ($UserLogin -split '\|')[-1]

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
            $routeType = 'Overshared'
        }
        elseif ($mType -eq 'User' -and $mLogin -eq $UserLogin) {
            $route = 'Direct grant'
            $routeType = 'Granted'
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
                $routeType = 'Granted'
            }
        }
        elseif ($mType -eq 'SecurityGroup') {
            # An Entra security or M365 group. Confirm the user is actually in it
            # (transitively, so nesting counts) via Graph. A confirmed non-member
            # is dropped - listing a route the user is not in is a false positive.
            # If Graph cannot answer, keep the honest "unconfirmed" label.
            $gid = Get-GroupIdFromLogin $mLogin
            $isMember = if ($gid) { Test-UserIsGroupMember -UserUpn $userDisplay -GroupId $gid -Cache $MembershipCache } else { $null }
            if ($isMember -ne $false) {
                $suffix = if ($isMember) { '' } else { ' (membership unconfirmed)' }
                $route = "Entra group '$mTitle'$suffix"
                $routeType = 'Granted'
            }
        }

        if ($route) {
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
                RouteType       = $routeType       # Granted | Overshared
                Permission      = $roles           # what THIS route grants
                # Deep-link straight to this site's advanced-permissions page, so
                # the GUI can open where the access is managed in one click.
                PermUrl         = "$SiteUrl/_layouts/15/user.aspx"
            }
        }
    }
}
