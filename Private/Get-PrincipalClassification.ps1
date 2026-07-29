function Get-PrincipalClassification {
    <#
        Classify a single role-assignment principal into what it IS and whether it
        is a Granted or Overshared route. The site-centric mirror of the user-centric
        route attribution in Get-UserAccessForSite - there we ask "is this the user";
        here we report every principal for its own sake.

        Pure - only the pure Test-* helpers, no SharePoint calls - so it is unit-tested.

        Kind:      User | SharePointGroup | EntraGroup | Everyone | SharingLink | Other
        RouteType: Overshared for an Everyone claim or a sharing link (access nobody
                   was explicitly given); Granted for a named user or group.
    #>
    param(
        [string] $PrincipalType,   # the CSOM PrincipalType: User / SharePointGroup / SecurityGroup / ...
        [string] $LoginName,
        [string] $Title
    )

    if (Test-EveryoneClaim $LoginName $Title) {
        return [pscustomobject]@{ Kind = 'Everyone'; RouteType = 'Overshared'; Display = $Title }
    }
    if (Test-SharingLinkGroup $Title $LoginName) {
        return [pscustomobject]@{ Kind = 'SharingLink'; RouteType = 'Overshared'; Display = "Sharing link ($(Get-SharingLinkKind $Title))" }
    }

    switch ("$PrincipalType") {
        'User'            { [pscustomobject]@{ Kind = 'User';            RouteType = 'Granted'; Display = $Title } }
        'SharePointGroup' { [pscustomobject]@{ Kind = 'SharePointGroup'; RouteType = 'Granted'; Display = $Title } }
        'SecurityGroup'   { [pscustomobject]@{ Kind = 'EntraGroup';      RouteType = 'Granted'; Display = $Title } }
        default           { [pscustomobject]@{ Kind = 'Other';           RouteType = 'Granted'; Display = $Title } }
    }
}
