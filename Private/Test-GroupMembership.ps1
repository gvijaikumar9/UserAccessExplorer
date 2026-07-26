function Get-GroupIdFromLogin {
    <#
        Pull the Entra object id out of a SharePoint claims login.

        SharePoint encodes directory principals in the login name:
          c:0t.c|tenant|<guid>                              - security group
          c:0o.c|federateddirectoryclaimprovider|<guid>     - M365 group (members)
          c:0o.c|federateddirectoryclaimprovider|<guid>_o   - M365 group (owners)

        All we need for a membership check is the GUID, so pull the first one out
        and let the caller decide. Returns $null when there is no GUID (an ordinary
        SharePoint group, a plain user), which is the signal to fall back to the
        "unconfirmed" label rather than claim anything.

        Pure - no Graph calls - so it is unit-tested on its own.
    #>
    param([string]$LoginName)

    if ([string]::IsNullOrWhiteSpace($LoginName)) { return $null }
    $m = [regex]::Match($LoginName, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Test-UserIsGroupMember {
    <#
        Is THIS user a member of THIS group? Answered by Graph's checkMemberGroups,
        which is TRANSITIVE - so a user who is in the group only through a nested
        group still counts. That transitivity is the whole point: a plain
        Get-PnPGroupMember misses nesting.

        Returns:
          $true   - confirmed member
          $false  - confirmed NOT a member
          $null   - could not determine (no Graph token / scope, or the call
                    failed). The caller keeps the "membership unconfirmed" label
                    rather than dropping a route it cannot rule out.

        Results are cached per (user, group) in the supplied hashtable, because one
        group turns up on many objects across a scan - one Graph call each, not one
        per row.

        Needs the Graph delegated scope GroupMember.Read.All (or Directory.Read.All).
    #>
    param(
        [Parameter(Mandatory)] [string]    $UserUpn,
        [Parameter(Mandatory)] [string]    $GroupId,
        [hashtable]                         $Cache = @{}
    )

    $key = "$UserUpn|$GroupId"
    if ($Cache.ContainsKey($key)) { return $Cache[$key] }

    $result = $null
    try {
        $body = @{ groupIds = @($GroupId) } | ConvertTo-Json
        $resp = Invoke-PnPGraphMethod -Url "users/$UserUpn/checkMemberGroups" -Method Post -Content $body
        $result = [bool](@($resp.value) -contains $GroupId)
    } catch {
        Write-Verbose "Membership check for $GroupId could not be resolved: $($_.Exception.Message)"
        $result = $null
    }

    $Cache[$key] = $result
    return $result
}
