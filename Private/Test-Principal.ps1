function Test-EveryoneClaim {
    <#
        True for the two claims that mean "everyone in the organisation". This is
        the route that matters most: access the user was never explicitly given.
        Match on login name, not title - the title is whatever the tenant renamed
        it to.
    #>
    param([string]$LoginName, [string]$Title)
    return $LoginName -match 'spo-grid-all-users' -or
           $LoginName -match 'c:0\(\.s\|true' -or
           $Title -match '^Everyone'
}

function Test-SystemGroup {
    <#
        SharePoint creates "Limited Access System Group" entries as internal
        plumbing whenever anyone has limited access to a sub-item. They are never
        a meaningful route and only add noise, so they are filtered out.
    #>
    param([string]$Title)
    return $Title -like 'Limited Access System Group*'
}

function Test-SharingLinkGroup {
    <#
        True for the hidden groups SharePoint creates to back a sharing link.
        They are named SharingLinks.<guid>.<type>.<linkId>, and their presence in
        an object's role assignments is what a sharing link actually IS at the
        permission layer - which is why a shared file shows up as broken
        inheritance. Verified 23 Jul 2026: an organisational link on a document
        made that item the only one of four with unique role assignments.
    #>
    param([string]$Title, [string]$LoginName)
    return $Title -like 'SharingLinks.*' -or $LoginName -like '*SharingLinks.*'
}

function Get-SharingLinkKind {
    <#
        Pull the link type out of the group name so the route reads as something
        a human can act on. The name looks like:
            SharingLinks.<guid>.<Type>.<linkId>
        Type is Flexible for modern links, so it is a hint, not the truth - the
        authoritative scope comes from Get-PnPFileSharingLink. Used only for
        display when the file's real link cannot be read.
    #>
    param([string]$Title)
    $parts = $Title -split '\.'
    if ($parts.Count -ge 3) { return $parts[2] }
    return 'Unknown'
}

function ConvertTo-ClaimLogin {
    <#
        Turn a UPN into the claims login SharePoint uses for an AAD member user.
        Passes through anything that already looks like a claims login (has a |).
    #>
    param([Parameter(Mandatory)][string]$User)
    if ($User -match '\|') { return $User }
    return "i:0#.f|membership|$User"
}
