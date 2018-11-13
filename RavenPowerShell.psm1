function CurrentUnixTimestamp () {
    return [int64](([datetime]::UtcNow)-(get-date "1/1/1970")).TotalSeconds
}


Class RavenClient {

    [string]$sentryDsn
    [string]$storeUri
    [string]$sentryKey
    [string]$sentrySecret
    [int]$projectId
    [string]$sentryAuth
    [string]$userAgent
    # https://github.com/PowerShell/vscode-powershell/issues/66
    hidden [bool]$_getFrameVariablesIsFixed


    RavenClient([string]$sentryDsn) {
        $uri = [System.Uri]::New($sentryDsn)
        $this.sentryDsn = $sentryDsn

        $this.sentryKey = $uri.UserInfo.Split(':')[0]
        $this.sentrySecret = $uri.UserInfo.Split(':')[1]
        $this.projectId = $uri.Segments[1]
        $this.storeUri = "$($uri.Scheme)://$($uri.Host):$($uri.Port)/api/$($this.projectId)/store/"

        $this.userAgent = 'PowerShellRaven/1.0'
        $this.sentryAuth = "Sentry sentry_version=5,sentry_key=$($this.sentryKey),sentry_secret=$($this.sentrySecret)"

        $this._getFrameVariablesIsFixed = $false
    }

    [hashtable]GetBaseRequestBody([string]$message) {

        $eventid = (New-Guid).Guid.Replace('-', '')
        $iso8601 = (Get-Date).ToUniversalTime() -UFormat '+%Y-%m-%dT%H:%M:%S'

        $body = @{}
        $body['event_id'] = $eventid
        $body['timestamp'] = [string]$iso8601
        $body['logger'] = 'root'
        $body['platform'] = 'other'
        $body['sdk'] = @{
            'name' = 'PowerShellRaven'
            'version' = '1.0'
        }
        $body['server_name'] = [System.Net.Dns]::GetHostName()
        $body['message'] = $message

        return $body
    }

    [void]StoreEvent([hashtable]$body) {

        $headers = @{}
        $headers.Add('X-Sentry-Auth', $this.sentryAuth + ",sentry_timestamp=" + $(CurrentUnixTimestamp))
        $headers.Add('User-Agent', $this.userAgent)

        $jsonBody = ConvertTo-Json $body -Depth 6

        Invoke-RestMethod -Uri $this.storeUri -Method Post -Body $jsonBody -ContentType 'application/json' -Headers $headers
    }

    [hashtable]ParsePSCallstack([System.Management.Automation.CallStackFrame[]]$callstackFrames, [hashtable[]]$frameVariables) {

        $context_lines_count = 10
        $stacktrace = @{
            'frames' = @()
        }
        $frames = @()

        for ($i=0; $i -lt $callstackFrames.Count; $i++) {
            $stackframe = $callstackFrames[$i]
            $frame = @{}
            $frame['filename'] = $stackframe.ScriptName
            $frame['abs_path'] = $stackframe.ScriptName
            $frame['context_line'] = $stackframe.Position.StartScriptPosition.Line
            $frame['lineno'] = $stackframe.ScriptLineNumber
            $frame['colno'] = $stackframe.Position.StartColumnNumber
            $frame['function'] = $stackframe.FunctionName
            
            $script_lines_arr = $stackframe.Position.StartScriptPosition.GetFullScript() -split '\r?\n'
            $script_line_index = $stackframe.ScriptLineNumber - 1
            $script_lines_count = $script_lines_arr.Count
            $script_before_idx = if ($script_line_index -lt $context_lines_count) { 0 } else { $script_line_index - $context_lines_count }
            $script_after_idx = if ($script_line_index -gt $script_lines_count - $context_lines_count) { $script_lines_count - 1  } else { $script_line_index + $context_lines_count }
            $pre_context = if ($script_line_index -eq 0) { @() } else { $script_lines_arr[$script_before_idx..($script_line_index - 1)] }
            $post_context = if ($script_line_index -eq $script_lines_count - 1) { @() } else { $script_lines_arr[($script_line_index + 1)..$script_after_idx] }
            $frame['pre_context'] = $pre_context
            $frame['post_context'] = $post_context

            $frame['vars'] = $frameVariables[$i]

            $frames += $frame
        }

        # [System.Array]::Reverse returns an empty array ???
        for ($i = $frames.Count - 1; $i -ge 0; $i--) {
            $stacktrace['frames'] += $frames[$i]
        }

        return $stacktrace
    }

    [void]CaptureMessage([string]$messageRaw, [string[]]$messageParams, [string]$messageFormatted) {

        $body = $this.GetBaseRequestBody('')
        $body['sentry.interfaces.Message'] = @{
            'message' = $messageRaw
            'params' = $messageParams
            'formatted' = $messageFormatted
        }
        $this.StoreEvent($body)
    }

    [void]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord) {
        
        # skip ourselves
        $this.CaptureException($errorRecord, 1)
    }

    [void]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord, [int]$skipFrames) {

        # skip ourselves
        $callstackSkip = 1 + $skipFrames
        $frameVariables = @()
        $callstackFrames = Get-PSCallStack | Select-Object -Skip $callstackSkip

        if ($this._getFrameVariablesIsFixed) {
            foreach ($stackframe in $callstackFrames) {
                $frameVariabless += $stackframe.GetFrameVariables()
            }
        } else {
            for ($i = $callstackSkip; $i -lt ($callstackFrames.Count + $callstackSkip); $i++) {
                $scopeVariables = @{}
                $scopeVariablesList = Get-Variable -Scope $i
                foreach ($scopeVariable in $scopeVariablesList) {
                    $scopeVariables[$scopeVariable.Name] = $scopeVariable.Value
                }
                $frameVariables += $scopeVariables
            }
        }

        $this.CaptureException($errorRecord, $callstackFrames, $frameVariables)
    }

    [void]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord,
        [System.Management.Automation.CallStackFrame[]]$callstackFrames=@(), [hashtable[]]$frameVariables) {

        $exceptionMessage = $errorRecord.Exception.Message
        if ($errorRecord.ErrorDetails.Message -ne $null) {
            $exceptionMessage = $errorRecord.ErrorDetails.Message
        }
        $exceptionName = $errorRecord.Exception.GetType().Name
        $exceptionSource = $errorRecord.Exception.Source

        $body = $this.GetBaseRequestBody($exceptionMessage)
        $exceptionValue = @{
            'type' = $exceptionName
            'value' = $exceptionMessage
            'module' = $exceptionSource
        }
        $exceptionValues = @()
        $exceptionValues += $exceptionValue
        $body['exception'] = @{
            'values' = $exceptionValues
        }

        $body['stacktrace'] = $this.ParsePSCallstack($callstackFrames, $frameVariables)

        $this.StoreEvent($body)
    }
}

function New-RavenClient {
    param(
        # Sentry DSN
        [Parameter(Mandatory=$true)]
        [string] $SentryDsn
    )
    
    return [RavenClient]::New($SentryDsn)
}


Export-ModuleMember -Function New-RavenClient
