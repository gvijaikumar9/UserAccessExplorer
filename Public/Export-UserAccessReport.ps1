function Export-UserAccessReport {
    <#
    .SYNOPSIS
        Write Get-UserAccess results to CSV or a standalone HTML report.

    .DESCRIPTION
        The HTML report leads with the Overshared access - the routes the user was
        never explicitly given - because that is the part someone actually needs to
        act on. Self-contained, so it opens anywhere and survives forwarding.

    .EXAMPLE
        Get-UserAccess -User jane@contoso.com -SiteUrls $sites -UseExistingConnection |
            Export-UserAccessReport -Path .\jane-access.html -Html
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [psobject] $Access,

        [Parameter(Mandatory)]
        [string]   $Path,

        [switch]   $Html
    )

    begin { $rows = [System.Collections.Generic.List[object]]::new() }
    process { $rows.Add($Access) }
    end {
        if ($rows.Count -eq 0) {
            Write-Warning "Nothing to export - Get-UserAccess returned no access."
            return
        }

        if (-not $Html) {
            $rows | Export-Csv -Path $Path -NoTypeInformation -Encoding UTF8
            $file = Get-Item $Path
            Write-Information "Report generated: $($rows.Count) row(s) written to $($file.FullName)" -InformationAction Continue
            return $file
        }

        Add-Type -AssemblyName System.Web

        $user = $rows[0].User
        $overshared = @($rows | Where-Object RouteType -eq 'Overshared')
        $granted    = @($rows | Where-Object RouteType -eq 'Granted')

        $enc = { param($s) [System.Web.HttpUtility]::HtmlEncode([string]$s) }

        $sectionHtml = {
            param($title, $colour, $items)
            if (-not $items) { return '' }
            $trs = foreach ($r in ($items | Sort-Object SiteTitle)) {
@"
<tr>
  <td>$(& $enc $r.SiteTitle)</td>
  <td>$(& $enc $r.GrantedVia)</td>
  <td>$(& $enc $r.Permission)</td>
  <td>$(& $enc $r.EffectiveAccess)</td>
</tr>
"@
            }
@"
<h2 style="color:$colour">$title ($($items.Count))</h2>
<table>
<thead><tr><th>Site</th><th>Granted via</th><th>This route grants</th><th>Overall access</th></tr></thead>
<tbody>
$([string]::Join("`n", $trs))
</tbody></table>
"@
        }

        $generated = Get-Date -Format 'yyyy-MM-dd HH:mm'
        $reportHtml = @"
<!doctype html><html><head><meta charset="utf-8">
<title>Access review - $(& $enc $user)</title>
<style>
 body{font-family:Segoe UI,system-ui,sans-serif;margin:2rem;color:#1f2430}
 h1{margin:0 0 .25rem} h2{margin:1.5rem 0 .5rem}
 .meta{color:#666;margin-bottom:1rem}
 table{border-collapse:collapse;width:100%;font-size:.9rem;margin-bottom:1rem}
 th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #e5e7eb;vertical-align:top}
 th{background:#f3f4f6}
</style></head><body>
<h1>Access review</h1>
<div class="meta">User <strong>$(& $enc $user)</strong> &middot; generated $generated &middot; $($rows.Count) route(s)</div>
$(& $sectionHtml 'Overshared access - never explicitly granted' '#b91c1c' $overshared)
$(& $sectionHtml 'Granted access - via membership or direct grant' '#4d7c0f' $granted)
</body></html>
"@

        Set-Content -Path $Path -Value $reportHtml -Encoding UTF8
        $file = Get-Item $Path
        Write-Information "Report generated: $($rows.Count) route(s) for $user written to $($file.FullName)" -InformationAction Continue
        return $file
    }
}
