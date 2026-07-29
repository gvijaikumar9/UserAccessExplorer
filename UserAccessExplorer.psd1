@{
    RootModule        = 'UserAccessExplorer.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = 'e2c9a7d4-3f81-4b6a-9d02-7c5e1a4f8b93'
    Author            = 'G Vijai Kumar'
    CompanyName       = 'Five Number'
    Copyright         = '(c) G Vijai Kumar. All rights reserved.'
    Description       = 'Shows what a user can access in SharePoint Online and HOW, grouping access by route so the oversharing they were never explicitly given is surfaced first - and the mirror question, WHO can reach a given site and how (Get-SiteAccess). Scans a site, a set of sites, or a whole tenant; -Deep walks subsites, lists and individual files, and finds sharing links that grant no per-user permission and so are invisible to a normal permission check. A Copilot-readiness tool. Requires PnP.PowerShell.'
    PowerShellVersion = '7.2'

    RequiredModules   = @(
        @{ ModuleName = 'PnP.PowerShell'; ModuleVersion = '2.12.0' }
    )

    FunctionsToExport = @(
        'Get-UserAccess'
        'Get-SiteAccess'
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
            ReleaseNotes = 'v0.3.0. By site (Get-SiteAccess): the mirror of Get-UserAccess - fix a site and report every principal that can reach it (user, SharePoint group, Entra group, Everyone claim, sharing link), Granted vs Overshared, with SharePoint- and Entra-group member counts (Graph transitive members) and -ExpandMembers for one row per person; -Deep walks subsites/lists/items with broken inheritance. The GUI has a By user / By site lens toggle with dedicated Who/Type/Members/Permission columns and site-aware Scan history. Compare two users: add a second user and the scan runs both, then diffs them into Shared by both / Only-A / Only-B, with a User column and matching tiles; compare runs save to Scan history. Correctness: a site that cannot be read after retries is now surfaced as a non-terminating error (FullyQualifiedErrorId UserAccessExplorer.IncompleteScan) so an incomplete scan is no longer mistaken for genuine "no access" - callers capture it with -ErrorVariable and still receive the rows from sites that responded. GUI: a collapsible navigation rail (Scan / Scan history, renamed from Saved scans; the redundant overflow menu and rail Settings were removed), an About panel with the running version and a Check for updates button (GitHub Releases), scan-history and report cards that show the site each scan covered, and a full light/dark theme. Prior (v0.2.0): Granted/Overshared terminology (Microsoft''s governance words; -UnexpectedOnly aliases -OversharedOnly), Graph-confirmed Entra/M365 group membership (transitive checkMemberGroups), PermUrl deep-links to each object''s advanced-permissions page, deep item-level scanning and the Site > Library > Folder > Item tree.'
        }
    }
}
