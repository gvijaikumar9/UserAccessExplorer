function Resolve-EntraGroup {
    <#
        Resolve an Entra (security / M365) group to its PEOPLE via Graph, using the
        transitive membership so nested groups are flattened. The site-centric
        counterpart to Test-UserIsGroupMember: there we ask "is this ONE user in the
        group"; here we ask "how many people are in it" and, on request, who.

        The microsoft.graph.user cast keeps only USER members - nested groups, devices
        and service principals drop out - so the number genuinely means "people".

        Returns { Count; Members } where Members is an array of { Upn; Display }
        (empty unless -IncludeMembers). Count is $null when Graph cannot answer (no
        scope / failure), so a caller shows a blank, never a wrong 0.

        Cached per (group, include-members) in the supplied hashtable - one group can
        appear on many objects across a scan. Needs Graph GroupMember.Read.All.
    #>
    param(
        [Parameter(Mandatory)] [string] $GroupId,
        [hashtable] $Cache = @{},
        [switch]    $IncludeMembers
    )

    $key = "grp|$GroupId|$([bool]$IncludeMembers)"
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }

    $result = [pscustomobject]@{ Count = $null; Members = @() }
    try {
        # $count + ConsistencyLevel:eventual is what makes @odata.count come back.
        $url    = "groups/$GroupId/transitiveMembers/microsoft.graph.user" + '?$count=true&$select=userPrincipalName,displayName&$top=999'
        $people = [System.Collections.Generic.List[object]]::new()
        $count  = $null

        do {
            $resp = Invoke-PnPGraphMethod -Url $url -Method Get -AdditionalHeaders @{ ConsistencyLevel = 'eventual' }

            if ($null -eq $count -and ($resp.PSObject.Properties.Name -contains '@odata.count')) {
                $count = [int]$resp.'@odata.count'
            }
            if ($IncludeMembers -and ($resp.PSObject.Properties.Name -contains 'value')) {
                foreach ($u in @($resp.value)) {
                    $people.Add([pscustomobject]@{ Upn = "$($u.userPrincipalName)"; Display = "$($u.displayName)" })
                }
            }
            # Only page when we actually want the members; a count needs one call.
            $url = if ($IncludeMembers -and ($resp.PSObject.Properties.Name -contains '@odata.nextLink')) {
                "$($resp.'@odata.nextLink')"
            } else { $null }
        } while ($url)

        # When we pulled the people, trust that count (nextLink pages omit @odata.count).
        if ($IncludeMembers) { $count = $people.Count }
        $result = [pscustomobject]@{ Count = $count; Members = $people.ToArray() }
    }
    catch {
        Write-Verbose "Could not resolve Entra group $GroupId : $($_.Exception.Message)"
    }

    $Cache[$key] = $result
    return $result
}
