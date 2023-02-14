Overview
--------

SentryPowershell is a PowerShell client for [sentry.io](https://sentry.io/welcome/)

Installation
-----

```powershell
Install-Module SentryPowershell
```

Usage
-----

```powershell
Import-Module SentryPowershell

$sentry = New-Sentry -SentryDsn 'https://mysentrydsn'

try {
    $null[5] = 0
} catch {
    $sentry.CaptureException($_)
}
```

AND/OR

```powershell
Import-Module SentryPowershell

$client = New-Sentry -SentryDsn 'https://mysentrydsn'

trap {
    $client.CaptureException($_)
    break
}

$null[1000] = $true
```