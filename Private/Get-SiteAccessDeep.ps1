function Get-SiteAccessDeep {
    <#
        The site-centric deep engine: one site, walked all the way down -
        web -> subwebs -> lists/libraries -> items - reporting who can reach each
        object that has its OWN permissions.

        Same pruning idea as the user-centric deep engine (Get-UserAccessDeep):
        permissions inherit, so only objects with HasUniqueRoleAssignments need their
        own walk; everything else has its parent's answer. That pruned set is also
        exactly where oversharing lives - a sharing link or a one-off Everyone grant
        is what breaks inheritance in the first place.

        Unlike the user-centric engine there is NO effective-permission pass here: the
        subject is the object, so we enumerate its principals directly. That makes the
        item level cheaper - a role-assignment read per unique item, no per-item
        permission round trip.

        Assumes Connect-PnPOnline has already run for $SiteUrl. Subwebs are connected
        to in turn, because PnP v2 dropped -Web from these cmdlets.
    #>
    param(
        [Parameter(Mandatory)] [string] $SiteUrl,
        [hashtable] $ConnectSplat = @{},
        [switch]    $IncludeItems,
        [int]       $MaxItemsPerList = 0,
        [hashtable] $MembershipCache = @{},
        [switch]    $ExpandMembers
    )

    $common = @{ MembershipCache = $MembershipCache; ExpandMembers = $ExpandMembers }

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
        $webTitle = Get-PnPProperty -ClientObject $web -Property Title
        if ([string]::IsNullOrWhiteSpace($webTitle)) { $webTitle = $webUrl }

        $isRoot = ($webUrl -eq $SiteUrl)

        # A subweb that inherits has the same principals as its parent - already
        # reported. Walk it only when it is the root or broke inheritance.
        $webUnique = if ($isRoot) { $true } else {
            Get-PnPProperty -ClientObject $web -Property HasUniqueRoleAssignments
        }
        if ($webUnique) {
            $webKind = if ($isRoot) { 'Site' } else { 'Subsite' }
            Get-SiteAccessRowsForObject -Object $web -SiteUrl $webUrl -SiteTitle $webTitle `
                -ObjectKind $webKind -ObjectTitle $webTitle -ObjectUrl $webUrl `
                -PermUrl "$webUrl/_layouts/15/user.aspx" @common
        }

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
            $listUrl  = "$webUrl/$($list.Title)"
            $listKind = if ("$($list.BaseType)" -eq 'DocumentLibrary') { 'Library' } else { 'List' }

            if ($list.HasUniqueRoleAssignments) {
                Get-SiteAccessRowsForObject -Object $list -SiteUrl $webUrl -SiteTitle $webTitle `
                    -ObjectKind $listKind -ObjectTitle $list.Title -ObjectUrl $listUrl `
                    -PermUrl "$webUrl/_layouts/15/user.aspx?obj=$($list.Id)%2Cdoclib&List=$($list.Id)" @common
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

            foreach ($it in $unique) {
                $fv       = $it.FieldValues
                $name     = if ($fv.ContainsKey('FileLeafRef')) { $fv['FileLeafRef'] } else { "Item $($it.Id)" }
                $ref      = if ($fv.ContainsKey('FileRef'))     { $fv['FileRef'] }     else { $listUrl }
                $itemKind = switch ("$($it.FileSystemObjectType)") { 'Folder' { 'Folder' } 'File' { 'File' } default { 'Item' } }

                Get-SiteAccessRowsForObject -Object $it -SiteUrl $webUrl -SiteTitle $webTitle `
                    -ObjectKind $itemKind -ObjectTitle $name -ObjectUrl $ref `
                    -PermUrl "$webUrl/_layouts/15/user.aspx?obj=$($list.Id)%2C$($it.Id)%2CLISTITEM&List=$($list.Id)" @common
            }
        }
    }
}
