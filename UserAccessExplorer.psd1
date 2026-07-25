@{
    RootModule        = 'UserAccessExplorer.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = 'e2c9a7d4-3f81-4b6a-9d02-7c5e1a4f8b93'
    Author            = 'G Vijai Kumar'
    CompanyName       = 'Five Number'
    Copyright         = '(c) G Vijai Kumar. All rights reserved.'
    Description       = 'Shows what a user can access in SharePoint Online and - crucially - HOW, grouping access by route so the oversharing they were never explicitly given is surfaced first. Scans a site, a set of sites, or a whole tenant; -Deep walks subsites, lists and individual files, and finds sharing links that grant no per-user permission and so are invisible to a normal permission check. A Copilot-readiness tool. Requires PnP.PowerShell.'
    PowerShellVersion = '7.2'

    RequiredModules   = @(
        @{ ModuleName = 'PnP.PowerShell'; ModuleVersion = '2.12.0' }
    )

    FunctionsToExport = @(
        'Get-UserAccess'
        'Export-UserAccessReport'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags         = @('SharePoint','SharePointOnline','Microsoft365','PnP','Permissions','Security','Governance','Copilot','Oversharing','AccessReview')
            LicenseUri   = 'https://opensource.org/licenses/MIT'
            ProjectUri   = 'https://github.com/gvijaikumar9/UserAccessExplorer'
            ReleaseNotes = 'First release. Get-UserAccess for named sites, grouping access as Expected vs Unexpected. Tenant-wide discovery is next.'
        }
    }
}
