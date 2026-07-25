#requires -Module Pester

BeforeAll {
    $moduleRoot = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $moduleRoot 'UserAccessExplorer.psd1') -Force
}

Describe 'Module surface' {
    It 'exports the two public functions' {
        (Get-Command -Module UserAccessExplorer).Name | Sort-Object |
            Should -Be @('Export-UserAccessReport', 'Get-UserAccess')
    }
    It 'public functions have help' {
        foreach ($fn in 'Get-UserAccess','Export-UserAccessReport') {
            (Get-Help $fn).Synopsis | Should -Not -BeNullOrEmpty
        }
    }
}

Describe 'Claim + principal helpers' {
    It 'wraps a UPN into a member claims login' {
        InModuleScope UserAccessExplorer {
            ConvertTo-ClaimLogin -User 'jane@contoso.com' |
                Should -Be 'i:0#.f|membership|jane@contoso.com'
        }
    }
    It 'passes a claims login through unchanged' {
        InModuleScope UserAccessExplorer {
            $claim = 'i:0#.f|membership|jane@contoso.com'
            ConvertTo-ClaimLogin -User $claim | Should -Be $claim
        }
    }
    It 'detects the Everyone-except-external claim by login name' {
        InModuleScope UserAccessExplorer {
            Test-EveryoneClaim 'c:0-.f|rolemanager|spo-grid-all-users/abc' 'Renamed Everyone' | Should -BeTrue
        }
    }
    It 'detects the Everyone claim' {
        InModuleScope UserAccessExplorer {
            Test-EveryoneClaim 'c:0(.s|true' 'Everyone' | Should -BeTrue
        }
    }
    It 'does not flag a normal SharePoint group' {
        InModuleScope UserAccessExplorer {
            Test-EveryoneClaim 'Sales Members' 'Sales Members' | Should -BeFalse
        }
    }
    It 'flags SharePoint system plumbing groups as noise' {
        InModuleScope UserAccessExplorer {
            Test-SystemGroup 'Limited Access System Group For Web abc' | Should -BeTrue
            Test-SystemGroup 'Sales Members' | Should -BeFalse
        }
    }
}

Describe 'Export-UserAccessReport' {
    BeforeAll {
        $script:sample = @(
            [pscustomobject]@{ User='jane@contoso.com'; SiteUrl='x'; SiteTitle='Finance'; EffectiveAccess='Read'; GrantedVia='Everyone claim (Everyone except external users)'; RouteType='Unexpected'; Permission='Read' }
            [pscustomobject]@{ User='jane@contoso.com'; SiteUrl='y'; SiteTitle='Sales & Ops'; EffectiveAccess='Full Control'; GrantedVia="SharePoint group 'Sales Owners'"; RouteType='Expected'; Permission='Full Control' }
        )
        $script:tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("uae_" + [System.IO.Path]::GetRandomFileName())
        New-Item -ItemType Directory -Path $script:tmp | Out-Null
    }
    AfterAll { Remove-Item $script:tmp -Recurse -Force -ErrorAction SilentlyContinue }

    It 'writes a CSV with one row per route' {
        $csv = Join-Path $script:tmp 'r.csv'
        $script:sample | Export-UserAccessReport -Path $csv
        (Import-Csv $csv).Count | Should -Be 2
    }
    It 'writes self-contained HTML with the Unexpected section first' {
        $h = Join-Path $script:tmp 'r.html'
        $script:sample | Export-UserAccessReport -Path $h -Html
        $c = Get-Content $h -Raw
        $c | Should -Match '<!doctype html>'
        $c | Should -Not -Match 'src="http'
        # Unexpected heading must appear before the Expected heading
        $c.IndexOf('Unexpected access') | Should -BeLessThan $c.IndexOf('Expected access')
    }
    It 'HTML-encodes special characters (no injection)' {
        $h = Join-Path $script:tmp 'enc.html'
        $script:sample | Export-UserAccessReport -Path $h -Html
        (Get-Content $h -Raw) | Should -Match 'Sales &amp; Ops'
    }
    It 'warns and writes nothing when empty' {
        $e = Join-Path $script:tmp 'empty.csv'
        @() | Export-UserAccessReport -Path $e -WarningAction SilentlyContinue
        Test-Path $e | Should -BeFalse
    }
}

Describe 'Get-UserAccess' {
    It 'filters to Unexpected with -UnexpectedOnly' {
        InModuleScope UserAccessExplorer {
            Mock Connect-IfNeeded {}
            Mock Get-UserAccessForSite {
                [pscustomobject]@{ User='u'; SiteUrl='x'; SiteTitle='S'; EffectiveAccess='Read'; GrantedVia='Everyone claim (x)'; RouteType='Unexpected'; Permission='Read' }
                [pscustomobject]@{ User='u'; SiteUrl='x'; SiteTitle='S'; EffectiveAccess='Read'; GrantedVia="group 'S Members'"; RouteType='Expected'; Permission='Read' }
            }
            $r = Get-UserAccess -User 'jane@contoso.com' -SiteUrl 'https://x/sites/S' -UseExistingConnection -UnexpectedOnly
            $r.Count | Should -Be 1
            $r.RouteType | Should -Be 'Unexpected'
        }
    }
    It 'reports when the user has no access' {
        InModuleScope UserAccessExplorer {
            Mock Connect-IfNeeded {}
            Mock Get-UserAccessForSite { }
            $info = Get-UserAccess -User 'jane@contoso.com' -SiteUrl 'https://x/sites/S' -UseExistingConnection 6>&1
            "$info" | Should -Match 'no access'
        }
    }
}

Describe 'Sharing-link detection' {
    It 'recognises a SharingLinks group by title' {
        InModuleScope UserAccessExplorer {
            Test-SharingLinkGroup 'SharingLinks.b45dd685-6c54-4691-aee8-f13a2079a706.Flexible.c57fd2d5-8b39-4400-94fa-b3b622db0599' '' |
                Should -BeTrue
        }
    }
    It 'does not mistake an ordinary SharePoint group for a link' {
        InModuleScope UserAccessExplorer {
            Test-SharingLinkGroup 'PowerShell Demo Members' 'PowerShell Demo Members' | Should -BeFalse
        }
    }
}

Describe 'Sharing-link audience rules' {
    # These decide whether a link REACHES a user. Getting them wrong is silent
    # in both directions: either an admin is told a file is safe when the whole
    # company can open it, or they drown in findings that do not apply.

    BeforeAll {
        function NewLink { param($Scope, $Type = 'View') [pscustomobject]@{ Scope = $Scope; Type = $Type } }
        function NewRecipient { param($Upn) [pscustomobject]@{ User = [pscustomobject]@{ Email = $Upn } } }
    }

    It 'an Organization link reaches any internal user' {
        InModuleScope UserAccessExplorer {
            $v = Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Organization'; Type='View' }) -UserUpn 'jane@contoso.com'
            $v | Should -Not -BeNullOrEmpty
            $v.Route.Type | Should -Be 'Unexpected'
            $v.Route.Route | Should -Match 'anyone in the organisation'
        }
    }

    It 'an Anonymous link reaches anyone' {
        InModuleScope UserAccessExplorer {
            $v = Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Anonymous'; Type='View' }) -UserUpn 'jane@contoso.com'
            $v | Should -Not -BeNullOrEmpty
            $v.Route.Route | Should -Match 'anyone with the link'
        }
    }

    It 'a Users link reaches a NAMED recipient' {
        InModuleScope UserAccessExplorer {
            $granted = @([pscustomobject]@{ User = [pscustomobject]@{ Email = 'jane@contoso.com' } })
            $v = Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Users'; Type='View' }) `
                    -UserUpn 'jane@contoso.com' -GrantedTo $granted
            $v | Should -Not -BeNullOrEmpty
            $v.Route.Route | Should -Match 'named recipient'
        }
    }

    It 'a Users link does NOT reach someone who is not a recipient' {
        InModuleScope UserAccessExplorer {
            $granted = @([pscustomobject]@{ User = [pscustomobject]@{ Email = 'bob@contoso.com' } })
            Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Users'; Type='View' }) `
                -UserUpn 'jane@contoso.com' -GrantedTo $granted | Should -BeNullOrEmpty
        }
    }

    It 'a Users link with no recipients reaches nobody' {
        InModuleScope UserAccessExplorer {
            Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Users'; Type='View' }) `
                -UserUpn 'jane@contoso.com' -GrantedTo $null | Should -BeNullOrEmpty
        }
    }

    It 'maps View to Read and Edit to Edit' {
        InModuleScope UserAccessExplorer {
            (Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Organization'; Type='View' }) -UserUpn 'j@c.com').Level | Should -Be 'Read'
            (Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Organization'; Type='Edit' }) -UserUpn 'j@c.com').Level | Should -Be 'Edit'
        }
    }

    It 'trusts the link scope, not the group name (group says Flexible, link says Organization)' {
        InModuleScope UserAccessExplorer {
            $v = Test-SharingLinkAudience -Link ([pscustomobject]@{ Scope='Organization'; Type='View' }) -UserUpn 'j@c.com'
            $v.Route.Route | Should -Match 'Organization'
            $v.Route.Route | Should -Not -Match 'Flexible'
        }
    }
}

Describe 'Deep scan guards' {
    It 'refuses -IncludeItems without -Deep' {
        { Get-UserAccess -User 'j@c.com' -SiteUrl 'https://x' -IncludeItems -UseExistingConnection } |
            Should -Throw '*-IncludeItems only means something with -Deep*'
    }
}

Describe 'Deep scan guards (connection)' {
    It 'refuses -Deep with -UseExistingConnection' {
        { Get-UserAccess -User 'j@c.com' -SiteUrl 'https://x' -Deep -UseExistingConnection } |
            Should -Throw '*subsites are connected to individually*'
    }
}
