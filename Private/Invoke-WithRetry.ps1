function Invoke-WithRetry {
    <#
        Run a PnP/Graph call, and if SharePoint throttles it (429 / 503), wait and
        try again. Honours the server's Retry-After when present, otherwise backs
        off exponentially. Anything that is not a throttle is rethrown immediately.
    #>
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [int]    $MaxAttempts = 5,
        [string] $Because = 'call'
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return & $Action
        }
        catch {
            $ex  = $_.Exception
            $msg = $ex.Message

            $status = $null
            $probe  = $ex
            while ($probe -and -not $status) {
                if ($probe.PSObject.Properties['Response'] -and $probe.Response) {
                    try { $status = [int]$probe.Response.StatusCode } catch { Write-Debug "no StatusCode" }
                }
                $probe = $probe.InnerException
            }

            $isThrottle =
                $status -in 429, 503 -or
                $msg -match '(?i)\b429\b|too many requests|throttl|\b503\b|service unavailable'

            if (-not $isThrottle -or $attempt -eq $MaxAttempts) { throw }

            $wait = $null
            $probe = $ex
            while ($probe -and -not $wait) {
                if ($probe.PSObject.Properties['Response'] -and $probe.Response) {
                    try {
                        $ra = $probe.Response.Headers['Retry-After']
                        if ($ra) { $wait = [int]$ra }
                    } catch { Write-Debug "no Retry-After" }
                }
                $probe = $probe.InnerException
            }
            if (-not $wait) { $wait = [Math]::Min([Math]::Pow(2, $attempt), 60) }

            Write-Warning "Throttled on $Because (attempt $attempt/$MaxAttempts). Waiting $wait s."
            Start-Sleep -Seconds $wait
        }
    }
}
