Class Sentry {
    hidden [string]$storeUri
    hidden [string]$sentryAuth
    hidden [hashtable]$tags
    # https://github.com/PowerShell/vscode-powershell/issues/66
    hidden [bool]$_getFrameVariablesIsFixed

    Sentry([string]$sentryDsn, [Hashtable] $tags) {
        if ($sentryDsn) {
            $uri = [System.Uri]::New($sentryDsn)
            $this.tags = $tags
            $sentryKey = $uri.UserInfo.Split('@')[0]
            $userAgent = 'SentryPowershell/1.0'
            $this.sentryAuth = "Sentry sentry_version=7,sentry_key=$($sentryKey),sentry_client=$userAgent"
            $projectId = $uri.Segments[1]
            $this.storeUri = "$($uri.Scheme)://$($uri.Host):$($uri.Port)/api/$($projectId)/store/"
        }
        $this._getFrameVariablesIsFixed = $false
    }

    [hashtable]GetBaseRequestBody([string]$message) {

        $eventid = (New-Guid).Guid.Replace('-', '')
        $utcNow = (Get-Date).ToUniversalTime()
        $iso8601 = Get-Date($utcNow) -UFormat '+%Y-%m-%dT%H:%M:%S'

        $body = @{}
        $body['event_id'] = $eventid
        $body['timestamp'] = [string]$iso8601
        $body['logger'] = 'root'
        $body['platform'] = 'other'
        $body['sdk'] = @{
            'name'    = 'SentryPowershell'
            'version' = '1.0'
        }
        $body['server_name'] = [System.Net.Dns]::GetHostName()
        $body['message'] = $message
        if ($this.tags) {
            $body['tags'] = $this.tags
        }
        return $body
    }

    [string]StoreEvent([hashtable]$body) {
        if ($this.storeUri) {
            $headers = @{}
            $headers.Add('X-Sentry-Auth', $this.sentryAuth)
 
            $jsonBody = ConvertTo-Json $body -Depth 6

            try {
                $result = Invoke-RestMethod -Uri $this.storeUri -Method Post -Body $jsonBody -ContentType 'application/json' -Headers $headers
                return $result.Id
            }
            catch {
                $errorCode = $_.Exception.Response.StatusCode
                $errorMessage = $_.ErrorDetails.Message
                $message = "Failed to post event to Sentry server"
                if($errorCode) {
                    $message += " - $($errorCode.value__) ($errorCode)"
                }
                elseif ($errorMessage) {
                    $message += " - $errorMessage"
                }
                Write-Warning $message
            }
        }
        return ""
    }

    [hashtable]ParsePSCallstack([System.Management.Automation.CallStackFrame[]]$callstackFrames, [hashtable[]]$frameVariables) {

        $context_lines_count = 10
         $thisStacktrace = @{
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
             $thisStacktrace['frames'] += $frames[$i]
        }

        return  $thisStacktrace
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

    [string]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord) {
        
        # skip ourselves
        return $this.CaptureException($errorRecord, 1)
    }

    [string]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord, [int]$skipFrames) {

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

        return $this.CaptureException($errorRecord, $callstackFrames, $frameVariables)
    }

    [string]CaptureException([System.Management.Automation.ErrorRecord]$errorRecord,
        [System.Management.Automation.CallStackFrame[]]$callstackFrames=@(), [hashtable[]]$frameVariables) {

        $exceptionMessage = $errorRecord.Exception.Message
        if ($errorRecord.ErrorDetails.Message) {
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

        return $this.StoreEvent($body)
    }
}

function New-Sentry {
    param(
        # Sentry DSN
        [string] $SentryDsn,
        [Hashtable] $Tags
    )
    
    return [Sentry]::New($SentryDsn, $Tags)
}


Export-ModuleMember -Function New-Sentry