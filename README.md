Overview
--------

RavenPowerShell is a PowerShell client for [sentry.io](https://sentry.io/welcome/)

Installation
-----

```powershell
Install-Module RavenPowerShell
```

Usage
-----

```powershell
Import-Module RavenPowerShell

$ravenClient = New-RavenClient -SentryDsn 'https://mysentrydsn'

try {
    $null[5] = 0
} catch {
    $ravenClient.CaptureException($_)
}
```

AND/OR

```powershell
Import-Module RavenPowerShell

$ravenClient = New-RavenClient -SentryDsn 'https://mysentrydsn'

trap {
    $ravenClient.CaptureException($_)
    break
}

$null[1000] = $true
```