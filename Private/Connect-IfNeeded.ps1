function Connect-IfNeeded {
    <#
        Connect to a site unless the caller already has a live PnP connection and
        asked to use it. One place for the auth logic so every public function
        handles -ClientId / -Interactive / -CertificatePath / -ManagedIdentity the
        same way.
    #>
    param(
        [Parameter(Mandatory)] [string] $Url,
        [string] $ClientId,
        [string] $Tenant,
        [string] $CertificatePath,
        [securestring] $CertificatePassword,
        [string] $Thumbprint,
        [switch] $Interactive,
        [switch] $ManagedIdentity,
        [switch] $UseExistingConnection
    )

    if ($UseExistingConnection) {
        if (-not (Get-PnPConnection -ErrorAction SilentlyContinue)) {
            throw "-UseExistingConnection was set but there is no active PnP connection. Run Connect-PnPOnline first."
        }
        return
    }

    if (-not $ClientId) {
        throw "Provide -ClientId (your Entra app registration), or run Connect-PnPOnline yourself and pass -UseExistingConnection."
    }

    $params = @{ Url = $Url; ClientId = $ClientId }

    if ($Interactive)            { $params.Interactive = $true }
    elseif ($CertificatePath)    {
        $params.Tenant = $Tenant; $params.CertificatePath = $CertificatePath
        if ($CertificatePassword) { $params.CertificatePassword = $CertificatePassword }
    }
    elseif ($Thumbprint)         { $params.Tenant = $Tenant; $params.Thumbprint = $Thumbprint }
    elseif ($ManagedIdentity)    { $params.ManagedIdentity = $true }
    else { throw "Choose an auth method: -Interactive, -CertificatePath, -Thumbprint or -ManagedIdentity." }

    Connect-PnPOnline @params
}
