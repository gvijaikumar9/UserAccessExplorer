function Get-SiteAccessForWeb {
    <#
        The site-centric engine, for one already-connected web. Walks the web's role
        assignments and reports EVERY principal that can reach it, and how - the
        mirror of Get-UserAccessForSite, which filters the same walk down to one user.

        It reports the route each principal holds (the role it is bound to), not a
        computed effective level: effective permissions are a per-USER question, and
        here the subject is the object, not a user.

        A group is resolved to its PEOPLE. By default that is a member COUNT, so "who,
        and how many" is answered without one row per person. With -ExpandMembers each
        group becomes one row per resolved person, with the group carried in Via - the
        full "who can actually reach this" list.

        Assumes Connect-PnPOnline has already run for this web.
    #>
    param(
        [Parameter(Mandatory)] [string] $WebUrl,
        # Site for the root web; Subsite/List/Item once the deep walk calls in here.
        [string]    $ObjectKind = 'Site',
        # Per-scan group -> count/members cache, shared across sites.
        [hashtable] $MembershipCache = @{},
        # Emit one row per person instead of a group + count.
        [switch]    $ExpandMembers
    )

    $web = Invoke-WithRetry -Because 'Get-PnPWeb' -Action { Get-PnPWeb }

    $webTitle = Get-PnPProperty -ClientObject $web -Property Title
    if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $WebUrl }

    $assignments = Invoke-WithRetry -Because 'role assignments' -Action {
        Get-PnPProperty -ClientObject $web -Property RoleAssignments
    }

    # One row builder so the group and expanded-person paths stay identical. The
    # loop-invariant fields are passed in, not closed over, so PSSA sees $ObjectKind
    # used (it does not look inside script blocks).
    $newRow = {
        param($SiteUrl, $SiteTitle, $Kind, $Principal, $PrincipalType, $MemberCount, $Via, $Perm, $RouteType, $Login)
        [pscustomobject]@{
            SiteUrl       = $SiteUrl
            SiteTitle     = $SiteTitle
            Principal     = $Principal        # WHO can reach it
            PrincipalType = $PrincipalType    # User / SharePointGroup / EntraGroup / Everyone / SharingLink / Other
            MemberCount   = $MemberCount      # people in the group, when it is one and not expanded
            Via           = $Via              # the group an expanded person came through ('Direct grant' for a direct user)
            Permission    = $Perm             # what THIS route grants (Read / Edit / Full Control / ...)
            RouteType     = $RouteType        # Granted | Overshared
            ObjectKind    = $Kind
            ObjectTitle   = $SiteTitle
            ObjectUrl     = $SiteUrl
            PermUrl       = "$SiteUrl/_layouts/15/user.aspx"
            LoginName     = $Login
        }
    }

    foreach ($ra in $assignments) {
        $member = Get-PnPProperty -ClientObject $ra -Property Member

        # Load the sub-properties EXPLICITLY - Get-PnPProperty -Property Member loads
        # the object but leaves LoginName/Title/PrincipalType lazily loaded, so under
        # StrictMode an unloaded one throws "property cannot be found".
        $mLogin = Get-PnPProperty -ClientObject $member -Property LoginName
        $mTitle = Get-PnPProperty -ClientObject $member -Property Title
        $mType  = Get-PnPProperty -ClientObject $member -Property PrincipalType

        if (Test-SystemGroup $mTitle) { continue }

        $roles = (Get-PnPProperty -ClientObject $ra -Property RoleDefinitionBindings |
                    ForEach-Object { $_.Name }) -join ', '

        $c = Get-PrincipalClassification -PrincipalType "$mType" -LoginName $mLogin -Title $mTitle

        # Resolve a group to its people (count always; the list only when expanding).
        $memberCount = $null
        $people      = @()
        if ($c.Kind -eq 'SharePointGroup') {
            # Iterate, never $mem.Prop on the collection - an empty group is @() and
            # @().Prop throws under StrictMode. .Count on the wrapped array is safe.
            $mem = @(Invoke-WithRetry -Because "members of $mTitle" -Action {
                Get-PnPGroupMember -Group $mTitle -ErrorAction SilentlyContinue
            })
            $memberCount = $mem.Count
            if ($ExpandMembers) {
                $people = $mem | ForEach-Object {
                    [pscustomobject]@{ Upn = ($_.LoginName -split '\|')[-1]; Display = $_.Title }
                }
            }
        }
        elseif ($c.Kind -eq 'EntraGroup') {
            $gid = Get-GroupIdFromLogin $mLogin
            if ($gid) {
                $eg = Resolve-EntraGroup -GroupId $gid -Cache $MembershipCache -IncludeMembers:$ExpandMembers
                $memberCount = $eg.Count
                if ($ExpandMembers) { $people = $eg.Members }
            }
        }

        $isGroup = ($c.Kind -eq 'SharePointGroup' -or $c.Kind -eq 'EntraGroup')

        if ($ExpandMembers -and $isGroup -and @($people).Count -gt 0) {
            foreach ($p in @($people)) {
                $pname = if ("$($p.Display)") { "$($p.Display)" } else { "$($p.Upn)" }
                & $newRow $WebUrl $webTitle $ObjectKind $pname 'User' $null $c.Display $roles $c.RouteType "$($p.Upn)"
            }
        }
        else {
            $via = if ($c.Kind -eq 'User') { 'Direct grant' } else { '' }
            & $newRow $WebUrl $webTitle $ObjectKind $c.Display $c.Kind $memberCount $via $roles $c.RouteType $mLogin
        }
    }
}
