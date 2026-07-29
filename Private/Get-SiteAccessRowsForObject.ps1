function Get-SiteAccessRowsForObject {
    <#
        Walk ONE securable's role assignments (a web, list or item - all
        SecurableObjects) and emit a row per principal that can reach it, classified
        and, on request, expanded to people. The shared core of the site-centric
        engine: Get-SiteAccessForWeb calls it for a web, Get-SiteAccessDeep calls it
        for every subsite, list and item that breaks inheritance.

        It reports the route each principal holds, not a computed effective level -
        effective permissions are a per-user question and the subject here is the
        object. The object's identity (kind, title, url, permissions page) is passed
        in so the same walk serves every level of the tree.
    #>
    param(
        [Parameter(Mandatory)] $Object,                 # a SecurableObject with RoleAssignments
        [Parameter(Mandatory)] [string] $SiteUrl,       # the containing web
        [Parameter(Mandatory)] [string] $SiteTitle,
        [string]    $ObjectKind  = 'Site',
        [string]    $ObjectTitle = '',
        [string]    $ObjectUrl   = '',
        [string]    $PermUrl     = '',
        [hashtable] $MembershipCache = @{},
        [switch]    $ExpandMembers
    )

    if (-not $ObjectTitle) { $ObjectTitle = $SiteTitle }
    if (-not $ObjectUrl)   { $ObjectUrl   = $SiteUrl }
    if (-not $PermUrl)     { $PermUrl     = "$SiteUrl/_layouts/15/user.aspx" }

    # Local so PSSA sees $Object used - it does not look inside the retry scriptblock.
    $securable = $Object
    $assignments = Invoke-WithRetry -Because "role assignments on $ObjectTitle" -Action {
        Get-PnPProperty -ClientObject $securable -Property RoleAssignments
    }

    # One row builder for the group and expanded-person paths. Object-identity fields
    # are passed in, not closed over, so PSSA sees them used (it does not look inside
    # script blocks).
    $newRow = {
        param($Su, $St, $Kind, $Ot, $Ou, $Pu, $Principal, $PrincipalType, $MemberCount, $Via, $Perm, $RouteType, $Login)
        [pscustomobject]@{
            SiteUrl       = $Su
            SiteTitle     = $St
            Principal     = $Principal
            PrincipalType = $PrincipalType
            MemberCount   = $MemberCount
            Via           = $Via
            Permission    = $Perm
            RouteType     = $RouteType
            ObjectKind    = $Kind
            ObjectTitle   = $Ot
            ObjectUrl     = $Ou
            PermUrl       = $Pu
            LoginName     = $Login
        }
    }

    foreach ($ra in $assignments) {
        $member = Get-PnPProperty -ClientObject $ra -Property Member

        # Load sub-properties explicitly - Member loads lazily and StrictMode throws
        # on an unloaded LoginName/Title/PrincipalType.
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
                & $newRow $SiteUrl $SiteTitle $ObjectKind $ObjectTitle $ObjectUrl $PermUrl $pname 'User' $null $c.Display $roles $c.RouteType "$($p.Upn)"
            }
        }
        else {
            $via = if ($c.Kind -eq 'User') { 'Direct grant' } else { '' }
            & $newRow $SiteUrl $SiteTitle $ObjectKind $ObjectTitle $ObjectUrl $PermUrl $c.Display $c.Kind $memberCount $via $roles $c.RouteType $mLogin
        }
    }
}
