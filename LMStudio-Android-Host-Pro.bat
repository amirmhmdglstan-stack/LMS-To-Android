@echo off
setlocal
 title LM Studio Android Host
set "LMSTUDIO_HOST_SELF=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$f=$env:LMSTUDIO_HOST_SELF; $raw=[IO.File]::ReadAllText($f); $mark='#'+'<POWERSHELL>'; $i=$raw.IndexOf($mark,[StringComparison]::Ordinal); if($i -lt 0){Write-Host 'Embedded PowerShell section not found.'; exit 90}; $src=$raw.Substring($i+$mark.Length); $tmp=Join-Path $env:TEMP ('LMStudioAndroidHost_'+[guid]::NewGuid().ToString('N')+'.ps1'); [IO.File]::WriteAllText($tmp,$src,[Text.UTF8Encoding]::new($false)); try { & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $tmp; $rc=$LASTEXITCODE } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }; if($null -eq $rc){$rc=1}; exit $rc"
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo The setup stopped with exit code %RC%.
pause
endlocal & exit /b %RC%

#<POWERSHELL>
$ErrorActionPreference = 'Stop'
$port = 1234
$apiModelName = 'lmsmob-chat'

# LM Studio CLI JSON schemas can vary by version. This normalizer supports:
#   - arrays of model objects
#   - wrapper objects such as { "models": [...] }
#   - column-style objects where fields like modelKey/paramsString are arrays
function Convert-JsonToRecords {
    param(
        [Parameter(Mandatory = $true)][string]$JsonText,
        [Parameter(Mandatory = $true)][string[]]$KeyNames
    )

    $parsed = ConvertFrom-Json -InputObject $JsonText -ErrorAction Stop
    $records = New-Object 'System.Collections.Generic.List[object]'
    $walk = $null
    $walk = {
        param($node)
        if ($null -eq $node) { return }

        if ($node -is [System.Array]) {
            foreach ($item in $node) { & $walk $item }
            return
        }

        if ($node -is [pscustomobject]) {
            $recordKeyProperty = $null
            foreach ($keyName in $KeyNames) {
                $candidateProperty = $node.PSObject.Properties[$keyName]
                if ($candidateProperty -and $null -ne $candidateProperty.Value) {
                    $recordKeyProperty = $candidateProperty
                    break
                }
            }

            if ($recordKeyProperty) {
                $keyValue = $recordKeyProperty.Value
                if ($keyValue -is [System.Array]) {
                    # Handle JSON that stores each field as an array of column values.
                    for ($index = 0; $index -lt $keyValue.Count; $index++) {
                        $row = [ordered]@{}
                        foreach ($property in $node.PSObject.Properties) {
                            $value = $property.Value
                            if ($value -is [System.Array]) {
                                if ($index -lt $value.Count) { $row[$property.Name] = $value[$index] }
                                else { $row[$property.Name] = $null }
                            } else {
                                $row[$property.Name] = $value
                            }
                        }
                        $rowObject = [pscustomobject]$row
                        $rowKey = [string]$rowObject.PSObject.Properties[$recordKeyProperty.Name].Value
                        if (-not [string]::IsNullOrWhiteSpace($rowKey)) { $null = $records.Add($rowObject) }
                    }
                } else {
                    $keyString = [string]$keyValue
                    if (-not [string]::IsNullOrWhiteSpace($keyString)) { $null = $records.Add($node) }
                }
                return
            }

            # If this is a wrapper object, keep walking into its properties until records are found.
            foreach ($property in $node.PSObject.Properties) {
                $value = $property.Value
                if ($null -ne $value -and ($value -is [System.Array] -or $value -is [pscustomobject])) {
                    & $walk $value
                }
            }
        }
    }

    & $walk $parsed
    return $records.ToArray()
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string[]]$Names
    )
    foreach ($name in $Names) {
        if ($Object -and $Object.PSObject -and $Object.PSObject.Properties[$name]) {
            $value = $Object.PSObject.Properties[$name].Value
            if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
                return $value
            }
        }
    }
    return $null
}

function Invoke-LmsCommand {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [switch]$StreamOutput
    )

    # CLI versions can write a normal empty-state message to stderr and can use a
    # non-zero exit code for an empty list. Capture that output before interpreting it.
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $captured = New-Object 'System.Collections.Generic.List[object]'
    $exitCode = 1

    try {
        if ($StreamOutput) {
            & $script:lmsPath @Arguments 2>&1 | ForEach-Object {
                $line = $_
                $null = $captured.Add($line)
                Write-Host $line
            }
            $exitCode = $LASTEXITCODE
        } else {
            $items = @(& $script:lmsPath @Arguments 2>&1)
            $exitCode = $LASTEXITCODE
            foreach ($item in $items) { $null = $captured.Add($item) }
        }
        if ($null -eq $exitCode) { $exitCode = 0 }
    } catch {
        $exitCode = 1
        $null = $captured.Add($_.Exception.Message)
    } finally {
        $ErrorActionPreference = $savedErrorActionPreference
    }

    $textLines = @($captured | ForEach-Object { [string]$_ })
    $text = ($textLines -join [Environment]::NewLine).Trim()
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Text = $text
        Lines = $captured.ToArray()
    }
}

function Test-ExplicitEmptyLoadedJson {
    param([Parameter(Mandatory = $true)]$ParsedJson)

    if ($ParsedJson -is [System.Array]) { return ($ParsedJson.Count -eq 0) }
    if ($ParsedJson -is [pscustomobject]) {
        foreach ($containerName in @('models', 'loadedModels', 'loaded_models', 'items', 'results', 'data')) {
            $property = $ParsedJson.PSObject.Properties[$containerName]
            if ($property -and $property.Value -is [System.Array] -and $property.Value.Count -eq 0) {
                return $true
            }
        }
    }
    return $false
}

function Get-LoadedModelRecords {
    # Prefer the documented machine-readable output when it can be interpreted.
    $jsonResult = Invoke-LmsCommand -Arguments @('ps', '--json')
    $jsonText = [string]$jsonResult.Text
    if (-not [string]::IsNullOrWhiteSpace($jsonText)) {
        try {
            $parsedJson = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
            $records = @(Convert-JsonToRecords -JsonText $jsonText -KeyNames @('identifier', 'modelKey', 'model_key', 'key', 'id', 'path'))
            if ($records.Count -gt 0) { return $records }
            if ($null -ne $parsedJson -and (Test-ExplicitEmptyLoadedJson -ParsedJson $parsedJson)) { return @() }
        } catch {
            # The JSON command may return a human-readable empty-state message on stderr.
            # Try the plain-text command before deciding the state is unknown.
        }
    }

    $plainResult = Invoke-LmsCommand -Arguments @('ps')
    $plainText = ([string]$plainResult.Text).Trim()
    # Remove ANSI escape sequences in case the CLI emits terminal styling while piped.
    $plainText = [regex]::Replace($plainText, '\x1B\[[0-?]*[ -/]*[@-~]', '')

    $identifierMatches = [regex]::Matches($plainText, '(?im)^\s*Identifier:\s*(.+?)\s*$')
    if ($identifierMatches.Count -gt 0) {
        $fallbackRecords = @()
        foreach ($match in $identifierMatches) {
            $fallbackRecords += [pscustomobject]@{ identifier = $match.Groups[1].Value.Trim() }
        }
        return $fallbackRecords
    }

    # Explicit empty states are valid regardless of the CLI exit code. In some
    # versions the no-models message is written to stderr and exits non-zero.
    $emptyStatePattern = '(?i)\bno\s+models?\s+(?:(?:are|is)\s+)?(?:currently\s+)?loaded\b|\bno\s+loaded\s+models\b|\bnothing\s+(?:is\s+)?loaded\b|\bno\s+models?\s+to\s+(?:display|show)\b|\bno\s+models?\s+in\s+memory\b'
    if ($plainText -match $emptyStatePattern) { return @() }
    if ($plainText -match '(?im)^\s*LOADED MODELS\s*$' -and $plainText -notmatch '(?im)^\s*Identifier\s*:') {
        return @()
    }

    if ([string]::IsNullOrWhiteSpace($plainText) -and $plainResult.ExitCode -eq 0 -and $jsonResult.ExitCode -eq 0) {
        # Both official list commands succeeded but returned no records or diagnostics.
        return @()
    }

    throw ('Could not safely interpret `lms ps` output. JSON exit code: {0}; plain-text exit code: {1}. Output: {2}' -f $jsonResult.ExitCode, $plainResult.ExitCode, $plainText)
}

function Test-TcpPort {
    param([string]$ComputerName = '127.0.0.1', [int]$Port = 1234, [int]$TimeoutMilliseconds = 500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds)) { return $false }
        $client.EndConnect($async)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}


function Get-LmsServerRunningState {
    # Return $true/$false when the CLI makes the state explicit; return $null when
    # this version's output cannot safely be interpreted.
    $jsonResult = Invoke-LmsCommand -Arguments @('server', 'status', '--json', '--quiet')
    if (-not [string]::IsNullOrWhiteSpace($jsonResult.Text)) {
        try {
            $statusObject = ConvertFrom-Json -InputObject $jsonResult.Text -ErrorAction Stop
            if ($statusObject -and $statusObject.PSObject.Properties['running']) {
                return [bool]$statusObject.PSObject.Properties['running'].Value
            }
        } catch { }
    }

    $plainResult = Invoke-LmsCommand -Arguments @('server', 'status')
    $statusText = [string]$plainResult.Text
    # Test negative phrases first: 'No server is running' contains the substring
    # 'server is running' and must not be misclassified as a live server.
    if ($statusText -match '(?i)\bserver\s+(?:is\s+)?not\s+running\b|\bno\s+server\s+is\s+running\b|\bserver\s+is\s+stopped\b') { return $false }
    if ($statusText -match '(?i)\bserver\s+(?:is\s+)?running\b|\bserver\s+is\s+now\s+running\b|\brunning\s+on\s+port\b') { return $true }
    return $null
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host '           LM Studio -> Android / LMSMOB Chat' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host 'This lists downloaded LLMs, stops the prior API server, unloads models,'
Write-Host 'loads your selection with LM Studio automatic GPU allocation, then starts LAN API.'
Write-Host 'Empty-model checks accept documented empty JSON and CLI no-models messages.'
Write-Host ''

# Find the LM Studio CLI (lms.exe).
$lmsPath = $null
$lmsCommand = Get-Command 'lms' -ErrorAction SilentlyContinue | Select-Object -First 1
if ($lmsCommand) {
    if ($lmsCommand.Source) { $lmsPath = $lmsCommand.Source }
    elseif ($lmsCommand.Definition) { $lmsPath = $lmsCommand.Definition }
}
if (-not $lmsPath -or -not (Test-Path -LiteralPath $lmsPath)) {
    $candidates = @(
        (Join-Path $env:USERPROFILE '.lmstudio\bin\lms.exe'),
        (Join-Path $env:USERPROFILE '.cache\lm-studio\bin\lms.exe')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { $lmsPath = $candidate; break }
    }
}
if (-not $lmsPath -or -not (Test-Path -LiteralPath $lmsPath)) {
    Write-Host 'ERROR: Could not find the LM Studio CLI (lms.exe).' -ForegroundColor Red
    Write-Host 'Open LM Studio at least once, then check that `lms` works in a new terminal.'
    Write-Host 'LM Studio CLI documentation: https://lmstudio.ai/docs/cli'
    exit 1
}
Write-Host ("Found LM Studio CLI: {0}" -f $lmsPath) -ForegroundColor DarkGray

# Ask LM Studio for the real list of downloaded language models.
Write-Host 'Reading downloaded LLMs from LM Studio...' -ForegroundColor Yellow
try {
    $listResult = Invoke-LmsCommand -Arguments @('ls', '--llm', '--json')
    $listExitCode = $listResult.ExitCode
    $jsonText = ([string]$listResult.Text).Trim()
    if ($listExitCode -ne 0) { throw 'The command `lms ls --llm --json` failed.' }
    if ([string]::IsNullOrWhiteSpace($jsonText)) { throw 'LM Studio returned an empty model list.' }
    $models = @(Convert-JsonToRecords -JsonText $jsonText -KeyNames @('modelKey', 'model_key', 'key'))
} catch {
    Write-Host ("ERROR: Could not read the model list. {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Try running `lms ls --llm --json` manually in a terminal.'
    exit 1
}
# Normalize common CLI schema variants so selection never depends on one exact property spelling.
$normalizedModels = @()
foreach ($record in $models) {
    $keyValue = Get-ObjectPropertyValue -Object $record -Names @('modelKey', 'model_key', 'key', 'identifier', 'path')
    if ($null -eq $keyValue) { continue }
    $keyText = [string]$keyValue
    if ([string]::IsNullOrWhiteSpace($keyText)) { continue }
    $paramsValue = Get-ObjectPropertyValue -Object $record -Names @('paramsString', 'params_string', 'params', 'parameterCount')
    $architectureValue = Get-ObjectPropertyValue -Object $record -Names @('architecture', 'arch')
    $normalizedModels += [pscustomobject]@{
        modelKey = $keyText
        paramsString = if ($null -ne $paramsValue) { [string]$paramsValue } else { '' }
        architecture = if ($null -ne $architectureValue) { [string]$architectureValue } else { '' }
    }
}
$models = @($normalizedModels | Sort-Object modelKey -Unique)
if ($models.Count -eq 0) {
    Write-Host 'No downloadable LLM model records could be normalized.' -ForegroundColor Red
    Write-Host 'For diagnosis, run: lms ls --llm --json'
    exit 1
}

Write-Host ''
Write-Host 'Choose the model to load (enter its number):' -ForegroundColor Green
for ($i = 0; $i -lt $models.Count; $i++) {
    $key = [string]$models[$i].modelKey
    $details = @()
    if ($models[$i].paramsString) { $details += [string]$models[$i].paramsString }
    if ($models[$i].architecture) { $details += [string]$models[$i].architecture }
    $suffix = if ($details.Count -gt 0) { '  [' + ($details -join ', ') + ']' } else { '' }
    Write-Host (' {0,3}. {1}{2}' -f ($i + 1), $key, $suffix)
}
Write-Host ''

$choiceIndex = 0
while ($true) {
    $choice = Read-Host 'Model number (Q to quit without changing anything)'
    if ($choice -match '^[Qq]$') { Write-Host 'Cancelled. Nothing was changed.'; exit 0 }
    $parsedChoice = 0
    if ([int]::TryParse($choice, [ref]$parsedChoice) -and $parsedChoice -ge 1 -and $parsedChoice -le $models.Count) {
        $choiceIndex = $parsedChoice - 1
        break
    }
    Write-Host ("Enter a number from 1 to {0}, or Q to quit." -f $models.Count) -ForegroundColor Yellow
}
$selectedModel = $models[$choiceIndex]
$modelKey = [string]$selectedModel.modelKey

$contextAnswer = Read-Host 'Context length in tokens [4096; recommended default for this PC]'
if ([string]::IsNullOrWhiteSpace($contextAnswer)) {
    $contextLength = 4096
} elseif ($contextAnswer -match '^\d+$') {
    $contextLength = [int]$contextAnswer
    if ($contextLength -lt 512 -or $contextLength -gt 131072) {
        Write-Host 'Context length must be between 512 and 131072.' -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host 'Context length must be a whole number.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ("Selected model: {0}" -f $modelKey) -ForegroundColor Cyan
Write-Host 'Stopping the previous API server, if one is running...'
$stopResult = Invoke-LmsCommand -Arguments @('server', 'stop')
$stopExitCode = $stopResult.ExitCode
if (-not [string]::IsNullOrWhiteSpace($stopResult.Text)) {
    $stopResult.Text -split '\r?\n' | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
}

# Confirm LM Studio's server is stopped, regardless of which port it used previously.
# Older CLI versions may not expose parseable status, so a confirmed-free target port
# remains the fallback rather than making the script version-dependent.
$serverStatusKnown = $false
$serverStillRunning = $false
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    $serverState = Get-LmsServerRunningState
    if ($null -ne $serverState) {
        $serverStatusKnown = $true
        $serverStillRunning = [bool]$serverState
        if (-not $serverStillRunning) { break }
    } else {
        break
    }
    Start-Sleep -Milliseconds 500
}
if ($serverStatusKnown -and $serverStillRunning) {
    Write-Host 'ERROR: LM Studio still reports an active API server after the stop command.' -ForegroundColor Red
    Write-Host 'No models have been unloaded. Stop the server in LM Studio and retry.'
    exit 1
}

# Do not unload the selected/current model if another process still owns port 1234.
# Give LM Studio a few seconds to release the listening socket after server stop.
$portReleased = $false
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    if (-not (Test-TcpPort -ComputerName '127.0.0.1' -Port $port -TimeoutMilliseconds 350)) {
        $portReleased = $true
        break
    }
    Start-Sleep -Milliseconds 500
}
if (-not $portReleased) {
    Write-Host ('ERROR: Port {0} is still accepting connections after `lms server stop`.' -f $port) -ForegroundColor Red
    Write-Host 'Another application may be using this port, or the LM Studio server did not stop.'
    Write-Host 'Nothing has been unloaded. Close the conflicting server or choose a free port, then retry.'
    exit 1
}

Write-Host 'Unloading all previously loaded models...'
$unloadResult = Invoke-LmsCommand -Arguments @('unload', '--all')
$unloadExitCode = $unloadResult.ExitCode
if (-not [string]::IsNullOrWhiteSpace($unloadResult.Text)) {
    $unloadResult.Text -split '\r?\n' | ForEach-Object { Write-Host $_ }
}

# Verify memory state robustly. Never treat an unrecognized status response as empty.
try {
    $stillLoaded = @()
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        $stillLoaded = @(Get-LoadedModelRecords)
        if ($stillLoaded.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
} catch {
    Write-Host ('ERROR: Could not verify the loaded-model state. {0}' -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'Stopping here rather than risking multiple models remaining in memory.'
    exit 1
}
if ($stillLoaded.Count -gt 0) {
    Write-Host 'ERROR: One or more models are still loaded. Stopping to avoid stacking models in memory.' -ForegroundColor Red
    foreach ($record in $stillLoaded) {
        $loadedName = Get-ObjectPropertyValue -Object $record -Names @('identifier', 'modelKey', 'model_key', 'key', 'id', 'path')
        if ($loadedName) { Write-Host (' - ' + [string]$loadedName) } else { Write-Host ' - (loaded model record detected)' }
    }
    exit 1
}
if ($unloadExitCode -ne 0) {
    Write-Host 'Note: unload returned a non-zero status, but follow-up verification confirms no models remain loaded.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host ("Loading {0} (context {1}; automatic GPU allocation)..." -f $modelKey, $contextLength) -ForegroundColor Yellow
# Do not pass --gpu=auto: some LM Studio CLI versions reject it. The documented default
# is automatic GPU allocation when --gpu is omitted.
$loadArgs = @('load', $modelKey, '--context-length', [string]$contextLength, '--identifier', $apiModelName)
$loadResult = Invoke-LmsCommand -Arguments $loadArgs -StreamOutput
$loadExitCode = $loadResult.ExitCode
if ($loadExitCode -ne 0) {
    Write-Host ("ERROR: LM Studio failed to load the selected model (exit code {0})." -f $loadExitCode) -ForegroundColor Red
    exit 1
}

# A zero exit code is not enough: confirm that LM Studio now reports a loaded model.
try {
    $loadedAfterLoad = @()
    for ($attempt = 0; $attempt -lt 20; $attempt++) {
        $loadedAfterLoad = @(Get-LoadedModelRecords)
        if ($loadedAfterLoad.Count -gt 0) { break }
        Start-Sleep -Milliseconds 500
    }
} catch {
    Write-Host ("ERROR: The model load command succeeded, but verification failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
    exit 1
}
if ($loadedAfterLoad.Count -eq 0) {
    Write-Host 'ERROR: The load command returned success, but `lms ps` shows no loaded model.' -ForegroundColor Red
    Write-Host 'The API server was not started. Check the LM Studio app for a model-loading error.'
    exit 1
}
$loadIdentityFound = $false
foreach ($loadedRecord in $loadedAfterLoad) {
    $identityValues = @()
    foreach ($propertyName in @('identifier', 'modelKey', 'model_key', 'key', 'id', 'path', 'model')) {
        if ($loadedRecord.PSObject.Properties[$propertyName] -and $loadedRecord.PSObject.Properties[$propertyName].Value) {
            $identityValues += [string]$loadedRecord.PSObject.Properties[$propertyName].Value
        }
    }
    if (($identityValues -contains $apiModelName) -or ($identityValues -contains $modelKey) -or
        (@($identityValues | Where-Object { $_.IndexOf($modelKey, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count -gt 0)) {
        $loadIdentityFound = $true
    }
}
if (-not $loadIdentityFound) {
    Write-Host 'WARNING: LM Studio reports a loaded model, but its identifier could not be matched to the selection.' -ForegroundColor Yellow
    Write-Host 'The API endpoint check below will help confirm which model name the app should use.'
}

Write-Host ''
Write-Host 'Starting the API server on port 1234 and binding it to the LAN...' -ForegroundColor Yellow
$serverStartResult = Invoke-LmsCommand -Arguments @('server', 'start', '--port', [string]$port, '--bind', '0.0.0.0') -StreamOutput
$serverExitCode = $serverStartResult.ExitCode
if ($serverExitCode -ne 0) {
    Write-Host ("ERROR: LM Studio could not start the server (exit code {0})." -f $serverExitCode) -ForegroundColor Red
    Write-Host 'Check whether another program is already using port 1234.'
    exit 1
}

# Wait for the local API port to accept connections. Do not print success when it never starts.
$serverReady = $false
for ($attempt = 0; $attempt -lt 40; $attempt++) {
    if (Test-TcpPort -ComputerName '127.0.0.1' -Port $port -TimeoutMilliseconds 500) {
        $serverReady = $true
        break
    }
    Start-Sleep -Milliseconds 500
}
if (-not $serverReady) {
    Write-Host ('ERROR: The server start command returned, but port {0} never became available.' -f $port) -ForegroundColor Red
    Write-Host 'Check LM Studio server status and whether another program is using this port.'
    try { $statusResult = Invoke-LmsCommand -Arguments @('server', 'status'); if ($statusResult.Text) { Write-Host $statusResult.Text } } catch { }
    exit 1
}

# Verify the OpenAI-compatible endpoint when possible. A 401/403 can simply mean API auth is enabled.
$apiEndpointStatus = 'TCP is reachable; HTTP endpoint not independently confirmed'
$apiIdentifierConfirmed = $false
try {
    $modelResponse = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/models" -f $port) -Method Get -TimeoutSec 4 -ErrorAction Stop
    $visibleIds = @()
    if ($modelResponse.data) {
        foreach ($apiModel in @($modelResponse.data)) {
            if ($apiModel.id) { $visibleIds += [string]$apiModel.id }
        }
    } elseif ($modelResponse.models) {
        foreach ($apiModel in @($modelResponse.models)) {
            if ($apiModel.id) { $visibleIds += [string]$apiModel.id }
            elseif ($apiModel.key) { $visibleIds += [string]$apiModel.key }
        }
    }
    if ($visibleIds.Count -gt 0) {
        $apiIdentifierConfirmed = ($visibleIds -contains $apiModelName)
        if ($apiIdentifierConfirmed) {
            $apiEndpointStatus = 'HTTP /v1/models responded; selected model ID confirmed'
        } else {
            $apiEndpointStatus = 'HTTP /v1/models returned model data, but selected model ID was not found'
            Write-Host 'WARNING: The API responded, but its model list did not contain the requested identifier.' -ForegroundColor Yellow
            Write-Host ('Visible API model IDs: ' + ($visibleIds -join ', ')) -ForegroundColor Yellow
            Write-Host 'Use the exact model ID shown by the API if LMSMOB Chat rejects the configured name.'
        }
    } else {
        $apiEndpointStatus = 'HTTP /v1/models responded, but no model IDs were found in its body'
    }
} catch {
    $statusCode = $null
    try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
    if ($statusCode -eq 401 -or $statusCode -eq 403) {
        $apiEndpointStatus = 'HTTP server reachable; authentication is enabled (401/403)'
    } else {
        $apiEndpointStatus = 'TCP is reachable; HTTP check was inconclusive'
    }
}

# Verify the socket is exposed beyond loopback so the Android can reach it.
$lanBindStatus = 'Could not independently inspect the listening address'
try {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction Stop)
    $listenAddresses = @($listeners | Select-Object -ExpandProperty LocalAddress -Unique)
    if (($listenAddresses -contains '0.0.0.0') -or ($listenAddresses -contains '::')) {
        $lanBindStatus = 'LAN bind confirmed (' + ($listenAddresses -join ', ') + ')'
    } elseif ($listenAddresses.Count -gt 0) {
        $lanBindStatus = 'Warning: listener is bound to ' + ($listenAddresses -join ', ') + '; Android access may fail'
        Write-Host ('WARNING: {0}' -f $lanBindStatus) -ForegroundColor Yellow
    } else {
        $lanBindStatus = 'No listening address was found for the API port'
        Write-Host ('WARNING: {0}' -f $lanBindStatus) -ForegroundColor Yellow
    }
} catch {
    # Get-NetTCPConnection may be unavailable or restricted on some Windows builds.
    $lanBindStatus = 'Listener address could not be inspected; server start used --bind 0.0.0.0'
}

# Find IPv4 candidates. Prefer private addresses on physical, up interfaces, but show
# all candidates because VPNs/virtual adapters can make the first address unsuitable.
$ipRecords = @()
$interfaceMetrics = @{}
try {
    foreach ($iface in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
        $interfaceMetrics[[int]$iface.InterfaceIndex] = [int]$iface.InterfaceMetric
    }
} catch { }
try {
    $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object {
        $_.NetAdapter -and $_.NetAdapter.Status -eq 'Up' -and $_.IPv4Address
    })
    $configs = @($configs | Sort-Object `
        @{ Expression = { if ($_.NetAdapter.HardwareInterface) { 0 } else { 1 } } }, `
        @{ Expression = { if ($interfaceMetrics.ContainsKey([int]$_.InterfaceIndex)) { $interfaceMetrics[[int]$_.InterfaceIndex] } else { 9999 } } })
    foreach ($config in $configs) {
        foreach ($address in @($config.IPv4Address)) {
            $ip = [string]$address.IPAddress
            if ($ip -and $ip -notmatch '^(127\.|169\.254\.|224\.|239\.|255\.)') {
                if (-not ($ipRecords | Where-Object { $_.IPAddress -eq $ip })) {
                    $isPrivate = ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
                    $isPhysical = [bool]$config.NetAdapter.HardwareInterface
                    $metric = 9999
                    if ($interfaceMetrics.ContainsKey([int]$config.InterfaceIndex)) { $metric = $interfaceMetrics[[int]$config.InterfaceIndex] }
                    $ipRecords += [pscustomobject]@{
                        IPAddress = $ip
                        InterfaceAlias = [string]$config.InterfaceAlias
                        IsPrivate = $isPrivate
                        IsPhysical = $isPhysical
                        Metric = $metric
                    }
                }
            }
        }
    }
} catch { }
if ($ipRecords.Count -eq 0) {
    try {
        foreach ($entry in @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object {
            $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(127\.|169\.254\.|224\.|239\.|255\.)'
        })) {
            $ip = [string]$entry.IPAddress
            if (-not ($ipRecords | Where-Object { $_.IPAddress -eq $ip })) {
                $isPrivate = ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)')
                $ipRecords += [pscustomobject]@{
                    IPAddress = $ip
                    InterfaceAlias = [string]$entry.InterfaceAlias
                    IsPrivate = $isPrivate
                    IsPhysical = $false
                    Metric = 9999
                }
            }
        }
    } catch { }
}
$ipRecords = @($ipRecords | Sort-Object `
    @{ Expression = { if ($_.IsPrivate) { 0 } else { 1 } } },
    @{ Expression = { if ($_.IsPhysical) { 0 } else { 1 } } },
    @{ Expression = { $_.Metric } })

Write-Host ''
Write-Host '===================== SETUP RESULT =====================' -ForegroundColor Green
Write-Host ("Model loaded from disk : {0}" -f $modelKey)
Write-Host ("Model name for LMSMOB  : {0}" -f $apiModelName) -ForegroundColor Cyan
Write-Host ("PC-local API           : http://127.0.0.1:{0}/v1" -f $port)
if ($serverReady) {
    Write-Host ("Server status          : listening on port {0}" -f $port) -ForegroundColor Green
}
Write-Host ("API endpoint check     : {0}" -f $apiEndpointStatus) -ForegroundColor DarkGray
Write-Host ("Network bind status    : {0}" -f $lanBindStatus) -ForegroundColor DarkGray

if ($ipRecords.Count -gt 0) {
    $primaryIP = [string]$ipRecords[0].IPAddress
    Write-Host ''
    Write-Host 'Best-guess API URL for your Android (verify it is the same LAN as your phone):' -ForegroundColor Green
    Write-Host ("http://{0}:{1}/v1" -f $primaryIP, $port) -ForegroundColor White
    Write-Host ("Network interface: {0}" -f $ipRecords[0].InterfaceAlias) -ForegroundColor DarkGray
    if ($ipRecords.Count -gt 1) {
        Write-Host ''
        Write-Host 'Other IPv4 candidates (use the address on the same LAN/Wi-Fi as your phone):'
        for ($i = 1; $i -lt $ipRecords.Count; $i++) {
            Write-Host ("  http://{0}:{1}/v1   [{2}]" -f $ipRecords[$i].IPAddress, $port, $ipRecords[$i].InterfaceAlias)
        }
    }
} else {
    Write-Host ''
    Write-Host 'Could not automatically detect a LAN IPv4 address.' -ForegroundColor Yellow
    Write-Host 'Run `ipconfig` and use your active Wi-Fi/Ethernet IPv4 address:'
    Write-Host ("http://YOUR_PC_IP:{0}/v1" -f $port)
}

Write-Host ''
Write-Host 'Enter these in LMSMOB Chat settings:' -ForegroundColor Cyan
Write-Host '  API/Base URL : the best-guess Android URL shown above'
Write-Host ("  Model        : {0}" -f $apiModelName)
Write-Host '  API token    : leave blank only if authentication is disabled in LM Studio'
Write-Host '  GPU allocation: automatic (LM Studio default; no unsupported --gpu=auto flag)'
Write-Host ''
Write-Host 'Connectivity checklist:'
Write-Host '  * The Android and PC must be on the same trusted Wi-Fi/LAN.'
Write-Host '  * If the best-guess URL fails, try the other listed IPv4 candidates.'
Write-Host '  * Allow TCP port 1234 through Windows Firewall on Private networks if prompted.'
Write-Host '  * Keep authentication enabled when the network is not fully trusted.'
Write-Host '  * Do not configure router port-forwarding for this local server.'
Write-Host '=========================================================' -ForegroundColor Green
exit 0
