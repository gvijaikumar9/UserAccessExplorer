function Test-SharingLinkAudience {
    <#
        Does THIS link reach THIS user?

        Split out from the crawl deliberately: this is pure decision logic with
        no SharePoint calls in it, so it can be unit-tested. It is also the most
        dangerous code in the module - getting it wrong either tells an admin a
        file is safe when anyone in the company can open it, or buries them in
        findings that do not apply. Both failures are silent.

        The rules:
          Anonymous     - anyone at all, signed in or not. Always applies.
          Organization  - anyone internal. Applies to any user we are asked about,
                          because we are only ever asked about internal users.
          Users         - restricted to named people. Applies ONLY if this user is
                          one of them.

        Returns $null when the link does not reach the user, so callers can just
        filter. Scope comes from the LINK, never from the group name - a modern
        link's group is named "...Flexible..." regardless of its real scope.
    #>
    param(
        # The .Link facet of a Get-PnPFileSharingLink result.
        [Parameter(Mandatory)] $Link,
        [Parameter(Mandatory)] [string] $UserUpn,
        # The .GrantedToIdentitiesV2 collection, when the scope is Users.
        $GrantedTo
    )

    if (-not $Link) { return $null }

    $scope = "$($Link.Scope)"
    $type  = "$($Link.Type)"

    $applies = $false
    $why     = ''

    if ($scope -match '^Anonymous') {
        $applies = $true; $why = 'anyone with the link'
    }
    elseif ($scope -match '^Organization') {
        $applies = $true; $why = 'anyone in the organisation'
    }
    elseif ($scope -match '^Users') {
        foreach ($g in @($GrantedTo)) {
            if (-not $g) { continue }
            $u = if ($g.PSObject.Properties.Name -contains 'User') { $g.User } else { $null }
            if (-not $u) { continue }
            foreach ($prop in 'Email', 'UserPrincipalName') {
                if ($u.PSObject.Properties.Name -contains $prop -and
                    "$($u.$prop)" -eq $UserUpn) {
                    $applies = $true; $why = 'named recipient'
                }
            }
        }
    }

    if (-not $applies) { return $null }

    [pscustomobject]@{
        # A View link grants Read; Edit and Review both let the user change things.
        Level = $(if ($type -match 'Edit|Review') { 'Edit' } else { 'Read' })
        Route = [pscustomobject]@{
            Route      = "Sharing link - $scope / $type ($why)"
            Type       = 'Overshared'
            Permission = $type
        }
    }
}

function Resolve-SharingLinkAudience {
    <#
        Ask a file what links it carries, and return the ones that reach this
        user. The I/O half of the pair - the decision half is
        Test-SharingLinkAudience, which is where the tests live.

        Sharing links are NOT a per-user grant. Verified 23 Jul 2026: an
        organisation-scope link put a SharingLinks.* group on an item's role
        assignments, yet GetUserEffectivePermissions for an ordinary org user
        returned every flag False. So this must be asked separately from "what
        can this user do here", and its answer trusted independently.
    #>
    param(
        [Parameter(Mandatory)] [string] $FileRef,
        [Parameter(Mandatory)] [string] $UserUpn
    )

    $links = @()
    try {
        $links = @(Get-PnPFileSharingLink -Identity $FileRef -ErrorAction Stop)
    } catch {
        # Folders and plain list items are not files - nothing to resolve.
        Write-Verbose "No file sharing links on $FileRef : $($_.Exception.Message)"
        return
    }

    foreach ($l in $links) {
        if (-not $l) { continue }
        $link = if ($l.PSObject.Properties.Name -contains 'Link') { $l.Link } else { $null }
        $granted = if ($l.PSObject.Properties.Name -contains 'GrantedToIdentitiesV2') { $l.GrantedToIdentitiesV2 } else { $null }

        $verdict = Test-SharingLinkAudience -Link $link -UserUpn $UserUpn -GrantedTo $granted
        if ($verdict) { $verdict }
    }
}
