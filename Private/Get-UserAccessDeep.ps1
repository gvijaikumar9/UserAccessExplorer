function Get-UserAccessDeep {
    <#
        The deep engine: one site, walked all the way down -
        web -> subwebs -> lists/libraries -> items.

        The design rests on ONE idea, verified against the lab 23 Jul 2026:
        permissions inherit, so only objects with HasUniqueRoleAssignments need
        their own evaluation. Everything else already has the parent's answer.
        That is not just the cheap path, it is the RIGHT target - breaking
        inheritance is what sharing links and one-off grants do, so the pruned
        set is exactly where oversharing lives.

        Important difference from Get-UserAccessForSite: that function early-exits
        when web-level access is 'None'. Here we must NOT, because a user granted
        a single item gets only "Limited Access" on the web - which does not
        include ViewListItems and so reads as 'None'. Early-exiting there is
        precisely what makes item-level access invisible.

        Assumes Connect-PnPOnline has already run for $SiteUrl. Subwebs are
        connected to in turn, because PnP v2 dropped -Web from these cmdlets.
    #>
    param(
        [Parameter(Mandatory)] [string] $SiteUrl,
        [Parameter(Mandatory)] [string] $UserLogin,

        # Passed through to Connect-IfNeeded for each subweb.
        [hashtable] $ConnectSplat = @{},

        # Items are the expensive level - the read pass is O(items) and its
        # throughput varies a lot (measured 4.4ms/item to 28ms/item on the same
        # list). Off unless asked for.
        [switch] $IncludeItems,

        # Effective-permission checks are queued and sent in one round trip.
        # Batching measured ~10x faster; this is not an optimisation, it is what
        # makes item level affordable at all.
        [int] $BatchSize = 100,

        # Safety valve for very large lists. 0 = no cap.
        [int] $MaxItemsPerList = 0
    )

    $userDisplay = ($UserLogin -split '\|')[-1]

    # ---- helpers -------------------------------------------------------------

    function Resolve-Level {
        param($Perms)
        if     ($Perms.Value.Has('FullMask') -or $Perms.Value.Has('ManagePermissions')) { 'Full Control' }
        elseif ($Perms.Value.Has('EditListItems'))  { 'Edit' }
        elseif ($Perms.Value.Has('ViewListItems'))  { 'Read' }
        else                                        { 'None' }
    }

    function Get-Route {
        <#
            Attribute access on ONE securable object to its routes. Same
            classification as the site-level engine, plus the sharing-link route
            which only appears below the web.
        #>
        param($Object, [string]$ObjectLabel)

        if (-not $Object) { return }

        $assignments = Invoke-WithRetry -Because "role assignments on $ObjectLabel" -Action {
            Get-PnPProperty -ClientObject $Object -Property RoleAssignments
        }

        foreach ($ra in $assignments) {
            $member = Get-PnPProperty -ClientObject $ra -Property Member
            $mLogin = Get-PnPProperty -ClientObject $member -Property LoginName
            $mTitle = Get-PnPProperty -ClientObject $member -Property Title
            $mType  = Get-PnPProperty -ClientObject $member -Property PrincipalType

            if (Test-SystemGroup $mTitle) { continue }

            $roles = (Get-PnPProperty -ClientObject $ra -Property RoleDefinitionBindings |
                        ForEach-Object { $_.Name }) -join ', '

            $route = $null; $routeType = $null

            if (Test-SharingLinkGroup $mTitle $mLogin) {
                $kind  = Get-SharingLinkKind $mTitle
                $route = "Sharing link ($kind)"
                $routeType = 'Unexpected'
            }
            elseif (Test-EveryoneClaim $mLogin $mTitle) {
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
                # Never $mem.LoginName - on an empty group that throws under
                # StrictMode exactly like $null.LoginName.
                if ($mem | Where-Object { $_.LoginName -eq $UserLogin }) {
                    $route = "SharePoint group '$mTitle'"
                    $routeType = 'Expected'
                }
            }
            elseif ($mType -eq 'SecurityGroup') {
                $route = "Entra group '$mTitle' (membership unconfirmed)"
                $routeType = 'Expected'
            }

            if ($route) { [pscustomobject]@{ Route = $route; Type = $routeType; Permission = $roles } }
        }
    }

    function ConvertTo-AccessRow {
        param(
            [string]$WebUrl, [string]$WebTitle,
            [string]$ObjectType, [string]$ObjectTitle, [string]$ObjectUrl,
            [string]$Level, $Route, [hashtable]$Meta = @{}
        )
        [pscustomobject]@{
            User            = $userDisplay
            SiteUrl         = $SiteUrl
            WebUrl          = $WebUrl
            SiteTitle       = $WebTitle
            ObjectType      = $ObjectType      # Web | List | Item
            ObjectTitle     = $ObjectTitle
            ObjectUrl       = $ObjectUrl
            EffectiveAccess = $Level
            GrantedVia      = $Route.Route
            RouteType       = $Route.Type
            Permission      = $Route.Permission
            ItemType        = $(if ($Meta.ContainsKey('ItemType')) { $Meta.ItemType } else { $null })
            Modified        = $(if ($Meta.ContainsKey('Modified')) { $Meta.Modified } else { $null })
            ModifiedBy      = $(if ($Meta.ContainsKey('ModifiedBy')) { $Meta.ModifiedBy } else { $null })
            CreatedBy       = $(if ($Meta.ContainsKey('CreatedBy')) { $Meta.CreatedBy } else { $null })
            Size            = $(if ($Meta.ContainsKey('Size')) { $Meta.Size } else { $null })
        }
    }

    # ---- 1. the web tree -----------------------------------------------------

    $webs = @(Invoke-WithRetry -Because 'Get-PnPSubWeb' -Action {
        Get-PnPSubWeb -Recurse -IncludeRootWeb
    })
    Write-Verbose "Webs to walk: $($webs.Count)"

    foreach ($wStub in $webs) {
        $webUrl = $wStub.Url
        try {
            if ($webUrl -ne $SiteUrl) { Connect-IfNeeded -Url $webUrl @ConnectSplat }
        } catch {
            Write-Warning "Skipped web $webUrl : $($_.Exception.Message)"
            continue
        }

        $web = Invoke-WithRetry -Because 'Get-PnPWeb' -Action { Get-PnPWeb }
        $ctx = Get-PnPContext

        $webTitle = Get-PnPProperty -ClientObject $web -Property Title
        if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $webUrl }

        # ---- web level ------------------------------------------------------
        $wPerms = $web.GetUserEffectivePermissions($UserLogin)
        Invoke-WithRetry -Because 'web effective permissions' -Action { $ctx.ExecuteQuery() }
        $webLevel = Resolve-Level $wPerms

        if ($webLevel -ne 'None') {
            foreach ($r in (Get-Route -Object $web -ObjectLabel $webTitle)) {
                ConvertTo-AccessRow -WebUrl $webUrl -WebTitle $webTitle -ObjectType 'Web' `
                        -ObjectTitle $webTitle -ObjectUrl $webUrl -Level $webLevel -Route $r
            }
        }
        # NOTE: no early exit. Limited Access reads as 'None' but still permits
        # item-level access - see the header comment.

        # ---- lists ----------------------------------------------------------
        $lists = @()
        try {
            $lists = @(Invoke-WithRetry -Because 'Get-PnPList' -Action {
                Get-PnPList -Includes HasUniqueRoleAssignments, ItemCount, Hidden, BaseType
            }) | Where-Object { -not $_.Hidden }
        } catch {
            Write-Warning "Cannot read lists on $webUrl : $($_.Exception.Message)"
            continue
        }

        foreach ($list in $lists) {
            $listUrl = "$webUrl/$($list.Title)"

            if ($list.HasUniqueRoleAssignments) {
                $lPerms = $list.GetUserEffectivePermissions($UserLogin)
                Invoke-WithRetry -Because "list perms $($list.Title)" -Action { $ctx.ExecuteQuery() }
                $listLevel = Resolve-Level $lPerms
                if ($listLevel -ne 'None') {
                    foreach ($r in (Get-Route -Object $list -ObjectLabel $list.Title)) {
                        ConvertTo-AccessRow -WebUrl $webUrl -WebTitle $webTitle -ObjectType 'List' `
                                -ObjectTitle $list.Title -ObjectUrl $listUrl -Level $listLevel -Route $r
                    }
                }
            }

            if (-not $IncludeItems -or $list.ItemCount -eq 0) { continue }

            # ---- items: the pruning pass ------------------------------------
            $items = @()
            try {
                $items = @(Invoke-WithRetry -Because "page items of $($list.Title)" -Action {
                    Get-PnPListItem -List $list -PageSize 2000 -Includes HasUniqueRoleAssignments, Id
                })
            } catch {
                Write-Warning "Cannot page '$($list.Title)' on $webUrl : $($_.Exception.Message)"
                continue
            }

            if ($MaxItemsPerList -gt 0 -and $items.Count -gt $MaxItemsPerList) {
                Write-Warning "'$($list.Title)' has $($items.Count) items; capped at $MaxItemsPerList. Results are INCOMPLETE for this list."
                $items = $items[0..($MaxItemsPerList - 1)]
            }

            $unique = @($items | Where-Object { $_.HasUniqueRoleAssignments })
            if ($unique.Count -eq 0) { continue }
            Write-Verbose "$($list.Title): $($unique.Count) of $($items.Count) items broke inheritance"

            # Batch the permission checks - one round trip per BatchSize items.
            for ($i = 0; $i -lt $unique.Count; $i += $BatchSize) {
                $end   = [Math]::Min($i + $BatchSize - 1, $unique.Count - 1)
                $chunk = $unique[$i..$end]

                $pending = foreach ($it in $chunk) {
                    [pscustomobject]@{ Item = $it; Perms = $it.GetUserEffectivePermissions($UserLogin) }
                }
                Invoke-WithRetry -Because 'batched item permissions' -Action { $ctx.ExecuteQuery() }

                foreach ($p in $pending) {
                    $lvl = Resolve-Level $p.Perms
                    $it  = $p.Item
                    $fv = $it.FieldValues
                    $name = if ($fv.ContainsKey('FileLeafRef')) { $fv['FileLeafRef'] } else { "Item $($it.Id)" }
                    $ref  = if ($fv.ContainsKey('FileRef'))     { $fv['FileRef'] }     else { $listUrl }

                    # Metadata is free with the item, but is NOT the same set on a
                    # list and a library - file size simply does not exist on a
                    # list item, so only include what is actually present.
                    $meta = @{ ItemType = "$($it.FileSystemObjectType)" }
                    foreach ($pair in @(@('Modified','Modified'), @('Created','Created'))) {
                        if ($fv.ContainsKey($pair[0])) { $meta[$pair[1]] = $fv[$pair[0]] }
                    }
                    foreach ($pair in @(@('Editor','ModifiedBy'), @('Author','CreatedBy'))) {
                        if ($fv.ContainsKey($pair[0]) -and $fv[$pair[0]]) {
                            $v = $fv[$pair[0]]
                            $meta[$pair[1]] = if ($v.PSObject.Properties.Name -contains 'LookupValue') { $v.LookupValue } else { "$v" }
                        }
                    }
                    if ($fv.ContainsKey('File_x0020_Size')) { $meta['Size'] = $fv['File_x0020_Size'] }

                    # Walk the role assignments ONCE, then answer two independent
                    # questions from it - they have different answers.
                    $allRoutes    = @(Get-Route -Object $it -ObjectLabel $name)
                    $hasLinkGroup = @($allRoutes | Where-Object { $_.Route -like 'Sharing link*' })

                    # 1. "What can this user do here?" - covers direct grants,
                    #    group membership and Everyone claims. Only meaningful if
                    #    they actually have effective access.
                    if ($lvl -ne 'None') {
                        foreach ($r in ($allRoutes | Where-Object { $_.Route -notlike 'Sharing link*' })) {
                            ConvertTo-AccessRow -WebUrl $webUrl -WebTitle $webTitle -ObjectType 'Item' `
                                    -ObjectTitle $name -ObjectUrl $ref -Level $lvl -Route $r -Meta $meta
                        }
                    }

                    # 2. "What links does this object carry, and is this user in
                    #    the audience?" - sharing links never show up in (1), so
                    #    this runs regardless of effective permissions. Only pay
                    #    for the extra call when a SharingLinks group is present.
                    if ($hasLinkGroup) {
                        foreach ($sl in (Resolve-SharingLinkAudience -FileRef $ref -UserUpn $userDisplay)) {
                            ConvertTo-AccessRow -WebUrl $webUrl -WebTitle $webTitle -ObjectType 'Item' `
                                    -ObjectTitle $name -ObjectUrl $ref -Level $sl.Level -Route $sl.Route -Meta $meta
                        }
                    }
                }
            }
        }
    }
}
