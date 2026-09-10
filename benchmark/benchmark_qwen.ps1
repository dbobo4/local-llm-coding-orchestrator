param(
    [switch]$PreflightOnly,
    [switch]$SyntheticSmoke,
    [switch]$SyntheticCandidates,
    [switch]$AgentSmoke,
    [switch]$ContextKvSweep
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ScriptVersion = "1.1.0-public-unified-adaptive"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath. Copy config\local.example.ps1 to config\local.ps1 and edit it first."
}

. $ConfigPath

if ($null -eq (Get-Variable -Name AlgorithmModelAlias -ErrorAction SilentlyContinue)) {
    $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
}
elseif ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) {
    $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
}

if ($null -eq (Get-Variable -Name TestModelAlias -ErrorAction SilentlyContinue)) {
    $TestModelAlias = "qwen3.8-27b-test"
}
elseif ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) {
    $TestModelAlias = "qwen3.8-27b-test"
}

if ($null -eq (Get-Variable -Name QwenUserRoot -ErrorAction SilentlyContinue)) {
    $QwenUserRoot = Join-Path $HOME ".qwen"
}
elseif ([string]::IsNullOrWhiteSpace([string]$QwenUserRoot)) {
    $QwenUserRoot = Join-Path $HOME ".qwen"
}

$BenchmarkDefaults = [ordered]@{
    ContextWindowSize = 40960
    SpecDraftPMin = "0.025"
    SpecNgramModNMin = 48
    SpecNgramModNMax = 64
    SpecNgramModNMatch = 16
    CacheTypeK = "q8_0"
    CacheTypeV = "q8_0"
}

foreach ($Entry in $BenchmarkDefaults.GetEnumerator()) {
    if ($null -eq (Get-Variable -Name $Entry.Key -ErrorAction SilentlyContinue)) {
        Set-Variable -Name $Entry.Key -Value $Entry.Value
    }
}

$StartScript = Join-Path $RepoRoot "scripts\start_qwen_server.ps1"
$StopScript = Join-Path $RepoRoot "scripts\stop_qwen_server.ps1"
$ModelsPreset = Join-Path $QwenRoot "config\qwen_models.ini"
$SettingsPath = Join-Path $QwenUserRoot "settings.json"
$ServerExe = $LlamaServerExe
$RuntimeClients = Join-Path $QwenUserRoot "runtime_clients"
$HostName = $ServerHost
$Port = [int]$ServerPort

function Get-PassFail {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Value
    )

    if ($Value) {
        return "PASS"
    }

    return "FAIL"
}

function Get-ActiveFree {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Value
    )

    if ($Value) {
        return "ACTIVE"
    }

    return "FREE"
}

function Get-SingleFlagValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Pattern = (
        "(?mi)^[ \t]*--" +
        [regex]::Escape($Name) +
        "[ \t]+([^ \t`r`n]+)"
    )

    $Matches = [regex]::Matches(
        $Text,
        $Pattern
    )

    if ($Matches.Count -ne 1) {
        throw (
            "FLAG_COUNT_FAIL --" +
            $Name +
            " count=" +
            $Matches.Count
        )
    }

    return $Matches[0].Groups[1].Value
}

function Get-SwitchOnlyCount {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Count = 0
    $Expected = "--" + $Name
    $Backtick = [string][char]96

    $Lines = [regex]::Split(
        $Text,
        "\r?\n"
    )

    foreach ($Line in $Lines) {
        $Normalized = $Line.Trim()

        if (
            $Normalized.EndsWith(
                $Backtick,
                [System.StringComparison]::Ordinal
            )
        ) {
            $Normalized = $Normalized.Substring(
                0,
                $Normalized.Length - 1
            ).TrimEnd()
        }

        if (
            [string]::Equals(
                $Normalized,
                $Expected,
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) {
            $Count++
        }
    }

    return $Count
}

function Get-LeaseState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (
        Test-Path `
            -LiteralPath $Path `
            -PathType Leaf
    )) {
        return "ABSENT"
    }

    $Stream = $null

    try {
        $Stream = [System.IO.File]::Open(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )

        return "UNOWNED"
    }
    catch [System.IO.IOException] {
        return "ACTIVE"
    }
    finally {
        if ($null -ne $Stream) {
            $Stream.Dispose()
        }
    }
}

function Test-PortListener {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Port
    )

    $Connections = @(
        Get-NetTCPConnection `
            -LocalPort $Port `
            -State Listen `
            -ErrorAction SilentlyContinue
    )

    return ($Connections.Count -gt 0)
}

function Add-Failure {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$List,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    [void]$List.Add($Message)
}


function ConvertTo-BenchmarkArgument {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.IndexOf('"') -ge 0) {
        throw (
            "Unsupported quote in process argument: " +
            $Value
        )
    }

    if (
        $Value.Length -eq 0 -or
        $Value -match "\s"
    ) {
        return (
            '"' +
            $Value +
            '"'
        )
    }

    return $Value
}

function Get-BenchmarkServerArgumentLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [string]$ModelAlias = "qwen-benchmark"
    )

    $Arguments = @(
        "--model",
        $ModelPath,
        "--alias",
        $ModelAlias,
        "--host",
        $HostName,
        "--port",
        [string]$Port,
        "--ctx-size",
        [string]$Parameters["ctx-size"],
        "--parallel",
        [string]$Parameters["parallel"],
        "--n-gpu-layers",
        [string]$Parameters["n-gpu-layers"],
        "--fit",
        [string]$Parameters["fit"],
        "--spec-type",
        [string]$Parameters["spec-type"],
        "--spec-draft-n-max",
        [string]$Parameters["spec-draft-n-max"],
        "--spec-draft-p-min",
        [string]$Parameters["spec-draft-p-min"],
        "--spec-ngram-mod-n-min",
        [string]$Parameters["spec-ngram-mod-n-min"],
        "--spec-ngram-mod-n-max",
        [string]$Parameters["spec-ngram-mod-n-max"],
        "--spec-ngram-mod-n-match",
        [string]$Parameters["spec-ngram-mod-n-match"],
        "--threads",
        [string]$Parameters["threads"],
        "--threads-batch",
        [string]$Parameters["threads-batch"],
        "--spec-draft-threads",
        [string]$Parameters["spec-draft-threads"],
        "--spec-draft-threads-batch",
        [string]$Parameters["spec-draft-threads-batch"],
        "--flash-attn",
        [string]$Parameters["flash-attn"],
        "--cache-type-k",
        [string]$Parameters["cache-type-k"],
        "--cache-type-v",
        [string]$Parameters["cache-type-v"],
        "--batch-size",
        [string]$Parameters["batch-size"],
        "--ubatch-size",
        [string]$Parameters["ubatch-size"],
        "--jinja",
        "--reasoning",
        [string]$Parameters["reasoning"],
        "--reasoning-effort",
        [string]$Parameters["reasoning-effort"],
        "--reasoning-budget",
        [string]$Parameters["reasoning-budget"],
        "--reasoning-preserve"
    )

    $Quoted = @()

    foreach ($Argument in $Arguments) {
        $Quoted += ConvertTo-BenchmarkArgument `
            -Value ([string]$Argument)
    }

    return ($Quoted -join " ")
}

function Invoke-BenchmarkGetModels {
    $Uri = (
        "http://" +
        $HostName +
        ":" +
        $Port +
        "/v1/models"
    )

    return Invoke-RestMethod `
        -Uri $Uri `
        -Method Get `
        -TimeoutSec 2
}

function Wait-BenchmarkServerReady {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [string]$ModelAlias = "qwen-benchmark"
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds(120)

    while (
        [DateTime]::UtcNow -lt $Deadline
    ) {
        $Process.Refresh()

        if ($Process.HasExited) {
            throw (
                "BENCHMARK_SERVER_EXITED_EARLY code=" +
                $Process.ExitCode
            )
        }

        try {
            $Response = Invoke-BenchmarkGetModels

            $Ids = @(
                $Response.data |
                ForEach-Object {
                    [string]$_.id
                }
            )

            if ($Ids -contains $ModelAlias) {
                return
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 500
    }

    throw "BENCHMARK_SERVER_READY_TIMEOUT"
}

function Stop-BenchmarkProcess {
    param(
        [System.Diagnostics.Process]$Process
    )

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()

        if (-not $Process.HasExited) {
            Stop-Process `
                -Id $Process.Id `
                -Force `
                -ErrorAction SilentlyContinue

            [void]$Process.WaitForExit(10000)
        }
    }
    catch {
        & taskkill.exe `
            /PID $Process.Id `
            /T `
            /F `
            *> $null
    }

    $Deadline = [DateTime]::UtcNow.AddSeconds(10)

    while (
        (Test-PortListener -Port $Port) -and
        [DateTime]::UtcNow -lt $Deadline
    ) {
        Start-Sleep -Milliseconds 250
    }

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw "BENCHMARK_SERVER_PORT_CLEANUP=FAIL"
    }
}

function ConvertTo-InvariantDouble {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [double]::Parse(
        $Value,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Get-BenchmarkMetrics {
    param(
        [Parameter(Mandatory = $true)]
        [string]$LogText
    )

    $PromptMatches = [regex]::Matches(
        $LogText,
        "prompt eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $EvalMatches = [regex]::Matches(
        $LogText,
        "(?<!prompt )eval time\s*=\s*([\d.]+)\s*ms\s*/\s*(\d+)\s*tokens.*?([\d.]+)\s*tokens per second",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $AcceptanceMatches = [regex]::Matches(
        $LogText,
        "draft acceptance\s*=\s*([\d.]+)\s*\(\s*(\d+)\s*accepted\s*/\s*(\d+)\s*generated\)",
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    if ($EvalMatches.Count -lt 1) {
        throw "DECODE_TIMING_PARSE=FAIL"
    }

    $EvalMs = 0.0
    $EvalTokens = 0

    foreach ($Match in $EvalMatches) {
        $EvalMs += ConvertTo-InvariantDouble `
            -Value $Match.Groups[1].Value

        $EvalTokens += [int]$Match.Groups[2].Value
    }

    if (
        $EvalMs -le 0 -or
        $EvalTokens -le 0
    ) {
        throw "DECODE_TIMING_VALUES=INVALID"
    }

    $DecodeTps = (
        [double]$EvalTokens /
        ($EvalMs / 1000.0)
    )

    $PromptTps = $null

    if ($PromptMatches.Count -gt 0) {
        $PromptMs = 0.0
        $PromptTokens = 0

        foreach ($Match in $PromptMatches) {
            $PromptMs += ConvertTo-InvariantDouble `
                -Value $Match.Groups[1].Value

            $PromptTokens += [int]$Match.Groups[2].Value
        }

        if (
            $PromptMs -gt 0 -and
            $PromptTokens -gt 0
        ) {
            $PromptTps = (
                [double]$PromptTokens /
                ($PromptMs / 1000.0)
            )
        }
    }

    $Acceptance = $null

    if ($AcceptanceMatches.Count -gt 0) {
        $Accepted = 0
        $Generated = 0

        foreach ($Match in $AcceptanceMatches) {
            $Accepted += [int]$Match.Groups[2].Value
            $Generated += [int]$Match.Groups[3].Value
        }

        if ($Generated -gt 0) {
            $Acceptance = (
                [double]$Accepted /
                [double]$Generated
            )
        }
    }

    return [pscustomobject]@{
        DecodeTps = $DecodeTps
        PromptTps = $PromptTps
        Acceptance = $Acceptance
        EvalTokens = $EvalTokens
    }
}

function Invoke-SyntheticSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Output ""
    Write-Output "========================================"
    Write-Output " SYNTHETIC ENGINE SMOKE"
    Write-Output "========================================"
    Write-Output "MODE=DIRECT_ISOLATED_LLAMA_SERVER"
    Write-Output "MODEL_ALIAS=qwen-benchmark"
    Write-Output "MAX_TOKENS=256"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw (
            "Port is not free: " +
            $Port
        )
    }

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-benchmark-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path `
        $TempRoot `
        "server.stdout.log"

    $StderrPath = Join-Path `
        $TempRoot `
        "server.stderr.log"

    $Process = $null
    $Metrics = $null
    $WallSeconds = 0.0

    [void](
        New-Item `
            -ItemType Directory `
            -Path $TempRoot `
            -Force
    )

    try {
        $ArgumentLine = Get-BenchmarkServerArgumentLine `
            -Parameters $Parameters

        $Process = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ArgumentLine `
            -WorkingDirectory (
                Split-Path $ServerExe -Parent
            ) `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($null -eq $Process) {
            throw "BENCHMARK_SERVER_START=FAIL"
        }

        Write-Output (
            "BENCHMARK_SERVER_PID=" +
            $Process.Id
        )

        try {
            Wait-BenchmarkServerReady `
                -Process $Process

            Write-Output "BENCHMARK_SERVER_READY=PASS"

            $Prompt = (
                "Write only Python code. Implement a self-contained " +
                "LRU cache class with get, put, delete, contains, clear, " +
                "capacity resizing, hit/miss statistics, iteration from " +
                "most-recently-used to least-recently-used, type hints, " +
                "docstrings, and a comprehensive unittest test suite. " +
                "Do not explain the code."
            )

            $Body = [ordered]@{
                model = "qwen-benchmark"
                reasoning_effort = [string]$Parameters[
                    "reasoning-effort"
                ]
                messages = @(
                    [ordered]@{
                        role = "user"
                        content = $Prompt
                    }
                )
                max_tokens = 256
                temperature = 0.2
                stream = $false
            }

            $Json = ConvertTo-Json `
                -InputObject $Body `
                -Depth 10 `
                -Compress

            $Uri = (
                "http://" +
                $HostName +
                ":" +
                $Port +
                "/v1/chat/completions"
            )

            $Timer = [System.Diagnostics.Stopwatch]::StartNew()

            $Response = Invoke-RestMethod `
                -Uri $Uri `
                -Method Post `
                -ContentType "application/json" `
                -Body $Json `
                -TimeoutSec 300

            $Timer.Stop()

            $WallSeconds = $Timer.Elapsed.TotalSeconds

            if ($null -eq $Response) {
                throw "SYNTHETIC_HTTP_RESPONSE=EMPTY"
            }

            Write-Output "SYNTHETIC_HTTP=PASS"

            Start-Sleep -Milliseconds 500
        }
        finally {
            Stop-BenchmarkProcess `
                -Process $Process
        }

        Write-Output "BENCHMARK_SERVER_CLEANUP=PASS"

        if (-not (
            Test-Path `
                -LiteralPath $StderrPath `
                -PathType Leaf
        )) {
            throw "BENCHMARK_SERVER_LOG=MISSING"
        }

        $LogText = [System.IO.File]::ReadAllText(
            $StderrPath
        )

        $Metrics = Get-BenchmarkMetrics `
            -LogText $LogText
    }
    finally {
        if (
            Test-Path `
                -LiteralPath $TempRoot
        ) {
            Remove-Item `
                -LiteralPath $TempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    if (
        Test-Path `
            -LiteralPath $TempRoot
    ) {
        throw "SYNTHETIC_TEMP_CLEANUP=FAIL"
    }

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw "PORT_8080_CLEANUP=FAIL"
    }

    Write-Output (
        "SYNTHETIC_WALL_SECONDS=" +
        $WallSeconds.ToString(
            "F3",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    Write-Output (
        "SYNTHETIC_DECODE_TPS=" +
        $Metrics.DecodeTps.ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    if ($null -eq $Metrics.PromptTps) {
        Write-Output "SYNTHETIC_PROMPT_TPS=UNAVAILABLE"
    }
    else {
        Write-Output (
            "SYNTHETIC_PROMPT_TPS=" +
            $Metrics.PromptTps.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )
    }

    if ($null -eq $Metrics.Acceptance) {
        Write-Output "SYNTHETIC_DRAFT_ACCEPTANCE=UNAVAILABLE"
    }
    else {
        Write-Output (
            "SYNTHETIC_DRAFT_ACCEPTANCE=" +
            $Metrics.Acceptance.ToString(
                "F5",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )
    }

    Write-Output (
        "SYNTHETIC_EVAL_TOKENS=" +
        $Metrics.EvalTokens
    )

    Write-Output "SYNTHETIC_TEMP_CLEANUP=PASS"
    Write-Output "PORT_8080_CLEANUP=PASS"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Output "SYNTHETIC_SMOKE=PASS"
}


function Copy-BenchmarkParameters {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $Copy = [ordered]@{}

    foreach ($Key in $Parameters.Keys) {
        $Copy[$Key] = [string]$Parameters[$Key]
    }

    return $Copy
}

function Get-BenchmarkMedian {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Values
    )

    if ($Values.Count -lt 1) {
        throw "MEDIAN_INPUT_EMPTY"
    }

    $Sorted = @(
        $Values |
        ForEach-Object {
            [double]$_
        } |
        Sort-Object
    )

    $Count = $Sorted.Count

    if (($Count % 2) -eq 1) {
        $Index = [int][Math]::Floor(
            $Count / 2
        )

        return [double]$Sorted[$Index]
    }

    $Upper = [int]($Count / 2)
    $Lower = $Upper - 1

    return (
        (
            [double]$Sorted[$Lower] +
            [double]$Sorted[$Upper]
        ) / 2.0
    )
}

function Invoke-SyntheticMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [int]$MaxTokens = 600
    )

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw (
            "BENCHMARK_PORT_NOT_FREE port=" +
            $Port
        )
    }

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-benchmark-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path `
        $TempRoot `
        "server.stdout.log"

    $StderrPath = Join-Path `
        $TempRoot `
        "server.stderr.log"

    $Process = $null
    $WallSeconds = 0.0

    [void](
        New-Item `
            -ItemType Directory `
            -Path $TempRoot `
            -Force
    )

    try {
        try {
            $ArgumentLine = Get-BenchmarkServerArgumentLine `
                -Parameters $Parameters

            $Process = Start-Process `
                -FilePath $ServerExe `
                -ArgumentList $ArgumentLine `
                -WorkingDirectory (
                    Split-Path $ServerExe -Parent
                ) `
                -RedirectStandardOutput $StdoutPath `
                -RedirectStandardError $StderrPath `
                -WindowStyle Hidden `
                -PassThru

            if ($null -eq $Process) {
                throw "BENCHMARK_SERVER_START=FAIL"
            }

            Wait-BenchmarkServerReady `
                -Process $Process

            $Prompt = (
                "Write only Python code. Implement a self-contained " +
                "LRU cache class with get, put, delete, contains, clear, " +
                "capacity resizing, hit/miss statistics, iteration from " +
                "most-recently-used to least-recently-used, type hints, " +
                "docstrings, and a comprehensive unittest test suite. " +
                "Do not explain the code."
            )

            $Body = [ordered]@{
                model = "qwen-benchmark"
                reasoning_effort = [string]$Parameters[
                    "reasoning-effort"
                ]
                messages = @(
                    [ordered]@{
                        role = "user"
                        content = $Prompt
                    }
                )
                max_tokens = $MaxTokens
                temperature = 0.2
                stream = $false
            }

            $Json = ConvertTo-Json `
                -InputObject $Body `
                -Depth 10 `
                -Compress

            $Uri = (
                "http://" +
                $HostName +
                ":" +
                $Port +
                "/v1/chat/completions"
            )

            $Timer = [System.Diagnostics.Stopwatch]::StartNew()

            $Response = Invoke-RestMethod `
                -Uri $Uri `
                -Method Post `
                -ContentType "application/json" `
                -Body $Json `
                -TimeoutSec 300

            $Timer.Stop()

            $WallSeconds = $Timer.Elapsed.TotalSeconds

            if ($null -eq $Response) {
                throw "SYNTHETIC_HTTP_RESPONSE=EMPTY"
            }

            Start-Sleep `
                -Milliseconds 400
        }
        finally {
            Stop-BenchmarkProcess `
                -Process $Process
        }

        if (-not (
            Test-Path `
                -LiteralPath $StderrPath `
                -PathType Leaf
        )) {
            throw "BENCHMARK_SERVER_LOG=MISSING"
        }

        $LogText = [System.IO.File]::ReadAllText(
            $StderrPath
        )

        $Metrics = Get-BenchmarkMetrics `
            -LogText $LogText

        return [pscustomobject]@{
            DecodeTps = [double]$Metrics.DecodeTps
            PromptTps = $Metrics.PromptTps
            Acceptance = $Metrics.Acceptance
            EvalTokens = [int]$Metrics.EvalTokens
            WallSeconds = [double]$WallSeconds
        }
    }
    finally {
        if (
            Test-Path `
                -LiteralPath $TempRoot
        ) {
            Remove-Item `
                -LiteralPath $TempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }

        if (
            Test-Path `
                -LiteralPath $TempRoot
        ) {
            throw (
                "BENCHMARK_TEMP_CLEANUP=FAIL path=" +
                $TempRoot
            )
        }

        if (
            Test-PortListener `
                -Port $Port
        ) {
            throw "BENCHMARK_PORT_CLEANUP=FAIL"
        }
    }
}

function Invoke-SyntheticGroup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [int]$Repeats = 2,

        [int]$MaxTokens = 600
    )

    if ($Repeats -lt 1) {
        throw "SYNTHETIC_REPEAT_COUNT_INVALID"
    }

    $Runs = @()

    for (
        $Index = 1;
        $Index -le $Repeats;
        $Index++
    ) {
        Write-Host (
            "RUN=" +
            $Name +
            " " +
            $Index +
            "/" +
            $Repeats
        )

        $Run = Invoke-SyntheticMeasurement `
            -Parameters $Parameters `
            -MaxTokens $MaxTokens

        $Runs += $Run

        Write-Host (
            "  decode=" +
            $Run.DecodeTps.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            " tok/s" +
            " | wall=" +
            $Run.WallSeconds.ToString(
                "F3",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            " s"
        )
    }

    $DecodeValues = @(
        $Runs |
        ForEach-Object {
            $_.DecodeTps
        }
    )

    $WallValues = @(
        $Runs |
        ForEach-Object {
            $_.WallSeconds
        }
    )

    $AcceptanceValues = @(
        $Runs |
        Where-Object {
            $null -ne $_.Acceptance
        } |
        ForEach-Object {
            $_.Acceptance
        }
    )

    $MedianDecode = Get-BenchmarkMedian `
        -Values $DecodeValues

    $MedianWall = Get-BenchmarkMedian `
        -Values $WallValues

    $MedianAcceptance = $null

    if ($AcceptanceValues.Count -gt 0) {
        $MedianAcceptance = Get-BenchmarkMedian `
            -Values $AcceptanceValues
    }

    return [pscustomobject]@{
        Name = $Name
        Parameters = $Parameters
        Runs = $Runs
        RunCount = $Runs.Count
        MedianDecode = [double]$MedianDecode
        MedianWall = [double]$MedianWall
        MedianAcceptance = $MedianAcceptance
    }
}

function Get-SyntheticLeader {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Groups
    )

    if ($Groups.Count -lt 1) {
        throw "NO_SYNTHETIC_GROUPS"
    }

    $Leader = $Groups[0]

    foreach ($Group in $Groups) {
        if (
            [double]$Group.MedianDecode -gt
            [double]$Leader.MedianDecode
        ) {
            $Leader = $Group
        }
    }

    return $Leader
}

function Write-SyntheticGroupSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Group
    )

    $Acceptance = "UNAVAILABLE"

    if ($null -ne $Group.MedianAcceptance) {
        $Acceptance = (
            [double]$Group.MedianAcceptance
        ).ToString(
            "F5",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    Write-Host (
        "  " +
        $Group.Name +
        " | median_decode=" +
        $Group.MedianDecode.ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        ) +
        " tok/s" +
        " | median_wall=" +
        $Group.MedianWall.ToString(
            "F3",
            [System.Globalization.CultureInfo]::InvariantCulture
        ) +
        " s" +
        " | acceptance=" +
        $Acceptance
    )
}

function Invoke-SyntheticCandidateSweep {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Output ""
    Write-Output "========================================"
    Write-Output " SYNTHETIC CANDIDATE SWEEP"
    Write-Output "========================================"
    Write-Output "SYNTHETIC_REPEATS_PER_CANDIDATE=2"
    Write-Output "MAX_TOKENS_PER_RUN=600"
    Write-Output "TOTAL_PLANNED_RUNS=12"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Output "PERSISTENT_RESULT_FILES=NO"
    Write-Output ""
    Write-Output "SELECTION_RULE=highest median synthetic decode TPS"
    Write-Output "QUALITY_GATE=DEFERRED_TO_REAL_AGENT_PHASE"

    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Output ""
    Write-Output "=== NGRAM PHASE ==="

    $NgramCandidates = @(
        @(48, 64, 24),
        @(32, 64, 16),
        @(48, 64, 16)
    )

    $NgramGroups = @()

    foreach ($Triple in $NgramCandidates) {
        $Config = Copy-BenchmarkParameters `
            -Parameters $Parameters

        $Config["spec-ngram-mod-n-min"] = [string]$Triple[0]
        $Config["spec-ngram-mod-n-max"] = [string]$Triple[1]
        $Config["spec-ngram-mod-n-match"] = [string]$Triple[2]

        $Name = (
            "ngram_" +
            $Triple[0] +
            "_" +
            $Triple[1] +
            "_" +
            $Triple[2]
        )

        $Group = Invoke-SyntheticGroup `
            -Name $Name `
            -Parameters $Config `
            -Repeats 2 `
            -MaxTokens 600

        $NgramGroups += $Group
    }

    Write-Output ""
    Write-Output "NGRAM RESULTS:"

    foreach ($Group in $NgramGroups) {
        Write-SyntheticGroupSummary `
            -Group $Group
    }

    $NgramLeader = Get-SyntheticLeader `
        -Groups $NgramGroups

    $NgramLeaderValue = (
        $NgramLeader.Parameters[
            "spec-ngram-mod-n-min"
        ] +
        "/" +
        $NgramLeader.Parameters[
            "spec-ngram-mod-n-max"
        ] +
        "/" +
        $NgramLeader.Parameters[
            "spec-ngram-mod-n-match"
        ]
    )

    Write-Output (
        "NGRAM_SYNTHETIC_LEADER=" +
        $NgramLeaderValue
    )

    Write-Output (
        "NGRAM_SYNTHETIC_LEADER_TPS=" +
        $NgramLeader.MedianDecode.ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    Write-Output ""
    Write-Output "=== P-MIN PHASE ==="

    $PminCandidates = @(
        "0",
        "0.025",
        "0.05"
    )

    $PminGroups = @()

    foreach ($Pmin in $PminCandidates) {
        $Config = Copy-BenchmarkParameters `
            -Parameters $NgramLeader.Parameters

        $Config["spec-draft-p-min"] = $Pmin

        $Name = (
            "pmin_" +
            $Pmin
        )

        $Group = Invoke-SyntheticGroup `
            -Name $Name `
            -Parameters $Config `
            -Repeats 2 `
            -MaxTokens 600

        $PminGroups += $Group
    }

    Write-Output ""
    Write-Output "P-MIN RESULTS:"

    foreach ($Group in $PminGroups) {
        Write-SyntheticGroupSummary `
            -Group $Group
    }

    $PminLeader = Get-SyntheticLeader `
        -Groups $PminGroups

    $PminLeaderValue = [string]$PminLeader.Parameters[
        "spec-draft-p-min"
    ]

    Write-Output (
        "PMIN_SYNTHETIC_LEADER=" +
        $PminLeaderValue
    )

    Write-Output (
        "PMIN_SYNTHETIC_LEADER_TPS=" +
        $PminLeader.MedianDecode.ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    $Timer.Stop()

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw "FINAL_PORT_CLEANUP=FAIL"
    }

    Write-Output ""
    Write-Output "=== SYNTHETIC SHORTLIST ==="
    Write-Output (
        "NGRAM=" +
        $NgramLeaderValue
    )
    Write-Output (
        "P_MIN=" +
        $PminLeaderValue
    )
    Write-Output (
        "TOTAL_WALL_SECONDS=" +
        $Timer.Elapsed.TotalSeconds.ToString(
            "F1",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )
    Write-Output "FINAL_RECOMMENDATION=NOT_YET_QUALITY_GATED"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Output "PERSISTENT_RESULT_FILES=NO"
    Write-Output "PORT_8080_CLEANUP=PASS"
    Write-Output "SYNTHETIC_CANDIDATE_SWEEP=PASS"
}


function Get-BenchmarkPromptAlias {
    if ([string]::IsNullOrWhiteSpace([string]$ModelAlias)) {
        throw "BENCHMARK_MODEL_ALIAS_MISSING"
    }

    return [string]$ModelAlias
}

function Write-AgentBenchmarkWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$ReasoningEffort
    )

    [void](New-Item -ItemType Directory -Path $Path -Force)

    $CacheSource = @"
from collections import OrderedDict

class LRUCache:
    def __init__(self, capacity: int):
        if capacity <= 0:
            raise ValueError("capacity must be positive")
        self.capacity = capacity
        self._data = OrderedDict()
        self.hits = 0
        self.misses = 0

    def get(self, key, default=None):
        if key not in self._data:
            self.hits += 1  # BUG
            return default
        self.misses += 1  # BUG
        value = self._data[key]
        return value

    def put(self, key, value):
        if key in self._data:
            self._data[key] = value
            return
        self._data[key] = value
        if len(self._data) > self.capacity:
            self._data.popitem(last=True)  # BUG

    def delete(self, key):
        return self._data.pop(key, None)

    def contains(self, key):
        return key in self._data

    def clear(self):
        self._data.clear()
        self.hits = 0
        self.misses = 0

    def resize(self, new_capacity: int):
        if new_capacity <= 0:
            raise ValueError("capacity must be positive")
        self.capacity = new_capacity
        if len(self._data) > self.capacity:
            self._data.popitem(last=False)

    def items_mru_to_lru(self):
        return list(self._data.items())
"@

    $TestSource = @"
import unittest
from cache import LRUCache

class TestLRUCache(unittest.TestCase):
    def test_get_updates_recency_and_stats(self):
        c = LRUCache(2)
        c.put("a", 1)
        c.put("b", 2)
        self.assertEqual(c.get("a"), 1)
        self.assertEqual(c.hits, 1)
        self.assertEqual(c.misses, 0)
        c.put("c", 3)
        self.assertTrue(c.contains("a"))
        self.assertFalse(c.contains("b"))

    def test_miss_stats(self):
        c = LRUCache(2)
        self.assertIsNone(c.get("missing"))
        self.assertEqual(c.hits, 0)
        self.assertEqual(c.misses, 1)

    def test_update_existing_is_mru(self):
        c = LRUCache(2)
        c.put("a", 1)
        c.put("b", 2)
        c.put("a", 10)
        c.put("c", 3)
        self.assertTrue(c.contains("a"))
        self.assertFalse(c.contains("b"))
        self.assertEqual(c.get("a"), 10)

    def test_resize_evicts_until_fit(self):
        c = LRUCache(5)
        for i in range(5):
            c.put(i, i)
        c.resize(2)
        self.assertEqual(len(c._data), 2)
        self.assertEqual(set(c._data.keys()), {3, 4})

    def test_iteration_mru_to_lru(self):
        c = LRUCache(3)
        c.put("a", 1)
        c.put("b", 2)
        c.put("c", 3)
        c.get("a")
        self.assertEqual(
            c.items_mru_to_lru(),
            [("a", 1), ("c", 3), ("b", 2)],
        )

    def test_delete_clear_and_validation(self):
        c = LRUCache(2)
        c.put("a", 1)
        self.assertEqual(c.delete("a"), 1)
        self.assertIsNone(c.delete("missing"))
        c.put("b", 2)
        c.get("b")
        c.get("missing")
        c.clear()
        self.assertEqual(len(c._data), 0)
        self.assertEqual(c.hits, 0)
        self.assertEqual(c.misses, 0)
        with self.assertRaises(ValueError):
            c.resize(0)

if __name__ == "__main__":
    unittest.main()
"@

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $Path "cache.py"), $CacheSource, $Utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $Path "test_cache.py"), $TestSource, $Utf8NoBom)

    $QwenDir = Join-Path $Path ".qwen"
    [void](New-Item -ItemType Directory -Path $QwenDir -Force)
    $Settings = [ordered]@{
        model = [ordered]@{
            reasoningEffort = $ReasoningEffort
        }
    }
    $SettingsJson = ConvertTo-Json -InputObject $Settings -Depth 5
    [System.IO.File]::WriteAllText((Join-Path $QwenDir "settings.json"), $SettingsJson, $Utf8NoBom)
}

function Invoke-AgentSmoke {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Output ""
    Write-Output "========================================"
    Write-Output " REAL QWEN CODE AGENT SMOKE"
    Write-Output "========================================"
    Write-Output "AGENT_RUNS=1"
    Write-Output "SELECTION=NONE"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"

    $PythonCommand = (
        Get-Command `
            python `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
        Select-Object -First 1
    )
    if ($null -eq $PythonCommand) {
        throw "PYTHON_RUNTIME=MISSING"
    }
    Write-Output ("PYTHON_RUNTIME=" + $PythonCommand.Source)

    $ModelAlias = Get-BenchmarkPromptAlias
    Write-Output ("AGENT_MODEL_ALIAS=" + $ModelAlias)

    if (Test-PortListener -Port $Port) {
        throw ("AGENT_BENCHMARK_PORT_NOT_FREE port=" + $Port)
    }

    $TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("qwen-agent-benchmark-" + [Guid]::NewGuid().ToString("N"))
    $StdoutPath = Join-Path $TempRoot "server.stdout.log"
    $StderrPath = Join-Path $TempRoot "server.stderr.log"

    $Process = $null
    $QwenExitCode = $null
    $TestExitCode = $null
    $QwenOutput = ""
    $TestOutput = ""
    $AgentWall = 0.0
    $Metrics = $null

    try {
        Write-AgentBenchmarkWorkspace -Path $TempRoot -ReasoningEffort ([string]$Parameters["reasoning-effort"])
        Write-Output "AGENT_WORKSPACE_CREATED=PASS"

        try {
            $ArgumentLine = Get-BenchmarkServerArgumentLine -Parameters $Parameters -ModelAlias $ModelAlias
            $Process = Start-Process `
                -FilePath $ServerExe `
                -ArgumentList $ArgumentLine `
                -WorkingDirectory (Split-Path $ServerExe -Parent) `
                -RedirectStandardOutput $StdoutPath `
                -RedirectStandardError $StderrPath `
                -WindowStyle Hidden `
                -PassThru

            if ($null -eq $Process) {
                throw "AGENT_BENCHMARK_SERVER_START=FAIL"
            }

            Write-Output ("AGENT_SERVER_PID=" + $Process.Id)
            Wait-BenchmarkServerReady -Process $Process -ModelAlias $ModelAlias
            Write-Output "AGENT_SERVER_READY=PASS"

            $AgentPrompt = (
                "Work only inside the current benchmark directory. " +
                "Fix cache.py so that all tests in test_cache.py pass. " +
                "Do NOT modify test_cache.py. Run the test suite yourself before finishing. " +
                "Do not use the network. Do not use git. " +
                "Do not create or modify files outside the current directory. " +
                "Follow the configured normal Qwen Code orchestration, hooks and agent/subagent workflow where appropriate. " +
                "Return a concise final status when the implementation is correct and the tests pass."
            )

            $QwenArgs = @(
                "--output-format", "json",
                "--approval-mode", "yolo",
                "--model", $ModelAlias,
                "--max-session-turns", "30",
                "--max-wall-time", "8m",
                "--max-tool-calls", "60",
                $AgentPrompt
            )

            Push-Location $TempRoot
            try {
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"
                try {
                    $Timer = [System.Diagnostics.Stopwatch]::StartNew()
                    $QwenOutput = (& $QwenCodeCli @QwenArgs 2>&1 | Out-String)
                    $Timer.Stop()
                    $AgentWall = $Timer.Elapsed.TotalSeconds
                    $QwenExitCode = $LASTEXITCODE

                    $TestOutput = (& python -m unittest -v test_cache.py 2>&1 | Out-String)
                    $TestExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            Write-Output ("QWEN_EXIT_CODE=" + $QwenExitCode)
            Write-Output ("EXTERNAL_TEST_EXIT_CODE=" + $TestExitCode)

            if ($QwenExitCode -ne 0) {
                Write-Output ""
                Write-Output "=== QWEN OUTPUT TAIL ==="
                $TailLength = [Math]::Min(3000, $QwenOutput.Length)
                if ($TailLength -gt 0) {
                    Write-Output $QwenOutput.Substring($QwenOutput.Length - $TailLength, $TailLength)
                }
                throw "QWEN_AGENT_EXECUTION=FAIL"
            }

            if ($TestExitCode -ne 0) {
                Write-Output ""
                Write-Output "=== EXTERNAL TEST OUTPUT ==="
                Write-Output $TestOutput
                throw "QWEN_AGENT_EXTERNAL_TESTS=FAIL"
            }

            Write-Output "QWEN_AGENT_EXECUTION=PASS"
            Write-Output "QWEN_AGENT_EXTERNAL_TESTS=PASS"
            Start-Sleep -Milliseconds 400
        }
        finally {
            Stop-BenchmarkProcess -Process $Process
        }

        Write-Output "AGENT_SERVER_CLEANUP=PASS"

        if (-not (Test-Path -LiteralPath $StderrPath -PathType Leaf)) {
            throw "AGENT_SERVER_LOG=MISSING"
        }

        $LogText = [System.IO.File]::ReadAllText($StderrPath)
        $Metrics = Get-BenchmarkMetrics -LogText $LogText
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) {
            Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction Stop
        }
    }

    if (Test-Path -LiteralPath $TempRoot) {
        throw ("AGENT_WORKSPACE_CLEANUP=FAIL path=" + $TempRoot)
    }
    if (Test-PortListener -Port $Port) {
        throw "AGENT_PORT_CLEANUP=FAIL"
    }
    if ($null -eq $Metrics) {
        throw "AGENT_METRICS=FAIL"
    }

    Write-Output ("AGENT_WALL_SECONDS=" + $AgentWall.ToString("F3", [System.Globalization.CultureInfo]::InvariantCulture))
    Write-Output ("AGENT_DECODE_TPS=" + $Metrics.DecodeTps.ToString("F2", [System.Globalization.CultureInfo]::InvariantCulture))

    if ($null -eq $Metrics.Acceptance) {
        Write-Output "AGENT_DRAFT_ACCEPTANCE=UNAVAILABLE"
    }
    else {
        Write-Output ("AGENT_DRAFT_ACCEPTANCE=" + $Metrics.Acceptance.ToString("F5", [System.Globalization.CultureInfo]::InvariantCulture))
    }

    Write-Output "AGENT_WORKSPACE_CLEANUP=PASS"
    Write-Output "AGENT_PORT_CLEANUP=PASS"
    Write-Output "PERSISTENT_AGENT_ARTIFACTS=NO"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Output "AGENT_SMOKE=PASS"
}


function Get-GpuFreeMemoryMb {
    $Commands = @(
        Get-Command `
            nvidia-smi.exe `
            -CommandType Application `
            -ErrorAction SilentlyContinue
    )

    if ($Commands.Count -lt 1) {
        throw "NVIDIA_SMI=MISSING"
    }

    $Executable = $Commands[0].Source

    $OldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $Output = @(
            & $Executable `
                --query-gpu=memory.free `
                --format=csv,noheader,nounits `
                2>&1
        )

        $ExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $OldPreference
    }

    if ($ExitCode -ne 0) {
        throw (
            "NVIDIA_SMI_QUERY=FAIL exit=" +
            $ExitCode
        )
    }

    $Values = @()

    foreach ($Line in $Output) {
        $Text = [string]$Line
        $Text = $Text.Trim()

        $Value = 0

        if (
            [int]::TryParse(
                $Text,
                [ref]$Value
            )
        ) {
            $Values += $Value
        }
    }

    if ($Values.Count -lt 1) {
        throw "NVIDIA_SMI_QUERY=NO_NUMERIC_VALUES"
    }

    return [int](
        $Values |
        Measure-Object -Minimum
    ).Minimum
}

function Invoke-ContextKvMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [int]$ContextSize,

        [Parameter(Mandatory = $true)]
        [string]$CacheK,

        [Parameter(Mandatory = $true)]
        [string]$CacheV,

        [int]$MaxTokens = 600,

        [int]$MinFreeVramMb = 512
    )

    $Config = Copy-BenchmarkParameters `
        -Parameters $Parameters

    $Config["ctx-size"] = [string]$ContextSize
    $Config["cache-type-k"] = $CacheK
    $Config["cache-type-v"] = $CacheV

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw (
            "CONTEXT_SWEEP_PORT_NOT_FREE port=" +
            $Port
        )
    }

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-benchmark-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path `
        $TempRoot `
        "server.stdout.log"

    $StderrPath = Join-Path `
        $TempRoot `
        "server.stderr.log"

    $Process = $null
    $Stable = $false
    $Reason = "UNKNOWN"
    $ReadyFreeMb = $null
    $PostFreeMb = $null
    $MinObservedFreeMb = $null
    $DecodeTps = $null
    $WallSeconds = $null
    $ExecutionError = $null
    $RequestSucceeded = $false

    [void](
        New-Item `
            -ItemType Directory `
            -Path $TempRoot `
            -Force
    )

    try {
        try {
            try {
                $ArgumentLine = Get-BenchmarkServerArgumentLine `
                    -Parameters $Config

                $Process = Start-Process `
                    -FilePath $ServerExe `
                    -ArgumentList $ArgumentLine `
                    -WorkingDirectory (
                        Split-Path $ServerExe -Parent
                    ) `
                    -RedirectStandardOutput $StdoutPath `
                    -RedirectStandardError $StderrPath `
                    -WindowStyle Hidden `
                    -PassThru

                if ($null -eq $Process) {
                    throw "CONTEXT_SERVER_START=FAIL"
                }

                Wait-BenchmarkServerReady `
                    -Process $Process

                # Preserve the proven v4 semantics: VRAM safety is sampled
                # once after model readiness, before the generation request.
                $ReadyFreeMb = Get-GpuFreeMemoryMb
                $MinObservedFreeMb = $ReadyFreeMb

                $Prompt = (
                    "Write only Python code. Implement a self-contained " +
                    "LRU cache class with get, put, delete, contains, clear, " +
                    "capacity resizing, hit/miss statistics, iteration from " +
                    "most-recently-used to least-recently-used, type hints, " +
                    "docstrings, and a comprehensive unittest test suite. " +
                    "Do not explain the code."
                )

                $Body = [ordered]@{
                    model = "qwen-benchmark"
                    reasoning_effort = [string]$Config[
                        "reasoning-effort"
                    ]
                    messages = @(
                        [ordered]@{
                            role = "user"
                            content = $Prompt
                        }
                    )
                    max_tokens = $MaxTokens
                    temperature = 0.2
                    stream = $false
                }

                $Json = ConvertTo-Json `
                    -InputObject $Body `
                    -Depth 10 `
                    -Compress

                $Uri = (
                    "http://" +
                    $HostName +
                    ":" +
                    $Port +
                    "/v1/chat/completions"
                )

                $Timer = [System.Diagnostics.Stopwatch]::StartNew()

                $Response = Invoke-RestMethod `
                    -Uri $Uri `
                    -Method Post `
                    -ContentType "application/json" `
                    -Body $Json `
                    -TimeoutSec 300

                $Timer.Stop()
                $WallSeconds = $Timer.Elapsed.TotalSeconds

                if ($null -eq $Response) {
                    throw "CONTEXT_HTTP_RESPONSE=EMPTY"
                }

                $RequestSucceeded = $true
                Start-Sleep -Milliseconds 400
            }
            catch {
                $ExecutionError = $_.Exception.Message
            }
            finally {
                try {
                    Stop-BenchmarkProcess `
                        -Process $Process
                }
                catch {
                    if ($null -eq $ExecutionError) {
                        $ExecutionError = $_.Exception.Message
                    }
                }
            }

            if ($null -ne $ExecutionError) {
                $Stable = $false
                $Reason = $ExecutionError
            }
            elseif (-not $RequestSucceeded) {
                $Stable = $false
                $Reason = "CONTEXT_REQUEST=FAIL"
            }
            elseif (
                $null -eq $ReadyFreeMb
            ) {
                $Stable = $false
                $Reason = "VRAM_READY_SAMPLE=MISSING"
            }
            elseif (
                [int]$ReadyFreeMb -lt $MinFreeVramMb
            ) {
                $Stable = $false
                $Reason = (
                    "VRAM_FREE_BELOW_GATE observed=" +
                    $ReadyFreeMb +
                    " required=" +
                    $MinFreeVramMb
                )
            }
            else {
                if (-not (
                    Test-Path `
                        -LiteralPath $StderrPath `
                        -PathType Leaf
                )) {
                    throw "CONTEXT_SERVER_LOG=MISSING"
                }

                # PowerShell Start-Process keeps the redirection handle open
                # while llama-server is alive, so parse only after stop.
                $LogText = [System.IO.File]::ReadAllText(
                    $StderrPath
                )

                $Metrics = Get-BenchmarkMetrics `
                    -LogText $LogText

                $DecodeTps = [double]$Metrics.DecodeTps
                $Stable = $true
                $Reason = "PASS"
            }
        }
        catch {
            $Stable = $false
            $Reason = $_.Exception.Message
        }
    }
    finally {
        if (
            Test-Path `
                -LiteralPath $TempRoot
        ) {
            Remove-Item `
                -LiteralPath $TempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    if (
        Test-Path `
            -LiteralPath $TempRoot
    ) {
        throw (
            "CONTEXT_TEMP_CLEANUP=FAIL path=" +
            $TempRoot
        )
    }

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw "CONTEXT_PORT_CLEANUP=FAIL"
    }

    return [pscustomobject]@{
        ContextSize = $ContextSize
        CacheK = $CacheK
        CacheV = $CacheV
        Stable = $Stable
        Reason = $Reason
        ReadyFreeMb = $ReadyFreeMb
        PostFreeMb = $PostFreeMb
        MinFreeMb = $MinObservedFreeMb
        DecodeTps = $DecodeTps
        WallSeconds = $WallSeconds
    }
}

function Write-ContextKvResult {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $State = "UNSTABLE"

    if ($Result.Stable) {
        $State = "STABLE"
    }

    $Vram = "UNAVAILABLE"

    if ($null -ne $Result.MinFreeMb) {
        $Vram = [string]$Result.MinFreeMb
    }

    $Decode = "UNAVAILABLE"

    if ($null -ne $Result.DecodeTps) {
        $Decode = ([double]$Result.DecodeTps).ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    Write-Output (
        "ctx=" +
        $Result.ContextSize +
        " cache=" +
        $Result.CacheK +
        "/" +
        $Result.CacheV +
        " state=" +
        $State +
        " min_free_mb=" +
        $Vram +
        " decode_tps=" +
        $Decode +
        " reason=" +
        $Result.Reason
    )
}

function Get-LargestStableContextResult {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Results
    )

    $Stable = @(
        $Results |
        Where-Object {
            $_.Stable
        } |
        Sort-Object ContextSize
    )

    if ($Stable.Count -lt 1) {
        return $null
    }

    return $Stable[$Stable.Count - 1]
}

function Invoke-ContextKvSweep {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Output ""
    Write-Output "========================================"
    Write-Output " CONTEXT / KV CAPACITY SWEEP"
    Write-Output "========================================"
    Write-Output "NGRAM_FIXED=48/64/16"
    Write-Output "P_MIN_FIXED=0.025"
    Write-Output "REPEATS_PER_CANDIDATE=1"
    Write-Output "VRAM_SAMPLING=after readiness before generation (proven v4 semantics)"
    Write-Output "MAX_TOKENS_PER_RUN=600"
    Write-Output "VRAM_MIN_FREE_MB=512"
    Write-Output "SELECTION_RULE=largest stable context with VRAM gate"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"

    $NvidiaCommands = @(
        Get-Command `
            nvidia-smi.exe `
            -CommandType Application `
            -ErrorAction SilentlyContinue
    )

    if ($NvidiaCommands.Count -lt 1) {
        throw "NVIDIA_SMI_PREFLIGHT=FAIL"
    }

    Write-Output (
        "NVIDIA_SMI=" +
        $NvidiaCommands[0].Source
    )

    $InitialFree = Get-GpuFreeMemoryMb

    Write-Output (
        "INITIAL_MIN_GPU_FREE_MB=" +
        $InitialFree
    )

    $QualityContexts = @(
        24576,
        32768,
        40960,
        49152
    )

    $ExtendedContexts = @(
        32768,
        40960,
        49152,
        57344,
        65536
    )

    $QualityResults = @()
    $ExtendedResults = @()

    Write-Output ""
    Write-Output "=== Q8/Q8 QUALITY PROFILE ==="

    foreach ($ContextSize in $QualityContexts) {
        Write-Output (
            "RUN ctx=" +
            $ContextSize +
            " cache=q8_0/q8_0"
        )

        $Result = Invoke-ContextKvMeasurement `
            -Parameters $Parameters `
            -ContextSize $ContextSize `
            -CacheK "q8_0" `
            -CacheV "q8_0" `
            -MaxTokens 600 `
            -MinFreeVramMb 512

        $QualityResults += $Result

        Write-ContextKvResult `
            -Result $Result
    }

    $QualityWinner = Get-LargestStableContextResult `
        -Results $QualityResults

    if ($null -eq $QualityWinner) {
        throw "QUALITY_Q8Q8_NO_STABLE_CONTEXT"
    }

    Write-Output ""
    Write-Output (
        "QUALITY_Q8Q8_CONTEXT=" +
        $QualityWinner.ContextSize
    )

    Write-Output (
        "QUALITY_Q8Q8_MIN_FREE_MB=" +
        $QualityWinner.MinFreeMb
    )

    Write-Output ""
    Write-Output "=== Q8/Q5 OPTIONAL MAX-CONTEXT PROFILE ==="

    foreach ($ContextSize in $ExtendedContexts) {
        Write-Output (
            "RUN ctx=" +
            $ContextSize +
            " cache=q8_0/q5_0"
        )

        $Result = Invoke-ContextKvMeasurement `
            -Parameters $Parameters `
            -ContextSize $ContextSize `
            -CacheK "q8_0" `
            -CacheV "q5_0" `
            -MaxTokens 600 `
            -MinFreeVramMb 512

        $ExtendedResults += $Result

        Write-ContextKvResult `
            -Result $Result
    }

    $ExtendedWinner = Get-LargestStableContextResult `
        -Results $ExtendedResults

    Write-Output ""
    Write-Output "=== CONTEXT / KV RESULT ==="
    Write-Output (
        "QUALITY_PROFILE_CTX=" +
        $QualityWinner.ContextSize
    )
    Write-Output "QUALITY_PROFILE_CACHE_K=q8_0"
    Write-Output "QUALITY_PROFILE_CACHE_V=q8_0"

    if ($null -eq $ExtendedWinner) {
        Write-Output "OPTIONAL_MAX_CONTEXT_PROFILE=NONE_STABLE"
    }
    else {
        Write-Output (
            "OPTIONAL_MAX_CONTEXT_CTX=" +
            $ExtendedWinner.ContextSize
        )
        Write-Output "OPTIONAL_MAX_CONTEXT_CACHE_K=q8_0"
        Write-Output "OPTIONAL_MAX_CONTEXT_CACHE_V=q5_0"
    }

    if (
        $QualityWinner.ContextSize -eq 49152 -and
        [string]$Parameters["ctx-size"] -eq "49152" -and
        [string]$Parameters["cache-type-k"] -eq "q8_0" -and
        [string]$Parameters["cache-type-v"] -eq "q8_0"
    ) {
        Write-Output "QUALITY_PROFILE_MATCHES_CURRENT_CONTEXT_KV=YES"
        Write-Output "EXTRA_CONTEXT_AGENT_GATE_REQUIRED=NO"
    }
    else {
        Write-Output "QUALITY_PROFILE_MATCHES_CURRENT_CONTEXT_KV=NO"
        Write-Output "EXTRA_CONTEXT_AGENT_GATE_REQUIRED=YES"
    }

    Write-Output "QUALITY_PROFILE_SCOPE=largest stable q8_0/q8_0 candidate tested"
    Write-Output "OPTIONAL_MAX_CONTEXT_SCOPE=largest stable q8_0/q5_0 candidate tested"
    Write-Output "OVERALL_RECOMMENDATION=NOT_YET_COMPLETE"
    Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Output "PORT_8080_CLEANUP=PASS"
    Write-Output "CONTEXT_KV_SWEEP=PASS"
}


function Assert-BenchmarkIdle {
    $ChatLease = Join-Path `
        $RuntimeClients `
        "chat.lock"

    if (
        (Get-LeaseState -Path $ChatLease) -eq "ACTIVE"
    ) {
        throw "ACTIVE_CHAT_CLIENT_DETECTED"
    }

    $CliDir = Join-Path `
        $RuntimeClients `
        "cli"

    if (Test-Path -LiteralPath $CliDir) {
        $CliLocks = @(
            Get-ChildItem `
                -LiteralPath $CliDir `
                -Filter "*.lock" `
                -File `
                -ErrorAction SilentlyContinue
        )

        foreach ($Lock in $CliLocks) {
            if (
                (Get-LeaseState -Path $Lock.FullName) -eq "ACTIVE"
            ) {
                throw "ACTIVE_CLI_CLIENT_DETECTED"
            }
        }
    }

    if (
        Test-PortListener `
            -Port $Port
    ) {
        throw (
            "PORT_NOT_FREE port=" +
            $Port
        )
    }
}

function Get-OutputMarkerDouble {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Pattern = (
        "(?m)^" +
        [regex]::Escape($Name) +
        "=([0-9.]+)[ \t]*$"
    )

    $Match = [regex]::Match(
        $Text,
        $Pattern
    )

    if (-not $Match.Success) {
        return $null
    }

    return [double]::Parse(
        $Match.Groups[1].Value,
        [System.Globalization.CultureInfo]::InvariantCulture
    )
}

function Invoke-AgentGateMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    Write-Host ""
    Write-Host (
        "AGENT_GATE_RUN=" +
        $Label
    )

    $Captured = @()
    $FailureReason = $null

    try {
        $Captured = @(
            Invoke-AgentSmoke `
                -Parameters $Parameters
        )
    }
    catch {
        $FailureReason = $_.Exception.Message
    }

    foreach ($Line in $Captured) {
        Write-Host ([string]$Line)
    }

    $Text = (
        $Captured |
        ForEach-Object {
            [string]$_
        }
    ) -join "`n"

    $RequiredMarkers = @(
        "QWEN_AGENT_EXECUTION=PASS",
        "QWEN_AGENT_EXTERNAL_TESTS=PASS",
        "AGENT_SERVER_CLEANUP=PASS",
        "AGENT_WORKSPACE_CLEANUP=PASS",
        "AGENT_PORT_CLEANUP=PASS",
        "AGENT_SMOKE=PASS"
    )

    $Passed = (
        $null -eq $FailureReason
    )

    foreach ($Marker in $RequiredMarkers) {
        if (
            $Text.IndexOf(
                $Marker,
                [System.StringComparison]::Ordinal
            ) -lt 0
        ) {
            $Passed = $false
        }
    }

    $WallSeconds = Get-OutputMarkerDouble `
        -Text $Text `
        -Name "AGENT_WALL_SECONDS"

    $DecodeTps = Get-OutputMarkerDouble `
        -Text $Text `
        -Name "AGENT_DECODE_TPS"

    $Acceptance = Get-OutputMarkerDouble `
        -Text $Text `
        -Name "AGENT_DRAFT_ACCEPTANCE"

    if (
        $Passed -and
        $null -eq $WallSeconds
    ) {
        $Passed = $false
        $FailureReason = "AGENT_WALL_SECONDS_MISSING"
    }

    if ($Passed) {
        Write-Host (
            "AGENT_GATE_RESULT=PASS label=" +
            $Label +
            " wall=" +
            $WallSeconds.ToString(
                "F3",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            "s"
        )
    }
    else {
        if ($null -eq $FailureReason) {
            $FailureReason = "REQUIRED_PASS_MARKER_MISSING"
        }

        Write-Host (
            "AGENT_GATE_RESULT=FAIL label=" +
            $Label +
            " reason=" +
            $FailureReason
        )
    }

    Assert-BenchmarkIdle

    return [pscustomobject]@{
        Pass = $Passed
        WallSeconds = $WallSeconds
        DecodeTps = $DecodeTps
        Acceptance = $Acceptance
        Reason = $FailureReason
    }
}

function Invoke-AdaptiveNgramStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " STAGE 1 - NGRAM"
    Write-Host "========================================"
    Write-Host "RULE=3 synthetic runs per candidate; rank by synthetic median decode; test candidates in rank order; candidate must pass 2/2 real-agent gates"

    $Candidates = @(
        [pscustomobject]@{
            Min = 48
            Max = 64
            Match = 24
        },
        [pscustomobject]@{
            Min = 32
            Max = 64
            Match = 16
        },
        [pscustomobject]@{
            Min = 48
            Max = 64
            Match = 16
        }
    )

    $Records = @()

    foreach ($Candidate in $Candidates) {
        Assert-BenchmarkIdle

        $Config = Copy-BenchmarkParameters `
            -Parameters $Parameters

        $Config["spec-ngram-mod-n-min"] = [string]$Candidate.Min
        $Config["spec-ngram-mod-n-max"] = [string]$Candidate.Max
        $Config["spec-ngram-mod-n-match"] = [string]$Candidate.Match

        $Name = (
            "ngram_" +
            $Candidate.Min +
            "_" +
            $Candidate.Max +
            "_" +
            $Candidate.Match
        )

        $Group = Invoke-SyntheticGroup `
            -Name $Name `
            -Parameters $Config `
            -Repeats 3 `
            -MaxTokens 600

        $Records += [pscustomobject]@{
            Name = $Name
            Min = $Candidate.Min
            Max = $Candidate.Max
            Match = $Candidate.Match
            Group = $Group
            Config = $Config
        }
    }

    $Ranked = @(
        $Records |
        Sort-Object `
            @{Expression = { $_.Group.MedianDecode }; Descending = $true}
    )

    Write-Host ""
    Write-Host "NGRAM_SYNTHETIC_RANKING:"

    foreach ($Record in $Ranked) {
        Write-Host (
            "  " +
            $Record.Min +
            "/" +
            $Record.Max +
            "/" +
            $Record.Match +
            " median_decode=" +
            $Record.Group.MedianDecode.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            " tok/s"
        )
    }

    $Winner = $null

    foreach ($Record in $Ranked) {
        $LabelBase = (
            "ngram_" +
            $Record.Min +
            "_" +
            $Record.Max +
            "_" +
            $Record.Match
        )

        $CandidatePassed = $true
        $LastGate = $null

        for (
            $Attempt = 1;
            $Attempt -le 2;
            $Attempt++
        ) {
            $LastGate = Invoke-AgentGateMeasurement `
                -Parameters $Record.Config `
                -Label (
                    $LabelBase +
                    "_run" +
                    $Attempt
                )

            if (-not $LastGate.Pass) {
                $CandidatePassed = $false
                break
            }
        }

        if ($CandidatePassed) {
            $Winner = [pscustomobject]@{
                Record = $Record
                Gate = $LastGate
            }

            break
        }
    }

    if ($null -eq $Winner) {
        throw "NGRAM_NO_QUALITY_GATED_CANDIDATE"
    }

    Write-Host ""
    Write-Host (
        "NGRAM_QUALITY_GATED_WINNER=" +
        $Winner.Record.Min +
        "/" +
        $Winner.Record.Max +
        "/" +
        $Winner.Record.Match
    )

    return $Winner.Record.Config
}

function Get-PminStateMedian {
    param(
        [Parameter(Mandatory = $true)]
        [object]$State
    )

    if (
        -not $State.Eligible -or
        $State.Walls.Count -lt 1
    ) {
        return $null
    }

    return Get-BenchmarkMedian `
        -Values @($State.Walls)
}

function Invoke-AdaptivePminStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " STAGE 2 - P-MIN"
    Write-Host "========================================"
    Write-Host "RULE=2 synthetic runs for all candidates; 2 real-agent runs initially; adapt to 3 then up to 5 when ranking is noisy or contradictory"
    Write-Host "FAST_ACCEPT=synthetic and agent leaders agree, top gap >=15%, leader spread <=15%, runner spread <=25%"
    Write-Host "ESCALATE_TO_3=all eligible candidates when fast-accept conditions are not met"
    Write-Host "ESCALATE_TO_5=top 2 plus any candidate within 15% of best, plus eligible synthetic leader and current production value"
    Write-Host "FINAL_EQUIVALENCE_BAND=5%; prefer current production value when inside band"
    Write-Host "SELECTION_SCOPE=best p-min within tested candidate set"

    $PminCandidates = @(
        "0",
        "0.025",
        "0.05"
    )

    $Records = @()

    foreach ($PMin in $PminCandidates) {
        Assert-BenchmarkIdle

        $Config = Copy-BenchmarkParameters `
            -Parameters $Parameters

        $Config["spec-draft-p-min"] = $PMin

        $Group = Invoke-SyntheticGroup `
            -Name ("pmin_" + $PMin) `
            -Parameters $Config `
            -Repeats 2 `
            -MaxTokens 600

        $Records += [pscustomobject]@{
            PMin = $PMin
            Group = $Group
            Config = $Config
        }
    }

    $Ranked = @(
        $Records |
        Sort-Object `
            @{Expression = { $_.Group.MedianDecode }; Descending = $true}
    )

    Write-Host ""
    Write-Host "PMIN_SYNTHETIC_RANKING:"

    foreach ($Record in $Ranked) {
        Write-Host (
            "  p-min=" +
            $Record.PMin +
            " median_decode=" +
            $Record.Group.MedianDecode.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            " tok/s"
        )
    }

    $SyntheticLeaderPMin = [string]$Ranked[0].PMin

    $CurrentPMin = [string]$Parameters[
        "spec-draft-p-min"
    ]

    $States = [ordered]@{}

    foreach ($Record in $Ranked) {
        $States[$Record.PMin] = [pscustomobject]@{
            Record = $Record
            Eligible = $true
            Walls = New-Object `
                "System.Collections.Generic.List[double]"
        }
    }

    for (
        $Round = 1;
        $Round -le 2;
        $Round++
    ) {
        $RoundRecords = @($Ranked)

        if ($Round -eq 2) {
            [array]::Reverse($RoundRecords)
        }

        foreach ($Record in $RoundRecords) {
            $State = $States[$Record.PMin]

            if (-not $State.Eligible) {
                continue
            }

            $Gate = Invoke-AgentGateMeasurement `
                -Parameters $Record.Config `
                -Label (
                    "pmin_" +
                    $Record.PMin +
                    "_run" +
                    $Round
                )

            if (-not $Gate.Pass) {
                $State.Eligible = $false
                continue
            }

            [void]$State.Walls.Add(
                [double]$Gate.WallSeconds
            )
        }
    }

    $EligibleStates = @(
        $States.Values |
        Where-Object {
            $_.Eligible -and
            $_.Walls.Count -eq 2
        }
    )

    if ($EligibleStates.Count -lt 1) {
        throw "PMIN_NO_QUALITY_GATED_CANDIDATE"
    }

    $InitialRanked = @(
        $EligibleStates |
        Sort-Object `
            @{Expression = {
                Get-PminStateMedian -State $_
            }; Descending = $false}
    )

    $FastAccept = $false
    $EscalationReasons = @()

    if ($InitialRanked.Count -eq 1) {
        $FastAccept = $true
        Write-Host "PMIN_FAST_ACCEPT=YES_SINGLE_ELIGIBLE"
    }
    else {
        $BestState = $InitialRanked[0]
        $SecondState = $InitialRanked[1]

        $BestMedian = Get-PminStateMedian `
            -State $BestState

        $SecondMedian = Get-PminStateMedian `
            -State $SecondState

        $InitialGapPercent = (
            [Math]::Abs(
                $BestMedian -
                $SecondMedian
            ) /
            [Math]::Min(
                $BestMedian,
                $SecondMedian
            ) *
            100.0
        )

        $BestValues = @($BestState.Walls)
        $BestMin = (
            $BestValues |
            Measure-Object -Minimum
        ).Minimum
        $BestMax = (
            $BestValues |
            Measure-Object -Maximum
        ).Maximum

        $BestSpreadPercent = (
            (
                [double]$BestMax -
                [double]$BestMin
            ) /
            [double]$BestMin *
            100.0
        )

        $SecondValues = @($SecondState.Walls)
        $SecondMin = (
            $SecondValues |
            Measure-Object -Minimum
        ).Minimum
        $SecondMax = (
            $SecondValues |
            Measure-Object -Maximum
        ).Maximum

        $SecondSpreadPercent = (
            (
                [double]$SecondMax -
                [double]$SecondMin
            ) /
            [double]$SecondMin *
            100.0
        )

        Write-Host (
            "PMIN_INITIAL_AGENT_LEADER=" +
            $BestState.Record.PMin
        )

        Write-Host (
            "PMIN_INITIAL_AGENT_GAP_PERCENT=" +
            $InitialGapPercent.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )

        Write-Host (
            "PMIN_INITIAL_LEADER_SPREAD_PERCENT=" +
            $BestSpreadPercent.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )

        Write-Host (
            "PMIN_INITIAL_RUNNER_SPREAD_PERCENT=" +
            $SecondSpreadPercent.ToString(
                "F2",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        )

        if (
            $BestState.Record.PMin -ne
            $SyntheticLeaderPMin
        ) {
            $EscalationReasons += "SYNTHETIC_AGENT_LEADER_DISAGREE"
        }

        if ($InitialGapPercent -lt 15.0) {
            $EscalationReasons += "TOP_GAP_BELOW_15_PERCENT"
        }

        if ($BestSpreadPercent -gt 15.0) {
            $EscalationReasons += "LEADER_SPREAD_ABOVE_15_PERCENT"
        }

        if ($SecondSpreadPercent -gt 25.0) {
            $EscalationReasons += "RUNNER_SPREAD_ABOVE_25_PERCENT"
        }

        if ($EscalationReasons.Count -eq 0) {
            $FastAccept = $true
            Write-Host "PMIN_FAST_ACCEPT=YES"
        }
        else {
            Write-Host "PMIN_FAST_ACCEPT=NO"
            Write-Host (
                "PMIN_ESCALATION_REASON=" +
                ($EscalationReasons -join ",")
            )
        }
    }

    if (-not $FastAccept) {
        Write-Host "PMIN_ADAPTIVE_ESCALATE_TO_3=YES"

        foreach ($Record in $Ranked) {
            $State = $States[$Record.PMin]

            if (-not $State.Eligible) {
                continue
            }

            $Gate = Invoke-AgentGateMeasurement `
                -Parameters $Record.Config `
                -Label (
                    "pmin_" +
                    $Record.PMin +
                    "_run3"
                )

            if (-not $Gate.Pass) {
                $State.Eligible = $false
                continue
            }

            [void]$State.Walls.Add(
                [double]$Gate.WallSeconds
            )
        }

        $ThreeRunEligible = @(
            $States.Values |
            Where-Object {
                $_.Eligible -and
                $_.Walls.Count -eq 3
            }
        )

        if ($ThreeRunEligible.Count -lt 1) {
            throw "PMIN_NO_ELIGIBLE_AFTER_THIRD_RUN"
        }

        $RankedAfterThree = @(
            $ThreeRunEligible |
            Sort-Object `
                @{Expression = {
                    Get-PminStateMedian -State $_
                }; Descending = $false}
        )

        if ($RankedAfterThree.Count -gt 1) {
            $BestAfterThreeMedian = Get-PminStateMedian `
                -State $RankedAfterThree[0]

            $ContenderNames = @()

            foreach ($Index in 0, 1) {
                if ($Index -lt $RankedAfterThree.Count) {
                    $Name = [string]$RankedAfterThree[$Index].Record.PMin

                    if ($ContenderNames -notcontains $Name) {
                        $ContenderNames += $Name
                    }
                }
            }

            foreach ($State in $RankedAfterThree) {
                $Median = Get-PminStateMedian `
                    -State $State

                $GapFromBest = (
                    (
                        $Median -
                        $BestAfterThreeMedian
                    ) /
                    $BestAfterThreeMedian *
                    100.0
                )

                if ($GapFromBest -le 15.0) {
                    $Name = [string]$State.Record.PMin

                    if ($ContenderNames -notcontains $Name) {
                        $ContenderNames += $Name
                    }
                }
            }

            if (
                $States.Contains($SyntheticLeaderPMin) -and
                $States[$SyntheticLeaderPMin].Eligible
            ) {
                if (
                    $ContenderNames -notcontains
                    $SyntheticLeaderPMin
                ) {
                    $ContenderNames += $SyntheticLeaderPMin
                }
            }

            if (
                $States.Contains($CurrentPMin) -and
                $States[$CurrentPMin].Eligible
            ) {
                if (
                    $ContenderNames -notcontains
                    $CurrentPMin
                ) {
                    $ContenderNames += $CurrentPMin
                }
            }

            $ContenderStates = @(
                $RankedAfterThree |
                Where-Object {
                    $ContenderNames -contains
                    [string]$_.Record.PMin
                }
            )

            $ContenderText = (
                $ContenderStates |
                ForEach-Object {
                    [string]$_.Record.PMin
                }
            ) -join ","

            Write-Host (
                "PMIN_ADAPTIVE_ESCALATE_TO_5=" +
                $ContenderText
            )

            for (
                $Round = 4;
                $Round -le 5;
                $Round++
            ) {
                $RoundStates = @($ContenderStates)

                if ($Round -eq 5) {
                    [array]::Reverse($RoundStates)
                }

                foreach ($State in $RoundStates) {
                    if (-not $State.Eligible) {
                        continue
                    }

                    $Gate = Invoke-AgentGateMeasurement `
                        -Parameters $State.Record.Config `
                        -Label (
                            "pmin_" +
                            $State.Record.PMin +
                            "_run" +
                            $Round
                        )

                    if (-not $Gate.Pass) {
                        $State.Eligible = $false
                        continue
                    }

                    [void]$State.Walls.Add(
                        [double]$Gate.WallSeconds
                    )
                }
            }
        }
        else {
            Write-Host "PMIN_ADAPTIVE_ESCALATE_TO_5=NO_SINGLE_ELIGIBLE"
        }
    }
    else {
        Write-Host "PMIN_ADAPTIVE_ESCALATE_TO_3=NO"
        Write-Host "PMIN_ADAPTIVE_ESCALATE_TO_5=NO"
    }

    $FinalEligible = @(
        $States.Values |
        Where-Object {
            $_.Eligible -and
            $_.Walls.Count -ge 2
        }
    )

    if ($FinalEligible.Count -lt 1) {
        throw "PMIN_NO_FINAL_ELIGIBLE_CANDIDATE"
    }

    $FinalRanked = @(
        $FinalEligible |
        Sort-Object `
            @{Expression = {
                Get-PminStateMedian -State $_
            }; Descending = $false}
    )

    $BestFinalMedian = Get-PminStateMedian `
        -State $FinalRanked[0]

    $Equivalent = @(
        $FinalRanked |
        Where-Object {
            $Median = Get-PminStateMedian `
                -State $_

            (
                (
                    $Median -
                    $BestFinalMedian
                ) /
                $BestFinalMedian *
                100.0
            ) -le 5.0
        }
    )

    $Winner = $FinalRanked[0]
    $TiePolicyUsed = $false

    $CurrentEquivalent = @(
        $Equivalent |
        Where-Object {
            [string]$_.Record.PMin -eq
            $CurrentPMin
        }
    )

    if ($CurrentEquivalent.Count -gt 0) {
        $Winner = $CurrentEquivalent[0]
        $TiePolicyUsed = (
            $Winner.Record.PMin -ne
            $FinalRanked[0].Record.PMin
        )
    }

    Write-Host ""
    Write-Host "PMIN_AGENT_RESULTS:"

    foreach ($State in $States.Values) {
        $MedianText = "INELIGIBLE"
        $SpreadText = "UNAVAILABLE"

        if (
            $State.Eligible -and
            $State.Walls.Count -gt 0
        ) {
            $Median = Get-PminStateMedian `
                -State $State

            $MedianText = (
                $Median.ToString(
                    "F3",
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) +
                " s"
            )

            $Values = @($State.Walls)
            $MinWall = (
                $Values |
                Measure-Object -Minimum
            ).Minimum
            $MaxWall = (
                $Values |
                Measure-Object -Maximum
            ).Maximum

            $Spread = (
                (
                    [double]$MaxWall -
                    [double]$MinWall
                ) /
                [double]$MinWall *
                100.0
            )

            $SpreadText = (
                $Spread.ToString(
                    "F2",
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) +
                "%"
            )
        }

        Write-Host (
            "  p-min=" +
            $State.Record.PMin +
            " eligible=" +
            $State.Eligible +
            " runs=" +
            $State.Walls.Count +
            " median_wall=" +
            $MedianText +
            " spread=" +
            $SpreadText
        )
    }

    Write-Host (
        "PMIN_FINAL_FASTEST=" +
        $FinalRanked[0].Record.PMin
    )

    Write-Host (
        "PMIN_EQUIVALENCE_BAND_CANDIDATES=" +
        (
            (
                $Equivalent |
                ForEach-Object {
                    [string]$_.Record.PMin
                }
            ) -join ","
        )
    )

    if ($TiePolicyUsed) {
        Write-Host "PMIN_CURRENT_VALUE_PREFERENCE_USED=YES"
    }
    else {
        Write-Host "PMIN_CURRENT_VALUE_PREFERENCE_USED=NO"
    }

    Write-Host (
        "PMIN_QUALITY_GATED_WINNER=" +
        $Winner.Record.PMin
    )

    return $Winner.Record.Config
}
function Write-ContextResultHost {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $State = "UNSTABLE"

    if ($Result.Stable) {
        $State = "STABLE"
    }

    $Free = "UNAVAILABLE"

    if ($null -ne $Result.MinFreeMb) {
        $Free = [string]$Result.MinFreeMb
    }

    $Decode = "UNAVAILABLE"

    if ($null -ne $Result.DecodeTps) {
        $Decode = ([double]$Result.DecodeTps).ToString(
            "F2",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    }

    Write-Host (
        "  ctx=" +
        $Result.ContextSize +
        " cache=" +
        $Result.CacheK +
        "/" +
        $Result.CacheV +
        " state=" +
        $State +
        " free_mb=" +
        $Free +
        " decode_tps=" +
        $Decode +
        " reason=" +
        $Result.Reason
    )
}

function Get-AdaptiveContextMedian {
    param(
        [Parameter(Mandatory = $true)]
        [double[]]$Values
    )

    if ($Values.Count -lt 1) {
        throw "ADAPTIVE_CONTEXT_MEDIAN_EMPTY"
    }

    $Sorted = @(
        $Values |
        Sort-Object
    )

    $Middle = [int][Math]::Floor(
        $Sorted.Count / 2
    )

    if (($Sorted.Count % 2) -eq 1) {
        return [double]$Sorted[$Middle]
    }

    return (
        (
            [double]$Sorted[$Middle - 1] +
            [double]$Sorted[$Middle]
        ) /
        2.0
    )
}

function Resolve-AdaptiveContextCapacityResult {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Measurements,

        [Parameter(Mandatory = $true)]
        [int]$MinFreeVramMb
    )

    if (
        $Measurements.Count -ne 1 -and
        $Measurements.Count -ne 3
    ) {
        throw (
            "ADAPTIVE_CONTEXT_SAMPLE_COUNT_INVALID count=" +
            $Measurements.Count
        )
    }

    if ($Measurements.Count -eq 1) {
        return $Measurements[0]
    }

    $Template = $Measurements[0]
    $CapacityValid = $true
    $FailureReason = $null

    foreach ($Measurement in $Measurements) {
        $ReasonText = [string]$Measurement.Reason

        $ValidMeasurement = (
            $null -ne $Measurement.ReadyFreeMb -and
            (
                $Measurement.Stable -or
                $ReasonText.StartsWith(
                    "VRAM_FREE_BELOW_GATE"
                )
            )
        )

        if (-not $ValidMeasurement) {
            $CapacityValid = $false
            $FailureReason = (
                "ADAPTIVE_VRAM_RETEST_EXECUTION_FAIL reason=" +
                $ReasonText
            )
            break
        }
    }

    if (-not $CapacityValid) {
        return [pscustomobject]@{
            ContextSize = $Template.ContextSize
            CacheK = $Template.CacheK
            CacheV = $Template.CacheV
            Stable = $false
            Reason = $FailureReason
            ReadyFreeMb = $null
            PostFreeMb = $null
            MinFreeMb = $null
            DecodeTps = $null
            WallSeconds = $null
            AdaptiveVramSamples = 3
        }
    }

    $FreeValues = @(
        $Measurements |
        ForEach-Object {
            [double]$_.ReadyFreeMb
        }
    )

    $MedianFreeMb = Get-AdaptiveContextMedian `
        -Values $FreeValues

    $Stable = (
        $MedianFreeMb -ge
        [double]$MinFreeVramMb
    )

    $DecodeValues = @(
        $Measurements |
        Where-Object {
            $null -ne $_.DecodeTps
        } |
        ForEach-Object {
            [double]$_.DecodeTps
        }
    )

    $WallValues = @(
        $Measurements |
        Where-Object {
            $null -ne $_.WallSeconds
        } |
        ForEach-Object {
            [double]$_.WallSeconds
        }
    )

    $MedianDecode = $null
    $MedianWall = $null

    if ($DecodeValues.Count -gt 0) {
        $MedianDecode = Get-AdaptiveContextMedian `
            -Values $DecodeValues
    }

    if ($WallValues.Count -gt 0) {
        $MedianWall = Get-AdaptiveContextMedian `
            -Values $WallValues
    }

    if ($Stable) {
        if ($DecodeValues.Count -lt 2) {
            return [pscustomobject]@{
                ContextSize = $Template.ContextSize
                CacheK = $Template.CacheK
                CacheV = $Template.CacheV
                Stable = $false
                Reason = "ADAPTIVE_VRAM_MEDIAN_DECODE_METRICS_INSUFFICIENT"
                ReadyFreeMb = [int][Math]::Round($MedianFreeMb)
                PostFreeMb = $null
                MinFreeMb = [int][Math]::Round($MedianFreeMb)
                DecodeTps = $null
                WallSeconds = $MedianWall
                AdaptiveVramSamples = 3
            }
        }

        $Reason = (
            "PASS_ADAPTIVE_VRAM_MEDIAN samples=3 gate=" +
            $MinFreeVramMb
        )
    }
    else {
        $Reason = (
            "VRAM_FREE_BELOW_GATE_MEDIAN observed=" +
            [int][Math]::Round($MedianFreeMb) +
            " required=" +
            $MinFreeVramMb +
            " samples=3"
        )

        $MedianDecode = $null
    }

    return [pscustomobject]@{
        ContextSize = $Template.ContextSize
        CacheK = $Template.CacheK
        CacheV = $Template.CacheV
        Stable = $Stable
        Reason = $Reason
        ReadyFreeMb = [int][Math]::Round($MedianFreeMb)
        PostFreeMb = $null
        MinFreeMb = [int][Math]::Round($MedianFreeMb)
        DecodeTps = $MedianDecode
        WallSeconds = $MedianWall
        AdaptiveVramSamples = 3
    }
}

function Invoke-AdaptiveContextCapacityMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [int]$ContextSize,

        [Parameter(Mandatory = $true)]
        [string]$CacheK,

        [Parameter(Mandatory = $true)]
        [string]$CacheV,

        [int]$MaxTokens = 600,

        [int]$MinFreeVramMb = 512,

        [int]$NearGateMarginMb = 128
    )

    Assert-BenchmarkIdle

    $First = Invoke-ContextKvMeasurement `
        -Parameters $Parameters `
        -ContextSize $ContextSize `
        -CacheK $CacheK `
        -CacheV $CacheV `
        -MaxTokens $MaxTokens `
        -MinFreeVramMb $MinFreeVramMb

    $Measurements = @(
        $First
    )

    $ReasonText = [string]$First.Reason

    $CapacityValid = (
        $null -ne $First.ReadyFreeMb -and
        (
            $First.Stable -or
            $ReasonText.StartsWith(
                "VRAM_FREE_BELOW_GATE"
            )
        )
    )

    $NearGate = $false

    if ($CapacityValid) {
        $DistanceMb = [Math]::Abs(
            [double]$First.ReadyFreeMb -
            [double]$MinFreeVramMb
        )

        $NearGate = (
            $DistanceMb -le
            [double]$NearGateMarginMb
        )
    }

    if (-not $NearGate) {
        return $First
    }

    Write-Host (
        "CONTEXT_VRAM_NEAR_GATE_RETEST ctx=" +
        $ContextSize +
        " cache=" +
        $CacheK +
        "/" +
        $CacheV +
        " first_free_mb=" +
        $First.ReadyFreeMb +
        " margin_mb=" +
        $NearGateMarginMb +
        " total_samples=3"
    )

    for (
        $Attempt = 2;
        $Attempt -le 3;
        $Attempt++
    ) {
        Assert-BenchmarkIdle

        $Measurements += Invoke-ContextKvMeasurement `
            -Parameters $Parameters `
            -ContextSize $ContextSize `
            -CacheK $CacheK `
            -CacheV $CacheV `
            -MaxTokens $MaxTokens `
            -MinFreeVramMb $MinFreeVramMb
    }

    $Resolved = Resolve-AdaptiveContextCapacityResult `
        -Measurements $Measurements `
        -MinFreeVramMb $MinFreeVramMb

    Write-Host (
        "CONTEXT_VRAM_ADAPTIVE_RESULT ctx=" +
        $ContextSize +
        " cache=" +
        $CacheK +
        "/" +
        $CacheV +
        " median_free_mb=" +
        $Resolved.ReadyFreeMb +
        " stable=" +
        $Resolved.Stable
    )

    return $Resolved
}

function Invoke-AdaptiveContextStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " STAGE 3 - CONTEXT / KV"
    Write-Host "========================================"
    Write-Host "RULE=1 capacity run normally; if readiness VRAM is within +/-128 MB of the 512 MB gate, use 3-run median; q8/q8 candidate must pass 2/2 real-agent gates; fallback downward on failure"
    Write-Host "OPTIONAL_Q8Q5=capacity candidate only; same adaptive VRAM gate; never auto-applied"

    $QualityContexts = @(
        24576,
        32768,
        40960,
        49152
    )

    $ExtendedContexts = @(
        32768,
        40960,
        49152,
        57344,
        65536
    )

    $QualityResults = @()

    Write-Host ""
    Write-Host "Q8/Q8 CAPACITY RESULTS:"

    foreach ($ContextSize in $QualityContexts) {
        $Result = Invoke-AdaptiveContextCapacityMeasurement `
            -Parameters $Parameters `
            -ContextSize $ContextSize `
            -CacheK "q8_0" `
            -CacheV "q8_0" `
            -MaxTokens 600 `
            -MinFreeVramMb 512 `
            -NearGateMarginMb 128

        $QualityResults += $Result

        Write-ContextResultHost `
            -Result $Result
    }

    $StableQuality = @(
        $QualityResults |
        Where-Object {
            $_.Stable
        } |
        Sort-Object ContextSize -Descending
    )

    if ($StableQuality.Count -lt 1) {
        throw "CONTEXT_NO_STABLE_Q8Q8_CANDIDATE"
    }

    $QualityWinner = $null

    foreach ($Result in $StableQuality) {
        $Config = Copy-BenchmarkParameters `
            -Parameters $Parameters

        $Config["ctx-size"] = [string]$Result.ContextSize
        $Config["cache-type-k"] = "q8_0"
        $Config["cache-type-v"] = "q8_0"

        $CandidatePassed = $true
        $LastGate = $null

        for (
            $Attempt = 1;
            $Attempt -le 2;
            $Attempt++
        ) {
            $LastGate = Invoke-AgentGateMeasurement `
                -Parameters $Config `
                -Label (
                    "context_q8q8_" +
                    $Result.ContextSize +
                    "_run" +
                    $Attempt
                )

            if (-not $LastGate.Pass) {
                $CandidatePassed = $false
                break
            }
        }

        if ($CandidatePassed) {
            $QualityWinner = [pscustomobject]@{
                Result = $Result
                Config = $Config
                Gate = $LastGate
            }

            break
        }
    }

    if ($null -eq $QualityWinner) {
        throw "CONTEXT_NO_QUALITY_GATED_Q8Q8_CANDIDATE"
    }

    $ExtendedResults = @()

    Write-Host ""
    Write-Host "Q8/Q5 OPTIONAL CAPACITY RESULTS:"

    foreach ($ContextSize in $ExtendedContexts) {
        $Result = Invoke-AdaptiveContextCapacityMeasurement `
            -Parameters $Parameters `
            -ContextSize $ContextSize `
            -CacheK "q8_0" `
            -CacheV "q5_0" `
            -MaxTokens 600 `
            -MinFreeVramMb 512 `
            -NearGateMarginMb 128

        $ExtendedResults += $Result

        Write-ContextResultHost `
            -Result $Result
    }

    $Optional = @(
        $ExtendedResults |
        Where-Object {
            $_.Stable -and
            $_.ContextSize -gt
            $QualityWinner.Result.ContextSize
        } |
        Sort-Object ContextSize -Descending
    )

    $OptionalWinner = $null

    if ($Optional.Count -gt 0) {
        $OptionalWinner = $Optional[0]
    }

    Write-Host ""
    Write-Host (
        "CONTEXT_QUALITY_GATED_WINNER=" +
        $QualityWinner.Result.ContextSize +
        " q8_0/q8_0"
    )

    if ($null -eq $OptionalWinner) {
        Write-Host "OPTIONAL_MAX_CONTEXT_CAPACITY_CANDIDATE=NONE"
    }
    else {
        Write-Host (
            "OPTIONAL_MAX_CONTEXT_CAPACITY_CANDIDATE=" +
            $OptionalWinner.ContextSize +
            " q8_0/q5_0"
        )

        Write-Host "OPTIONAL_MAX_CONTEXT_QUALITY_GATE=NOT_RUN"
        Write-Host "OPTIONAL_MAX_CONTEXT_AUTO_APPLY=NO"
    }

    return [pscustomobject]@{
        Config = $QualityWinner.Config
        QualityResult = $QualityWinner.Result
        OptionalResult = $OptionalWinner
    }
}
function Set-SingleBenchmarkFlagValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    # Match the same prefix/value shape as Get-SingleFlagValue and
    # replace only the value token. Preserve whitespace, continuation
    # backticks, and newline formatting.
    $Pattern = (
        "(?mi)^([ \t]*--" +
        [regex]::Escape($Name) +
        "[ \t]+)([^ \t`r`n]+)"
    )

    $Matches = [regex]::Matches(
        $Text,
        $Pattern
    )

    if ($Matches.Count -ne 1) {
        throw (
            "APPLY_FLAG_COUNT_FAIL --" +
            $Name +
            " count=" +
            $Matches.Count
        )
    }

    $ValueGroup = $Matches[0].Groups[2]

    return (
        $Text.Substring(
            0,
            $ValueGroup.Index
        ) +
        $Value +
        $Text.Substring(
            $ValueGroup.Index +
            $ValueGroup.Length
        )
    )
}

function Test-PowerShellFileParse {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $Tokens = $null
    $Errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$Tokens,
        [ref]$Errors
    ) | Out-Null

    if ($Errors.Count -ne 0) {
        $Messages = (
            $Errors |
            ForEach-Object {
                $_.Message
            }
        ) -join " | "

        throw (
            "POWERSHELL_PARSE_FAIL path=" +
            $Path +
            " errors=" +
            $Messages
        )
    }
}

function Set-LocalBenchmarkConfigValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Literal
    )

    $Pattern = (
        "(?m)^([ \t]*\$" +
        [regex]::Escape($Name) +
        "[ \t]*=[ \t]*)([^\r\n]*)(\r?$)"
    )

    $Matches = [regex]::Matches($Text,$Pattern)

    if ($Matches.Count -gt 1) {
        throw (
            "LOCAL_CONFIG_VALUE_COUNT_FAIL $" +
            $Name +
            " count=" +
            $Matches.Count
        )
    }

    if ($Matches.Count -eq 1) {
        $ValueGroup = $Matches[0].Groups[2]

        return (
            $Text.Substring(0,$ValueGroup.Index) +
            $Literal +
            $Text.Substring($ValueGroup.Index + $ValueGroup.Length)
        )
    }

    $NewLine = [Environment]::NewLine
    if ($Text.Contains("`r`n")) {
        $NewLine = "`r`n"
    }
    elseif ($Text.Contains("`n")) {
        $NewLine = "`n"
    }

    return (
        $Text.TrimEnd([char[]]"`r`n") +
        $NewLine +
        $NewLine +
        "# Benchmark-tunable inference setting." +
        $NewLine +
        ("$" + $Name + " = " + $Literal) +
        $NewLine
    )
}

function ConvertTo-LocalBenchmarkLiteral {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    if (
        $Name -eq "CacheTypeK" -or
        $Name -eq "CacheTypeV" -or
        $Name -eq "SpecDraftPMin"
    ) {
        if ($Value.IndexOf('"') -ge 0) {
            throw ("UNSUPPORTED_LOCAL_CONFIG_QUOTE $" + $Name)
        }

        return ('"' + $Value + '"')
    }

    return $Value
}

function Set-ManagedProviderContextInSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$ContextWindowSize
    )

    $Settings = $Text | ConvertFrom-Json

    if (
        $null -eq $Settings.modelProviders -or
        $null -eq $Settings.modelProviders.openai
    ) {
        throw "SETTINGS_OPENAI_PROVIDERS_MISSING"
    }

    $Managed = @(
        $ModelAlias
        $AlgorithmModelAlias
        $TestModelAlias
    )

    foreach ($Alias in $Managed) {
        $Matches = @(
            $Settings.modelProviders.openai |
            Where-Object { $_.id -eq $Alias }
        )

        if ($Matches.Count -ne 1) {
            throw (
                "SETTINGS_PROVIDER_COUNT_FAIL alias=" +
                $Alias +
                " count=" +
                $Matches.Count
            )
        }

        if ($null -eq $Matches[0].generationConfig) {
            throw ("SETTINGS_GENERATION_CONFIG_MISSING alias=" + $Alias)
        }

        $Matches[0].generationConfig.contextWindowSize = $ContextWindowSize
    }

    return ($Settings | ConvertTo-Json -Depth 30)
}

function Test-ManagedProviderContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ContextWindowSize
    )

    $Settings = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json

    $Managed = @(
        $ModelAlias
        $AlgorithmModelAlias
        $TestModelAlias
    )

    foreach ($Alias in $Managed) {
        $Matches = @(
            $Settings.modelProviders.openai |
            Where-Object { $_.id -eq $Alias }
        )

        if ($Matches.Count -ne 1) {
            throw (
                "SETTINGS_PROVIDER_COUNT_FAIL alias=" +
                $Alias +
                " count=" +
                $Matches.Count
            )
        }

        if (
            [int]$Matches[0].generationConfig.contextWindowSize -ne
            $ContextWindowSize
        ) {
            throw (
                "SETTINGS_CONTEXT_MISMATCH alias=" +
                $Alias +
                " expected=" +
                $ContextWindowSize +
                " actual=" +
                $Matches[0].generationConfig.contextWindowSize
            )
        }
    }
}

function Invoke-TransactionalBenchmarkApply {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Recommended,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedLocalConfigSha,

        [Parameter(Mandatory = $true)]
        [string]$ExpectedSettingsSha
    )

    $CurrentLocalSha = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($CurrentLocalSha -ne $ExpectedLocalConfigSha) {
        throw (
            "LOCAL_CONFIG_CHANGED_DURING_BENCHMARK expected=" +
            $ExpectedLocalConfigSha +
            " actual=" +
            $CurrentLocalSha
        )
    }

    $CurrentSettingsSha = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($CurrentSettingsSha -ne $ExpectedSettingsSha) {
        throw (
            "SETTINGS_CHANGED_DURING_BENCHMARK expected=" +
            $ExpectedSettingsSha +
            " actual=" +
            $CurrentSettingsSha
        )
    }

    $OriginalLocalBytes = [System.IO.File]::ReadAllBytes($ConfigPath)
    $OriginalSettingsBytes = [System.IO.File]::ReadAllBytes($SettingsPath)
    $LocalText = [System.IO.File]::ReadAllText($ConfigPath)

    $Map = [ordered]@{
        "ctx-size" = "ContextWindowSize"
        "spec-draft-p-min" = "SpecDraftPMin"
        "spec-ngram-mod-n-min" = "SpecNgramModNMin"
        "spec-ngram-mod-n-max" = "SpecNgramModNMax"
        "spec-ngram-mod-n-match" = "SpecNgramModNMatch"
        "cache-type-k" = "CacheTypeK"
        "cache-type-v" = "CacheTypeV"
    }

    foreach ($FlagName in $Map.Keys) {
        if (-not $Recommended.Contains($FlagName)) {
            throw ("APPLY_RECOMMENDATION_MISSING --" + $FlagName)
        }

        $VariableName = [string]$Map[$FlagName]
        $Value = [string]$Recommended[$FlagName]
        $Literal = ConvertTo-LocalBenchmarkLiteral `
            -Name $VariableName `
            -Value $Value

        $LocalText = Set-LocalBenchmarkConfigValue `
            -Text $LocalText `
            -Name $VariableName `
            -Literal $Literal
    }

    $SettingsText = [System.IO.File]::ReadAllText($SettingsPath)
    $SettingsText = Set-ManagedProviderContextInSettings `
        -Text $SettingsText `
        -ContextWindowSize ([int]$Recommended["ctx-size"])

    $LocalHadBom = (
        $OriginalLocalBytes.Length -ge 3 -and
        $OriginalLocalBytes[0] -eq 0xEF -and
        $OriginalLocalBytes[1] -eq 0xBB -and
        $OriginalLocalBytes[2] -eq 0xBF
    )

    $SettingsHadBom = (
        $OriginalSettingsBytes.Length -ge 3 -and
        $OriginalSettingsBytes[0] -eq 0xEF -and
        $OriginalSettingsBytes[1] -eq 0xBB -and
        $OriginalSettingsBytes[2] -eq 0xBF
    )

    $LocalEncoding = New-Object System.Text.UTF8Encoding($LocalHadBom)
    $SettingsEncoding = New-Object System.Text.UTF8Encoding($SettingsHadBom)
    $Token = [Guid]::NewGuid().ToString("N")

    $LocalTemp = Join-Path `
        (Split-Path $ConfigPath -Parent) `
        (".local.apply." + $Token + ".tmp.ps1")

    $LocalRestore = Join-Path `
        (Split-Path $ConfigPath -Parent) `
        (".local.restore." + $Token + ".tmp.ps1")

    $SettingsTemp = Join-Path `
        (Split-Path $SettingsPath -Parent) `
        (".settings.apply." + $Token + ".tmp.json")

    $SettingsRestore = Join-Path `
        (Split-Path $SettingsPath -Parent) `
        (".settings.restore." + $Token + ".tmp.json")

    $LocalReplaced = $false
    $SettingsReplaced = $false

    try {
        [System.IO.File]::WriteAllText($LocalTemp,$LocalText,$LocalEncoding)
        [System.IO.File]::WriteAllText($SettingsTemp,$SettingsText,$SettingsEncoding)

        Test-PowerShellFileParse -Path $LocalTemp
        Test-ManagedProviderContext `
            -Path $SettingsTemp `
            -ContextWindowSize ([int]$Recommended["ctx-size"])

        [System.IO.File]::Replace($LocalTemp,$ConfigPath,$LocalRestore)
        $LocalReplaced = $true

        [System.IO.File]::Replace($SettingsTemp,$SettingsPath,$SettingsRestore)
        $SettingsReplaced = $true

        Test-PowerShellFileParse -Path $ConfigPath
        Test-ManagedProviderContext `
            -Path $SettingsPath `
            -ContextWindowSize ([int]$Recommended["ctx-size"])

        Write-Output (
            "APPLY_NEW_LOCAL_CONFIG_SHA256=" +
            (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
        )

        Write-Output (
            "APPLY_NEW_SETTINGS_SHA256=" +
            (Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash.ToUpperInvariant()
        )

        Write-Output "APPLY_RESULT=PASS"
    }
    catch {
        if ($SettingsReplaced) {
            [System.IO.File]::WriteAllBytes($SettingsPath,$OriginalSettingsBytes)
        }

        if ($LocalReplaced) {
            [System.IO.File]::WriteAllBytes($ConfigPath,$OriginalLocalBytes)
        }

        Write-Output "APPLY_BUNDLE_ROLLBACK=PASS"
        throw
    }
    finally {
        foreach ($Path in @(
            $LocalTemp,
            $LocalRestore,
            $SettingsTemp,
            $SettingsRestore
        )) {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item `
                    -LiteralPath $Path `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-FullAdaptiveBenchmark {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " FULL ADAPTIVE QWEN BENCHMARK"
    Write-Host "========================================"
    Write-Host "SCOPE=best recommended settings within tested candidate set"
    Write-Host "PRODUCTION_CONFIG_MODIFIED_BEFORE_APPROVAL=NO"
    Write-Host "REASONING_EFFORT=UNCHANGED_NOT_AUTOTUNED"
    Write-Host "THREADS_BATCH_UBATCH=UNCHANGED_ESTABLISHED_BASELINE"

    Assert-BenchmarkIdle

    $LocalConfigShaAtBegin = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAtBegin = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $CurrentAtBegin = [ordered]@{
        "ctx-size" = [string]$Parameters["ctx-size"]
        "spec-draft-p-min" = [string]$Parameters["spec-draft-p-min"]
        "spec-ngram-mod-n-min" = [string]$Parameters["spec-ngram-mod-n-min"]
        "spec-ngram-mod-n-max" = [string]$Parameters["spec-ngram-mod-n-max"]
        "spec-ngram-mod-n-match" = [string]$Parameters["spec-ngram-mod-n-match"]
        "cache-type-k" = [string]$Parameters["cache-type-k"]
        "cache-type-v" = [string]$Parameters["cache-type-v"]
    }

    $TotalTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $NgramConfig = Invoke-AdaptiveNgramStage -Parameters $Parameters
    Assert-BenchmarkIdle

    $PminConfig = Invoke-AdaptivePminStage -Parameters $NgramConfig
    Assert-BenchmarkIdle

    $ContextResult = Invoke-AdaptiveContextStage -Parameters $PminConfig
    Assert-BenchmarkIdle

    $RecommendedConfig = $ContextResult.Config

    $Recommended = [ordered]@{
        "ctx-size" = [string]$RecommendedConfig["ctx-size"]
        "spec-draft-p-min" = [string]$RecommendedConfig["spec-draft-p-min"]
        "spec-ngram-mod-n-min" = [string]$RecommendedConfig["spec-ngram-mod-n-min"]
        "spec-ngram-mod-n-max" = [string]$RecommendedConfig["spec-ngram-mod-n-max"]
        "spec-ngram-mod-n-match" = [string]$RecommendedConfig["spec-ngram-mod-n-match"]
        "cache-type-k" = [string]$RecommendedConfig["cache-type-k"]
        "cache-type-v" = [string]$RecommendedConfig["cache-type-v"]
    }

    $TotalTimer.Stop()

    Write-Host ""
    Write-Host "========================================"
    Write-Host " FINAL RECOMMENDATION"
    Write-Host "========================================"

    Write-Host (
        "RECOMMENDED_NGRAM=" +
        $Recommended["spec-ngram-mod-n-min"] +
        "/" +
        $Recommended["spec-ngram-mod-n-max"] +
        "/" +
        $Recommended["spec-ngram-mod-n-match"]
    )
    Write-Host ("RECOMMENDED_P_MIN=" + $Recommended["spec-draft-p-min"])
    Write-Host ("RECOMMENDED_CONTEXT=" + $Recommended["ctx-size"])
    Write-Host ("RECOMMENDED_CACHE_K=" + $Recommended["cache-type-k"])
    Write-Host ("RECOMMENDED_CACHE_V=" + $Recommended["cache-type-v"])
    Write-Host "RECOMMENDED_REASONING_EFFORT=UNCHANGED"
    Write-Host "RECOMMENDED_THREADS=UNCHANGED"
    Write-Host "RECOMMENDED_BATCH_SIZE=UNCHANGED"
    Write-Host "RECOMMENDED_UBATCH_SIZE=UNCHANGED"

    if ($null -eq $ContextResult.OptionalResult) {
        Write-Host "OPTIONAL_MAX_CONTEXT_CAPACITY_CANDIDATE=NONE"
    }
    else {
        Write-Host (
            "OPTIONAL_MAX_CONTEXT_CAPACITY_CANDIDATE=" +
            $ContextResult.OptionalResult.ContextSize +
            " q8_0/q5_0"
        )
        Write-Host "OPTIONAL_MAX_CONTEXT_STATUS=CAPACITY_ONLY_NOT_QUALITY_GATED_NOT_AUTO_APPLIED"
    }

    Write-Host (
        "BENCHMARK_TOTAL_WALL_SECONDS=" +
        $TotalTimer.Elapsed.TotalSeconds.ToString(
            "F1",
            [System.Globalization.CultureInfo]::InvariantCulture
        )
    )

    Write-Host "RECOMMENDATION_SCOPE=best quality-gated primary configuration within tested candidate set"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host ""
    Write-Host "CURRENT -> RECOMMENDED:"

    $Changed = @()

    foreach ($Name in $Recommended.Keys) {
        $CurrentValue = [string]$CurrentAtBegin[$Name]
        $NewValue = [string]$Recommended[$Name]

        Write-Host (
            "  --" +
            $Name +
            ": " +
            $CurrentValue +
            " -> " +
            $NewValue
        )

        if ($CurrentValue -ne $NewValue) {
            $Changed += $Name
        }
    }

    if ($Changed.Count -eq 0) {
        Write-Host ""
        Write-Host "APPLY_REQUIRED=NO_ALREADY_MATCHES"
        Write-Host "FULL_BENCHMARK=PASS"
        return
    }

    $LocalShaBeforePrompt = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($LocalShaBeforePrompt -ne $LocalConfigShaAtBegin) {
        throw "LOCAL_CONFIG_CHANGED_DURING_BENCHMARK"
    }

    $SettingsShaBeforePrompt = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($SettingsShaBeforePrompt -ne $SettingsShaAtBegin) {
        throw "SETTINGS_CHANGED_DURING_BENCHMARK"
    }

    Write-Host ""
    Write-Host ("APPLY_CANDIDATE_FLAGS=" + ($Changed -join ","))

    $Answer = Read-Host `
        "Apply the primary tested recommendation to config\local.ps1 and synchronize Qwen Code context metadata? [Y/N]"

    $NormalizedAnswer = $Answer.Trim().ToUpperInvariant()

    if (
        $NormalizedAnswer -ne "Y" -and
        $NormalizedAnswer -ne "YES"
    ) {
        Write-Host "APPLY_RESULT=DECLINED"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        Write-Host "FULL_BENCHMARK=PASS"
        return
    }

    Assert-BenchmarkIdle

    Invoke-TransactionalBenchmarkApply `
        -Recommended $Recommended `
        -ExpectedLocalConfigSha $LocalConfigShaAtBegin `
        -ExpectedSettingsSha $SettingsShaAtBegin

    Write-Host "FULL_BENCHMARK=PASS"
}

Write-Output "========================================"
Write-Output " QWEN UNIFIED BENCHMARK"
Write-Output " PREFLIGHT"
Write-Output "========================================"
Write-Output ("VERSION=" + $ScriptVersion)
Write-Output ("QWEN_ROOT=" + $QwenRoot)

$Failures = New-Object `
    "System.Collections.Generic.List[string]"

$RequiredFiles = [ordered]@{
    LOCAL_CONFIG  = $ConfigPath
    SETTINGS      = $SettingsPath
    START_SCRIPT  = $StartScript
    STOP_SCRIPT   = $StopScript
    SERVER_EXE    = $ServerExe
    MODEL         = $ModelPath
    QWEN_CODE_CLI = $QwenCodeCli
}

Write-Output ""
Write-Output "=== REQUIRED FILES ==="

foreach ($Entry in $RequiredFiles.GetEnumerator()) {
    $Exists = Test-Path `
        -LiteralPath $Entry.Value `
        -PathType Leaf

    $FileState = "MISSING"

    if ($Exists) {
        $FileState = "PASS"
    }

    Write-Output (
        $Entry.Key +
        "=" +
        $FileState
    )

    if (-not $Exists) {
        Add-Failure `
            -List $Failures `
            -Message (
                "Missing required file: " +
                $Entry.Value
            )
    }
}

if ($Failures.Count -gt 0) {
    Write-Output ""
    Write-Output "BENCHMARK_PREFLIGHT=FAIL"

    foreach ($Failure in $Failures) {
        Write-Output ("ERROR=" + $Failure)
    }

    exit 1
}

$StartText = [System.IO.File]::ReadAllText(
    $StartScript
)

$ParameterNames = @(
    "ctx-size",
    "parallel",
    "n-gpu-layers",
    "fit",
    "spec-type",
    "spec-draft-n-max",
    "spec-draft-p-min",
    "spec-ngram-mod-n-min",
    "spec-ngram-mod-n-max",
    "spec-ngram-mod-n-match",
    "threads",
    "threads-batch",
    "spec-draft-threads",
    "spec-draft-threads-batch",
    "flash-attn",
    "cache-type-k",
    "cache-type-v",
    "batch-size",
    "ubatch-size",
    "reasoning",
    "reasoning-effort",
    "reasoning-budget"
)

$TunableMap = [ordered]@{
    "ctx-size" = "ContextWindowSize"
    "spec-draft-p-min" = "SpecDraftPMin"
    "spec-ngram-mod-n-min" = "SpecNgramModNMin"
    "spec-ngram-mod-n-max" = "SpecNgramModNMax"
    "spec-ngram-mod-n-match" = "SpecNgramModNMatch"
    "cache-type-k" = "CacheTypeK"
    "cache-type-v" = "CacheTypeV"
}

$Parameters = [ordered]@{}

Write-Output ""
Write-Output "=== PRODUCTION PARAMETERS ==="

foreach ($Name in $ParameterNames) {
    try {
        if ($TunableMap.Contains($Name)) {
            $VariableName = [string]$TunableMap[$Name]
            $Variable = Get-Variable -Name $VariableName -ErrorAction Stop
            $Value = [string]$Variable.Value
        }
        else {
            $Value = Get-SingleFlagValue `
                -Text $StartText `
                -Name $Name
        }

        $Parameters[$Name] = $Value

        Write-Output (
            "--" +
            $Name +
            "=" +
            $Value
        )
    }
    catch {
        Add-Failure -List $Failures -Message $_.Exception.Message
    }
}

try {
    Test-ManagedProviderContext `
        -Path $SettingsPath `
        -ContextWindowSize ([int]$Parameters["ctx-size"])

    Write-Output "QWEN_CODE_CONTEXT_SYNC=PASS"
}
catch {
    Write-Output "QWEN_CODE_CONTEXT_SYNC=FAIL"
    Add-Failure -List $Failures -Message $_.Exception.Message
}

$RequiredSwitchOnly = @(
    "jinja",
    "reasoning-preserve"
)

foreach ($Name in $RequiredSwitchOnly) {
    $Count = Get-SwitchOnlyCount `
        -Text $StartText `
        -Name $Name

    Write-Output (
        "--" +
        $Name +
        "_COUNT=" +
        $Count
    )

    if ($Count -ne 1) {
        Add-Failure `
            -List $Failures `
            -Message (
                "Switch count invalid: --" +
                $Name +
                " count=" +
                $Count
            )
    }
}

Write-Output ""
Write-Output "=== EXPECTED BASELINE SHAPE ==="

$BaselineChecks = [ordered]@{
    PARALLEL_ONE = (
        $Parameters["parallel"] -eq "1"
    )

    GPU_99 = (
        $Parameters["n-gpu-layers"] -eq "99"
    )

    FIT_OFF = (
        $Parameters["fit"] -eq "off"
    )

    SPEC_MTP_NGRAM = (
        $Parameters["spec-type"] -eq
        "draft-mtp,ngram-mod"
    )

    MTP_DRAFT_N_MAX_2 = (
        $Parameters["spec-draft-n-max"] -eq "2"
    )

    FLASH_ATTN_ON = (
        $Parameters["flash-attn"] -eq "on"
    )

    REASONING_ON = (
        $Parameters["reasoning"] -eq "on"
    )
}

foreach ($Check in $BaselineChecks.GetEnumerator()) {
    $State = Get-PassFail `
        -Value ([bool]$Check.Value)

    Write-Output (
        $Check.Key +
        "=" +
        $State
    )

    if (-not $Check.Value) {
        Add-Failure `
            -List $Failures `
            -Message (
                "Baseline invariant failed: " +
                $Check.Key
            )
    }
}

Write-Output ""
Write-Output "=== CLIENT LEASES ==="

$ChatLease = Join-Path `
    $RuntimeClients `
    "chat.lock"

$ChatState = Get-LeaseState `
    -Path $ChatLease

Write-Output (
    "CHAT_LEASE=" +
    $ChatState
)

if ($ChatState -eq "ACTIVE") {
    Add-Failure `
        -List $Failures `
        -Message "Active chat client lease."
}

$CliDir = Join-Path `
    $RuntimeClients `
    "cli"

$CliLocks = @()

if (Test-Path -LiteralPath $CliDir) {
    $CliLocks = @(
        Get-ChildItem `
            -LiteralPath $CliDir `
            -Filter "*.lock" `
            -File `
            -ErrorAction SilentlyContinue
    )
}

$ActiveCli = 0
$UnownedCli = 0

foreach ($Lock in $CliLocks) {
    $State = Get-LeaseState `
        -Path $Lock.FullName

    if ($State -eq "ACTIVE") {
        $ActiveCli++
    }
    elseif ($State -eq "UNOWNED") {
        $UnownedCli++
    }
}

Write-Output (
    "CLI_LEASE_FILES=" +
    $CliLocks.Count
)

Write-Output (
    "CLI_LEASE_ACTIVE=" +
    $ActiveCli
)

Write-Output (
    "CLI_LEASE_UNOWNED=" +
    $UnownedCli
)

if ($ActiveCli -gt 0) {
    Add-Failure `
        -List $Failures `
        -Message (
            "Active CLI client leases: " +
            $ActiveCli
        )
}

Write-Output ""
Write-Output "=== SERVER STATE ==="

$PortActive = Test-PortListener `
    -Port $Port

$PortState = Get-ActiveFree `
    -Value $PortActive

Write-Output (
    "PORT_8080=" +
    $PortState
)

if ($PortActive) {
    Add-Failure `
        -List $Failures `
        -Message (
            "Port " +
            $Port +
            " already has an active listener."
        )
}

Write-Output ""
Write-Output "=== LLAMA.CPP CAPABILITY ==="

$HelpText = (
    & $ServerExe --help 2>&1 |
    Out-String
)

$RequiredServerOptions = @(
    "--model",
    "--alias",
    "--ctx-size",
    "--spec-type",
    "--spec-draft-n-max",
    "--spec-draft-p-min",
    "--spec-ngram-mod-n-min",
    "--spec-ngram-mod-n-max",
    "--spec-ngram-mod-n-match",
    "--cache-type-k",
    "--cache-type-v",
    "--batch-size",
    "--ubatch-size",
    "--reasoning-effort"
)

$MissingOptions = @()

foreach ($Option in $RequiredServerOptions) {
    if (
        $HelpText.IndexOf(
            $Option,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -lt 0
    ) {
        $MissingOptions += $Option
    }
}

if ($MissingOptions.Count -eq 0) {
    Write-Output "LLAMA_REQUIRED_OPTIONS=PASS"
}
else {
    Write-Output (
        "LLAMA_REQUIRED_OPTIONS=MISSING " +
        ($MissingOptions -join ",")
    )

    Add-Failure `
        -List $Failures `
        -Message (
            "llama-server missing required options: " +
            ($MissingOptions -join ", ")
        )
}

Write-Output ""
Write-Output "=== BENCHMARK PLAN ==="
Write-Output "NGRAM_CANDIDATES=48/64/24,32/64/16,48/64/16"
Write-Output "PMIN_CANDIDATES=0,0.025,0.05"
Write-Output "CONTEXT_Q8Q8=24576,32768,40960,49152"
Write-Output "EXTENDED_Q8Q5=32768,40960,49152,57344,65536"
Write-Output "VRAM_MIN_FREE_MB=512"
Write-Output "THREAD_BATCH_UBATCH=FIXED_ESTABLISHED_BASELINE"
Write-Output "APPLY_TARGET=config\local.ps1 + Qwen Code provider context metadata"
Write-Output "APPLY_MODE=WHITELISTED_TRANSACTIONAL_LOCAL_CONFIG_AND_CONTEXT_SYNC"
Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"

Write-Output ""

if ($Failures.Count -gt 0) {
    Write-Output "BENCHMARK_PREFLIGHT=FAIL"

    foreach ($Failure in $Failures) {
        Write-Output (
            "ERROR=" +
            $Failure
        )
    }

    exit 1
}

Write-Output "REQUIRED_FILES=PASS"
Write-Output "PRODUCTION_PARAMETER_PARSE=PASS"
Write-Output "BASELINE_INVARIANTS=PASS"
Write-Output "NO_ACTIVE_CLIENT_LEASES=PASS"
Write-Output "PORT_AVAILABLE=PASS"
Write-Output "LLAMA_CAPABILITY_CHECK=PASS"
Write-Output "PRODUCTION_CONFIG_MODIFIED=NO"
Write-Output "TEMP_FILES_CREATED=NO"
Write-Output "BENCHMARKS_EXECUTED_DURING_PREFLIGHT=NO"
Write-Output "BENCHMARK_PREFLIGHT=PASS"

if ($PreflightOnly) {
    exit 0
}

if ($SyntheticSmoke) {
    Invoke-SyntheticSmoke `
        -Parameters $Parameters
    exit 0
}

if ($SyntheticCandidates) {
    Invoke-SyntheticCandidateSweep `
        -Parameters $Parameters
    exit 0
}

if ($AgentSmoke) {
    Invoke-AgentSmoke `
        -Parameters $Parameters
    exit 0
}

if ($ContextKvSweep) {
    Invoke-ContextKvSweep `
        -Parameters $Parameters
    exit 0
}

Invoke-FullAdaptiveBenchmark `
    -Parameters $Parameters
