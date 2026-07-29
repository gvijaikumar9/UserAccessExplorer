function Get-SiteAccessForWeb {
    <#
        The site-centric engine, for one already-connected web. Walks the web's role
        assignments and reports EVERY principal that can reach it, and how - the
        mirror of Get-UserAccessForSite, which filters the same walk down to one user.

        It reports the route each principal holds (the role it is bound to), not a
        computed effective level: effective permissions are a per-USER question, and
        here the subject is the object, not a user. A SharePoint group is expanded to
        a member COUNT so "who, and how many" is answered without one row per person -
        full member expansion is a separate, opt-in pass.

        Assumes Connect-PnPOnline has already run for this web.
    #>
    param(
        [Parameter(Mandatory)] [string] $WebUrl,
        # Site for the root web; Subsite/List/Item once the deep walk calls in here.
        [string] $ObjectKind = 'Site'
    )

    $web = Invoke-WithRetry -Because 'Get-PnPWeb' -Action { Get-PnPWeb }

    $webTitle = Get-PnPProperty -ClientObject $web -Property Title
    if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $WebUrl }

    $assignments = Invoke-WithRetry -Because 'role assignments' -Action {
        Get-PnPProperty -ClientObject $web -Property RoleAssignments
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

        # Expand a SharePoint group to how many people it holds. Iterate, never touch
        # $mem.Count via .LoginName - an empty group is @(), and @().Prop throws under
        # StrictMode. .Count on the wrapped array is safe.
        $memberCount = $null
        if ($c.Kind -eq 'SharePointGroup') {
            $mem = @(Invoke-WithRetry -Because "members of $mTitle" -Action {
                Get-PnPGroupMember -Group $mTitle -ErrorAction SilentlyContinue
            })
            $memberCount = $mem.Count
        }

        [pscustomobject]@{
            SiteUrl       = $WebUrl
            SiteTitle     = $webTitle
            Principal     = $c.Display          # WHO can reach it
            PrincipalType = $c.Kind             # User / SharePointGroup / EntraGroup / Everyone / SharingLink / Other
            MemberCount   = $memberCount        # people in the group, when it is one
            Permission    = $roles              # what THIS route grants (Read / Edit / Full Control / ...)
            RouteType     = $c.RouteType        # Granted | Overshared
            ObjectKind    = $ObjectKind
            ObjectTitle   = $webTitle
            ObjectUrl     = $WebUrl
            PermUrl       = "$WebUrl/_layouts/15/user.aspx"
            LoginName     = $mLogin             # kept for member expansion / debugging
        }
    }
}
