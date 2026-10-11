param(
    [switch]$PreflightOnly,
    [switch]$SyntheticSmoke,
    [switch]$SyntheticCandidates,
    [switch]$AgentSmoke,
    [switch]$ContextKvSweep,
    [switch]$ReasoningGrowthSelfTest,
    [switch]$ReasoningGrowthSmoke,
    [switch]$ReasoningGrowthTune,
    [switch]$AutoTune,
    [switch]$AdaptivePlannerSelfTest,
    [switch]$AgenticHarnessSelfTest,
    [switch]$AgenticAutoTune,
    [switch]$AgenticCandidateConfirmation,
    [switch]$ContextLifecycleCompactionStress,
    [switch]$ContextLifecycleOpenAiAudit,
    [switch]$ContextLifecycleRolloverStress,
    [switch]$OrchestrationEnduranceSelfTest,
    [switch]$OrchestrationEnduranceStress,
    [int]$ConfirmPromptReasoningBudget = 0,
    [int]$ConfirmAlgorithmReasoningBudget = 0,
    [int]$ConfirmTestReasoningBudget = 0,
    [int]$ConfirmGrowthBudget = 0,
    [ValidateRange(1,3)]
    [int]$ConfirmationRepeats = 2,
    [switch]$RecommendationOnly,
    [ValidateRange(1,12)]
    [int]$MaxAdaptiveStressSessions = 6,
    [ValidateRange(8,120)]
    [int]$StressMaxWallTimeMinutes = 48,
    [int]$SeedAlgorithmFailBudget = 0,
    [string]$SeedAlgorithmFailClass = "",
    [string]$PromptReasoningBudgetCandidates = "",
    [string]$AlgorithmReasoningBudgetCandidates = "",
    [string]$TestReasoningBudgetCandidates = "",
    [string]$GrowthBudgetCandidates = ""
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$ScriptVersion = "2.5.0-live-orchestration-endurance"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot ".localai\config\local.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath. Run the clone's root qwen.cmd to initialize .localai\config\local.ps1."
}

try {
. (Join-Path $RepoRoot "scripts\local_environment.ps1")

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
    $QwenUserRoot = Join-Path $QwenRoot ".localai\qwen"
}
elseif ([string]::IsNullOrWhiteSpace([string]$QwenUserRoot)) {
    $QwenUserRoot = Join-Path $QwenRoot ".localai\qwen"
}

$BenchmarkDefaults = [ordered]@{
    ContextWindowSize = 40960
    PromptReasoningBudgetTokens = 4608
    AlgorithmReasoningBudgetTokens = 6144
    TestReasoningBudgetTokens = 6144
    MaxContextGrowthTokensPerTurn = 24576
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

$ServerScript = Join-Path $QwenRoot "scripts\qwen_server.ps1"
$StartScript = $ServerScript
$StopScript = $ServerScript
$ModelsPreset = Join-Path $QwenRoot ".localai\config\qwen_models.ini"
$SettingsPath = Join-Path $QwenUserRoot "settings.json"
$ServerExe = $LlamaServerExe
$RuntimeClients = Join-Path $QwenUserRoot "runtime_clients"
$HostName = $ServerHost
$Port = [int]$ServerPort

$script:CollectOrchestrationEnduranceEvidence = $false
$script:OrchestrationEnduranceArtifactDirectory = $null
$script:OrchestrationTerminalTracePath = Join-Path `
    $QwenUserRoot `
    "orchestration\logs\terminal_completion_trace_v5_14.jsonl"
$script:OrchestrationHookErrorsPath = Join-Path `
    $QwenUserRoot `
    "orchestration\logs\hook_errors.log"

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

function Test-BenchmarkJoinPathAst {
    param($Command, [string]$Variable, [string]$Path)
    return ($Command -is [Management.Automation.Language.CommandAst] -and
        $Command.GetCommandName() -ceq 'Join-Path' -and $Command.InvocationOperator -eq 'Unknown' -and
        $Command.Redirections.Count -eq 0 -and $Command.CommandElements.Count -eq 3 -and
        $Command.CommandElements[1] -is [Management.Automation.Language.VariableExpressionAst] -and $Command.CommandElements[1].VariablePath.UserPath -ceq $Variable -and
        $Command.CommandElements[2] -is [Management.Automation.Language.StringConstantExpressionAst] -and $Command.CommandElements[2].Value -ceq $Path)
}

function Resolve-BenchmarkArgumentAst {
    param($Node, [hashtable]$Values)
    switch ($Node.GetType().Name) {
        'StringConstantExpressionAst' { return $Node.Value }
        'ConstantExpressionAst' { return [string]$Node.Value }
        'VariableExpressionAst' {
            $name = $Node.VariablePath.UserPath
            if (-not $Values.ContainsKey($name)) { throw "Unsupported server argument variable: $name" }
            return [string]$Values[$name]
        }
        'ConvertExpressionAst' {
            if ($Node.Type.TypeName.FullName -ine 'string') { throw 'Unsupported server argument conversion.' }
            return Resolve-BenchmarkArgumentAst $Node.Child $Values
        }
        'ParenExpressionAst' { return Resolve-BenchmarkArgumentAst $Node.Pipeline $Values }
        'ArrayExpressionAst' {
            if ($Node.SubExpression.Statements.Count -ne 1 -or $null -ne $Node.SubExpression.Traps) { throw 'Ambiguous server argument array.' }
            return Resolve-BenchmarkArgumentAst $Node.SubExpression.Statements[0] $Values
        }
        'ArrayLiteralAst' {
            foreach ($element in $Node.Elements) { Resolve-BenchmarkArgumentAst $element $Values }
            return
        }
        'PipelineAst' {
            if ($Node.PipelineElements.Count -ne 1) { throw 'Unsupported server argument pipeline.' }
            $element = $Node.PipelineElements[0]
            if ($element.Redirections.Count -ne 0) { throw 'Server argument redirection is unsupported.' }
            if ($element -is [Management.Automation.Language.CommandExpressionAst]) {
                return Resolve-BenchmarkArgumentAst $element.Expression $Values
            }
            if (Test-BenchmarkJoinPathAst $element 'QwenRoot' '.localai\config\qwen_models.ini') {
                return Join-Path $Values.QwenRoot '.localai\config\qwen_models.ini'
            }
            throw 'Unsupported server argument command.'
        }
        default { throw "Unsupported server argument syntax: $($Node.GetType().Name)" }
    }
}

function Get-BenchmarkServerOptions {
    param([string]$Text)
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errors)
    if ($errors.Count -ne 0) { throw 'Server launcher syntax is invalid.' }
    $builders = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-QwenServerArguments' }, $true))
    $launchers = @($ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-QwenServerStart' }, $true))
    if ($builders.Count -ne 1 -or $launchers.Count -ne 1) { throw 'Server argument builder/launcher is missing or ambiguous.' }
    $builder = $builders[0].Body
    $start = $launchers[0].Body
    $statements = @($start.EndBlock.Statements)
    if ($statements.Count -lt 2 -or
        ($statements[-2].Extent.Text -replace '\s', '') -cne '$ServerArguments=@(Get-QwenServerArguments)' -or
        ($statements[-1].Extent.Text -replace '\s', '') -cne '&$ServerExe@ServerArguments') {
        throw 'Server argument builder is not directly linked to the executable invocation.'
    }
    $references = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath.Split(':')[-1] -eq 'ServerArguments' }, $true))
    $builderCalls = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Get-QwenServerArguments' }, $true))
    $exeAssignments = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath.Split(':')[-1] -eq 'ServerExe' }, $true))
    if ($references.Count -ne 2 -or $builderCalls.Count -ne 1 -or $exeAssignments.Count -ne 1 -or
        ($exeAssignments[0].Extent.Text -replace '\s', '') -cne '$ServerExe=$LlamaServerExe') {
        throw 'Server executable/argument bindings are ambiguous or modified.'
    }
    $loaders = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.InvocationOperator -eq 'Dot' }, $true))
    $loaderCommand = if ($loaders.Count -eq 1 -and $loaders[0].CommandElements.Count -eq 1 -and
        $loaders[0].CommandElements[0] -is [Management.Automation.Language.ParenExpressionAst] -and $loaders[0].CommandElements[0].Pipeline.PipelineElements.Count -eq 1) { $loaders[0].CommandElements[0].Pipeline.PipelineElements[0] } else { $null }
    $roots = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath.Split(':')[-1] -eq 'RepoRoot' }, $true))
    $rootCommand = if ($roots.Count -eq 1 -and $roots[0].Right -is [Management.Automation.Language.PipelineAst] -and $roots[0].Right.PipelineElements.Count -eq 1) { $roots[0].Right.PipelineElements[0] } else { $null }
    if (-not (Test-BenchmarkJoinPathAst $loaderCommand 'RepoRoot' 'scripts\local_environment.ps1') -or
        $roots.Count -ne 1 -or $roots[0].Left.Extent.Text -cne '$RepoRoot' -or $roots[0].Operator -ne 'Equals' -or
        $rootCommand -isnot [Management.Automation.Language.CommandAst] -or $rootCommand.GetCommandName() -cne 'Split-Path' -or
        $rootCommand.InvocationOperator -ne 'Unknown' -or $rootCommand.Redirections.Count -ne 0 -or $rootCommand.CommandElements.Count -ne 3 -or
        $rootCommand.CommandElements[1] -isnot [Management.Automation.Language.VariableExpressionAst] -or $rootCommand.CommandElements[1].VariablePath.UserPath -cne 'PSScriptRoot' -or
        $rootCommand.CommandElements[2] -isnot [Management.Automation.Language.CommandParameterAst] -or $rootCommand.CommandElements[2].ParameterName -cne 'Parent' -or $null -ne $rootCommand.CommandElements[2].Argument) {
        throw 'Server launcher configuration is not linked to this clone.'
    }
    $values = @{}
    foreach ($name in @('QwenRoot','ServerHost','ServerPort','ContextWindowSize','SpecDraftPMin',
        'SpecNgramModNMin','SpecNgramModNMax','SpecNgramModNMatch','CacheTypeK','CacheTypeV')) {
        $value = Get-Variable -Name $name -ValueOnly -ErrorAction Stop
        if ($value -is [array]) { throw "Server configuration must be scalar: $name" }
        $values[$name] = $value
    }
    foreach ($assignment in @($start.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] }, $true))) {
        if ($assignment.Left -is [Management.Automation.Language.VariableExpressionAst] -and $values.ContainsKey($assignment.Left.VariablePath.UserPath.Split(':')[-1])) {
            throw 'Server launcher overrides configuration before constructing its arguments.'
        }
    }
    $setters = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-Variable' }, $true))
    if ($setters.Count -ne 1) { throw 'Server defaults assignment is missing or ambiguous.' }
    $defaultsLoop = $setters[0].Parent
    while ($null -ne $defaultsLoop -and $defaultsLoop -isnot [Management.Automation.Language.ForEachStatementAst]) { $defaultsLoop = $defaultsLoop.Parent }
    $expectedLoop = 'foreach($Entryin$BenchmarkDefaults.GetEnumerator()){if($null-eq(Get-Variable-Name$Entry.Key-ErrorActionSilentlyContinue)){Set-Variable-Name$Entry.Key-Value$Entry.Value}}'
    if ($null -eq $defaultsLoop -or ($defaultsLoop.Extent.Text -replace '\s', '') -cne $expectedLoop) {
        throw 'Server defaults must apply only to missing configuration variables.'
    }
    # Older configs must receive the same defaults in both callers.
    $defaults = @($start.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left -is [Management.Automation.Language.VariableExpressionAst] -and $n.Left.VariablePath.UserPath.Split(':')[-1] -eq 'BenchmarkDefaults' }, $true))
    if ($defaults.Count -ne 1 -or $defaults[0].Left.Extent.Text -cne '$BenchmarkDefaults' -or $defaults[0].Operator -ne 'Equals' -or
        $defaults[0].Right -isnot [Management.Automation.Language.CommandExpressionAst] -or $defaults[0].Right.Redirections.Count -ne 0 -or
        $defaults[0].Right.Expression -isnot [Management.Automation.Language.ConvertExpressionAst] -or $defaults[0].Right.Expression.Type.TypeName.FullName -cne 'ordered' -or
        $defaults[0].Right.Expression.Child -isnot [Management.Automation.Language.HashtableAst]) {
        throw 'Unsupported server fallback defaults structure.'
    }
    $expectedDefaults = [ordered]@{
        ContextWindowSize = '40960'; SpecDraftPMin = '0.025'; SpecNgramModNMin = '48'; SpecNgramModNMax = '64'
        SpecNgramModNMatch = '16'; CacheTypeK = 'q8_0'; CacheTypeV = 'q8_0'
    }
    $seenDefaults = @{}
    foreach ($pair in $defaults[0].Right.Expression.Child.KeyValuePairs) {
        if ($pair.Item1 -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
            $expectedDefaults.Keys -cnotcontains $pair.Item1.Value -or $seenDefaults.ContainsKey($pair.Item1.Value)) { throw 'Unknown or duplicate server fallback default.' }
        $name = $pair.Item1.Value
        $value = @(Resolve-BenchmarkArgumentAst $pair.Item2 @{})
        if ($value.Count -ne 1 -or $value[0] -cne $expectedDefaults[$name]) { throw "Server fallback default mismatch: $name" }
        $seenDefaults[$name] = $true
    }
    if ($seenDefaults.Count -ne $expectedDefaults.Count) { throw 'Required server fallback defaults are missing.' }
    foreach ($command in @($start.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true))) {
        if ($command.GetCommandName() -in @('Clear-Variable','Remove-Variable','Invoke-Expression')) {
            throw 'Unsupported dynamic server configuration mutation.'
        }
    }
    $body = @($builder.EndBlock.Statements)
    if ($null -ne $builder.BeginBlock -or $null -ne $builder.ProcessBlock -or $null -ne $builder.DynamicParamBlock -or
        ($builder.ParamBlock.Extent.Text -replace '\s', '') -cne 'param([switch]$Legacy)' -or $body.Count -ne 2 -or
        $body[0] -isnot [Management.Automation.Language.AssignmentStatementAst] -or $body[0].Operator -ne 'Equals' -or $body[0].Left.Extent.Text -cne '$modelArguments' -or
        $body[0].Right -isnot [Management.Automation.Language.IfStatementAst] -or $body[0].Right.Clauses.Count -ne 1 -or
        $body[0].Right.Clauses[0].Item1.Extent.Text.Trim() -cne '$Legacy' -or $body[0].Right.ElseClause.Statements.Count -ne 1 -or
        $body[1] -isnot [Management.Automation.Language.ReturnStatementAst]) {
        throw 'Unsupported server argument builder structure.'
    }
    $expression = $body[1].Pipeline.PipelineElements[0].Expression
    if ($body[1].Pipeline.PipelineElements.Count -ne 1 -or $expression -isnot [Management.Automation.Language.BinaryExpressionAst] -or
        $expression.Operator -ne 'Plus' -or $expression.Left.Extent.Text -cne '$modelArguments') {
        throw 'Unsupported server argument return expression.'
    }
    $arguments = @(Resolve-BenchmarkArgumentAst $body[0].Right.ElseClause.Statements[0] $values) +
        @(Resolve-BenchmarkArgumentAst $expression.Right $values)
    $expected = [ordered]@{
        'models-preset' = Join-Path $QwenRoot '.localai\config\qwen_models.ini'; 'models-max' = '1'; 'host' = [string]$ServerHost; 'port' = [string]$ServerPort
        'ctx-size' = [string]$ContextWindowSize; 'parallel' = '1'; 'n-gpu-layers' = '99'; 'fit' = 'off'
        'spec-type' = 'draft-mtp,ngram-mod'; 'spec-draft-n-max' = '2'; 'spec-draft-p-min' = [string]$SpecDraftPMin
        'spec-ngram-mod-n-min' = [string]$SpecNgramModNMin; 'spec-ngram-mod-n-max' = [string]$SpecNgramModNMax
        'spec-ngram-mod-n-match' = [string]$SpecNgramModNMatch
        'threads' = '20'; 'threads-batch' = '20'; 'spec-draft-threads' = '20'; 'spec-draft-threads-batch' = '20'
        'flash-attn' = 'on'; 'cache-type-k' = $CacheTypeK; 'cache-type-v' = $CacheTypeV
        'batch-size' = '1024'; 'ubatch-size' = '512'; 'jinja' = $null; 'reasoning' = 'on'
        'reasoning-effort' = 'xhigh'; 'reasoning-budget' = '-1'; 'reasoning-preserve' = $null
    }
    $options = [ordered]@{}
    for ($i = 0; $i -lt $arguments.Count; $i++) {
        $flag = [string]$arguments[$i]
        if (-not $flag.StartsWith('--')) { throw "Unexpected server argument: $flag" }
        $name = $flag.Substring(2)
        if ($expected.Keys -cnotcontains $name -or $options.Contains($name)) { throw "Unknown or duplicate server option: $flag" }
        if ($null -eq $expected[$name]) { $options[$name] = 1; continue }
        if (++$i -ge $arguments.Count) { throw "Missing server option value: $flag" }
        $value = [string]$arguments[$i]
        $comparison = if ($name -eq 'models-preset') { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if (-not $value.Equals([string]$expected[$name], $comparison)) { throw "Configured server option mismatch: $flag" }
        $options[$name] = $value
    }
    if ($options.Count -ne $expected.Count) { throw 'Required server options are missing.' }
    return $options
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

    Assert-LocalTree $TempRoot

    [void](
        New-Item `
            -ItemType Directory `
            -Path $TempRoot `
            -Force
    )

    try {
        $ArgumentLine = Get-BenchmarkServerArgumentLine `
            -Parameters $Parameters

        Assert-LocalPath $StdoutPath
        Assert-LocalPath $StderrPath
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
            Assert-LocalTree $TempRoot
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

    Assert-LocalTree $TempRoot

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

            Assert-LocalPath $StdoutPath
            Assert-LocalPath $StderrPath
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
            Assert-LocalTree $TempRoot
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

    Assert-LocalTree $Path
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
    Assert-LocalPath (Join-Path $Path "cache.py")
    [System.IO.File]::WriteAllText((Join-Path $Path "cache.py"), $CacheSource, $Utf8NoBom)
    Assert-LocalPath (Join-Path $Path "test_cache.py")
    [System.IO.File]::WriteAllText((Join-Path $Path "test_cache.py"), $TestSource, $Utf8NoBom)

    $QwenDir = Join-Path $Path ".qwen"
    Assert-LocalTree $QwenDir
    [void](New-Item -ItemType Directory -Path $QwenDir -Force)
    $Settings = [ordered]@{
        model = [ordered]@{
            reasoningEffort = $ReasoningEffort
        }
    }
    $SettingsJson = ConvertTo-Json -InputObject $Settings -Depth 5
    Assert-LocalPath (Join-Path $QwenDir "settings.json")
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
            Assert-LocalPath $StdoutPath
            Assert-LocalPath $StderrPath
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
            Assert-LocalTree $TempRoot
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


function Get-BenchmarkRouterArgumentLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $Direct = Get-BenchmarkServerArgumentLine `
        -Parameters $Parameters `
        -ModelAlias ([string]$ModelAlias)

    $ModelToken = ConvertTo-BenchmarkArgument `
        -Value ([string]$ModelPath)

    $AliasToken = ConvertTo-BenchmarkArgument `
        -Value ([string]$ModelAlias)

    $DirectPrefix = (
        "--model " +
        $ModelToken +
        " --alias " +
        $AliasToken
    )

    if (-not $Direct.StartsWith(
        $DirectPrefix,
        [System.StringComparison]::Ordinal
    )) {
        throw "BENCHMARK_ROUTER_ARGUMENT_PREFIX_MISMATCH"
    }

    $PresetToken = ConvertTo-BenchmarkArgument `
        -Value ([string]$ModelsPreset)

    return (
        "--models-preset " +
        $PresetToken +
        " --models-max 1" +
        $Direct.Substring($DirectPrefix.Length)
    )
}

function Wait-BenchmarkRouterReady {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    $RequiredAliases = @(
        [string]$ModelAlias,
        [string]$AlgorithmModelAlias,
        [string]$TestModelAlias
    )

    $Deadline = [DateTime]::UtcNow.AddSeconds(120)
    $LastIds = @()
    $LastAliases = @()

    while ([DateTime]::UtcNow -lt $Deadline) {
        $Process.Refresh()

        if ($Process.HasExited) {
            throw (
                "BENCHMARK_ROUTER_EXITED_EARLY code=" +
                $Process.ExitCode
            )
        }

        try {
            $Response = Invoke-BenchmarkGetModels
            $Data = @($Response.data)
            $LastIds = @(
                $Data |
                ForEach-Object { [string]$_.id }
            )

            $Canonical = @(
                $Data |
                Where-Object {
                    $null -ne $_.id -and
                    [string]$_.id -eq [string]$ChatModelAlias
                }
            )

            if ($Canonical.Count -eq 1) {
                $LastAliases = @(
                    @($Canonical[0].aliases) |
                    ForEach-Object { [string]$_ } |
                    Select-Object -Unique
                )

                $MissingAliases = @(
                    $RequiredAliases |
                    Where-Object { $LastAliases -notcontains $_ }
                )

                if ($MissingAliases.Count -eq 0) {
                    Write-Host (
                        "BENCHMARK_ROUTER_READY=PASS canonical=" +
                        $ChatModelAlias +
                        " aliases=" +
                        ($LastAliases -join ",")
                    )
                    return
                }
            }
        }
        catch {
        }

        Start-Sleep -Milliseconds 500
    }

    throw (
        "BENCHMARK_ROUTER_READY_TIMEOUT canonical=" +
        $ChatModelAlias +
        " observed_ids=" +
        ($LastIds -join ",") +
        " observed_aliases=" +
        ($LastAliases -join ",")
    )
}

function Stop-BenchmarkRouterProcess {
    param(
        [System.Diagnostics.Process]$Process
    )

    if ($null -eq $Process) {
        return
    }

    try {
        $Process.Refresh()

        if (-not $Process.HasExited) {
            & taskkill.exe `
                /PID $Process.Id `
                /T `
                /F `
                *> $null
        }
    }
    catch {
    }

    $Deadline = [DateTime]::UtcNow.AddSeconds(15)

    while (
        (Test-PortListener -Port $Port) -and
        [DateTime]::UtcNow -lt $Deadline
    ) {
        Start-Sleep -Milliseconds 250
    }

    if (Test-PortListener -Port $Port) {
        throw "BENCHMARK_ROUTER_PORT_CLEANUP=FAIL"
    }
}

function Round-BenchmarkIntegerCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [double]$Value,

        [Parameter(Mandatory = $true)]
        [int]$Quantum,

        [Parameter(Mandatory = $true)]
        [int]$Minimum,

        [Parameter(Mandatory = $true)]
        [int]$Maximum
    )

    if ($Quantum -le 0) {
        throw "CANDIDATE_QUANTUM_INVALID"
    }

    $Rounded = [int](
        [Math]::Round(
            $Value / [double]$Quantum,
            0,
            [MidpointRounding]::AwayFromZero
        ) * $Quantum
    )

    if ($Rounded -lt $Minimum) {
        $Rounded = $Minimum
    }

    if ($Rounded -gt $Maximum) {
        $Rounded = $Maximum
    }

    return $Rounded
}

function ConvertFrom-BenchmarkCandidateList {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$Minimum,

        [Parameter(Mandatory = $true)]
        [int]$Maximum
    )

    $Values = New-Object "System.Collections.Generic.List[int]"
    [void]$Values.Add($Current)

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($Piece in ($Text -split "[,;]")) {
            $Trimmed = $Piece.Trim()

            if ($Trimmed.Length -eq 0) {
                continue
            }

            $Parsed = 0

            if (-not [int]::TryParse($Trimmed,[ref]$Parsed)) {
                throw (
                    "INVALID_INTEGER_CANDIDATE value=" +
                    $Trimmed
                )
            }

            if (
                $Parsed -lt $Minimum -or
                $Parsed -gt $Maximum
            ) {
                throw (
                    "INTEGER_CANDIDATE_OUT_OF_RANGE value=" +
                    $Parsed +
                    " min=" +
                    $Minimum +
                    " max=" +
                    $Maximum
                )
            }

            [void]$Values.Add($Parsed)
        }
    }

    return @(
        $Values |
        Sort-Object -Unique
    )
}

function Get-ReasoningBudgetCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$ContextWindowSize,

        [AllowEmptyString()]
        [string]$ExplicitCandidates = ""
    )

    $Minimum = 1024
    $ReservedMargin = [int][Math]::Ceiling(
        $ContextWindowSize * 0.05
    )
    $Maximum = [Math]::Max(
        $Minimum,
        $ContextWindowSize - $ReservedMargin
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitCandidates)) {
        return @(
            ConvertFrom-BenchmarkCandidateList `
                -Text $ExplicitCandidates `
                -Current $Current `
                -Minimum $Minimum `
                -Maximum $Maximum
        )
    }

    $Lower = Round-BenchmarkIntegerCandidate `
        -Value ($Current * 0.75) `
        -Quantum 512 `
        -Minimum $Minimum `
        -Maximum $Maximum

    $Upper = Round-BenchmarkIntegerCandidate `
        -Value ($Current * 1.25) `
        -Quantum 512 `
        -Minimum $Minimum `
        -Maximum $Maximum

    return @(
        @($Lower,$Current,$Upper) |
        Sort-Object -Unique
    )
}

function Get-GrowthBudgetCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [AllowEmptyString()]
        [string]$ExplicitCandidates = ""
    )

    $Minimum = 4096
    $Maximum = [int]::MaxValue

    if (-not [string]::IsNullOrWhiteSpace($ExplicitCandidates)) {
        return @(
            ConvertFrom-BenchmarkCandidateList `
                -Text $ExplicitCandidates `
                -Current $Current `
                -Minimum $Minimum `
                -Maximum $Maximum
        )
    }

    $Lower = Round-BenchmarkIntegerCandidate `
        -Value ($Current * (2.0 / 3.0)) `
        -Quantum 1024 `
        -Minimum $Minimum `
        -Maximum $Maximum

    $Upper = Round-BenchmarkIntegerCandidate `
        -Value ($Current * (4.0 / 3.0)) `
        -Quantum 1024 `
        -Minimum $Minimum `
        -Maximum $Maximum

    return @(
        @($Lower,$Current,$Upper) |
        Sort-Object -Unique
    )
}

function Get-QwenJsonlSnapshot {
    $Result = @{}
    $ProjectsRoot = Join-Path $QwenUserRoot "projects"

    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
        return $Result
    }

    foreach ($File in @(
        Get-ChildItem `
            -LiteralPath $ProjectsRoot `
            -Filter "*.jsonl" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    )) {
        $Result[$File.FullName] = [long]$File.LastWriteTimeUtc.Ticks
    }

    return $Result
}

function Get-QwenProjectDirectorySnapshot {
    $Result = @{}
    $ProjectsRoot = Join-Path $QwenUserRoot "projects"

    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
        return $Result
    }

    foreach ($Directory in @(
        Get-ChildItem `
            -LiteralPath $ProjectsRoot `
            -Directory `
            -ErrorAction SilentlyContinue
    )) {
        $Result[$Directory.FullName] = $true
    }

    return $Result
}

function Get-ChangedQwenJsonlFiles {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Before
    )

    $ProjectsRoot = Join-Path $QwenUserRoot "projects"

    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
        return @()
    }

    $Changed = @()

    foreach ($File in @(
        Get-ChildItem `
            -LiteralPath $ProjectsRoot `
            -Filter "*.jsonl" `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue
    )) {
        if (-not $Before.ContainsKey($File.FullName)) {
            $Changed += $File
            continue
        }

        if (
            [long]$File.LastWriteTimeUtc.Ticks -gt
            [long]$Before[$File.FullName]
        ) {
            $Changed += $File
        }
    }

    return @($Changed)
}

function Remove-NewQwenProjectDirectories {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Before
    )

    $ProjectsRoot = Join-Path $QwenUserRoot "projects"

    if (-not (Test-Path -LiteralPath $ProjectsRoot -PathType Container)) {
        return
    }

    foreach ($Directory in @(
        Get-ChildItem `
            -LiteralPath $ProjectsRoot `
            -Directory `
            -ErrorAction SilentlyContinue
    )) {
        if (-not $Before.ContainsKey($Directory.FullName)) {
            Assert-LocalTree $Directory.FullName
            Remove-Item `
                -LiteralPath $Directory.FullName `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-ObjectPropertyValue {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    $Property = $Object.PSObject.Properties[$Name]

    if ($null -eq $Property) {
        return $null
    }

    return $Property.Value
}


function ConvertTo-BenchmarkTimestamp {
    param(
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [datetimeoffset]::Parse(
            [string]$Value,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch {
        return $null
    }
}

function New-EmptyOrchestrationEnduranceSummary {
    return [pscustomobject]@{
        MainSessionId = ""
        ChatCompressionCount = 0
        CompressionContinuationGapCount = 0
        GrowthLimitResultCount = 0
        RecoveryAuthoritativeStateCount = 0
        RecoveryGuardRejectionCount = 0
        RecoveryRereadCycleCount = 0
        SuccessfulAlgorithmAfterGrowthCount = 0
        AlgorithmResultCount = 0
        TestAgentResultCount = 0
        TestAfterLastAlgorithm = $false
        TopLevelFinalCount = 0
        TopLevelFinalAfterLastTool = $false
        TerminalTraceFound = $false
        TerminalTraceEventCount = 0
        TerminalStopCount = 0
        LastPreAgentGuardActive = $null
        LastPreAgentRecoveryRequired = $null
        TurnClosedAtStop = $null
        TerminalAbortObserved = $false
        HookErrorCount = 0
        RuntimeFatalErrorCount = 0
    }
}

function Get-OrchestrationEnduranceSummary {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Files,

        [string]$QwenOutput = "",

        [string]$ServerStdoutPath = "",

        [string]$ServerStderrPath = "",

        [string]$TerminalTracePath = "",

        [string]$HookErrorsPath = ""
    )

    $MainSessionId = ""
    $CompressionEvents = @()
    $ApiEvents = @()
    $GrowthEvents = @()
    $RootReadEvents = @()
    $AlgorithmCallEvents = @()
    $AlgorithmResultEvents = @()
    $TestResultEvents = @()
    $RootAssistantEvents = @()
    $ToolishEvents = @()

    $RecoveryAuthoritativeStateCount = 0
    $RecoveryGuardRejectionCount = 0

    foreach ($File in $Files) {
        foreach ($Line in Get-Content -LiteralPath $File.FullName) {
            $Raw = [string]$Line

            try {
                $Object = $Raw | ConvertFrom-Json
            }
            catch {
                continue
            }

            $Timestamp = ConvertTo-BenchmarkTimestamp `
                -Value (Get-ObjectPropertyValue -Object $Object -Name "timestamp")

            $SessionId = [string](
                Get-ObjectPropertyValue `
                    -Object $Object `
                    -Name "sessionId"
            )

            $Type = [string](
                Get-ObjectPropertyValue `
                    -Object $Object `
                    -Name "type"
            )

            $Provenance = [string](
                Get-ObjectPropertyValue `
                    -Object $Object `
                    -Name "provenance"
            )

            $Subtype = [string](
                Get-ObjectPropertyValue `
                    -Object $Object `
                    -Name "subtype"
            )

            if ($Subtype -eq "chat_compression") {
                $CompressionEvents += [pscustomobject]@{
                    SessionId = $SessionId
                    Timestamp = $Timestamp
                }
            }

            if ($Type -eq "tool_result") {
                $ToolishEvents += [pscustomobject]@{
                    SessionId = $SessionId
                    Timestamp = $Timestamp
                }

                if (
                    $Raw.IndexOf(
                        "AUTHORITATIVE_GROWTH_RECOVERY_STATE=",
                        [System.StringComparison]::Ordinal
                    ) -ge 0
                ) {
                    $RecoveryAuthoritativeStateCount++
                    $RecoveryGuardRejectionCount++
                }

                $ToolCallResult = Get-ObjectPropertyValue `
                    -Object $Object `
                    -Name "toolCallResult"

                $ResultDisplay = Get-ObjectPropertyValue `
                    -Object $ToolCallResult `
                    -Name "resultDisplay"

                $SubagentName = [string](
                    Get-ObjectPropertyValue `
                        -Object $ResultDisplay `
                        -Name "subagentName"
                )

                $TerminateReason = [string](
                    Get-ObjectPropertyValue `
                        -Object $ResultDisplay `
                        -Name "terminateReason"
                )

                if ($SubagentName -eq "algorithm-agent") {
                    $AlgorithmResultEvents += [pscustomobject]@{
                        SessionId = $SessionId
                        Timestamp = $Timestamp
                        TerminateReason = $TerminateReason
                    }
                }
                elseif ($SubagentName -eq "test-agent") {
                    $TestResultEvents += [pscustomobject]@{
                        SessionId = $SessionId
                        Timestamp = $Timestamp
                        TerminateReason = $TerminateReason
                    }
                }

                if (
                    $TerminateReason -eq "GROWTH_LIMIT" -or
                    $Raw.IndexOf(
                        "per-turn context growth limit reached",
                        [System.StringComparison]::OrdinalIgnoreCase
                    ) -ge 0
                ) {
                    $GrowthEvents += [pscustomobject]@{
                        SessionId = $SessionId
                        Timestamp = $Timestamp
                    }
                }
            }

            if (
                $Type -eq "assistant" -and
                $Provenance -eq "assistant_output"
            ) {
                $Model = [string](
                    Get-ObjectPropertyValue `
                        -Object $Object `
                        -Name "model"
                )

                if (
                    $Model -notlike "*algorithm*" -and
                    $Model -notlike "*test*"
                ) {
                    $RootAssistantEvents += [pscustomobject]@{
                        SessionId = $SessionId
                        Timestamp = $Timestamp
                    }
                }
            }

            if ($Type -ne "system") {
                continue
            }

            $Payload = Get-ObjectPropertyValue `
                -Object $Object `
                -Name "systemPayload"

            $Event = Get-ObjectPropertyValue `
                -Object $Payload `
                -Name "uiEvent"

            if ($null -eq $Event) {
                continue
            }

            $EventName = [string](
                Get-ObjectPropertyValue `
                    -Object $Event `
                    -Name "event.name"
            )

            $PromptId = [string](
                Get-ObjectPropertyValue `
                    -Object $Event `
                    -Name "prompt_id"
            )

            $EventTimestamp = ConvertTo-BenchmarkTimestamp `
                -Value (
                    Get-ObjectPropertyValue `
                        -Object $Event `
                        -Name "event.timestamp"
                )

            if ($null -eq $EventTimestamp) {
                $EventTimestamp = $Timestamp
            }

            if (
                [string]::IsNullOrWhiteSpace($MainSessionId) -and
                $EventName -eq "qwen-code.api_response" -and
                $PromptId -like "*########0"
            ) {
                $MainSessionId = $SessionId
            }

            if ($EventName -eq "qwen-code.api_response") {
                $ApiEvents += [pscustomobject]@{
                    SessionId = $SessionId
                    Timestamp = $EventTimestamp
                    PromptId = $PromptId
                }
                continue
            }

            if ($EventName -ne "qwen-code.tool_call") {
                continue
            }

            $ToolishEvents += [pscustomobject]@{
                SessionId = $SessionId
                Timestamp = $EventTimestamp
            }

            $FunctionName = [string](
                Get-ObjectPropertyValue `
                    -Object $Event `
                    -Name "function_name"
            )

            $FunctionArgs = Get-ObjectPropertyValue `
                -Object $Event `
                -Name "function_args"

            if (
                $FunctionName -eq "read_file" -and
                $PromptId -like "*########0"
            ) {
                $RootReadEvents += [pscustomobject]@{
                    SessionId = $SessionId
                    Timestamp = $EventTimestamp
                }
            }

            if ($FunctionName -ne "agent") {
                continue
            }

            $SubagentType = [string](
                Get-ObjectPropertyValue `
                    -Object $FunctionArgs `
                    -Name "subagent_type"
            )

            if ($SubagentType -eq "algorithm-agent") {
                $AlgorithmCallEvents += [pscustomobject]@{
                    SessionId = $SessionId
                    Timestamp = $EventTimestamp
                }
            }
        }
    }

    if (
        [string]::IsNullOrWhiteSpace($MainSessionId) -and
        $RootAssistantEvents.Count -gt 0
    ) {
        $MainSessionId = [string]$RootAssistantEvents[-1].SessionId
    }

    if ([string]::IsNullOrWhiteSpace($MainSessionId)) {
        $Empty = New-EmptyOrchestrationEnduranceSummary
        return $Empty
    }

    $MainCompressionEvents = @(
        $CompressionEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainApiEvents = @(
        $ApiEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainGrowthEvents = @(
        $GrowthEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainRootReads = @(
        $RootReadEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainAlgorithmCalls = @(
        $AlgorithmCallEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainAlgorithmResults = @(
        $AlgorithmResultEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainTestResults = @(
        $TestResultEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainAssistantEvents = @(
        $RootAssistantEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $MainToolishEvents = @(
        $ToolishEvents |
        Where-Object { $_.SessionId -eq $MainSessionId }
    )

    $CompressionContinuationGapCount = 0

    foreach ($Compression in $MainCompressionEvents) {
        $LaterApi = @(
            $MainApiEvents |
            Where-Object {
                $null -ne $_.Timestamp -and
                $null -ne $Compression.Timestamp -and
                $_.Timestamp -gt $Compression.Timestamp
            }
        )

        if ($LaterApi.Count -eq 0) {
            $CompressionContinuationGapCount++
        }
    }

    $RecoveryRereadCycleCount = 0

    foreach ($Growth in $MainGrowthEvents) {
        $NextAlgorithm = @(
            $MainAlgorithmCalls |
            Where-Object {
                $null -ne $_.Timestamp -and
                $null -ne $Growth.Timestamp -and
                $_.Timestamp -gt $Growth.Timestamp
            } |
            Sort-Object Timestamp |
            Select-Object -First 1
        )

        $UpperBound = $null

        if ($NextAlgorithm.Count -gt 0) {
            $UpperBound = $NextAlgorithm[0].Timestamp
        }

        $Reads = @(
            $MainRootReads |
            Where-Object {
                if (
                    $null -eq $_.Timestamp -or
                    $null -eq $Growth.Timestamp
                ) {
                    return $false
                }

                if ($_.Timestamp -le $Growth.Timestamp) {
                    return $false
                }

                if (
                    $null -ne $UpperBound -and
                    $_.Timestamp -ge $UpperBound
                ) {
                    return $false
                }

                return $true
            }
        )

        if ($Reads.Count -gt 0) {
            $RecoveryRereadCycleCount++
        }
    }

    $SuccessfulAlgorithmAfterGrowthCount = 0

    if ($MainGrowthEvents.Count -gt 0) {
        $FirstGrowthTimestamp = (
            $MainGrowthEvents |
            Sort-Object Timestamp |
            Select-Object -First 1
        ).Timestamp

        $SuccessfulAlgorithmAfterGrowthCount = @(
            $MainAlgorithmResults |
            Where-Object {
                $null -ne $_.Timestamp -and
                $_.Timestamp -gt $FirstGrowthTimestamp -and
                $_.TerminateReason -eq "GOAL"
            }
        ).Count
    }

    $TestAfterLastAlgorithm = $false

    if (
        $MainAlgorithmResults.Count -gt 0 -and
        $MainTestResults.Count -gt 0
    ) {
        $LastAlgorithmTimestamp = (
            $MainAlgorithmResults |
            Sort-Object Timestamp |
            Select-Object -Last 1
        ).Timestamp

        $FirstTestTimestamp = (
            $MainTestResults |
            Sort-Object Timestamp |
            Select-Object -First 1
        ).Timestamp

        if (
            $null -ne $LastAlgorithmTimestamp -and
            $null -ne $FirstTestTimestamp -and
            $FirstTestTimestamp -gt $LastAlgorithmTimestamp
        ) {
            $TestAfterLastAlgorithm = $true
        }
    }

    $TopLevelFinalAfterLastTool = $false

    if (
        $MainAssistantEvents.Count -gt 0 -and
        $MainToolishEvents.Count -gt 0
    ) {
        $LastAssistantTimestamp = (
            $MainAssistantEvents |
            Sort-Object Timestamp |
            Select-Object -Last 1
        ).Timestamp

        $LastToolishTimestamp = (
            $MainToolishEvents |
            Sort-Object Timestamp |
            Select-Object -Last 1
        ).Timestamp

        if (
            $null -ne $LastAssistantTimestamp -and
            $null -ne $LastToolishTimestamp -and
            $LastAssistantTimestamp -gt $LastToolishTimestamp
        ) {
            $TopLevelFinalAfterLastTool = $true
        }
    }

    $TerminalTraceFound = $false
    $TerminalTraceEventCount = 0
    $TerminalStopCount = 0
    $LastPreAgentGuardActive = $null
    $LastPreAgentRecoveryRequired = $null
    $TurnClosedAtStop = $null
    $TerminalAbortObserved = $false

    if (
        -not [string]::IsNullOrWhiteSpace($TerminalTracePath) -and
        (Test-Path -LiteralPath $TerminalTracePath -PathType Leaf)
    ) {
        $TraceRecords = @()

        foreach ($TraceLine in Get-Content -LiteralPath $TerminalTracePath) {
            try {
                $Trace = ([string]$TraceLine) | ConvertFrom-Json
            }
            catch {
                continue
            }

            $TraceSession = [string](
                Get-ObjectPropertyValue `
                    -Object $Trace `
                    -Name "session_id"
            )

            if ($TraceSession -ne $MainSessionId) {
                continue
            }

            $TraceRecords += $Trace
        }

        if ($TraceRecords.Count -gt 0) {
            $TerminalTraceFound = $true
            $TerminalTraceEventCount = $TraceRecords.Count

            $PreAgents = @(
                $TraceRecords |
                Where-Object {
                    [string](
                        Get-ObjectPropertyValue `
                            -Object $_ `
                            -Name "event"
                    ) -eq "PreToolUse" -and
                    [string](
                        Get-ObjectPropertyValue `
                            -Object $_ `
                            -Name "tool"
                    ) -eq "agent"
                }
            )

            if ($PreAgents.Count -gt 0) {
                $LastPreAgent = $PreAgents[-1]
                $LastPreAgentGuardActive = [bool](
                    Get-ObjectPropertyValue `
                        -Object $LastPreAgent `
                        -Name "growth_recovery_guard_active"
                )
                $LastPreAgentRecoveryRequired = [bool](
                    Get-ObjectPropertyValue `
                        -Object $LastPreAgent `
                        -Name "growth_recovery_required"
                )
            }

            $Stops = @(
                $TraceRecords |
                Where-Object {
                    [string](
                        Get-ObjectPropertyValue `
                            -Object $_ `
                            -Name "event"
                    ) -eq "Stop"
                }
            )

            $TerminalStopCount = $Stops.Count

            if ($Stops.Count -gt 0) {
                $LastStop = $Stops[-1]
                $TurnClosedValue = Get-ObjectPropertyValue `
                    -Object $LastStop `
                    -Name "turn_closed"

                if ($null -ne $TurnClosedValue) {
                    $TurnClosedAtStop = [bool]$TurnClosedValue
                }
            }

            foreach ($Trace in $TraceRecords) {
                $AbortReason = [string](
                    Get-ObjectPropertyValue `
                        -Object $Trace `
                        -Name "terminal_abort_reason"
                )

                if (-not [string]::IsNullOrWhiteSpace($AbortReason)) {
                    $TerminalAbortObserved = $true
                    break
                }
            }
        }
    }

    $HookErrorCount = 0

    if (
        -not [string]::IsNullOrWhiteSpace($HookErrorsPath) -and
        (Test-Path -LiteralPath $HookErrorsPath -PathType Leaf)
    ) {
        foreach ($HookLine in Get-Content -LiteralPath $HookErrorsPath) {
            if (
                ([string]$HookLine).IndexOf(
                    $MainSessionId,
                    [System.StringComparison]::Ordinal
                ) -ge 0
            ) {
                $HookErrorCount++
            }
        }
    }

    $RuntimeTextParts = @($QwenOutput)

    foreach ($LogPath in @($ServerStdoutPath,$ServerStderrPath)) {
        if (
            -not [string]::IsNullOrWhiteSpace($LogPath) -and
            (Test-Path -LiteralPath $LogPath -PathType Leaf)
        ) {
            try {
                $RuntimeTextParts += [System.IO.File]::ReadAllText($LogPath)
            }
            catch {
                # A futó benchmark-szerver átmenetileg foghatja a logot.
                # Ez nem lehet oka annak, hogy az orchestration evidence mérés elbukjon.
            }
        }
    }

    $RuntimeText = ($RuntimeTextParts -join "`n")
    $RuntimeFatalErrorCount = 0

    foreach ($Pattern in @(
        "out of memory",
        "failed to allocate",
        "cannot allocate memory",
        "cuda error",
        "context size exceeded",
        "exceeds context window",
        "ggml_assert",
        "fatal error"
    )) {
        if (
            $RuntimeText.IndexOf(
                $Pattern,
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        ) {
            $RuntimeFatalErrorCount++
        }
    }

    return [pscustomobject]@{
        MainSessionId = $MainSessionId
        ChatCompressionCount = $MainCompressionEvents.Count
        CompressionContinuationGapCount = $CompressionContinuationGapCount
        GrowthLimitResultCount = $MainGrowthEvents.Count
        RecoveryAuthoritativeStateCount = $RecoveryAuthoritativeStateCount
        RecoveryGuardRejectionCount = $RecoveryGuardRejectionCount
        RecoveryRereadCycleCount = $RecoveryRereadCycleCount
        SuccessfulAlgorithmAfterGrowthCount = $SuccessfulAlgorithmAfterGrowthCount
        AlgorithmResultCount = $MainAlgorithmResults.Count
        TestAgentResultCount = $MainTestResults.Count
        TestAfterLastAlgorithm = $TestAfterLastAlgorithm
        TopLevelFinalCount = $MainAssistantEvents.Count
        TopLevelFinalAfterLastTool = $TopLevelFinalAfterLastTool
        TerminalTraceFound = $TerminalTraceFound
        TerminalTraceEventCount = $TerminalTraceEventCount
        TerminalStopCount = $TerminalStopCount
        LastPreAgentGuardActive = $LastPreAgentGuardActive
        LastPreAgentRecoveryRequired = $LastPreAgentRecoveryRequired
        TurnClosedAtStop = $TurnClosedAtStop
        TerminalAbortObserved = $TerminalAbortObserved
        HookErrorCount = $HookErrorCount
        RuntimeFatalErrorCount = $RuntimeFatalErrorCount
    }
}

function Copy-OrchestrationEnduranceArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Directory,

        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$JsonlFiles,

        [string]$QwenOutput = "",

        [string]$CoreTestOutput = "",

        [string]$ExtendedTestOutput = "",

        [string]$ServerStdoutPath = "",

        [string]$ServerStderrPath = ""
    )

    Assert-LocalTree $Directory
    [void](New-Item -ItemType Directory -Path $Directory -Force)

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath (Join-Path $Directory "qwen-output.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory "qwen-output.txt"),
        $QwenOutput,
        $Utf8NoBom
    )

    Assert-LocalPath (Join-Path $Directory "core-tests.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory "core-tests.txt"),
        $CoreTestOutput,
        $Utf8NoBom
    )

    Assert-LocalPath (Join-Path $Directory "extended-tests.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Directory "extended-tests.txt"),
        $ExtendedTestOutput,
        $Utf8NoBom
    )

    foreach ($Pair in @(
        @($ServerStdoutPath,"server.stdout.log"),
        @($ServerStderrPath,"server.stderr.log")
    )) {
        $Source = [string]$Pair[0]
        $Name = [string]$Pair[1]

        if (
            -not [string]::IsNullOrWhiteSpace($Source) -and
            (Test-Path -LiteralPath $Source -PathType Leaf)
        ) {
            Assert-LocalPath $Source
            Assert-LocalPath (Join-Path $Directory $Name)
            Copy-Item `
                -LiteralPath $Source `
                -Destination (Join-Path $Directory $Name) `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    $JsonlDirectory = Join-Path $Directory "session-jsonl"
    Assert-LocalTree $JsonlDirectory
    [void](New-Item -ItemType Directory -Path $JsonlDirectory -Force)

    $Index = 0

    foreach ($File in $JsonlFiles) {
        $Index++
        $DestinationName = (
            $Index.ToString("D3") +
            "-" +
            $File.Name
        )

        Assert-LocalPath $File.FullName
        Assert-LocalPath (Join-Path $JsonlDirectory $DestinationName)
        Copy-Item `
            -LiteralPath $File.FullName `
            -Destination (Join-Path $JsonlDirectory $DestinationName) `
            -Force
    }
}

function Get-RoleAwareTelemetrySummary {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Files
    )

    $Counts = [ordered]@{
        PROMPT = 0
        ALGORITHM = 0
        TEST = 0
    }

    $MaxThoughts = [ordered]@{
        PROMPT = 0
        ALGORITHM = 0
        TEST = 0
    }

    $SumThoughts = [ordered]@{
        PROMPT = 0
        ALGORITHM = 0
        TEST = 0
    }

    $ApiResponses = 0
    $ToolCalls = 0
    $GrowthLimitCount = 0
    $MaxTokensCount = 0
    $NoVisibleProgressCount = 0
    $PartialSideEffectsCount = 0
    $CompactionPassCount = 0
    $ContextRolloverRequiredCount = 0
    $ContextRolloverCompletedCount = 0
    $ContextCompactionNoProgressCount = 0
    $ContextHighWatermarkTokens = 0
    $ContextPostCompactionMaxTokens = 0

    foreach ($File in $Files) {
        foreach ($Line in Get-Content -LiteralPath $File.FullName) {
            $Raw = [string]$Line

            if ($Raw.IndexOf(
                "GROWTH_LIMIT",
                [System.StringComparison]::Ordinal
            ) -ge 0) {
                $GrowthLimitCount++
            }

            if (
                $Raw -match
                '(?i)(finishReason|finish_reason|deferredFinishReason)[\\"]*\s*:\s*[\\"]*MAX_TOKENS'
            ) {
                $MaxTokensCount++
            }

            if ($Raw.IndexOf(
                "Model stream ended after a tool result without visible progress",
                [System.StringComparison]::Ordinal
            ) -ge 0) {
                $NoVisibleProgressCount++
            }

            if ($Raw.IndexOf(
                "Partial side effects are possible",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0) {
                $PartialSideEffectsCount++
            }

            if ($Raw.IndexOf(
                "[LOCALAI_CONTEXT_LIFECYCLE] compaction pass",
                [System.StringComparison]::Ordinal
            ) -ge 0) {
                $CompactionPassCount++

                if (
                    $Raw -match
                    'compaction pass\s+\d+:\s+(\d+)\s+->\s+(\d+)'
                ) {
                    $BeforeTokens = [int]$Matches[1]
                    $AfterTokens = [int]$Matches[2]

                    if ($BeforeTokens -gt $ContextHighWatermarkTokens) {
                        $ContextHighWatermarkTokens = $BeforeTokens
                    }

                    if ($AfterTokens -gt $ContextPostCompactionMaxTokens) {
                        $ContextPostCompactionMaxTokens = $AfterTokens
                    }
                }
            }

            if ($Raw.IndexOf(
                "LOCALAI_CONTEXT_ROLLOVER_REQUIRED:",
                [System.StringComparison]::Ordinal
            ) -ge 0) {
                $ContextRolloverRequiredCount++

                if (
                    $Raw.IndexOf(
                        "reason=insufficient_compaction_progress",
                        [System.StringComparison]::Ordinal
                    ) -ge 0 -or
                    $Raw.IndexOf(
                        "reason=max_compaction_passes",
                        [System.StringComparison]::Ordinal
                    ) -ge 0
                ) {
                    $ContextCompactionNoProgressCount++
                }
            }

            if ($Raw.IndexOf(
                "[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed",
                [System.StringComparison]::Ordinal
            ) -ge 0) {
                $ContextRolloverCompletedCount++
            }

            try {
                $Object = $Raw | ConvertFrom-Json
            }
            catch {
                continue
            }

            if ([string](Get-ObjectPropertyValue -Object $Object -Name "type") -ne "system") {
                continue
            }

            $Payload = Get-ObjectPropertyValue `
                -Object $Object `
                -Name "systemPayload"

            $Event = Get-ObjectPropertyValue `
                -Object $Payload `
                -Name "uiEvent"

            if ($null -eq $Event) {
                continue
            }

            $EventName = [string](
                Get-ObjectPropertyValue `
                    -Object $Event `
                    -Name "event.name"
            )

            if ($EventName -eq "qwen-code.tool_call") {
                $ToolCalls++
                continue
            }

            if ($EventName -ne "qwen-code.api_response") {
                continue
            }

            $ApiResponses++

            $PromptId = [string](
                Get-ObjectPropertyValue `
                    -Object $Event `
                    -Name "prompt_id"
            )

            $Role = "PROMPT"

            if ($PromptId -like "*#algorithm-agent-*") {
                $Role = "ALGORITHM"
            }
            elseif ($PromptId -like "*#test-agent-*") {
                $Role = "TEST"
            }

            $Counts[$Role] = [int]$Counts[$Role] + 1

            $ThoughtValue = Get-ObjectPropertyValue `
                -Object $Event `
                -Name "thoughts_token_count"

            $Thoughts = 0

            if ($null -ne $ThoughtValue) {
                [void][int]::TryParse(
                    [string]$ThoughtValue,
                    [ref]$Thoughts
                )
            }

            $SumThoughts[$Role] = (
                [int]$SumThoughts[$Role] +
                $Thoughts
            )

            if ($Thoughts -gt [int]$MaxThoughts[$Role]) {
                $MaxThoughts[$Role] = $Thoughts
            }
        }
    }

    return [pscustomobject]@{
        JsonlFileCount = $Files.Count
        ApiResponses = $ApiResponses
        ToolCalls = $ToolCalls
        PromptResponses = [int]$Counts["PROMPT"]
        AlgorithmResponses = [int]$Counts["ALGORITHM"]
        TestResponses = [int]$Counts["TEST"]
        PromptMaxThoughts = [int]$MaxThoughts["PROMPT"]
        AlgorithmMaxThoughts = [int]$MaxThoughts["ALGORITHM"]
        TestMaxThoughts = [int]$MaxThoughts["TEST"]
        PromptSumThoughts = [int]$SumThoughts["PROMPT"]
        AlgorithmSumThoughts = [int]$SumThoughts["ALGORITHM"]
        TestSumThoughts = [int]$SumThoughts["TEST"]
        GrowthLimitCount = $GrowthLimitCount
        MaxTokensCount = $MaxTokensCount
        NoVisibleProgressCount = $NoVisibleProgressCount
        PartialSideEffectsCount = $PartialSideEffectsCount
        CompactionPassCount = $CompactionPassCount
        ContextRolloverRequiredCount = $ContextRolloverRequiredCount
        ContextRolloverCompletedCount = $ContextRolloverCompletedCount
        ContextCompactionNoProgressCount = $ContextCompactionNoProgressCount
        ContextHighWatermarkTokens = $ContextHighWatermarkTokens
        ContextPostCompactionMaxTokens = $ContextPostCompactionMaxTokens
    }
}

function Write-RoleAwareAgentBenchmarkWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-AgentBenchmarkWorkspace `
        -Path $Path `
        -ReasoningEffort ([string]$Parameters["reasoning-effort"])

    $SettingsText = [System.IO.File]::ReadAllText($SettingsPath)

    $SettingsText = Set-ManagedProviderBenchmarkStateInSettings `
        -Text $SettingsText `
        -ContextWindowSize ([int]$Parameters["ctx-size"]) `
        -PromptReasoningBudgetTokens ([int]$Parameters["prompt-reasoning-budget"]) `
        -AlgorithmReasoningBudgetTokens ([int]$Parameters["algorithm-reasoning-budget"]) `
        -TestReasoningBudgetTokens ([int]$Parameters["test-reasoning-budget"]) `
        -MaxContextGrowthTokensPerTurn ([int]$Parameters["max-context-growth-tokens-per-turn"])

    $QwenDir = Join-Path $Path ".qwen"
    $LocalSettingsPath = Join-Path $QwenDir "settings.json"
    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath $LocalSettingsPath
    [System.IO.File]::WriteAllText(
        $LocalSettingsPath,
        $SettingsText,
        $Utf8NoBom
    )
}


function Write-ReasoningStressBenchmarkWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-LocalTree $Path
    [void](New-Item -ItemType Directory -Path $Path -Force)

    $ExportSource = @'
from __future__ import annotations

import shutil
import sqlite3
import subprocess
from pathlib import Path

DOMAIN_FILTER = "chatgpt.com"
CHCK = b"CHCK"


def chrome_processes_for_profile(user_data_dir: str, profile_directory: str):
    """Legacy implementation: any chrome.exe process blocks the profile."""
    output = subprocess.check_output(
        ["tasklist", "/FI", "IMAGENAME eq chrome.exe"],
        text=True,
        errors="replace",
    )
    if "chrome.exe" in output.lower():
        return [{"pid": -1, "cmdline": ["chrome.exe"]}]
    return []


def snapshot_cookie_db(source: str | Path, destination: str | Path) -> None:
    """Create a temporary cookie DB snapshot."""
    source = Path(source)
    destination = Path(destination)
    shutil.copy2(source, destination)


def select_export_rows(connection: sqlite3.Connection):
    return connection.execute(
        """
        SELECT host_key, name, path, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE ?
        ORDER BY host_key, name, path
        """,
        (f"%{DOMAIN_FILTER}%",),
    ).fetchall()


def preserve_cookie_blob(blob: bytes) -> bytes:
    """Existing CHCK behavior must remain unchanged."""
    if blob.startswith(CHCK):
        return blob
    return blob


def export_cookies(
    source_db: str | Path,
    snapshot_db: str | Path,
    user_data_dir: str,
    profile_directory: str,
):
    """Export chatgpt.com cookies from a stable SQLite snapshot."""
    # Export must remain usable while Chrome owns the live source database.
    snapshot_cookie_db(source_db, snapshot_db)

    with sqlite3.connect(snapshot_db) as connection:
        rows = select_export_rows(connection)

    return [
        (
            host_key,
            name,
            path,
            value,
            preserve_cookie_blob(encrypted_value),
        )
        for host_key, name, path, value, encrypted_value in rows
    ]
'@

    $ImportSource = @'
from __future__ import annotations

import sqlite3
import subprocess
import time
from pathlib import Path

DOMAIN_FILTER = "chatgpt.com"
CHCK = b"CHCK"


def chrome_processes_for_profile(user_data_dir: str, profile_directory: str):
    """Legacy implementation: any chrome.exe process blocks the profile."""
    output = subprocess.check_output(
        ["tasklist", "/FI", "IMAGENAME eq chrome.exe"],
        text=True,
        errors="replace",
    )
    if "chrome.exe" in output.lower():
        return [{"pid": -1, "cmdline": ["chrome.exe"]}]
    return []


def wait_for_profile_free(
    user_data_dir: str,
    profile_directory: str,
    timeout: float = 120,
    poll_seconds: float = 2.0,
) -> None:
    """Wait until the target Chrome profile becomes writable."""
    busy = chrome_processes_for_profile(
        user_data_dir,
        profile_directory,
    )
    if busy:
        raise RuntimeError(
            "A Chrome fut. Zárd be a Chrome-ot az import előtt."
        )


def decode_cookie_blob(blob: bytes) -> bytes:
    """Existing CHCK behavior must remain unchanged."""
    if blob.startswith(CHCK):
        return blob[len(CHCK):]
    return blob


def upsert_cookie(connection: sqlite3.Connection, row: tuple) -> None:
    """Existing upsert semantics must remain unchanged."""
    connection.execute(
        """
        INSERT INTO cookies(host_key, name, path, value, encrypted_value)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(host_key, name, path) DO UPDATE SET
            value = excluded.value,
            encrypted_value = excluded.encrypted_value
        """,
        row,
    )


def import_cookies(
    target_db: str | Path,
    rows: list[tuple],
    user_data_dir: str,
    profile_directory: str,
    timeout: float = 120,
) -> int:
    wait_for_profile_free(
        user_data_dir,
        profile_directory,
        timeout=timeout,
    )

    accepted = [
        row
        for row in rows
        if DOMAIN_FILTER in row[0]
    ]

    with sqlite3.connect(target_db) as connection:
        for row in accepted:
            host_key, name, path, value, encrypted_value = row
            upsert_cookie(
                connection,
                (
                    host_key,
                    name,
                    path,
                    value,
                    decode_cookie_blob(encrypted_value),
                ),
            )
        connection.commit()

    return len(accepted)
'@

    $PsutilStub = @'
from __future__ import annotations

_processes = []


class NoSuchProcess(Exception):
    pass


class AccessDenied(Exception):
    pass


def process_iter(attrs=None):
    return list(_processes)
'@

    $Requirements = @'
cryptography
'@

    $TestSource = @'
from __future__ import annotations

import inspect
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import psutil

import export_cookies
import import_cookies


class FakeProcess:
    def __init__(self, pid: int, name: str, cmdline: list[str]):
        self.pid = pid
        self.info = {
            "pid": pid,
            "name": name,
            "cmdline": list(cmdline),
        }

    def name(self):
        return self.info["name"]

    def cmdline(self):
        return list(self.info["cmdline"])


class CookieWorkflowTests(unittest.TestCase):
    def setUp(self):
        psutil._processes = []

    def target_process(self, pid=101):
        return FakeProcess(
            pid,
            "chrome.exe",
            [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                r"--user-data-dir=C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
                "--profile-directory=Profile 2",
            ],
        )

    def other_profile_process(self, pid=102):
        return FakeProcess(
            pid,
            "chrome.exe",
            [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                r"--user-data-dir=C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
                "--profile-directory=Default",
            ],
        )

    def crashpad_process(self, pid=103):
        return FakeProcess(
            pid,
            "chrome.exe",
            [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                "--type=crashpad-handler",
                r"--user-data-dir=C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
                "--profile-directory=Profile 2",
            ],
        )

    def default_browser_process(self, pid=104):
        return FakeProcess(
            pid,
            "chrome.exe",
            [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
            ],
        )

    def default_renderer_process(self, pid=105):
        return FakeProcess(
            pid,
            "chrome.exe",
            [
                r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                "--type=renderer",
            ],
        )

    def assert_profile_detection(self, module):
        psutil._processes = [
            self.other_profile_process(),
            self.crashpad_process(),
        ]
        found = module.chrome_processes_for_profile(
            r"C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
            "Profile 2",
        )
        self.assertEqual(found, [])

        psutil._processes.append(self.target_process())
        found = module.chrome_processes_for_profile(
            r"C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
            "Profile 2",
        )
        self.assertEqual(len(found), 1)

        item = found[0]
        if isinstance(item, dict):
            pid = item.get("pid")
        else:
            pid = getattr(item, "pid", None)
        self.assertEqual(pid, 101)

    def test_export_profile_detection_is_profile_aware(self):
        self.assert_profile_detection(export_cookies)

    def test_import_profile_detection_is_profile_aware(self):
        self.assert_profile_detection(import_cookies)

    def assert_default_profile_without_flags(self, module):
        psutil._processes = [
            self.default_renderer_process(),
        ]

        found = module.chrome_processes_for_profile(
            r"C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
            "Default",
        )
        self.assertEqual(found, [])

        psutil._processes.append(self.default_browser_process())

        found = module.chrome_processes_for_profile(
            r"C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
            "Default",
        )
        self.assertEqual(len(found), 1)

        item = found[0]
        if isinstance(item, dict):
            pid = item.get("pid")
        else:
            pid = getattr(item, "pid", None)
        self.assertEqual(pid, 104)

        found = module.chrome_processes_for_profile(
            r"C:\Users\Bench\AppData\Local\Google\Chrome\User Data",
            "Profile 2",
        )
        self.assertEqual(found, [])

    def test_export_default_profile_without_flags_is_detected(self):
        self.assert_default_profile_without_flags(export_cookies)

    def test_import_default_profile_without_flags_is_detected(self):
        self.assert_default_profile_without_flags(import_cookies)

    def test_export_uses_sqlite_online_backup_not_file_copy(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            source = root / "Cookies"
            snapshot = root / "Cookies.snapshot"

            connection = sqlite3.connect(source)
            try:
                connection.execute("PRAGMA journal_mode=WAL")
                connection.execute(
                    """
                    CREATE TABLE cookies(
                        host_key TEXT,
                        name TEXT,
                        path TEXT,
                        value TEXT,
                        encrypted_value BLOB,
                        UNIQUE(host_key, name, path)
                    )
                    """
                )
                connection.execute(
                    "INSERT INTO cookies VALUES (?, ?, ?, ?, ?)",
                    (".chatgpt.com", "session", "/", "v", b"blob"),
                )
                connection.commit()

                with mock.patch(
                    "shutil.copy",
                    side_effect=AssertionError("simple copy forbidden"),
                ), mock.patch(
                    "shutil.copy2",
                    side_effect=AssertionError("simple copy forbidden"),
                ), mock.patch(
                    "shutil.copyfile",
                    side_effect=AssertionError("simple copy forbidden"),
                ):
                    export_cookies.snapshot_cookie_db(source, snapshot)
            finally:
                connection.close()

            check = sqlite3.connect(snapshot)
            try:
                row = check.execute(
                    "SELECT host_key, name FROM cookies"
                ).fetchone()
            finally:
                check.close()

            self.assertEqual(row, (".chatgpt.com", "session"))

        source_text = inspect.getsource(export_cookies.snapshot_cookie_db)
        self.assertIn(".backup(", source_text)

    def test_import_waits_with_polling_and_does_not_kill(self):
        calls = {"count": 0}

        def fake_busy(*args, **kwargs):
            calls["count"] += 1
            if calls["count"] <= 2:
                return [{"pid": 201}, {"pid": 202}]
            return []

        sleeps = []

        with mock.patch.object(
            import_cookies,
            "chrome_processes_for_profile",
            side_effect=fake_busy,
        ), mock.patch.object(
            import_cookies.time,
            "sleep",
            side_effect=lambda seconds: sleeps.append(seconds),
        ):
            import_cookies.wait_for_profile_free(
                "USER_DATA",
                "Profile 2",
                timeout=10,
                poll_seconds=2.0,
            )

        self.assertEqual(calls["count"], 3)
        self.assertGreaterEqual(len(sleeps), 2)
        self.assertTrue(
            all(abs(float(value) - 2.0) < 0.05 for value in sleeps)
        )

        source_text = inspect.getsource(import_cookies).lower()
        forbidden = (
            "taskkill",
            "os.kill",
            ".terminate(",
            ".kill(",
        )
        for token in forbidden:
            self.assertNotIn(token, source_text)

    def test_import_default_timeout_is_120(self):
        signature = inspect.signature(
            import_cookies.wait_for_profile_free
        )
        self.assertEqual(signature.parameters["timeout"].default, 120)

    def test_timeout_is_nonzero_failure(self):
        with mock.patch.object(
            import_cookies,
            "chrome_processes_for_profile",
            return_value=[{"pid": 301}],
        ), mock.patch.object(
            import_cookies.time,
            "sleep",
            return_value=None,
        ), mock.patch.object(
            import_cookies.time,
            "monotonic",
            side_effect=[0.0, 0.0, 1.0, 2.0, 3.0, 4.0],
        ):
            with self.assertRaises((TimeoutError, RuntimeError)):
                import_cookies.wait_for_profile_free(
                    "USER_DATA",
                    "Profile 2",
                    timeout=1,
                    poll_seconds=2.0,
                )

    def test_chatgpt_filter_chck_and_upsert_are_preserved(self):
        self.assertEqual(export_cookies.DOMAIN_FILTER, "chatgpt.com")
        self.assertEqual(import_cookies.DOMAIN_FILTER, "chatgpt.com")
        self.assertEqual(export_cookies.CHCK, b"CHCK")
        self.assertEqual(import_cookies.CHCK, b"CHCK")
        self.assertEqual(
            export_cookies.preserve_cookie_blob(b"CHCKpayload"),
            b"CHCKpayload",
        )
        self.assertEqual(
            import_cookies.decode_cookie_blob(b"CHCKpayload"),
            b"payload",
        )

        connection = sqlite3.connect(":memory:")
        try:
            connection.execute(
                """
                CREATE TABLE cookies(
                    host_key TEXT,
                    name TEXT,
                    path TEXT,
                    value TEXT,
                    encrypted_value BLOB,
                    UNIQUE(host_key, name, path)
                )
                """
            )
            import_cookies.upsert_cookie(
                connection,
                (".chatgpt.com", "session", "/", "old", b"a"),
            )
            import_cookies.upsert_cookie(
                connection,
                (".chatgpt.com", "session", "/", "new", b"b"),
            )
            rows = connection.execute(
                "SELECT value, encrypted_value FROM cookies"
            ).fetchall()
        finally:
            connection.close()

        self.assertEqual(rows, [("new", b"b")])

    def test_requirements_contains_psutil_and_cryptography(self):
        requirements = {
            line.strip().lower()
            for line in Path("requirements.txt").read_text(
                encoding="utf-8"
            ).splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        }
        self.assertIn("psutil", requirements)
        self.assertIn("cryptography", requirements)

    def test_user_facing_messages_and_comments_are_hungarian(self):
        import_source = Path("import_cookies.py").read_text(
            encoding="utf-8"
        )
        self.assertTrue(
            any(
                token in import_source.lower()
                for token in (
                    "zár",
                    "chrome",
                    "profil",
                    "vár",
                )
            )
        )


if __name__ == "__main__":
    unittest.main()
'@

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath (Join-Path $Path "export_cookies.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "export_cookies.py"),
        $ExportSource,
        $Utf8NoBom
    )
    Assert-LocalPath (Join-Path $Path "import_cookies.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "import_cookies.py"),
        $ImportSource,
        $Utf8NoBom
    )
    Assert-LocalPath (Join-Path $Path "psutil.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "psutil.py"),
        $PsutilStub,
        $Utf8NoBom
    )
    Assert-LocalPath (Join-Path $Path "requirements.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "requirements.txt"),
        $Requirements,
        $Utf8NoBom
    )
    Assert-LocalPath (Join-Path $Path "test_cookie_workflow.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "test_cookie_workflow.py"),
        $TestSource,
        $Utf8NoBom
    )

    $QwenDir = Join-Path $Path ".qwen"
    Assert-LocalTree $QwenDir
    [void](New-Item -ItemType Directory -Path $QwenDir -Force)

    $SettingsText = [System.IO.File]::ReadAllText($SettingsPath)
    $SettingsText = Set-ManagedProviderBenchmarkStateInSettings `
        -Text $SettingsText `
        -ContextWindowSize ([int]$Parameters["ctx-size"]) `
        -PromptReasoningBudgetTokens ([int]$Parameters["prompt-reasoning-budget"]) `
        -AlgorithmReasoningBudgetTokens ([int]$Parameters["algorithm-reasoning-budget"]) `
        -TestReasoningBudgetTokens ([int]$Parameters["test-reasoning-budget"]) `
        -MaxContextGrowthTokensPerTurn ([int]$Parameters["max-context-growth-tokens-per-turn"])

    Assert-LocalPath (Join-Path $QwenDir "settings.json")
    [System.IO.File]::WriteAllText(
        (Join-Path $QwenDir "settings.json"),
        $SettingsText,
        $Utf8NoBom
    )
}


function Set-RoleBudgetInConfig {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PROMPT","ALGORITHM","TEST")]
        [string]$Role,

        [Parameter(Mandatory = $true)]
        [int]$Budget
    )

    $Config = Copy-BenchmarkParameters -Parameters $Parameters

    switch ($Role) {
        "PROMPT" {
            $Config["prompt-reasoning-budget"] = [string]$Budget
        }
        "ALGORITHM" {
            $Config["algorithm-reasoning-budget"] = [string]$Budget
        }
        "TEST" {
            $Config["test-reasoning-budget"] = [string]$Budget
        }
    }

    return $Config
}


function Get-AgenticCoreTestTargets {
    return @(
        "test_cookie_workflow.CookieWorkflowTests.test_chatgpt_filter_chck_and_upsert_are_preserved",
        "test_cookie_workflow.CookieWorkflowTests.test_export_profile_detection_is_profile_aware",
        "test_cookie_workflow.CookieWorkflowTests.test_export_default_profile_without_flags_is_detected",
        "test_cookie_workflow.CookieWorkflowTests.test_import_default_timeout_is_120",
        "test_cookie_workflow.CookieWorkflowTests.test_import_profile_detection_is_profile_aware",
        "test_cookie_workflow.CookieWorkflowTests.test_import_default_profile_without_flags_is_detected",
        "test_cookie_workflow.CookieWorkflowTests.test_import_waits_with_polling_and_does_not_kill",
        "test_cookie_workflow.CookieWorkflowTests.test_requirements_contains_psutil_and_cryptography",
        "test_cookie_workflow.CookieWorkflowTests.test_timeout_is_nonzero_failure",
        "test_cookie_workflow.CookieWorkflowTests.test_user_facing_messages_and_comments_are_hungarian"
    )
}

function Get-AgenticExtendedTestTargets {
    return @(
        "test_cookie_workflow.CookieWorkflowTests.test_export_uses_sqlite_online_backup_not_file_copy"
    )
}

function Write-AgenticHarnessReferenceImplementation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $ReferenceExport = @'
from __future__ import annotations

import sqlite3
from pathlib import Path

import psutil

DOMAIN_FILTER = "chatgpt.com"
CHCK = b"CHCK"


def _norm(value: str) -> str:
    return str(value).strip().strip('"').replace("/", "\\").rstrip("\\").casefold()


def chrome_processes_for_profile(user_data_dir: str, profile_directory: str):
    target_user = _norm(user_data_dir)
    target_profile = str(profile_directory).strip().casefold()
    found = []

    for process in psutil.process_iter(attrs=["pid", "name", "cmdline"]):
        try:
            info = getattr(process, "info", {}) or {}
            name = str(info.get("name") or process.name()).casefold()
            cmdline = list(info.get("cmdline") or process.cmdline() or [])
        except (psutil.NoSuchProcess, psutil.AccessDenied, OSError):
            continue

        if name not in ("chrome.exe", "chrome"):
            continue

        if any(str(arg).casefold().startswith("--type=") for arg in cmdline):
            continue

        user_arg = None
        profile_arg = None

        for arg in cmdline:
            text = str(arg)
            low = text.casefold()
            if low.startswith("--user-data-dir="):
                user_arg = text.split("=", 1)[1]
            elif low.startswith("--profile-directory="):
                profile_arg = text.split("=", 1)[1]

        if user_arg is not None and _norm(user_arg) != target_user:
            continue

        if profile_arg is None:
            if target_profile != "default":
                continue
        elif str(profile_arg).strip().casefold() != target_profile:
            continue

        found.append({
            "pid": info.get("pid", getattr(process, "pid", None)),
            "cmdline": cmdline,
        })

    return found


def snapshot_cookie_db(source: str | Path, destination: str | Path) -> None:
    source = Path(source).resolve()
    destination = Path(destination).resolve()

    source_connection = sqlite3.connect(
        f"{source.as_uri()}?mode=ro",
        uri=True,
    )
    destination_connection = sqlite3.connect(destination)

    try:
        source_connection.backup(destination_connection)
    finally:
        destination_connection.close()
        source_connection.close()


def select_export_rows(connection: sqlite3.Connection):
    return connection.execute(
        """
        SELECT host_key, name, path, value, encrypted_value
        FROM cookies
        WHERE host_key LIKE ?
        ORDER BY host_key, name, path
        """,
        (f"%{DOMAIN_FILTER}%",),
    ).fetchall()


def preserve_cookie_blob(blob: bytes) -> bytes:
    if blob.startswith(CHCK):
        return blob
    return blob


def export_cookies(
    source_db: str | Path,
    snapshot_db: str | Path,
    user_data_dir: str,
    profile_directory: str,
):
    snapshot_cookie_db(source_db, snapshot_db)

    connection = sqlite3.connect(snapshot_db)
    try:
        rows = select_export_rows(connection)
    finally:
        connection.close()

    return [
        (
            host_key,
            name,
            path,
            value,
            preserve_cookie_blob(encrypted_value),
        )
        for host_key, name, path, value, encrypted_value in rows
    ]
'@

    $ReferenceImport = @'
from __future__ import annotations

import sqlite3
import time
from pathlib import Path

import psutil

DOMAIN_FILTER = "chatgpt.com"
CHCK = b"CHCK"


def _norm(value: str) -> str:
    return str(value).strip().strip('"').replace("/", "\\").rstrip("\\").casefold()


def chrome_processes_for_profile(user_data_dir: str, profile_directory: str):
    target_user = _norm(user_data_dir)
    target_profile = str(profile_directory).strip().casefold()
    found = []

    for process in psutil.process_iter(attrs=["pid", "name", "cmdline"]):
        try:
            info = getattr(process, "info", {}) or {}
            name = str(info.get("name") or process.name()).casefold()
            cmdline = list(info.get("cmdline") or process.cmdline() or [])
        except (psutil.NoSuchProcess, psutil.AccessDenied, OSError):
            continue

        if name not in ("chrome.exe", "chrome"):
            continue

        if any(str(arg).casefold().startswith("--type=") for arg in cmdline):
            continue

        user_arg = None
        profile_arg = None

        for arg in cmdline:
            text = str(arg)
            low = text.casefold()
            if low.startswith("--user-data-dir="):
                user_arg = text.split("=", 1)[1]
            elif low.startswith("--profile-directory="):
                profile_arg = text.split("=", 1)[1]

        if user_arg is not None and _norm(user_arg) != target_user:
            continue

        if profile_arg is None:
            if target_profile != "default":
                continue
        elif str(profile_arg).strip().casefold() != target_profile:
            continue

        found.append({
            "pid": info.get("pid", getattr(process, "pid", None)),
            "cmdline": cmdline,
        })

    return found


def wait_for_profile_free(
    user_data_dir: str,
    profile_directory: str,
    timeout: float = 120,
    poll_seconds: float = 2.0,
) -> None:
    start = time.monotonic()

    while True:
        busy = chrome_processes_for_profile(
            user_data_dir,
            profile_directory,
        )

        if not busy:
            return

        pids = ", ".join(str(item.get("pid")) for item in busy)

        # Magyar felhasználói üzenet; a referencia csak a harness helyességét ellenőrzi.
        print(
            f"A Chrome profil foglalt (PID: {pids}). "
            "Zárd be a Chrome-ot, vagy várj."
        )

        if time.monotonic() - start >= float(timeout):
            raise TimeoutError(
                f"A Chrome profil {timeout} másodperc után is foglalt."
            )

        time.sleep(float(poll_seconds))


def decode_cookie_blob(blob: bytes) -> bytes:
    if blob.startswith(CHCK):
        return blob[len(CHCK):]
    return blob


def upsert_cookie(connection: sqlite3.Connection, row: tuple) -> None:
    connection.execute(
        """
        INSERT INTO cookies(host_key, name, path, value, encrypted_value)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(host_key, name, path) DO UPDATE SET
            value = excluded.value,
            encrypted_value = excluded.encrypted_value
        """,
        row,
    )


def import_cookies(
    target_db: str | Path,
    rows: list[tuple],
    user_data_dir: str,
    profile_directory: str,
    timeout: float = 120,
) -> int:
    wait_for_profile_free(
        user_data_dir,
        profile_directory,
        timeout=timeout,
    )

    accepted = [
        row
        for row in rows
        if DOMAIN_FILTER in row[0]
    ]

    connection = sqlite3.connect(target_db)

    try:
        for row in accepted:
            host_key, name, path, value, encrypted_value = row
            upsert_cookie(
                connection,
                (
                    host_key,
                    name,
                    path,
                    value,
                    decode_cookie_blob(encrypted_value),
                ),
            )

        connection.commit()
    finally:
        connection.close()

    return len(accepted)
'@

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath (Join-Path $Path "export_cookies.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "export_cookies.py"),
        $ReferenceExport,
        $Utf8NoBom
    )

    Assert-LocalPath (Join-Path $Path "import_cookies.py")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "import_cookies.py"),
        $ReferenceImport,
        $Utf8NoBom
    )

    Assert-LocalPath (Join-Path $Path "requirements.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "requirements.txt"),
        "psutil`ncryptography`n",
        $Utf8NoBom
    )
}

function Invoke-AgenticHarnessSelfTest {
    Assert-BenchmarkIdle

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("qwen-agentic-harness-selftest-" + [Guid]::NewGuid().ToString("N"))

    try {
        Write-ReasoningStressBenchmarkWorkspace `
            -Path $TempRoot `
            -Parameters $Parameters

        Write-AgenticHarnessReferenceImplementation `
            -Path $TempRoot

        $CoreTargets = @(Get-AgenticCoreTestTargets)
        $ExtendedTargets = @(Get-AgenticExtendedTestTargets)

        Push-Location $TempRoot

        try {
            $PreviousPythonUtf8 = $env:PYTHONUTF8
            $PreviousPythonIoEncoding = $env:PYTHONIOENCODING
            $env:PYTHONUTF8 = "1"
            $env:PYTHONIOENCODING = "utf-8"

            $OldPreference = $ErrorActionPreference
            $ErrorActionPreference = "Continue"
            Write-Host "AGENTIC_HARNESS_NATIVE_STDERR_POLICY=CONTINUE_AND_CAPTURE"

            try {
                $CoreOutput = (
                    & python -m unittest -v @CoreTargets 2>&1 |
                    Out-String
                )
                $CoreExit = $LASTEXITCODE

                $ExtendedOutput = (
                    & python -m unittest -v @ExtendedTargets 2>&1 |
                    Out-String
                )
                $ExtendedExit = $LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $OldPreference
                if ($null -eq $PreviousPythonUtf8) {
                    Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
                }
                else {
                    $env:PYTHONUTF8 = $PreviousPythonUtf8
                }

                if ($null -eq $PreviousPythonIoEncoding) {
                    Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
                }
                else {
                    $env:PYTHONIOENCODING = $PreviousPythonIoEncoding
                }
            }
        }
        finally {
            Pop-Location
        }

        if ($CoreExit -ne 0) {
            Write-Host $CoreOutput
            throw "AGENTIC_HARNESS_REFERENCE_CORE_FAIL"
        }

        if ($ExtendedExit -ne 0) {
            Write-Host $ExtendedOutput
            throw "AGENTIC_HARNESS_REFERENCE_EXTENDED_FAIL"
        }

        Write-Host "AGENTIC_HARNESS_ENCODING=UTF8_DETERMINISTIC"
        Write-Host "AGENTIC_HARNESS_REFERENCE_CORE=PASS"
        Write-Host "AGENTIC_HARNESS_REFERENCE_EXTENDED=PASS"
        Write-Host "AGENTIC_EXTENDED_POLICY=NON_BLOCKING_FOR_MODEL_AUTOTUNE"
        Write-Host "AGENTIC_HARNESS_SELFTEST=PASS"
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) {
            Assert-LocalTree $TempRoot
            Remove-Item `
                -LiteralPath $TempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }

    Assert-BenchmarkIdle
}

function Invoke-RoleAwareAgentMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [ValidateSet("SMOKE","STRESS")]
        [string]$Workload = "SMOKE"
    )

    Assert-BenchmarkIdle

    if (Test-PortListener -Port $Port) {
        throw ("ROLE_AWARE_PORT_NOT_FREE port=" + $Port)
    }

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

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("qwen-role-benchmark-" + [Guid]::NewGuid().ToString("N"))

    $StdoutPath = Join-Path $TempRoot "server.stdout.log"
    $StderrPath = Join-Path $TempRoot "server.stderr.log"

    $BeforeJsonl = Get-QwenJsonlSnapshot
    $BeforeProjects = Get-QwenProjectDirectorySnapshot

    $Process = $null
    $QwenExitCode = $null
    $TestExitCode = $null
    $ExtendedTestExitCode = $null
    $QwenOutput = ""
    $TestOutput = ""
    $ExtendedTestOutput = ""
    $WallSeconds = 0.0
    $Telemetry = $null
    $Endurance = $null
    $FailureReason = $null

    try {
        if ($Workload -eq "STRESS") {
            Write-ReasoningStressBenchmarkWorkspace `
                -Path $TempRoot `
                -Parameters $Parameters
        }
        else {
            Write-RoleAwareAgentBenchmarkWorkspace `
                -Path $TempRoot `
                -Parameters $Parameters
        }

        $ArgumentLine = Get-BenchmarkRouterArgumentLine `
            -Parameters $Parameters

        Assert-LocalPath $StdoutPath
        Assert-LocalPath $StderrPath
        $Process = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ArgumentLine `
            -WorkingDirectory (Split-Path $ServerExe -Parent) `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($null -eq $Process) {
            throw "ROLE_AWARE_ROUTER_START=FAIL"
        }

        Wait-BenchmarkRouterReady -Process $Process

        if ($Workload -eq "STRESS") {
            $AgentPrompt = (
                "Work only inside the current benchmark directory. " +
                "This is a role-routing reasoning-budget stress benchmark. " +
                "You MUST delegate implementation to the configured algorithm-agent and then independent verification to the configured test-agent. " +
                "Before editing, read export_cookies.py and import_cookies.py completely. " +
                "Implement profile-aware chrome.exe detection with psutil based on command-line user-data-dir and profile-directory; unrelated profiles, renderer/helper processes, and crashpad handlers must not block. " +
                "For the Default profile, a top-level Chrome browser process with no --user-data-dir, no --profile-directory, and no --type flag uses the default user-data-dir and MUST count as occupying Default; child/helper processes carrying --type must not. " +
                "export_cookies.py must work while the target Chrome profile is open by creating its SQLite snapshot with the SQLite online backup API, never a simple file copy. " +
                "import_cookies.py must wait for the target profile to become free by polling about every 2 seconds, with configurable timeout defaulting to 120 seconds; print the blocking PIDs and tell the user to close Chrome; never terminate or kill Chrome. " +
                "Preserve the existing chatgpt.com filter, CHCK behavior, and SQLite upsert semantics. " +
                "requirements.txt must contain both psutil and cryptography. " +
                "User-facing messages and comments should be Hungarian. " +
                "Do not modify test_cookie_workflow.py or psutil.py. " +
                "Run python compilation and the unittest suite before finishing. " +
                "The protected test named test_export_uses_sqlite_online_backup_not_file_copy is an extended diagnostic: attempt it and report it, but after the blocking core tests pass, do not loop on that extended edge case. " +
                "Do not use the network or git and do not write outside the benchmark directory. " +
                "If a specialist is stopped after partial side effects, re-read current files before continuing. " +
                "Return concise per-file receipts only after implementation and independent verification are complete."
            )
            $ProtectedTestPath = Join-Path $TempRoot "test_cookie_workflow.py"
            $TestModule = "test_cookie_workflow.py"
        }
        else {
            $AgentPrompt = (
                "Work only inside the current benchmark directory. " +
                "This is a role-routing quality benchmark. " +
                "You MUST delegate the implementation work to the configured algorithm-agent. " +
                "After implementation, you MUST delegate independent verification to the configured test-agent. " +
                "Fix cache.py so every test in test_cache.py passes. " +
                "Do not modify test_cache.py. " +
                "Run the tests before finishing. " +
                "Do not use the network or git. " +
                "Do not create or modify files outside the current directory. " +
                "If a specialist is stopped after partial side effects, re-read the files before continuing. " +
                "Return a concise final status only after the implementation and independent verification are complete."
            )
            $ProtectedTestPath = Join-Path $TempRoot "test_cache.py"
            $TestModule = "test_cache.py"
        }

        if ($Workload -eq "STRESS") {
            $CoreTestTargets = @(
                Get-AgenticCoreTestTargets
            )

            $ExtendedTestTargets = @(
                Get-AgenticExtendedTestTargets
            )
        }
        else {
            $CoreTestTargets = @($TestModule)
            $ExtendedTestTargets = @()
        }

        $ProtectedTestHashBefore = (
            Get-FileHash `
                -LiteralPath $ProtectedTestPath `
                -Algorithm SHA256
        ).Hash.ToUpperInvariant()

        $MaxSessionTurns = "40"
        $MaxWallTime = "8m"
        $MaxToolCalls = "100"

        if ($Workload -eq "STRESS") {
            $MaxSessionTurns = "100"
            $MaxWallTime = ([string]$StressMaxWallTimeMinutes + "m")
            $MaxToolCalls = "240"
        }

        Write-Host (
            "ROLE_AWARE_LIMITS workload=" +
            $Workload +
            " max_session_turns=" +
            $MaxSessionTurns +
            " max_wall_time=" +
            $MaxWallTime +
            " max_tool_calls=" +
            $MaxToolCalls
        )

        $QwenArgs = @(
            "--output-format", "json",
            "--approval-mode", "yolo",
            "--model", [string]$ModelAlias,
            "--max-session-turns", $MaxSessionTurns,
            "--max-wall-time", $MaxWallTime,
            "--max-tool-calls", $MaxToolCalls,
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
                $WallSeconds = $Timer.Elapsed.TotalSeconds
                $QwenExitCode = $LASTEXITCODE

                $PreviousPythonUtf8 = $env:PYTHONUTF8
                $PreviousPythonIoEncoding = $env:PYTHONIOENCODING
                $env:PYTHONUTF8 = "1"
                $env:PYTHONIOENCODING = "utf-8"

                try {
                    $TestOutput = (
                        & python -m unittest -v @CoreTestTargets 2>&1 |
                        Out-String
                    )
                    $TestExitCode = $LASTEXITCODE

                    if ($ExtendedTestTargets.Count -gt 0) {
                        $ExtendedTestOutput = (
                            & python -m unittest -v @ExtendedTestTargets 2>&1 |
                            Out-String
                        )
                        $ExtendedTestExitCode = $LASTEXITCODE
                    }
                    else {
                        $ExtendedTestExitCode = 0
                    }
                }
                finally {
                    if ($null -eq $PreviousPythonUtf8) {
                        Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue
                    }
                    else {
                        $env:PYTHONUTF8 = $PreviousPythonUtf8
                    }

                    if ($null -eq $PreviousPythonIoEncoding) {
                        Remove-Item Env:PYTHONIOENCODING -ErrorAction SilentlyContinue
                    }
                    else {
                        $env:PYTHONIOENCODING = $PreviousPythonIoEncoding
                    }
                }
            }
            finally {
                $ErrorActionPreference = $OldPreference
            }
        }
        finally {
            Pop-Location
        }

        Start-Sleep -Milliseconds 500

        $ChangedJsonl = @(
            Get-ChangedQwenJsonlFiles `
                -Before $BeforeJsonl
        )

        $Telemetry = Get-RoleAwareTelemetrySummary `
            -Files $ChangedJsonl

        if ($script:CollectOrchestrationEnduranceEvidence) {
            $Endurance = Get-OrchestrationEnduranceSummary `
                -Files $ChangedJsonl `
                -QwenOutput $QwenOutput `
                -ServerStdoutPath $StdoutPath `
                -ServerStderrPath $StderrPath `
                -TerminalTracePath $script:OrchestrationTerminalTracePath `
                -HookErrorsPath $script:OrchestrationHookErrorsPath

            if (
                -not [string]::IsNullOrWhiteSpace(
                    [string]$script:OrchestrationEnduranceArtifactDirectory
                )
            ) {
                Copy-OrchestrationEnduranceArtifacts `
                    -Directory $script:OrchestrationEnduranceArtifactDirectory `
                    -JsonlFiles $ChangedJsonl `
                    -QwenOutput $QwenOutput `
                    -CoreTestOutput $TestOutput `
                    -ExtendedTestOutput $ExtendedTestOutput `
                    -ServerStdoutPath $StdoutPath `
                    -ServerStderrPath $StderrPath
            }
        }

        $ProtectedTestHashAfter = (
            Get-FileHash `
                -LiteralPath $ProtectedTestPath `
                -Algorithm SHA256
        ).Hash.ToUpperInvariant()

        Write-Host (
            "ROLE_AWARE_EXIT_CODES label=" +
            $Label +
            " qwen=" +
            $QwenExitCode +
            " core_test=" +
            $TestExitCode +
            " extended_test=" +
            $ExtendedTestExitCode
        )

        if ($ProtectedTestHashAfter -ne $ProtectedTestHashBefore) {
            $FailureReason = "PROTECTED_TEST_MODIFIED"
        }
        elseif ($QwenExitCode -ne 0) {
            $FailureReason = "QWEN_EXIT_CODE_" + $QwenExitCode
        }
        elseif ($TestExitCode -ne 0) {
            $FailureReason = "CORE_TEST_EXIT_CODE_" + $TestExitCode
        }
        elseif ($Telemetry.JsonlFileCount -lt 1) {
            $FailureReason = "ROLE_TELEMETRY_JSONL_MISSING"
        }
        elseif ($Telemetry.PromptResponses -lt 1) {
            $FailureReason = "PROMPT_ROLE_NOT_OBSERVED"
        }
        elseif ($Telemetry.AlgorithmResponses -lt 1) {
            $FailureReason = "ALGORITHM_ROLE_NOT_OBSERVED"
        }
        elseif ($Telemetry.TestResponses -lt 1) {
            $FailureReason = "TEST_ROLE_NOT_OBSERVED"
        }
        elseif ($Telemetry.MaxTokensCount -gt 0) {
            $FailureReason = "MAX_TOKENS_OBSERVED"
        }
        elseif ($Telemetry.NoVisibleProgressCount -gt 0) {
            $FailureReason = "NO_VISIBLE_PROGRESS_OBSERVED"
        }
    }
    catch {
        if ($null -eq $FailureReason) {
            $FailureReason = $_.Exception.Message
        }
    }
    finally {
        try {
            Stop-BenchmarkRouterProcess -Process $Process
        }
        finally {
            if (Test-Path -LiteralPath $TempRoot) {
                Assert-LocalTree $TempRoot
                Remove-Item `
                    -LiteralPath $TempRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Remove-NewQwenProjectDirectories `
                -Before $BeforeProjects
        }
    }

    if ($null -eq $Telemetry) {
        $Telemetry = [pscustomobject]@{
            JsonlFileCount = 0
            ApiResponses = 0
            ToolCalls = 0
            PromptResponses = 0
            AlgorithmResponses = 0
            TestResponses = 0
            PromptMaxThoughts = 0
            AlgorithmMaxThoughts = 0
            TestMaxThoughts = 0
            PromptSumThoughts = 0
            AlgorithmSumThoughts = 0
            TestSumThoughts = 0
            GrowthLimitCount = 0
            MaxTokensCount = 0
            NoVisibleProgressCount = 0
            PartialSideEffectsCount = 0
            CompactionPassCount = 0
            ContextRolloverRequiredCount = 0
            ContextRolloverCompletedCount = 0
            ContextCompactionNoProgressCount = 0
            ContextHighWatermarkTokens = 0
            ContextPostCompactionMaxTokens = 0
        }
    }

    if ($null -eq $Endurance) {
        $Endurance = New-EmptyOrchestrationEnduranceSummary
    }

    $Passed = ($null -eq $FailureReason)

    Write-Host (
        "ROLE_AWARE_RESULT label=" +
        $Label +
        " workload=" +
        $Workload +
        " pass=" +
        $Passed +
        " wall=" +
        $WallSeconds.ToString(
            "F3",
            [System.Globalization.CultureInfo]::InvariantCulture
        ) +
        "s prompt_max_thoughts=" +
        $Telemetry.PromptMaxThoughts +
        " algorithm_max_thoughts=" +
        $Telemetry.AlgorithmMaxThoughts +
        " test_max_thoughts=" +
        $Telemetry.TestMaxThoughts +
        " growth_limit=" +
        $Telemetry.GrowthLimitCount +
        " max_tokens=" +
        $Telemetry.MaxTokensCount +
        " no_visible_progress=" +
        $Telemetry.NoVisibleProgressCount +
        " prompt_sum_thoughts=" +
        $Telemetry.PromptSumThoughts +
        " algorithm_sum_thoughts=" +
        $Telemetry.AlgorithmSumThoughts +
        " test_sum_thoughts=" +
        $Telemetry.TestSumThoughts +
        " api_responses=" +
        $Telemetry.ApiResponses +
        " tool_calls=" +
        $Telemetry.ToolCalls +
        " partial_side_effects=" +
        $Telemetry.PartialSideEffectsCount +
        " compaction_passes=" +
        $Telemetry.CompactionPassCount +
        " rollover_required=" +
        $Telemetry.ContextRolloverRequiredCount +
        " rollover_completed=" +
        $Telemetry.ContextRolloverCompletedCount +
        " compaction_no_progress=" +
        $Telemetry.ContextCompactionNoProgressCount +
        " context_high_watermark=" +
        $Telemetry.ContextHighWatermarkTokens +
        " post_compaction_max=" +
        $Telemetry.ContextPostCompactionMaxTokens +
        " extended_pass=" +
        ($ExtendedTestExitCode -eq 0)
    )

    if ($script:CollectOrchestrationEnduranceEvidence) {
        Write-Host (
            "ROLE_AWARE_ORCHESTRATION label=" +
            $Label +
            " session=" +
            $Endurance.MainSessionId +
            " growth_results=" +
            $Endurance.GrowthLimitResultCount +
            " recovery_reread_cycles=" +
            $Endurance.RecoveryRereadCycleCount +
            " recovery_rejections=" +
            $Endurance.RecoveryGuardRejectionCount +
            " successful_algorithm_after_growth=" +
            $Endurance.SuccessfulAlgorithmAfterGrowthCount +
            " test_after_last_algorithm=" +
            $Endurance.TestAfterLastAlgorithm +
            " compressions=" +
            $Endurance.ChatCompressionCount +
            " compression_gaps=" +
            $Endurance.CompressionContinuationGapCount +
            " top_final_after_last_tool=" +
            $Endurance.TopLevelFinalAfterLastTool +
            " terminal_stop=" +
            $Endurance.TerminalStopCount +
            " hook_errors=" +
            $Endurance.HookErrorCount +
            " runtime_fatal=" +
            $Endurance.RuntimeFatalErrorCount
        )
    }

    if (-not $Passed) {
        Write-Host (
            "ROLE_AWARE_FAILURE label=" +
            $Label +
            " reason=" +
            $FailureReason
        )

        if ($QwenOutput.Length -gt 0) {
            $TailLength = [Math]::Min(2000,$QwenOutput.Length)
            Write-Host (
                $QwenOutput.Substring(
                    $QwenOutput.Length - $TailLength,
                    $TailLength
                )
            )
        }

        if ($TestOutput.Length -gt 0) {
            Write-Host "=== CORE BLOCKING TEST OUTPUT TAIL ==="
            $TestTailLength = [Math]::Min(4000,$TestOutput.Length)
            Write-Host (
                $TestOutput.Substring(
                    $TestOutput.Length - $TestTailLength,
                    $TestTailLength
                )
            )
        }
    }

    if (
        $Workload -eq "STRESS" -and
        $ExtendedTestExitCode -ne 0
    ) {
        Write-Host (
            "EXTENDED_NON_BLOCKING_RESULT label=" +
            $Label +
            " pass=False exit=" +
            $ExtendedTestExitCode
        )

        if ($ExtendedTestOutput.Length -gt 0) {
            $ExtendedTailLength = [Math]::Min(
                4000,
                $ExtendedTestOutput.Length
            )
            Write-Host "=== EXTENDED NON-BLOCKING TEST OUTPUT TAIL ==="
            Write-Host (
                $ExtendedTestOutput.Substring(
                    $ExtendedTestOutput.Length - $ExtendedTailLength,
                    $ExtendedTailLength
                )
            )
        }
    }
    elseif ($Workload -eq "STRESS") {
        Write-Host (
            "EXTENDED_NON_BLOCKING_RESULT label=" +
            $Label +
            " pass=True exit=0"
        )
    }

    Assert-BenchmarkIdle

    return [pscustomobject]@{
        Pass = $Passed
        Reason = $FailureReason
        Workload = $Workload
        WallSeconds = $WallSeconds
        PromptResponses = $Telemetry.PromptResponses
        AlgorithmResponses = $Telemetry.AlgorithmResponses
        TestResponses = $Telemetry.TestResponses
        PromptMaxThoughts = $Telemetry.PromptMaxThoughts
        AlgorithmMaxThoughts = $Telemetry.AlgorithmMaxThoughts
        TestMaxThoughts = $Telemetry.TestMaxThoughts
        PromptSumThoughts = $Telemetry.PromptSumThoughts
        AlgorithmSumThoughts = $Telemetry.AlgorithmSumThoughts
        TestSumThoughts = $Telemetry.TestSumThoughts
        ApiResponses = $Telemetry.ApiResponses
        ToolCalls = $Telemetry.ToolCalls
        GrowthLimitCount = $Telemetry.GrowthLimitCount
        MaxTokensCount = $Telemetry.MaxTokensCount
        NoVisibleProgressCount = $Telemetry.NoVisibleProgressCount
        PartialSideEffectsCount = $Telemetry.PartialSideEffectsCount
        CompactionPassCount = $Telemetry.CompactionPassCount
        ContextRolloverRequiredCount = $Telemetry.ContextRolloverRequiredCount
        ContextRolloverCompletedCount = $Telemetry.ContextRolloverCompletedCount
        ContextCompactionNoProgressCount = $Telemetry.ContextCompactionNoProgressCount
        ContextHighWatermarkTokens = $Telemetry.ContextHighWatermarkTokens
        ContextPostCompactionMaxTokens = $Telemetry.ContextPostCompactionMaxTokens
        QwenExitCode = $QwenExitCode
        ExternalTestExitCode = $TestExitCode
        CoreTestExitCode = $TestExitCode
        ExtendedTestExitCode = $ExtendedTestExitCode
        ExtendedPass = ($ExtendedTestExitCode -eq 0)
        EnduranceMainSessionId = $Endurance.MainSessionId
        EnduranceChatCompressionCount = $Endurance.ChatCompressionCount
        EnduranceCompressionContinuationGapCount = $Endurance.CompressionContinuationGapCount
        EnduranceGrowthLimitResultCount = $Endurance.GrowthLimitResultCount
        EnduranceRecoveryAuthoritativeStateCount = $Endurance.RecoveryAuthoritativeStateCount
        EnduranceRecoveryGuardRejectionCount = $Endurance.RecoveryGuardRejectionCount
        EnduranceRecoveryRereadCycleCount = $Endurance.RecoveryRereadCycleCount
        EnduranceSuccessfulAlgorithmAfterGrowthCount = $Endurance.SuccessfulAlgorithmAfterGrowthCount
        EnduranceAlgorithmResultCount = $Endurance.AlgorithmResultCount
        EnduranceTestAgentResultCount = $Endurance.TestAgentResultCount
        EnduranceTestAfterLastAlgorithm = $Endurance.TestAfterLastAlgorithm
        EnduranceTopLevelFinalCount = $Endurance.TopLevelFinalCount
        EnduranceTopLevelFinalAfterLastTool = $Endurance.TopLevelFinalAfterLastTool
        EnduranceTerminalTraceFound = $Endurance.TerminalTraceFound
        EnduranceTerminalTraceEventCount = $Endurance.TerminalTraceEventCount
        EnduranceTerminalStopCount = $Endurance.TerminalStopCount
        EnduranceLastPreAgentGuardActive = $Endurance.LastPreAgentGuardActive
        EnduranceLastPreAgentRecoveryRequired = $Endurance.LastPreAgentRecoveryRequired
        EnduranceTurnClosedAtStop = $Endurance.TurnClosedAtStop
        EnduranceTerminalAbortObserved = $Endurance.TerminalAbortObserved
        EnduranceHookErrorCount = $Endurance.HookErrorCount
        EnduranceRuntimeFatalErrorCount = $Endurance.RuntimeFatalErrorCount
    }
}


function Invoke-OrchestrationEnduranceSelfTest {
    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("qwen-orchestration-endurance-selftest-" + [Guid]::NewGuid().ToString("N"))

    Assert-LocalTree $TempRoot
    [void](New-Item -ItemType Directory -Path $TempRoot -Force)

    $JsonlPath = Join-Path $TempRoot "fixture.jsonl"
    $TracePath = Join-Path $TempRoot "terminal-trace.jsonl"
    $HookPath = Join-Path $TempRoot "hook-errors.log"

    $Fixture = @'
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:00.000Z","type":"system","provenance":"system","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-01-01T00:00:00.000Z","prompt_id":"selftest-session########0"}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:01.000Z","type":"system","provenance":"system","subtype":"chat_compression","systemPayload":{"info":{"originalTokenCount":30000,"newTokenCount":18000}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:02.000Z","type":"system","provenance":"system","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-01-01T00:00:02.000Z","prompt_id":"selftest-session########0"}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:03.000Z","type":"tool_result","provenance":"tool_result","toolCallResult":{"resultDisplay":{"subagentName":"algorithm-agent","terminateReason":"GROWTH_LIMIT"}},"message":{"role":"user","parts":[{"functionResponse":{"name":"agent","response":{"output":"Agent stopped: per-turn context growth limit reached. Partial side effects are possible."}}}]}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:04.000Z","type":"system","provenance":"system","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.tool_call","event.timestamp":"2026-01-01T00:00:04.000Z","prompt_id":"selftest-session########0","function_name":"read_file","function_args":{"file_path":"export_cookies.py"}}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:05.000Z","type":"tool_result","provenance":"tool_result","message":{"role":"user","parts":[{"functionResponse":{"name":"agent","response":{"error":"rejected AUTHORITATIVE_GROWTH_RECOVERY_STATE={\"generation\":1}"}}}]}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:06.000Z","type":"system","provenance":"system","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.tool_call","event.timestamp":"2026-01-01T00:00:06.000Z","prompt_id":"selftest-session########0","function_name":"agent","function_args":{"subagent_type":"algorithm-agent"}}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:07.000Z","type":"tool_result","provenance":"tool_result","toolCallResult":{"resultDisplay":{"subagentName":"algorithm-agent","terminateReason":"GOAL"}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:08.000Z","type":"system","provenance":"system","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.tool_call","event.timestamp":"2026-01-01T00:00:08.000Z","prompt_id":"selftest-session########0","function_name":"agent","function_args":{"subagent_type":"test-agent"}}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:09.000Z","type":"tool_result","provenance":"tool_result","toolCallResult":{"resultDisplay":{"subagentName":"test-agent","terminateReason":"GOAL"}}}
{"sessionId":"selftest-session","timestamp":"2026-01-01T00:00:10.000Z","type":"assistant","provenance":"assistant_output","model":"qwen3.8-27b-local","message":{"role":"model","parts":[{"text":"PASS"}]}}
'@

    $TraceFixture = @'
{"timestamp":"2026-01-01T00:00:03.500Z","session_id":"selftest-session","event":"PreToolUse","tool":"agent","growth_recovery_required":true,"growth_recovery_guard_active":true,"turn_closed":false,"terminal_abort_reason":null}
{"timestamp":"2026-01-01T00:00:07.500Z","session_id":"selftest-session","event":"PreToolUse","tool":"agent","growth_recovery_required":false,"growth_recovery_guard_active":false,"turn_closed":false,"terminal_abort_reason":null}
{"timestamp":"2026-01-01T00:00:10.500Z","session_id":"selftest-session","event":"Stop","tool":"","growth_recovery_required":false,"growth_recovery_guard_active":false,"turn_closed":false,"terminal_abort_reason":null}
'@

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    try {
        Assert-LocalPath $JsonlPath
        [System.IO.File]::WriteAllText(
            $JsonlPath,
            $Fixture,
            $Utf8NoBom
        )

        Assert-LocalPath $TracePath
        [System.IO.File]::WriteAllText(
            $TracePath,
            $TraceFixture,
            $Utf8NoBom
        )

        Assert-LocalPath $HookPath
        [System.IO.File]::WriteAllText(
            $HookPath,
            "",
            $Utf8NoBom
        )

        $File = Get-Item -LiteralPath $JsonlPath

        $Summary = Get-OrchestrationEnduranceSummary `
            -Files @($File) `
            -QwenOutput "normal completion" `
            -TerminalTracePath $TracePath `
            -HookErrorsPath $HookPath

        $Checks = [ordered]@{
            MAIN_SESSION = ($Summary.MainSessionId -eq "selftest-session")
            COMPACTION_COUNT = ($Summary.ChatCompressionCount -eq 1)
            COMPACTION_CONTINUATION = ($Summary.CompressionContinuationGapCount -eq 0)
            GROWTH_RESULT = ($Summary.GrowthLimitResultCount -eq 1)
            RECOVERY_REREAD = ($Summary.RecoveryRereadCycleCount -eq 1)
            RECOVERY_REJECTION = ($Summary.RecoveryGuardRejectionCount -eq 1)
            AUTHORITATIVE_STATE = ($Summary.RecoveryAuthoritativeStateCount -eq 1)
            RESIDUAL_ALGORITHM = ($Summary.SuccessfulAlgorithmAfterGrowthCount -eq 1)
            TEST_ORDER = ([bool]$Summary.TestAfterLastAlgorithm)
            TOP_LEVEL_FINAL = ([bool]$Summary.TopLevelFinalAfterLastTool)
            TERMINAL_TRACE = ([bool]$Summary.TerminalTraceFound)
            TERMINAL_STOP = ($Summary.TerminalStopCount -eq 1)
            GUARD_CLEARED = (-not [bool]$Summary.LastPreAgentGuardActive)
            RECOVERY_CLEARED = (-not [bool]$Summary.LastPreAgentRecoveryRequired)
            TERMINAL_ABORT_NONE = (-not [bool]$Summary.TerminalAbortObserved)
            HOOK_ERRORS_NONE = ($Summary.HookErrorCount -eq 0)
            RUNTIME_FATAL_NONE = ($Summary.RuntimeFatalErrorCount -eq 0)
        }

        $Failed = @()

        foreach ($Check in $Checks.GetEnumerator()) {
            Write-Host (
                "ORCHESTRATION_ENDURANCE_SELFTEST_" +
                $Check.Key +
                "=" +
                (Get-PassFail -Value ([bool]$Check.Value))
            )

            if (-not [bool]$Check.Value) {
                $Failed += $Check.Key
            }
        }

        if ($Failed.Count -gt 0) {
            throw (
                "ORCHESTRATION_ENDURANCE_SELFTEST_FAILED=" +
                ($Failed -join ",")
            )
        }

        Write-Host "ORCHESTRATION_ENDURANCE_SELFTEST=PASS"
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) {
            Assert-LocalTree $TempRoot
            Remove-Item `
                -LiteralPath $TempRoot `
                -Recurse `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-OrchestrationEnduranceStress {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-BenchmarkIdle

    $Config = Copy-BenchmarkParameters -Parameters $Parameters

    if ($ConfirmPromptReasoningBudget -gt 0) {
        $Config["prompt-reasoning-budget"] = [string]$ConfirmPromptReasoningBudget
    }

    if ($ConfirmAlgorithmReasoningBudget -gt 0) {
        $Config["algorithm-reasoning-budget"] = [string]$ConfirmAlgorithmReasoningBudget
    }

    if ($ConfirmTestReasoningBudget -gt 0) {
        $Config["test-reasoning-budget"] = [string]$ConfirmTestReasoningBudget
    }

    if ($ConfirmGrowthBudget -gt 0) {
        $Config["max-context-growth-tokens-per-turn"] = [string]$ConfirmGrowthBudget
    }

    $LocalConfigShaBefore = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaBefore = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $PersistentRoot = Join-Path `
        (Join-Path $QwenRoot ".localai\results") `
        "orchestration-endurance"

    $RunDirectory = Join-Path `
        $PersistentRoot `
        (Get-Date -Format "yyyyMMdd-HHmmss")

    Assert-LocalTree $RunDirectory
    [void](New-Item -ItemType Directory -Path $RunDirectory -Force)

    Write-Host ""
    Write-Host "========================================"
    Write-Host " ORCHESTRATION ENDURANCE STRESS"
    Write-Host "========================================"
    Write-Host "SCOPE=ROLE_ROUTING_GROWTH_RECOVERY_COMPACTION_TERMINAL_COMPLETION"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "ROLLOVER_DYNAMIC_EXERCISE=NON_BLOCKING"
    Write-Host "TEMP_WORKSPACE=SYSTEM_TEMP_CLEANED"
    Write-Host ("PERSISTENT_EVIDENCE_DIR=" + $RunDirectory)
    Write-Host (
        "ENDURANCE_CONFIG prompt=" +
        $Config["prompt-reasoning-budget"] +
        " algorithm=" +
        $Config["algorithm-reasoning-budget"] +
        " test=" +
        $Config["test-reasoning-budget"] +
        " growth=" +
        $Config["max-context-growth-tokens-per-turn"] +
        " context=" +
        $Config["ctx-size"]
    )

    $script:CollectOrchestrationEnduranceEvidence = $true
    $script:OrchestrationEnduranceArtifactDirectory = $RunDirectory

    try {
        $Measurement = Invoke-RoleAwareAgentMeasurement `
            -Parameters $Config `
            -Label "orchestration_endurance" `
            -Workload "STRESS"
    }
    finally {
        $script:CollectOrchestrationEnduranceEvidence = $false
        $script:OrchestrationEnduranceArtifactDirectory = $null
    }

    $FailureReasons = New-Object `
        "System.Collections.Generic.List[string]"

    if (-not $Measurement.Pass) {
        $FailureReasons.Add(
            "ROLE_AWARE_MEASUREMENT_FAILED=" + $Measurement.Reason
        )
    }

    if (-not [bool]$Measurement.EnduranceTopLevelFinalAfterLastTool) {
        $FailureReasons.Add("TOP_LEVEL_FINAL_AFTER_LAST_TOOL=FAIL")
    }

    if (-not [bool]$Measurement.EnduranceTestAfterLastAlgorithm) {
        $FailureReasons.Add("TEST_AFTER_LAST_ALGORITHM=FAIL")
    }

    if ($Measurement.EnduranceCompressionContinuationGapCount -gt 0) {
        $FailureReasons.Add(
            "COMPACTION_CONTINUATION_GAPS=" +
            $Measurement.EnduranceCompressionContinuationGapCount
        )
    }

    if ($Measurement.EnduranceHookErrorCount -gt 0) {
        $FailureReasons.Add(
            "HOOK_ERRORS=" +
            $Measurement.EnduranceHookErrorCount
        )
    }

    if ($Measurement.EnduranceRuntimeFatalErrorCount -gt 0) {
        $FailureReasons.Add(
            "RUNTIME_FATAL_ERRORS=" +
            $Measurement.EnduranceRuntimeFatalErrorCount
        )
    }

    if ([bool]$Measurement.EnduranceTerminalAbortObserved) {
        $FailureReasons.Add("TERMINAL_ABORT_OBSERVED=YES")
    }

    $RecoveryStatus = "NOT_EXERCISED_NON_BLOCKING"

    if ($Measurement.EnduranceGrowthLimitResultCount -gt 0) {
        $RecoveryStatus = "PASS"

        if (
            $Measurement.EnduranceRecoveryRereadCycleCount -lt
            $Measurement.EnduranceGrowthLimitResultCount
        ) {
            $RecoveryStatus = "FAIL"
            $FailureReasons.Add(
                "RECOVERY_REREAD_CYCLES=" +
                $Measurement.EnduranceRecoveryRereadCycleCount +
                "/" +
                $Measurement.EnduranceGrowthLimitResultCount
            )
        }

        if (
            $Measurement.EnduranceSuccessfulAlgorithmAfterGrowthCount -lt 1
        ) {
            $RecoveryStatus = "FAIL"
            $FailureReasons.Add("RESIDUAL_ALGORITHM_AFTER_GROWTH=0")
        }

        if (
            $Measurement.EnduranceRecoveryGuardRejectionCount -gt 3
        ) {
            $RecoveryStatus = "FAIL"
            $FailureReasons.Add(
                "RECOVERY_GUARD_REJECTION_LOOP_RISK=" +
                $Measurement.EnduranceRecoveryGuardRejectionCount
            )
        }

        if ([bool]$Measurement.EnduranceTerminalTraceFound) {
            if ([bool]$Measurement.EnduranceLastPreAgentGuardActive) {
                $RecoveryStatus = "FAIL"
                $FailureReasons.Add("RECOVERY_GUARD_NOT_CLEARED_BEFORE_FINAL_SPECIALIST")
            }

            if ([bool]$Measurement.EnduranceLastPreAgentRecoveryRequired) {
                $RecoveryStatus = "FAIL"
                $FailureReasons.Add("RECOVERY_REQUIRED_NOT_CLEARED_BEFORE_FINAL_SPECIALIST")
            }
        }
    }

    $CompactionStatus = "NOT_EXERCISED_NON_BLOCKING"

    if ($Measurement.EnduranceChatCompressionCount -gt 0) {
        if ($Measurement.EnduranceCompressionContinuationGapCount -eq 0) {
            $CompactionStatus = "PASS"
        }
        else {
            $CompactionStatus = "FAIL"
        }
    }

    $RolloverStatus = "NOT_EXERCISED_NON_BLOCKING"

    if ($Measurement.ContextRolloverRequiredCount -gt 0) {
        if ($Measurement.ContextRolloverCompletedCount -gt 0) {
            $RolloverStatus = "PASS"
        }
        else {
            $RolloverStatus = "FAIL"
            $FailureReasons.Add("ROLLOVER_REQUIRED_WITHOUT_COMPLETION")
        }
    }

    $LocalConfigShaAfter = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAfter = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($LocalConfigShaAfter -ne $LocalConfigShaBefore) {
        $FailureReasons.Add("PRODUCTION_LOCAL_CONFIG_CHANGED")
    }

    if ($SettingsShaAfter -ne $SettingsShaBefore) {
        $FailureReasons.Add("PRODUCTION_SETTINGS_CHANGED")
    }

    $Overall = "PASS"

    if ($FailureReasons.Count -gt 0) {
        $Overall = "FAIL"
    }

    $TurnClosedTrace = "UNAVAILABLE"

    if ($null -ne $Measurement.EnduranceTurnClosedAtStop) {
        $TurnClosedTrace = [string]$Measurement.EnduranceTurnClosedAtStop
    }

    $LastPreAgentGuard = "UNAVAILABLE"
    $LastPreAgentRequired = "UNAVAILABLE"

    if ([bool]$Measurement.EnduranceTerminalTraceFound) {
        $LastPreAgentGuard = [string]$Measurement.EnduranceLastPreAgentGuardActive
        $LastPreAgentRequired = [string]$Measurement.EnduranceLastPreAgentRecoveryRequired
    }

    $ReportLines = @(
        "LOCALAI ORCHESTRATION ENDURANCE BENCHMARK REPORT",
        ("CREATED=" + (Get-Date).ToString("o")),
        ("BENCHMARK_VERSION=" + $ScriptVersion),
        ("RESULT=" + $Overall),
        ("REPORT_DIR=" + $RunDirectory),
        ("PROMPT_REASONING_BUDGET=" + $Config["prompt-reasoning-budget"]),
        ("ALGORITHM_REASONING_BUDGET=" + $Config["algorithm-reasoning-budget"]),
        ("TEST_REASONING_BUDGET=" + $Config["test-reasoning-budget"]),
        ("MAX_CONTEXT_GROWTH_TOKENS_PER_TURN=" + $Config["max-context-growth-tokens-per-turn"]),
        ("CONTEXT_WINDOW=" + $Config["ctx-size"]),
        "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED",
        ("ROLE_AWARE_PASS=" + $Measurement.Pass),
        ("CORE_TEST_EXIT_CODE=" + $Measurement.CoreTestExitCode),
        ("EXTENDED_TEST_EXIT_CODE=" + $Measurement.ExtendedTestExitCode),
        ("WALL_SECONDS=" + $Measurement.WallSeconds.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture)),
        ("API_RESPONSES=" + $Measurement.ApiResponses),
        ("TOOL_CALLS=" + $Measurement.ToolCalls),
        ("MAX_TOKENS=" + $Measurement.MaxTokensCount),
        ("NO_VISIBLE_PROGRESS=" + $Measurement.NoVisibleProgressCount),
        ("GROWTH_LIMIT_TELEMETRY=" + $Measurement.GrowthLimitCount),
        ("GROWTH_LIMIT_RESULT_COUNT=" + $Measurement.EnduranceGrowthLimitResultCount),
        ("RECOVERY_DYNAMIC_STATUS=" + $RecoveryStatus),
        ("RECOVERY_REREAD_CYCLES=" + $Measurement.EnduranceRecoveryRereadCycleCount),
        ("RECOVERY_GUARD_REJECTIONS=" + $Measurement.EnduranceRecoveryGuardRejectionCount),
        ("AUTHORITATIVE_RECOVERY_STATE_RESPONSES=" + $Measurement.EnduranceRecoveryAuthoritativeStateCount),
        ("SUCCESSFUL_ALGORITHM_AFTER_GROWTH=" + $Measurement.EnduranceSuccessfulAlgorithmAfterGrowthCount),
        ("ALGORITHM_RESULT_COUNT=" + $Measurement.EnduranceAlgorithmResultCount),
        ("TEST_AGENT_RESULT_COUNT=" + $Measurement.EnduranceTestAgentResultCount),
        ("TEST_AFTER_LAST_ALGORITHM=" + $Measurement.EnduranceTestAfterLastAlgorithm),
        ("TOP_LEVEL_FINAL_COUNT=" + $Measurement.EnduranceTopLevelFinalCount),
        ("TOP_LEVEL_FINAL_AFTER_LAST_TOOL=" + $Measurement.EnduranceTopLevelFinalAfterLastTool),
        ("CHAT_COMPRESSION_COUNT=" + $Measurement.EnduranceChatCompressionCount),
        ("COMPACTION_STATUS=" + $CompactionStatus),
        ("COMPACTION_CONTINUATION_GAPS=" + $Measurement.EnduranceCompressionContinuationGapCount),
        ("ROLLOVER_REQUIRED=" + $Measurement.ContextRolloverRequiredCount),
        ("ROLLOVER_COMPLETED=" + $Measurement.ContextRolloverCompletedCount),
        ("ROLLOVER_STATUS=" + $RolloverStatus),
        ("TERMINAL_TRACE_FOUND=" + $Measurement.EnduranceTerminalTraceFound),
        ("TERMINAL_TRACE_EVENTS=" + $Measurement.EnduranceTerminalTraceEventCount),
        ("TERMINAL_STOP_COUNT=" + $Measurement.EnduranceTerminalStopCount),
        ("LAST_PRE_AGENT_GUARD_ACTIVE=" + $LastPreAgentGuard),
        ("LAST_PRE_AGENT_RECOVERY_REQUIRED=" + $LastPreAgentRequired),
        ("TURN_CLOSED_AT_STOP_TRACE_RAW=" + $TurnClosedTrace),
        "TURN_CLOSED_AT_STOP_TRACE_POLICY=OBSERVABILITY_ONLY_NOT_BLOCKING",
        ("TERMINAL_ABORT_OBSERVED=" + $Measurement.EnduranceTerminalAbortObserved),
        ("HOOK_ERROR_COUNT=" + $Measurement.EnduranceHookErrorCount),
        ("RUNTIME_FATAL_ERROR_COUNT=" + $Measurement.EnduranceRuntimeFatalErrorCount),
        ("PRODUCTION_LOCAL_CONFIG_CHANGED=" + ($LocalConfigShaAfter -ne $LocalConfigShaBefore)),
        ("PRODUCTION_SETTINGS_CHANGED=" + ($SettingsShaAfter -ne $SettingsShaBefore)),
        "PRODUCTION_CONFIG_MODIFIED=NO",
        "TEMP_WORKSPACE_POLICY=SYSTEM_TEMP_AND_NEW_QWEN_PROJECT_DIRS_CLEANED",
        "PERSISTENT_EVIDENCE_POLICY=DESKTOP_LOCALAI_TESTS",
        ("FAILURE_COUNT=" + $FailureReasons.Count)
    )

    foreach ($Reason in $FailureReasons) {
        $ReportLines += ("FAILURE=" + $Reason)
    }

    $ReportPath = Join-Path `
        $RunDirectory `
        "ORCHESTRATION_ENDURANCE_REPORT.txt"

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath $ReportPath
    [System.IO.File]::WriteAllLines(
        $ReportPath,
        $ReportLines,
        $Utf8NoBom
    )

    foreach ($Line in $ReportLines) {
        Write-Host $Line
    }

    Write-Host ("RETURN_FILE=" + $ReportPath)
    Write-Host "RETURN_TO_CHAT=FILE_REQUIRED"

    if ($FailureReasons.Count -gt 0) {
        throw (
            "ORCHESTRATION_ENDURANCE_STRESS_FAILED: " +
            ($FailureReasons -join "; ")
        )
    }

    Write-Host "ORCHESTRATION_ENDURANCE_STRESS=PASS"
}

function Get-RoleBudgetKey {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("PROMPT","ALGORITHM","TEST")]
        [string]$Role
    )

    switch ($Role) {
        "PROMPT" { return "prompt-reasoning-budget" }
        "ALGORITHM" { return "algorithm-reasoning-budget" }
        "TEST" { return "test-reasoning-budget" }
    }
}

function Get-RoleMaxThoughts {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Measurement,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PROMPT","ALGORITHM","TEST")]
        [string]$Role
    )

    $Name = (
        $Role.Substring(0,1) +
        $Role.Substring(1).ToLowerInvariant() +
        "MaxThoughts"
    )

    return [int]$Measurement.PSObject.Properties[$Name].Value
}


# =============================================================================
# BENCHMARK MODULE: convergent reasoning / growth planner
# =============================================================================

$script:AdaptiveStressCache = @{}
$script:AdaptiveStressEvidence = @()
$script:AdaptiveStressSessionCount = 0
$script:AutotuneSeedPlatformFingerprint = $null
$script:AgenticCheckpointRunFingerprint = $null
$script:AgenticCheckpointResumed = $false
$script:AgenticCheckpointPath = Join-Path `
    $RepoRoot `
    ".localai\benchmark-state\agentic-autotune-checkpoint.json"

function Reset-AdaptiveStressPlannerState {
    $script:AdaptiveStressCache = @{}
    $script:AdaptiveStressEvidence = @()
    $script:AdaptiveStressSessionCount = 0
    $script:AgenticCheckpointRunFingerprint = $null
    $script:AgenticCheckpointResumed = $false
}

function Get-AdaptiveConfigFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $Keys = @(
        "ctx-size",
        "spec-draft-p-min",
        "spec-ngram-mod-n-min",
        "spec-ngram-mod-n-max",
        "spec-ngram-mod-n-match",
        "cache-type-k",
        "cache-type-v",
        "prompt-reasoning-budget",
        "algorithm-reasoning-budget",
        "test-reasoning-budget",
        "max-context-growth-tokens-per-turn"
    )

    $Parts = @()

    foreach ($Key in $Keys) {
        $Parts += ($Key + "=" + [string]$Parameters[$Key])
    }

    return ($Parts -join ";")
}

function Get-AdaptivePlatformFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $Keys = @(
        "ctx-size",
        "spec-draft-p-min",
        "spec-ngram-mod-n-min",
        "spec-ngram-mod-n-max",
        "spec-ngram-mod-n-match",
        "cache-type-k",
        "cache-type-v"
    )

    $Parts = @()

    foreach ($Key in $Keys) {
        $Parts += ($Key + "=" + [string]$Parameters[$Key])
    }

    return ($Parts -join ";")
}

function Initialize-AutotuneSeedPlatformFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $script:AutotuneSeedPlatformFingerprint = (
        Get-AdaptivePlatformFingerprint `
            -Parameters $Parameters
    )

    return [string]$script:AutotuneSeedPlatformFingerprint
}

function Get-AdaptiveFailureClass {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Measurement
    )

    if ($Measurement.Pass) {
        return "PASS"
    }

    $Reason = [string]$Measurement.Reason

    if ($Reason -match "^QWEN_EXIT_CODE_55$") {
        return "TIMEOUT"
    }

    if (
        $Reason -match "^(EXTERNAL_TEST_EXIT_CODE_|CORE_TEST_EXIT_CODE_)" -or
        $Reason -eq "PROTECTED_TEST_MODIFIED" -or
        $Reason -eq "NO_VISIBLE_PROGRESS_OBSERVED"
    ) {
        return "QUALITY"
    }

    if ($Reason -eq "MAX_TOKENS_OBSERVED") {
        return "REASONING_PRESSURE"
    }

    if (
        $Reason -match "PROMPT_ROLE_NOT_OBSERVED|ALGORITHM_ROLE_NOT_OBSERVED|TEST_ROLE_NOT_OBSERVED|ROLE_TELEMETRY_JSONL_MISSING"
    ) {
        return "HARNESS"
    }

    if (
        $Reason -match "(?i)(out of memory|cuda.*memory|vram|allocation failed|failed to allocate|ggml.*memory)"
    ) {
        return "HARDWARE_CAPACITY"
    }

    if (
        $Reason -match "BENCHMARK_ROUTER_READY_TIMEOUT|ROLE_AWARE_ROUTER_START|PORT_NOT_FREE"
    ) {
        return "ENVIRONMENT"
    }

    return "EXECUTION"
}

function Get-AdaptiveBudgetMidpoint {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Lower,

        [Parameter(Mandatory = $true)]
        [int]$Upper,

        [int]$Quantum = 512
    )

    if (($Upper - $Lower) -le $Quantum) {
        return $null
    }

    $Midpoint = Round-BenchmarkIntegerCandidate `
        -Value (($Lower + $Upper) / 2.0) `
        -Quantum $Quantum `
        -Minimum ($Lower + $Quantum) `
        -Maximum ($Upper - $Quantum)

    if (
        $Midpoint -le $Lower -or
        $Midpoint -ge $Upper
    ) {
        return $null
    }

    return $Midpoint
}

function Get-RoleReductionCandidate {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$ObservedMax
    )

    if ($Current -le 1024) {
        return $Current
    }

    $Target = [Math]::Max(
        $Current * 0.50,
        $ObservedMax * 1.50
    )

    $Candidate = Round-BenchmarkIntegerCandidate `
        -Value $Target `
        -Quantum 512 `
        -Minimum 1024 `
        -Maximum $Current

    if ($Candidate -ge $Current) {
        return $Current
    }

    return $Candidate
}

function Get-AgenticRuntimeFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $ServerItem = Get-Item -LiteralPath $ServerExe -ErrorAction Stop
    $ModelItem = Get-Item -LiteralPath $ModelPath -ErrorAction Stop
    $GpuIdentity = "GPU_QUERY_UNAVAILABLE"

    $NvidiaSmi = (
        Get-Command `
            nvidia-smi.exe `
            -CommandType Application `
            -ErrorAction SilentlyContinue |
        Select-Object -First 1
    )

    if ($null -ne $NvidiaSmi) {
        $OldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $GpuOutput = @(
                & $NvidiaSmi.Source `
                    --query-gpu=name,memory.total,driver_version `
                    --format=csv,noheader,nounits `
                    2>&1
            )
            if ($LASTEXITCODE -eq 0) {
                $GpuIdentity = (($GpuOutput | ForEach-Object {
                    ([string]$_).Trim()
                }) -join "|")
            }
        }
        finally {
            $ErrorActionPreference = $OldPreference
        }
    }

    $Raw = (
        "version=" + $ScriptVersion +
        ";platform=" +
        (Get-AdaptivePlatformFingerprint -Parameters $Parameters) +
        ";prompt=" + [string]$Parameters["prompt-reasoning-budget"] +
        ";algorithm=" + [string]$Parameters["algorithm-reasoning-budget"] +
        ";test=" + [string]$Parameters["test-reasoning-budget"] +
        ";growth=" + [string]$Parameters["max-context-growth-tokens-per-turn"] +
        ";stress_wall=" + [string]$StressMaxWallTimeMinutes +
        ";server_len=" + [string]$ServerItem.Length +
        ";server_mtime=" + $ServerItem.LastWriteTimeUtc.Ticks +
        ";model_len=" + [string]$ModelItem.Length +
        ";model_mtime=" + $ModelItem.LastWriteTimeUtc.Ticks +
        ";gpu=" + $GpuIdentity
    )

    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Raw)
    $Hasher = [System.Security.Cryptography.SHA256]::Create()
    try {
        $HashBytes = $Hasher.ComputeHash($Bytes)
    }
    finally {
        $Hasher.Dispose()
    }

    return (
        [System.BitConverter]::ToString($HashBytes).Replace("-","")
    )
}

function ConvertTo-AdaptiveCheckpointConfig {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Object
    )

    $Config = [ordered]@{}
    foreach ($Property in $Object.PSObject.Properties) {
        $Config[$Property.Name] = [string]$Property.Value
    }
    return $Config
}

function Initialize-AgenticAutotuneCheckpoint {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $script:AgenticCheckpointRunFingerprint = (
        Get-AgenticRuntimeFingerprint -Parameters $Parameters
    )

    Write-Host (
        "AGENTIC_CHECKPOINT_RUN_FINGERPRINT=" +
        $script:AgenticCheckpointRunFingerprint
    )

    if (-not (Test-Path -LiteralPath $script:AgenticCheckpointPath -PathType Leaf)) {
        Write-Host "AGENTIC_CHECKPOINT_RESUME=NO reason=ABSENT"
        return
    }

    try {
        $Checkpoint = Get-Content `
            -LiteralPath $script:AgenticCheckpointPath `
            -Raw `
            -Encoding UTF8 |
            ConvertFrom-Json
    }
    catch {
        Write-Host "AGENTIC_CHECKPOINT_RESUME=NO reason=INVALID_JSON"
        return
    }

    if (
        [string]$Checkpoint.RunFingerprint -ne
        [string]$script:AgenticCheckpointRunFingerprint
    ) {
        Write-Host "AGENTIC_CHECKPOINT_RESUME=NO reason=FINGERPRINT_MISMATCH"
        return
    }

    if ([bool]$Checkpoint.Completed) {
        Write-Host "AGENTIC_CHECKPOINT_RESUME=NO reason=PREVIOUS_RUN_COMPLETED"
        return
    }

    $Loaded = 0
    foreach ($Entry in @($Checkpoint.Evidence)) {
        if ($null -eq $Entry) {
            continue
        }

        $Config = ConvertTo-AdaptiveCheckpointConfig -Object $Entry.Config
        $Measurement = $Entry.Measurement
        $Fingerprint = Get-AdaptiveConfigFingerprint -Parameters $Config

        $script:AdaptiveStressEvidence += [pscustomobject]@{
            Label = [string]$Entry.Label
            Fingerprint = $Fingerprint
            Config = $Config
            Measurement = $Measurement
        }

        $script:AdaptiveStressCache[$Fingerprint] = $Measurement
        $Loaded++
    }

    $script:AdaptiveStressSessionCount = $Loaded
    $script:AgenticCheckpointResumed = ($Loaded -gt 0)

    Write-Host (
        "AGENTIC_CHECKPOINT_RESUME=" +
        $(if ($Loaded -gt 0) { "YES" } else { "NO" }) +
        " evidence_sessions=" + $Loaded
    )
}

function Save-AgenticAutotuneCheckpoint {
    param(
        [bool]$Completed = $false
    )

    if ([string]::IsNullOrWhiteSpace([string]$script:AgenticCheckpointRunFingerprint)) {
        return
    }

    $Directory = Split-Path $script:AgenticCheckpointPath -Parent
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        Assert-LocalTree $Directory
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $Payload = [ordered]@{
        Schema = 1
        BenchmarkVersion = $ScriptVersion
        RunFingerprint = $script:AgenticCheckpointRunFingerprint
        Completed = $Completed
        Evidence = @($script:AdaptiveStressEvidence)
    }

    $Temp = $script:AgenticCheckpointPath + ".tmp"
    Assert-LocalPath $Temp
    $Payload |
        ConvertTo-Json -Depth 12 |
        Set-Content -LiteralPath $Temp -Encoding UTF8

    Assert-LocalPath $Temp
    Assert-LocalPath $script:AgenticCheckpointPath
    Move-Item `
        -LiteralPath $Temp `
        -Destination $script:AgenticCheckpointPath `
        -Force

    Write-Host (
        "AGENTIC_CHECKPOINT_SAVED completed=" +
        $Completed +
        " evidence_sessions=" +
        $script:AdaptiveStressEvidence.Count
    )
}

function Get-AgenticEfficiencyVector {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Measurement
    )

    $RoleResponses = (
        [int]$Measurement.PromptResponses +
        [int]$Measurement.AlgorithmResponses +
        [int]$Measurement.TestResponses
    )

    $RecoveryEvents = (
        [int]$Measurement.GrowthLimitCount +
        [int]$Measurement.PartialSideEffectsCount +
        [int]$Measurement.ContextCompactionNoProgressCount
    )

    $TotalThoughts = (
        [int64]$Measurement.PromptSumThoughts +
        [int64]$Measurement.AlgorithmSumThoughts +
        [int64]$Measurement.TestSumThoughts
    )

    return [pscustomobject]@{
        WallSeconds = [double]$Measurement.WallSeconds
        ApiResponses = [int]$Measurement.ApiResponses
        ToolCalls = [int]$Measurement.ToolCalls
        RoleResponses = $RoleResponses
        RecoveryEvents = $RecoveryEvents
        TotalThoughts = $TotalThoughts
    }
}

function Get-AgenticEfficiencyComparison {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Candidate,

        [Parameter(Mandatory = $true)]
        [object]$Reference
    )

    $C = Get-AgenticEfficiencyVector -Measurement $Candidate
    $R = Get-AgenticEfficiencyVector -Measurement $Reference

    function Get-Ratio([double]$A,[double]$B) {
        if ($B -le 0.0) {
            if ($A -le 0.0) { return 1.0 }
            return [double]::PositiveInfinity
        }
        return ($A / $B)
    }

    $WallRatio = Get-Ratio $C.WallSeconds $R.WallSeconds
    $ApiRatio = Get-Ratio $C.ApiResponses $R.ApiResponses
    $ToolRatio = Get-Ratio $C.ToolCalls $R.ToolCalls
    $RoleRatio = Get-Ratio $C.RoleResponses $R.RoleResponses
    $ThoughtRatio = Get-Ratio $C.TotalThoughts $R.TotalThoughts
    $RecoveryDelta = $C.RecoveryEvents - $R.RecoveryEvents

    $StructuralSignals = 0
    if ($ApiRatio -ge 1.35) { $StructuralSignals++ }
    if ($ToolRatio -ge 1.35) { $StructuralSignals++ }
    if ($RoleRatio -ge 1.35) { $StructuralSignals++ }
    if ($ThoughtRatio -ge 1.50) { $StructuralSignals++ }
    if ($RecoveryDelta -ge 2) { $StructuralSignals++ }

    $Regression = (
        ($WallRatio -ge 1.75 -and $StructuralSignals -ge 1) -or
        ($WallRatio -ge 1.25 -and $StructuralSignals -ge 3)
    )

    return [pscustomobject]@{
        Regression = $Regression
        WallRatio = $WallRatio
        ApiRatio = $ApiRatio
        ToolRatio = $ToolRatio
        RoleRatio = $RoleRatio
        ThoughtRatio = $ThoughtRatio
        RecoveryDelta = $RecoveryDelta
        StructuralSignals = $StructuralSignals
    }
}

function Test-AgenticEfficiencyDominates {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Left,

        [Parameter(Mandatory = $true)]
        [object]$Right
    )

    $L = Get-AgenticEfficiencyVector -Measurement $Left
    $R = Get-AgenticEfficiencyVector -Measurement $Right

    $AllNoWorse = (
        $L.WallSeconds -le $R.WallSeconds -and
        $L.ApiResponses -le $R.ApiResponses -and
        $L.ToolCalls -le $R.ToolCalls -and
        $L.RoleResponses -le $R.RoleResponses -and
        $L.RecoveryEvents -le $R.RecoveryEvents -and
        $L.TotalThoughts -le $R.TotalThoughts
    )

    $AnyBetter = (
        $L.WallSeconds -lt $R.WallSeconds -or
        $L.ApiResponses -lt $R.ApiResponses -or
        $L.ToolCalls -lt $R.ToolCalls -or
        $L.RoleResponses -lt $R.RoleResponses -or
        $L.RecoveryEvents -lt $R.RecoveryEvents -or
        $L.TotalThoughts -lt $R.TotalThoughts
    )

    return ($AllNoWorse -and $AnyBetter)
}

function Get-AgenticRobustnessComparison {
    param(
        [Parameter(Mandatory = $true)]
        [object]$First,

        [Parameter(Mandatory = $true)]
        [object]$Second
    )

    if (-not $First.Pass -or -not $Second.Pass) {
        return [pscustomobject]@{
            Confirmed = $false
            HighVariance = $true
            Reason = "QUALITY_NOT_REPEATABLE"
            FirstVsSecondRegression = $false
            SecondVsFirstRegression = $false
        }
    }

    $A = Get-AgenticEfficiencyVector -Measurement $First
    $B = Get-AgenticEfficiencyVector -Measurement $Second

    function Get-Spread([double]$X,[double]$Y) {
        $Low = [Math]::Min($X,$Y)
        $High = [Math]::Max($X,$Y)

        if ($Low -le 0.0) {
            if ($High -le 0.0) {
                return 1.0
            }
            return [double]::PositiveInfinity
        }

        return ($High / $Low)
    }

    # Robustness must use the same agentic-efficiency semantics as candidate
    # selection. A pair is NOT robust merely because both trajectories pass
    # quality. If either trajectory is an efficiency regression relative to
    # the other, the repeated candidate is trajectory-unstable.
    $FirstVsSecond = Get-AgenticEfficiencyComparison `
        -Candidate $First `
        -Reference $Second

    $SecondVsFirst = Get-AgenticEfficiencyComparison `
        -Candidate $Second `
        -Reference $First

    $EfficiencyVarianceHigh = (
        [bool]$FirstVsSecond.Regression -or
        [bool]$SecondVsFirst.Regression
    )

    return [pscustomobject]@{
        Confirmed = (-not $EfficiencyVarianceHigh)
        HighVariance = $EfficiencyVarianceHigh
        Reason = $(
            if ($EfficiencyVarianceHigh) {
                "TRAJECTORY_EFFICIENCY_VARIANCE_HIGH"
            }
            else {
                "PASS_QUALITY_AND_EFFICIENCY_REPEATABLE"
            }
        )
        WallSpread = (Get-Spread $A.WallSeconds $B.WallSeconds)
        ApiSpread = (Get-Spread $A.ApiResponses $B.ApiResponses)
        ToolSpread = (Get-Spread $A.ToolCalls $B.ToolCalls)
        RoleSpread = (Get-Spread $A.RoleResponses $B.RoleResponses)
        ThoughtSpread = (Get-Spread $A.TotalThoughts $B.TotalThoughts)
        RecoverySpread = (Get-Spread $A.RecoveryEvents $B.RecoveryEvents)
        FirstVsSecondRegression = [bool]$FirstVsSecond.Regression
        SecondVsFirstRegression = [bool]$SecondVsFirst.Regression
    }
}

function Write-AgenticEfficiencyEvidence {
    foreach ($Entry in @($script:AdaptiveStressEvidence)) {
        $M = $Entry.Measurement
        if ($null -eq $M -or -not [bool]$M.Pass) {
            continue
        }
        $V = Get-AgenticEfficiencyVector -Measurement $M
        $C = $Entry.Config
        Write-Host (
            "AGENTIC_EFFICIENCY_EVIDENCE label=" + $Entry.Label +
            " prompt=" + $C["prompt-reasoning-budget"] +
            " algorithm=" + $C["algorithm-reasoning-budget"] +
            " test=" + $C["test-reasoning-budget"] +
            " growth=" + $C["max-context-growth-tokens-per-turn"] +
            " wall=" + $V.WallSeconds.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
            " api=" + $V.ApiResponses +
            " tools=" + $V.ToolCalls +
            " role_responses=" + $V.RoleResponses +
            " recovery_events=" + $V.RecoveryEvents +
            " total_thoughts=" + $V.TotalThoughts
        )
    }
}

function Invoke-AdaptiveStressMeasurement {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [string]$Label,

        [switch]$ForceRepeat
    )

    $Fingerprint = Get-AdaptiveConfigFingerprint `
        -Parameters $Parameters

    if (
        -not $ForceRepeat -and
        $script:AdaptiveStressCache.ContainsKey($Fingerprint)
    ) {
        Write-Host (
            "ADAPTIVE_STRESS_CACHE_HIT label=" +
            $Label +
            " fingerprint=" +
            $Fingerprint
        )
        return $script:AdaptiveStressCache[$Fingerprint]
    }

    if (
        $script:AdaptiveStressSessionCount -ge
        $MaxAdaptiveStressSessions
    ) {
        Write-Host (
            "ADAPTIVE_STRESS_SESSION_LIMIT_REACHED used=" +
            $script:AdaptiveStressSessionCount +
            " max=" +
            $MaxAdaptiveStressSessions
        )
        return $null
    }

    $script:AdaptiveStressSessionCount++

    Write-Host (
        "ADAPTIVE_STRESS_SESSION_START index=" +
        $script:AdaptiveStressSessionCount +
        " max=" +
        $MaxAdaptiveStressSessions +
        " label=" +
        $Label
    )

    $Measurement = Invoke-RoleAwareAgentMeasurement `
        -Parameters $Parameters `
        -Label $Label `
        -Workload "STRESS"

    $FailureClass = Get-AdaptiveFailureClass `
        -Measurement $Measurement

    $Measurement |
        Add-Member `
            -NotePropertyName FailureClass `
            -NotePropertyValue $FailureClass `
            -Force

    $script:AdaptiveStressCache[$Fingerprint] = $Measurement
    $script:AdaptiveStressEvidence += [pscustomobject]@{
        Label = $Label
        Fingerprint = $Fingerprint
        Config = (Copy-BenchmarkParameters -Parameters $Parameters)
        Measurement = $Measurement
    }

    Save-AgenticAutotuneCheckpoint -Completed $false

    Write-Host (
        "ADAPTIVE_STRESS_SESSION_RESULT index=" +
        $script:AdaptiveStressSessionCount +
        " pass=" +
        $Measurement.Pass +
        " failure_class=" +
        $FailureClass
    )

    return $Measurement
}

function Invoke-ConvergentReasoningGrowthStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Reset-AdaptiveStressPlannerState
    Initialize-AgenticAutotuneCheckpoint -Parameters $Parameters

    Write-Host ""
    Write-Host "========================================"
    Write-Host " CONVERGENT REASONING / GROWTH STAGE"
    Write-Host "========================================"
    Write-Host "SEARCH=shared-evidence + efficiency-knee + bracket-refinement + grouped-headroom + final-confirmation"
    Write-Host "SELECTION_OBJECTIVE=CORE_QUALITY_FIRST_THEN_AGENTIC_EFFICIENCY_KNEE"
    Write-Host "EFFICIENCY_VECTOR=WALL,API,TOOLS,ROLE_RESPONSES,RECOVERY_EVENTS,TOTAL_THOUGHTS"
    Write-Host "PARETO_POLICY=DOMINANCE_REPORT_PLUS_SUCCESSIVE_KNEE_REJECTION"
    Write-Host "PERSISTENT_EVIDENCE=CRASH_RESUME_ONLY"
    Write-Host ("MAX_EXPENSIVE_STRESS_SESSIONS=" + $MaxAdaptiveStressSessions)
    Write-Host ("STRESS_MAX_WALL_TIME=" + $StressMaxWallTimeMinutes + "m")
    Write-Host "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"

    $WorkingConfig = Copy-BenchmarkParameters -Parameters $Parameters
    $CurrentAlgorithm = [int]$WorkingConfig["algorithm-reasoning-budget"]

    $SafeConfig = $null
    $SafeMeasurement = $null
    $Status = "NO_SAFE_CANDIDATE"
    $SearchConverged = $false
    $RobustnessConfirmed = $false
    $SelectionReason = "NONE"
    $EfficiencyKneeLowerBudget = 0
    $FailAlgorithm = 0

    $Baseline = Invoke-AdaptiveStressMeasurement `
        -Parameters $WorkingConfig `
        -Label "autotune_baseline"

    if ($null -eq $Baseline) {
        return [pscustomobject]@{
            Safe = $false
            Status = "SESSION_BUDGET_EXHAUSTED"
            Config = $Parameters
            Measurement = $null
            StressSessions = $script:AdaptiveStressSessionCount
            SearchConverged = $false
            RobustnessConfirmed = $false
            SelectionReason = "NO_BASELINE_EVIDENCE"
        }
    }

    if ($Baseline.Pass) {
        $SafeConfig = $WorkingConfig
        $SafeMeasurement = $Baseline
        $Status = "BASELINE_SAFE"
    }
    else {
        $BaselineClass = [string]$Baseline.FailureClass
        Write-Host ("BASELINE_UNSAFE failure_class=" + $BaselineClass)

        if (
            $BaselineClass -eq "QUALITY" -or
            $BaselineClass -eq "REASONING_PRESSURE"
        ) {
            $MaximumReasoning = [Math]::Max(
                1024,
                [int][Math]::Floor(
                    [int]$WorkingConfig["ctx-size"] * 0.95
                )
            )

            foreach ($Multiplier in @(1.25,1.50)) {
                if ($script:AdaptiveStressSessionCount -ge ($MaxAdaptiveStressSessions - 1)) {
                    break
                }

                $CandidateBudget = Round-BenchmarkIntegerCandidate `
                    -Value ($CurrentAlgorithm * $Multiplier) `
                    -Quantum 512 `
                    -Minimum 1024 `
                    -Maximum $MaximumReasoning

                if ($CandidateBudget -le $CurrentAlgorithm) {
                    continue
                }

                $CandidateConfig = Set-RoleBudgetInConfig `
                    -Parameters $WorkingConfig `
                    -Role "ALGORITHM" `
                    -Budget $CandidateBudget

                $CandidateMeasurement = Invoke-AdaptiveStressMeasurement `
                    -Parameters $CandidateConfig `
                    -Label ("algorithm_recovery_" + $CandidateBudget)

                if ($null -eq $CandidateMeasurement) {
                    break
                }

                if ($CandidateMeasurement.Pass) {
                    $SafeConfig = $CandidateConfig
                    $SafeMeasurement = $CandidateMeasurement
                    $Status = "RECOVERED_BY_MORE_ALGORITHM_REASONING"
                    $FailAlgorithm = $CurrentAlgorithm
                    break
                }
            }
        }
        elseif ($BaselineClass -eq "TIMEOUT") {
            foreach ($Multiplier in @(0.75,0.875)) {
                if ($script:AdaptiveStressSessionCount -ge ($MaxAdaptiveStressSessions - 1)) {
                    break
                }

                $CandidateBudget = Round-BenchmarkIntegerCandidate `
                    -Value ($CurrentAlgorithm * $Multiplier) `
                    -Quantum 512 `
                    -Minimum 1024 `
                    -Maximum $CurrentAlgorithm

                if ($CandidateBudget -ge $CurrentAlgorithm) {
                    continue
                }

                $CandidateConfig = Set-RoleBudgetInConfig `
                    -Parameters $WorkingConfig `
                    -Role "ALGORITHM" `
                    -Budget $CandidateBudget

                $CandidateMeasurement = Invoke-AdaptiveStressMeasurement `
                    -Parameters $CandidateConfig `
                    -Label ("algorithm_timeout_recovery_" + $CandidateBudget)

                if ($null -eq $CandidateMeasurement) {
                    break
                }

                if ($CandidateMeasurement.Pass) {
                    $SafeConfig = $CandidateConfig
                    $SafeMeasurement = $CandidateMeasurement
                    $Status = "RECOVERED_FROM_TIMEOUT"
                    break
                }
            }
        }
        elseif (
            $BaselineClass -eq "HARNESS" -or
            $BaselineClass -eq "ENVIRONMENT" -or
            $BaselineClass -eq "EXECUTION"
        ) {
            throw (
                "AUTOTUNE_BASELINE_INFRASTRUCTURE_FAIL class=" +
                $BaselineClass +
                " reason=" +
                $Baseline.Reason
            )
        }
    }

    if ($null -eq $SafeMeasurement) {
        Write-Host "CONVERGENT_REASONING_GROWTH_SAFE=NO"
        Save-AgenticAutotuneCheckpoint -Completed $false
        return [pscustomobject]@{
            Safe = $false
            Status = $Status
            Config = $Parameters
            Measurement = $Baseline
            StressSessions = $script:AdaptiveStressSessionCount
            SearchConverged = $false
            RobustnessConfirmed = $false
            SelectionReason = "NO_SAFE_CANDIDATE"
        }
    }

    $SafeAlgorithm = [int]$SafeConfig["algorithm-reasoning-budget"]

    $SeedPlatformMatches = $false
    if (
        $null -ne $script:AutotuneSeedPlatformFingerprint -and
        [string]$script:AutotuneSeedPlatformFingerprint -eq
        (Get-AdaptivePlatformFingerprint -Parameters $SafeConfig)
    ) {
        $SeedPlatformMatches = $true
    }

    if (
        $FailAlgorithm -eq 0 -and
        $SeedAlgorithmFailBudget -gt 0 -and
        $SeedAlgorithmFailBudget -lt $SafeAlgorithm -and
        $SeedPlatformMatches
    ) {
        $FailAlgorithm = $SeedAlgorithmFailBudget
        Write-Host (
            "ALGORITHM_BRACKET_SEEDED_FAIL budget=" +
            $FailAlgorithm +
            " class=" +
            $SeedAlgorithmFailClass +
            " platform_match=YES"
        )
    }
    elseif (
        $SeedAlgorithmFailBudget -gt 0 -and
        -not $SeedPlatformMatches
    ) {
        Write-Host "ALGORITHM_BRACKET_SEED_IGNORED reason=PLATFORM_CONFIG_CHANGED"
    }

    if ($FailAlgorithm -eq 0 -and $Baseline.Pass) {
        while (
            $script:AdaptiveStressSessionCount -lt
            ($MaxAdaptiveStressSessions - 2)
        ) {
            $LowerProbe = Round-BenchmarkIntegerCandidate `
                -Value ($SafeAlgorithm * 0.75) `
                -Quantum 512 `
                -Minimum 1024 `
                -Maximum $SafeAlgorithm

            if ($LowerProbe -ge $SafeAlgorithm) {
                $SearchConverged = $true
                $SelectionReason = "ALGORITHM_POLICY_FLOOR_REACHED"
                break
            }

            $LowerConfig = Set-RoleBudgetInConfig `
                -Parameters $SafeConfig `
                -Role "ALGORITHM" `
                -Budget $LowerProbe

            $LowerMeasurement = Invoke-AdaptiveStressMeasurement `
                -Parameters $LowerConfig `
                -Label ("algorithm_lower_probe_" + $LowerProbe)

            if ($null -eq $LowerMeasurement) {
                break
            }

            if ($LowerMeasurement.Pass) {
                $Efficiency = Get-AgenticEfficiencyComparison `
                    -Candidate $LowerMeasurement `
                    -Reference $SafeMeasurement

                Write-Host (
                    "ALGORITHM_LOWER_EFFICIENCY budget=" + $LowerProbe +
                    " wall_ratio=" + $Efficiency.WallRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                    " api_ratio=" + $Efficiency.ApiRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                    " tool_ratio=" + $Efficiency.ToolRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                    " role_ratio=" + $Efficiency.RoleRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                    " thought_ratio=" + $Efficiency.ThoughtRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                    " recovery_delta=" + $Efficiency.RecoveryDelta +
                    " regression=" + $Efficiency.Regression
                )

                if ($Efficiency.Regression) {
                    $EfficiencyKneeLowerBudget = $LowerProbe
                    $SearchConverged = $true
                    $Status = "ALGORITHM_EFFICIENCY_KNEE"
                    $SelectionReason = "LOWER_BUDGET_AGENTIC_EFFICIENCY_REGRESSION"
                    Write-Host (
                        "ALGORITHM_EFFICIENCY_KNEE safe_budget=" +
                        $SafeAlgorithm +
                        " lower_budget=" +
                        $LowerProbe
                    )
                    break
                }

                $SafeConfig = $LowerConfig
                $SafeMeasurement = $LowerMeasurement
                $SafeAlgorithm = $LowerProbe
                $Status = "ALGORITHM_REDUCED_WITHOUT_EFFICIENCY_REGRESSION"
                continue
            }

            $LowerClass = [string]$LowerMeasurement.FailureClass
            if (
                $LowerClass -eq "QUALITY" -or
                $LowerClass -eq "REASONING_PRESSURE" -or
                $LowerClass -eq "TIMEOUT"
            ) {
                $FailAlgorithm = $LowerProbe
                $SearchConverged = $true
                $SelectionReason = "LOWER_BUDGET_QUALITY_OR_PRESSURE_FAIL"
            }
            elseif (
                $LowerClass -eq "HARNESS" -or
                $LowerClass -eq "ENVIRONMENT" -or
                $LowerClass -eq "EXECUTION"
            ) {
                throw (
                    "ALGORITHM_LOWER_PROBE_INFRASTRUCTURE_FAIL class=" +
                    $LowerClass +
                    " reason=" +
                    $LowerMeasurement.Reason
                )
            }
            break
        }
    }

    if (
        $FailAlgorithm -gt 0 -and
        $FailAlgorithm -lt $SafeAlgorithm -and
        $script:AdaptiveStressSessionCount -lt
        ($MaxAdaptiveStressSessions - 2)
    ) {
        $Midpoint = Get-AdaptiveBudgetMidpoint `
            -Lower $FailAlgorithm `
            -Upper $SafeAlgorithm `
            -Quantum 512

        if ($null -ne $Midpoint) {
            $MidConfig = Set-RoleBudgetInConfig `
                -Parameters $SafeConfig `
                -Role "ALGORITHM" `
                -Budget $Midpoint

            $MidMeasurement = Invoke-AdaptiveStressMeasurement `
                -Parameters $MidConfig `
                -Label ("algorithm_bracket_" + $Midpoint)

            if ($null -ne $MidMeasurement) {
                if ($MidMeasurement.Pass) {
                    $Efficiency = Get-AgenticEfficiencyComparison `
                        -Candidate $MidMeasurement `
                        -Reference $SafeMeasurement

                    if (-not $Efficiency.Regression) {
                        $SafeConfig = $MidConfig
                        $SafeMeasurement = $MidMeasurement
                        $SafeAlgorithm = $Midpoint
                        $Status = "ALGORITHM_BRACKET_REFINED"
                    }
                    else {
                        $EfficiencyKneeLowerBudget = $Midpoint
                        $Status = "ALGORITHM_BRACKET_EFFICIENCY_KNEE"
                    }
                }
                else {
                    $MidClass = [string]$MidMeasurement.FailureClass
                    if (
                        $MidClass -eq "HARNESS" -or
                        $MidClass -eq "ENVIRONMENT" -or
                        $MidClass -eq "EXECUTION"
                    ) {
                        throw (
                            "ALGORITHM_BRACKET_INFRASTRUCTURE_FAIL class=" +
                            $MidClass +
                            " reason=" +
                            $MidMeasurement.Reason
                        )
                    }
                    $FailAlgorithm = $Midpoint
                }
                $SearchConverged = $true
            }
        }
    }

    Write-Host ("ALGORITHM_SAFE_BUDGET=" + $SafeAlgorithm)
    if ($FailAlgorithm -gt 0) {
        Write-Host ("ALGORITHM_KNOWN_FAIL_BUDGET=" + $FailAlgorithm)
    }
    else {
        Write-Host "ALGORITHM_KNOWN_FAIL_BUDGET=NONE"
    }
    if ($EfficiencyKneeLowerBudget -gt 0) {
        Write-Host (
            "ALGORITHM_EFFICIENCY_KNEE_LOWER_BUDGET=" +
            $EfficiencyKneeLowerBudget
        )
    }
    else {
        Write-Host "ALGORITHM_EFFICIENCY_KNEE_LOWER_BUDGET=NONE"
    }

    # Growth pressure is a system-health signal and takes priority over
    # cosmetic role-budget reduction when only one exploratory slot remains.
    $GrowthPressureObserved = (
        $SafeMeasurement.GrowthLimitCount -ge 2 -or
        $SafeMeasurement.PartialSideEffectsCount -ge 2 -or
        $SafeMeasurement.ContextCompactionNoProgressCount -gt 0
    )

    if (
        $GrowthPressureObserved -and
        $script:AdaptiveStressSessionCount -lt
        ($MaxAdaptiveStressSessions - 1)
    ) {
        $CurrentGrowth = [int]$SafeConfig[
            "max-context-growth-tokens-per-turn"
        ]

        $GrowthCandidate = Round-BenchmarkIntegerCandidate `
            -Value ($CurrentGrowth * (4.0 / 3.0)) `
            -Quantum 1024 `
            -Minimum 4096 `
            -Maximum ([int]::MaxValue)

        if ($GrowthCandidate -gt $CurrentGrowth) {
            $GrowthConfig = Copy-BenchmarkParameters -Parameters $SafeConfig
            $GrowthConfig["max-context-growth-tokens-per-turn"] = [string]$GrowthCandidate

            $GrowthMeasurement = Invoke-AdaptiveStressMeasurement `
                -Parameters $GrowthConfig `
                -Label ("growth_pressure_" + $GrowthCandidate)

            if ($null -ne $GrowthMeasurement -and $GrowthMeasurement.Pass) {
                $Efficiency = Get-AgenticEfficiencyComparison `
                    -Candidate $GrowthMeasurement `
                    -Reference $SafeMeasurement

                if (
                    $GrowthMeasurement.GrowthLimitCount -lt
                    $SafeMeasurement.GrowthLimitCount -and
                    -not $Efficiency.Regression
                ) {
                    $SafeConfig = $GrowthConfig
                    $SafeMeasurement = $GrowthMeasurement
                    $Status = "GROWTH_PRESSURE_REDUCED_WITHOUT_EFFICIENCY_REGRESSION"
                    Write-Host (
                        "GROWTH_PROBE_RESULT=PASS_ACCEPTED budget=" +
                        $GrowthCandidate
                    )
                }
                else {
                    Write-Host (
                        "GROWTH_PROBE_RESULT=REJECTED_NO_NET_AGENTIC_GAIN budget=" +
                        $CurrentGrowth
                    )
                }
            }
        }
    }
    else {
        Write-Host "GROWTH_PROBE=SKIPPED_NO_GROWTH_PRESSURE_OR_RESERVED_CONFIRMATION_SLOT"
    }

    # PROMPT and TEST are reduced together only when both show headroom.
    # A PASS is insufficient: the full-session efficiency must not regress.
    $GroupedConfig = Copy-BenchmarkParameters -Parameters $SafeConfig
    $GroupedChanges = @()

    foreach ($Role in @("PROMPT","TEST")) {
        $Key = Get-RoleBudgetKey -Role $Role
        $CurrentBudget = [int]$GroupedConfig[$Key]
        $Observed = Get-RoleMaxThoughts -Measurement $SafeMeasurement -Role $Role

        if ($Observed -lt [int][Math]::Floor($CurrentBudget * 0.60)) {
            $Candidate = Get-RoleReductionCandidate `
                -Current $CurrentBudget `
                -ObservedMax $Observed

            if ($Candidate -lt $CurrentBudget) {
                $GroupedConfig[$Key] = [string]$Candidate
                $GroupedChanges += (
                    $Role + ":" + $CurrentBudget + "->" + $Candidate
                )
            }
        }
    }

    if (
        $GroupedChanges.Count -gt 0 -and
        $script:AdaptiveStressSessionCount -lt
        ($MaxAdaptiveStressSessions - 1)
    ) {
        Write-Host ("GROUPED_ROLE_HEADROOM_PROBE=" + ($GroupedChanges -join ","))

        $GroupedMeasurement = Invoke-AdaptiveStressMeasurement `
            -Parameters $GroupedConfig `
            -Label "prompt_test_grouped_headroom"

        if ($null -ne $GroupedMeasurement -and $GroupedMeasurement.Pass) {
            $Efficiency = Get-AgenticEfficiencyComparison `
                -Candidate $GroupedMeasurement `
                -Reference $SafeMeasurement

            Write-Host (
                "GROUPED_ROLE_EFFICIENCY wall_ratio=" +
                $Efficiency.WallRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                " api_ratio=" + $Efficiency.ApiRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                " tool_ratio=" + $Efficiency.ToolRatio.ToString("F3",[System.Globalization.CultureInfo]::InvariantCulture) +
                " recovery_delta=" + $Efficiency.RecoveryDelta +
                " regression=" + $Efficiency.Regression
            )

            if (-not $Efficiency.Regression) {
                $SafeConfig = $GroupedConfig
                $SafeMeasurement = $GroupedMeasurement
                $Status = "GROUPED_ROLE_REDUCTION_ACCEPTED_BY_AGENTIC_EFFICIENCY"
                Write-Host "GROUPED_ROLE_HEADROOM_RESULT=PASS_ACCEPTED"
            }
            else {
                Write-Host "GROUPED_ROLE_HEADROOM_RESULT=PASS_BUT_EFFICIENCY_REGRESSION_REJECTED"
            }
        }
        else {
            Write-Host "GROUPED_ROLE_HEADROOM_RESULT=REJECTED_KEEP_SAFE"
        }
    }
    else {
        Write-Host "GROUPED_ROLE_HEADROOM_PROBE=SKIPPED_OR_CONFIRMATION_SLOT_RESERVED"
    }

    # One repeat of the selected final candidate is worth more than another
    # blind lower probe: it confirms quality and catches trajectory instability.
    if ($script:AdaptiveStressSessionCount -lt $MaxAdaptiveStressSessions) {
        $Confirmation = Invoke-AdaptiveStressMeasurement `
            -Parameters $SafeConfig `
            -Label "final_agentic_candidate_confirmation" `
            -ForceRepeat

        if ($null -ne $Confirmation) {
            $Robustness = Get-AgenticRobustnessComparison `
                -First $SafeMeasurement `
                -Second $Confirmation

            $RobustnessConfirmed = [bool]$Robustness.Confirmed
            Write-Host (
                "AGENTIC_FINAL_CONFIRMATION pass=" +
                $Confirmation.Pass +
                " robustness_confirmed=" +
                $RobustnessConfirmed +
                " reason=" +
                $Robustness.Reason
            )

            if ($Confirmation.Pass -and $RobustnessConfirmed) {
                $SafeMeasurement = $Confirmation
            }
            elseif (-not $Confirmation.Pass) {
                $Status = "FINAL_CONFIRMATION_QUALITY_FAIL"
            }
            else {
                $Status = "FINAL_CONFIRMATION_TRAJECTORY_VARIANCE_HIGH"
            }
        }
    }
    else {
        Write-Host "AGENTIC_FINAL_CONFIRMATION=SKIPPED_SESSION_BUDGET_EXHAUSTED"
    }

    if (-not $SearchConverged) {
        if ($EfficiencyKneeLowerBudget -gt 0 -or $FailAlgorithm -gt 0) {
            $SearchConverged = $true
        }
        else {
            $Status = "SAFE_LOWER_BOUND_NOT_FOUND"
            if ($SelectionReason -eq "NONE") {
                $SelectionReason = "NO_FAIL_OR_EFFICIENCY_KNEE_WITHIN_SESSION_BUDGET"
            }
        }
    }

    if ($SearchConverged -and $RobustnessConfirmed) {
        if ($SelectionReason -eq "NONE") {
            $SelectionReason = "CONVERGED_AND_REPEATABLE"
        }
        $Status = "EFFICIENCY_KNEE_OR_QUALITY_BOUND_CONFIRMED"
    }

    Write-AgenticEfficiencyEvidence

    Write-Host (
        "CONVERGENT_STRESS_SESSIONS_USED=" +
        $script:AdaptiveStressSessionCount
    )
    Write-Host ("CONVERGENT_REASONING_GROWTH_STATUS=" + $Status)
    Write-Host ("CONVERGENT_SEARCH_CONVERGED=" + $SearchConverged)
    Write-Host ("CONVERGENT_ROBUSTNESS_CONFIRMED=" + $RobustnessConfirmed)
    Write-Host ("CONVERGENT_SELECTION_REASON=" + $SelectionReason)
    Write-Host "CONVERGENT_REASONING_GROWTH_SAFE=YES"

    $CheckpointCompleted = ($SearchConverged -and $RobustnessConfirmed)
    Save-AgenticAutotuneCheckpoint -Completed $CheckpointCompleted

    return [pscustomobject]@{
        Safe = $true
        Status = $Status
        Config = $SafeConfig
        Measurement = $SafeMeasurement
        StressSessions = $script:AdaptiveStressSessionCount
        AlgorithmSafeBudget = [int]$SafeConfig["algorithm-reasoning-budget"]
        AlgorithmKnownFailBudget = $FailAlgorithm
        AlgorithmEfficiencyKneeLowerBudget = $EfficiencyKneeLowerBudget
        SearchConverged = $SearchConverged
        RobustnessConfirmed = $RobustnessConfirmed
        SelectionReason = $SelectionReason
    }
}


function Invoke-AgenticOnlyAutoTune {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " AGENTIC-ONLY AUTOTUNE"
    Write-Host "========================================"
    Write-Host "SCOPE=REASONING_GROWTH_CONTEXT_LIFECYCLE_ONLY"
    Write-Host "SKIP_NGRAM_PMIN_CONTEXT_CAPACITY=YES"
    Write-Host "CORE_AGENTIC_TESTS=BLOCKING"
    Write-Host "EXTENDED_AGENTIC_TESTS=NON_BLOCKING"
    Write-Host "EXTERNAL_TEST_ENCODING=UTF8_DETERMINISTIC"
    Write-Host "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "AGENTIC_SELECTION=QUALITY_GATE_THEN_EFFICIENCY_KNEE_THEN_REPEAT_CONFIRMATION"
    Write-Host "AGENTIC_EVIDENCE_CHECKPOINT=CRASH_RESUME_ONLY"

    Invoke-AgenticHarnessSelfTest

    $null = Initialize-AutotuneSeedPlatformFingerprint `
        -Parameters $Parameters

    Write-Host "AGENTIC_AUTOTUNE_SEED_PLATFORM_FINGERPRINT=INITIALIZED"

    $Result = Invoke-ConvergentReasoningGrowthStage `
        -Parameters $Parameters

    Write-Host ""
    Write-Host "========================================"
    Write-Host " AGENTIC-ONLY AUTOTUNE STATUS"
    Write-Host "========================================"
    Write-Host "BENCHMARK_EXECUTION=PASS"

    if (-not $Result.Safe) {
        Write-Host "RECOMMENDATION_STATUS=NO_SAFE_CANDIDATE"
        Write-Host ("RECOMMENDATION_REASON=" + $Result.Status)
        Write-Host "APPLY_ALLOWED=NO"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        Write-Host "CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
        Write-Host (
            "EXPENSIVE_STRESS_SESSIONS_USED=" +
            $Result.StressSessions
        )
        return
    }

    $Recommended = $Result.Config
    $Same = (
        [int]$Recommended["prompt-reasoning-budget"] -eq
        [int]$Parameters["prompt-reasoning-budget"] -and
        [int]$Recommended["algorithm-reasoning-budget"] -eq
        [int]$Parameters["algorithm-reasoning-budget"] -and
        [int]$Recommended["test-reasoning-budget"] -eq
        [int]$Parameters["test-reasoning-budget"] -and
        [int]$Recommended["max-context-growth-tokens-per-turn"] -eq
        [int]$Parameters["max-context-growth-tokens-per-turn"]
    )

    if (-not $Result.SearchConverged) {
        Write-Host "RECOMMENDATION_STATUS=SAFE_LOWER_BOUND_NOT_FOUND"
    }
    elseif (-not $Result.RobustnessConfirmed) {
        Write-Host "RECOMMENDATION_STATUS=PARTIAL_SAFE_NOT_ROBUSTNESS_CONFIRMED"
    }
    elseif ($Same) {
        Write-Host "RECOMMENDATION_STATUS=KEEP_CURRENT"
    }
    else {
        Write-Host "RECOMMENDATION_STATUS=FOUND"
    }

    Write-Host ("SEARCH_CONVERGED=" + $Result.SearchConverged)
    Write-Host ("ROBUSTNESS_CONFIRMED=" + $Result.RobustnessConfirmed)
    Write-Host ("SELECTION_REASON=" + $Result.SelectionReason)
    Write-Host (
        "ALGORITHM_EFFICIENCY_KNEE_LOWER_BUDGET=" +
        $(if ($Result.AlgorithmEfficiencyKneeLowerBudget -gt 0) {
            [string]$Result.AlgorithmEfficiencyKneeLowerBudget
        } else {
            "NONE"
        })
    )

    Write-Host (
        "RECOMMENDED_PROMPT_REASONING_BUDGET=" +
        $Recommended["prompt-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_ALGORITHM_REASONING_BUDGET=" +
        $Recommended["algorithm-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_TEST_REASONING_BUDGET=" +
        $Recommended["test-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN=" +
        $Recommended["max-context-growth-tokens-per-turn"]
    )

    $Measurement = $Result.Measurement

    if ($null -ne $Measurement) {
        Write-Host (
            "FINAL_CORE_AGENTIC_PASS=" +
            $Measurement.Pass
        )
        Write-Host (
            "FINAL_EXTENDED_NON_BLOCKING_PASS=" +
            $Measurement.ExtendedPass
        )
        Write-Host (
            "FINAL_GROWTH_LIMIT_COUNT=" +
            $Measurement.GrowthLimitCount
        )
        Write-Host (
            "FINAL_PARTIAL_SIDE_EFFECTS_COUNT=" +
            $Measurement.PartialSideEffectsCount
        )
        Write-Host (
            "FINAL_COMPACTION_PASS_COUNT=" +
            $Measurement.CompactionPassCount
        )
        Write-Host (
            "FINAL_CONTEXT_ROLLOVER_REQUIRED_COUNT=" +
            $Measurement.ContextRolloverRequiredCount
        )
        Write-Host (
            "FINAL_CONTEXT_ROLLOVER_COMPLETED_COUNT=" +
            $Measurement.ContextRolloverCompletedCount
        )
        Write-Host (
            "FINAL_CONTEXT_COMPACTION_NO_PROGRESS_COUNT=" +
            $Measurement.ContextCompactionNoProgressCount
        )
        Write-Host (
            "FINAL_CONTEXT_HIGH_WATERMARK_TOKENS=" +
            $Measurement.ContextHighWatermarkTokens
        )
        Write-Host (
            "FINAL_POST_COMPACTION_MAX_TOKENS=" +
            $Measurement.ContextPostCompactionMaxTokens
        )
        Write-Host (
            "FINAL_MAX_TOKENS_COUNT=" +
            $Measurement.MaxTokensCount
        )
        Write-Host (
            "FINAL_NO_VISIBLE_PROGRESS_COUNT=" +
            $Measurement.NoVisibleProgressCount
        )
    }

    Write-Host "APPLY_ALLOWED=NO"
    Write-Host "RECOMMENDATION_ONLY=YES"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
    Write-Host (
        "EXPENSIVE_STRESS_SESSIONS_USED=" +
        $Result.StressSessions
    )
}


function New-AgenticConfirmationConfig {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,
        [Parameter(Mandatory = $true)]
        [int]$PromptBudget,
        [Parameter(Mandatory = $true)]
        [int]$AlgorithmBudget,
        [Parameter(Mandatory = $true)]
        [int]$TestBudget,
        [Parameter(Mandatory = $true)]
        [int]$GrowthBudget
    )

    foreach ($Pair in @(
        [pscustomobject]@{ Name = "PROMPT"; Value = $PromptBudget },
        [pscustomobject]@{ Name = "ALGORITHM"; Value = $AlgorithmBudget },
        [pscustomobject]@{ Name = "TEST"; Value = $TestBudget },
        [pscustomobject]@{ Name = "GROWTH"; Value = $GrowthBudget }
    )) {
        if ([int]$Pair.Value -le 0) {
            throw (
                "TARGETED_CONFIRMATION_INVALID_" +
                $Pair.Name +
                "_BUDGET=" +
                $Pair.Value
            )
        }
    }

    $MaximumReasoning = [Math]::Max(
        1024,
        [int][Math]::Floor([int]$Parameters["ctx-size"] * 0.95)
    )

    foreach ($ReasoningBudget in @(
        $PromptBudget,
        $AlgorithmBudget,
        $TestBudget
    )) {
        if ($ReasoningBudget -gt $MaximumReasoning) {
            throw (
                "TARGETED_CONFIRMATION_REASONING_EXCEEDS_CONTEXT_CAP budget=" +
                $ReasoningBudget +
                " max=" +
                $MaximumReasoning
            )
        }
    }

    $Candidate = Copy-BenchmarkParameters -Parameters $Parameters
    $Candidate["prompt-reasoning-budget"] = [string]$PromptBudget
    $Candidate["algorithm-reasoning-budget"] = [string]$AlgorithmBudget
    $Candidate["test-reasoning-budget"] = [string]$TestBudget
    $Candidate["max-context-growth-tokens-per-turn"] = [string]$GrowthBudget
    return $Candidate
}

function Invoke-AgenticCandidateConfirmation {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " TARGETED AGENTIC CANDIDATE CONFIRMATION"
    Write-Host "========================================"
    Write-Host "SCOPE=EXACT_CANDIDATE_REPEAT_ONLY"
    Write-Host "SKIP_NGRAM_PMIN_CONTEXT_CAPACITY=YES"
    Write-Host "SEARCH_DISABLED=YES"
    Write-Host "CORE_AGENTIC_TESTS=BLOCKING"
    Write-Host "EXTENDED_AGENTIC_TESTS=NON_BLOCKING"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"

    Invoke-AgenticHarnessSelfTest

    $Candidate = New-AgenticConfirmationConfig `
        -Parameters $Parameters `
        -PromptBudget $ConfirmPromptReasoningBudget `
        -AlgorithmBudget $ConfirmAlgorithmReasoningBudget `
        -TestBudget $ConfirmTestReasoningBudget `
        -GrowthBudget $ConfirmGrowthBudget

    Write-Host (
        "TARGETED_CANDIDATE prompt=" +
        $Candidate["prompt-reasoning-budget"] +
        " algorithm=" +
        $Candidate["algorithm-reasoning-budget"] +
        " test=" +
        $Candidate["test-reasoning-budget"] +
        " growth=" +
        $Candidate["max-context-growth-tokens-per-turn"] +
        " repeats=" +
        $ConfirmationRepeats
    )

    $Measurements = @()
    $AllCorePass = $true
    $AllExtendedPass = $true

    for ($Index = 1; $Index -le $ConfirmationRepeats; $Index++) {
        $Measurement = Invoke-RoleAwareAgentMeasurement `
            -Parameters $Candidate `
            -Label ("targeted_candidate_confirmation_" + $Index) `
            -Workload "STRESS"

        $Measurements += $Measurement

        if (-not [bool]$Measurement.Pass) {
            $AllCorePass = $false
        }
        if (-not [bool]$Measurement.ExtendedPass) {
            $AllExtendedPass = $false
        }

        $Vector = Get-AgenticEfficiencyVector -Measurement $Measurement

        Write-Host (
            "TARGETED_CONFIRMATION_EVIDENCE index=" +
            $Index +
            " pass=" +
            $Measurement.Pass +
            " extended_pass=" +
            $Measurement.ExtendedPass +
            " wall=" +
            $Vector.WallSeconds.ToString(
                "F3",
                [System.Globalization.CultureInfo]::InvariantCulture
            ) +
            " api=" +
            $Vector.ApiResponses +
            " tools=" +
            $Vector.ToolCalls +
            " role_responses=" +
            $Vector.RoleResponses +
            " recovery_events=" +
            $Vector.RecoveryEvents +
            " total_thoughts=" +
            $Vector.TotalThoughts +
            " growth_limit=" +
            $Measurement.GrowthLimitCount +
            " partial_side_effects=" +
            $Measurement.PartialSideEffectsCount +
            " compaction_passes=" +
            $Measurement.CompactionPassCount +
            " rollover_required=" +
            $Measurement.ContextRolloverRequiredCount +
            " rollover_completed=" +
            $Measurement.ContextRolloverCompletedCount +
            " max_tokens=" +
            $Measurement.MaxTokensCount +
            " no_visible_progress=" +
            $Measurement.NoVisibleProgressCount
        )

        if (-not [bool]$Measurement.Pass) {
            break
        }
    }

    $RobustnessConfirmed = $false
    $RobustnessReason = "INSUFFICIENT_REPEAT_EVIDENCE"

    if ($Measurements.Count -ge 2 -and $AllCorePass) {
        $RobustnessConfirmed = $true
        $First = $Measurements[0]

        for ($Index = 1; $Index -lt $Measurements.Count; $Index++) {
            $Comparison = Get-AgenticRobustnessComparison `
                -First $First `
                -Second $Measurements[$Index]

            Write-Host (
                "TARGETED_CONFIRMATION_ROBUSTNESS pair=1-" +
                ($Index + 1) +
                " confirmed=" +
                $Comparison.Confirmed +
                " reason=" +
                $Comparison.Reason
            )

            if (-not [bool]$Comparison.Confirmed) {
                $RobustnessConfirmed = $false
                $RobustnessReason = [string]$Comparison.Reason
                break
            }

            $RobustnessReason = [string]$Comparison.Reason
        }
    }
    elseif ($Measurements.Count -eq 1 -and $AllCorePass) {
        $RobustnessReason = "SINGLE_REPEAT_ONLY"
    }
    elseif (-not $AllCorePass) {
        $RobustnessReason = "CORE_QUALITY_NOT_REPEATABLE"
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " TARGETED CONFIRMATION STATUS"
    Write-Host "========================================"
    Write-Host "BENCHMARK_EXECUTION=PASS"
    Write-Host ("TARGETED_CORE_ALL_PASS=" + $AllCorePass)
    Write-Host ("TARGETED_EXTENDED_ALL_PASS=" + $AllExtendedPass)
    Write-Host ("TARGETED_ROBUSTNESS_CONFIRMED=" + $RobustnessConfirmed)
    Write-Host ("TARGETED_ROBUSTNESS_REASON=" + $RobustnessReason)

    if ($AllCorePass -and $RobustnessConfirmed) {
        Write-Host "TARGETED_CONFIRMATION_STATUS=PASS"
    }
    elseif ($AllCorePass) {
        Write-Host "TARGETED_CONFIRMATION_STATUS=PARTIAL_SAFE_NOT_ROBUSTNESS_CONFIRMED"
    }
    else {
        Write-Host "TARGETED_CONFIRMATION_STATUS=FAIL"
    }

    Write-Host "APPLY_ALLOWED=NO"
    Write-Host "RECOMMENDATION_ONLY=YES"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
}


# =============================================================================
# BENCHMARK MODULE: forced context-lifecycle compaction proof
# =============================================================================

function Get-ContextLifecycleDigest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        $Hash = $Sha.ComputeHash($Bytes)

        return (
            [System.BitConverter]::ToString($Hash).
                Replace("-","").
                Substring(0,16)
        )
    }
    finally {
        $Sha.Dispose()
    }
}

function New-ContextLifecyclePacket {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Turn,

        [Parameter(Mandatory = $true)]
        [int]$TargetChars
    )

    if ($Turn -lt 1) {
        throw "CONTEXT_LIFECYCLE_PACKET_INVALID_TURN"
    }

    if ($TargetChars -lt 800) {
        throw "CONTEXT_LIFECYCLE_PACKET_TOO_SMALL"
    }

    $Digest = Get-ContextLifecycleDigest `
        -Text ("localai-context-lifecycle-turn-" + $Turn)

    $Keep = (
        "KEEP_T" +
        $Turn.ToString("D2") +
        "=INV-" +
        $Digest
    )

    $Builder = New-Object System.Text.StringBuilder

    [void]$Builder.AppendLine("LOCALAI FORCED CONTEXT LIFECYCLE STRESS")
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine("Do not call tools.")
    [void]$Builder.AppendLine("Do not delegate.")
    [void]$Builder.AppendLine("Do not inspect or modify files.")
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine(
        "Treat this exact string as a durable current-session invariant that must survive compaction:"
    )
    [void]$Builder.AppendLine($Keep)
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine(
        "Everything between TRANSIENT_BEGIN and TRANSIENT_END is resolved diagnostic noise and should be discarded by compaction."
    )
    [void]$Builder.AppendLine("TRANSIENT_BEGIN")

    $Index = 0

    while ($Builder.Length -lt ($TargetChars - 220)) {
        $RecordDigest = Get-ContextLifecycleDigest `
            -Text (
                "turn=" +
                $Turn +
                ";record=" +
                $Index +
                ";context-lifecycle"
            )

        [void]$Builder.AppendLine(
            (
                "R" +
                $Index.ToString("D4") +
                " trace=" +
                $RecordDigest +
                " status=resolved durable=no discard=yes"
            )
        )

        $Index++
    }

    [void]$Builder.AppendLine("TRANSIENT_END")
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine(
        (
            "Reply with exactly: ACK T" +
            $Turn.ToString("D2") +
            " " +
            $Keep
        )
    )

    return [pscustomobject]@{
        Text = $Builder.ToString()
        Sentinel = $Keep
        CharCount = $Builder.Length
    }
}

function Get-ContextLifecycleEventsFromText {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $Pattern = (
        '\[LOCALAI_CONTEXT_LIFECYCLE\]\s*' +
        'compaction pass\s+(\d+):\s+' +
        '(\d+)\s*->\s*(\d+)'
    )

    $Events = @()

    foreach ($Match in [regex]::Matches($Text,$Pattern)) {
        $Events += [pscustomobject]@{
            Pass = [int]$Match.Groups[1].Value
            BeforeTokens = [int]$Match.Groups[2].Value
            AfterTokens = [int]$Match.Groups[3].Value
            Raw = [string]$Match.Value
        }
    }

    return @($Events)
}

function Get-ContextLifecycleEventsFromFiles {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Files
    )

    $Events = @()

    foreach ($File in $Files) {
        if (
            $null -eq $File -or
            -not (Test-Path -LiteralPath $File.FullName -PathType Leaf)
        ) {
            continue
        }

        $LineNumber = 0

        foreach ($Line in Get-Content -LiteralPath $File.FullName) {
            $LineNumber++

            $Parsed = @(
                Get-ContextLifecycleEventsFromText `
                    -Text ([string]$Line)
            )

            foreach ($Event in $Parsed) {
                $Events += [pscustomobject]@{
                    File = [string]$File.FullName
                    Line = $LineNumber
                    Pass = [int]$Event.Pass
                    BeforeTokens = [int]$Event.BeforeTokens
                    AfterTokens = [int]$Event.AfterTokens
                    Raw = [string]$Event.Raw
                }
            }
        }
    }

    return @($Events)
}

function Write-ContextLifecycleBenchmarkWorkspace {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-LocalTree $Path
    [void](New-Item -ItemType Directory -Path $Path -Force)

    $QwenDir = Join-Path $Path ".qwen"
    Assert-LocalTree $QwenDir
    [void](New-Item -ItemType Directory -Path $QwenDir -Force)

    $SettingsText = [System.IO.File]::ReadAllText($SettingsPath)

    $SettingsText = Set-ManagedProviderBenchmarkStateInSettings `
        -Text $SettingsText `
        -ContextWindowSize ([int]$Parameters["ctx-size"]) `
        -PromptReasoningBudgetTokens ([int]$Parameters["prompt-reasoning-budget"]) `
        -AlgorithmReasoningBudgetTokens ([int]$Parameters["algorithm-reasoning-budget"]) `
        -TestReasoningBudgetTokens ([int]$Parameters["test-reasoning-budget"]) `
        -MaxContextGrowthTokensPerTurn ([int]$Parameters["max-context-growth-tokens-per-turn"])

    $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    Assert-LocalPath (Join-Path $QwenDir "settings.json")
    [System.IO.File]::WriteAllText(
        (Join-Path $QwenDir "settings.json"),
        $SettingsText,
        $Utf8NoBom
    )

    Assert-LocalPath (Join-Path $Path "BENCHMARK_MARKER.txt")
    [System.IO.File]::WriteAllText(
        (Join-Path $Path "BENCHMARK_MARKER.txt"),
        "LocalAI forced context lifecycle compaction stress.`n",
        $Utf8NoBom
    )
}


function Get-ContextLifecycleCumulativeMetrics {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    function Get-MaxMetric {
        param(
            [Parameter(Mandatory = $true)]
            [AllowEmptyString()]
            [string]$Source,

            [Parameter(Mandatory = $true)]
            [string[]]$Names
        )

        $Escaped = @(
            $Names |
            ForEach-Object {
                [regex]::Escape($_)
            }
        )

        $Pattern = (
            '"(?:' +
            ($Escaped -join "|") +
            ')"\s*:\s*(\d+)'
        )

        $Values = @(
            [regex]::Matches(
                $Source,
                $Pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            ) |
            ForEach-Object {
                [long]$_.Groups[1].Value
            }
        )

        if ($Values.Count -eq 0) {
            return $null
        }

        return [long](
            $Values |
            Measure-Object -Maximum
        ).Maximum
    }

    return [pscustomobject]@{
        PromptTokens = Get-MaxMetric `
            -Source $Text `
            -Names @(
                "prompt_tokens",
                "promptTokenCount",
                "input_tokens",
                "inputTokens"
            )

        CompletionTokens = Get-MaxMetric `
            -Source $Text `
            -Names @(
                "completion_tokens",
                "candidatesTokenCount",
                "output_tokens",
                "outputTokens"
            )
    }
}

function Get-ContextLifecycleOpenAiCompactionEvents {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return @()
    }

    $Files = @(
        Get-ChildItem `
            -LiteralPath $Path `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, FullName
    )

    if ($Files.Count -eq 0) {
        return @()
    }

    function Get-FirstMetric {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Source,

            [Parameter(Mandatory = $true)]
            [string[]]$Names
        )

        foreach ($Name in $Names) {
            $Pattern = (
                '"' +
                [regex]::Escape($Name) +
                '"\s*:\s*(\d+)'
            )

            $Match = [regex]::Match(
                $Source,
                $Pattern,
                [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )

            if ($Match.Success) {
                return [long]$Match.Groups[1].Value
            }
        }

        return $null
    }

    $Records = @()

    foreach ($File in $Files) {
        try {
            $Text = [System.IO.File]::ReadAllText($File.FullName)
        }
        catch {
            $Text = ""
        }

        $PromptTokens = Get-FirstMetric `
            -Source $Text `
            -Names @(
                "prompt_tokens",
                "promptTokenCount"
            )

        $CompletionTokens = Get-FirstMetric `
            -Source $Text `
            -Names @(
                "completion_tokens",
                "candidatesTokenCount"
            )

        $RequestLike = (
            $Text.IndexOf(
                '"messages"',
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -or
            $Text.IndexOf(
                '"input"',
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasExactDirective = (
            $Text.IndexOf(
                "Produce the compact <state_snapshot> XML directly",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0 -or
            $Text.IndexOf(
                "Produce the compact XML directly",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasStateSnapshot = (
            $Text.IndexOf(
                "<state_snapshot>",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $Records += [pscustomobject]@{
            File = [string]$File.FullName
            RequestLike = [bool]$RequestLike
            HasExactDirective = [bool]$HasExactDirective
            HasStateSnapshot = [bool]$HasStateSnapshot
            PromptTokens = $PromptTokens
            CompletionTokens = $CompletionTokens
        }
    }

    $Events = @()

    # First prefer an explicit directive if the logger preserves it.
    for ($Index = 0; $Index -lt $Records.Count; $Index++) {
        $Current = $Records[$Index]

        if (
            -not $Current.RequestLike -or
            -not $Current.HasExactDirective -or
            $null -eq $Current.PromptTokens -or
            $null -eq $Current.CompletionTokens
        ) {
            continue
        }

        $PostPromptTokens = $null

        if (($Index + 1) -lt $Records.Count) {
            $Next = $Records[$Index + 1]

            if (
                $Next.RequestLike -and
                $null -ne $Next.PromptTokens
            ) {
                $PostPromptTokens = [long]$Next.PromptTokens
            }
        }

        $Events += [pscustomobject]@{
            SourceFile = [string]$Current.File
            PromptTokens = [long]$Current.PromptTokens
            CompletionTokens = [long]$Current.CompletionTokens
            PostPromptTokens = $PostPromptTokens
            EvidenceSource = "EXACT_COMPRESSION_DIRECTIVE"
        }
    }

    if ($Events.Count -gt 0) {
        return @($Events)
    }

    # Current Qwen Code OpenAI logging does not preserve the LocalAI
    # compression directive, but the no-tools lifecycle harness exposes a
    # deterministic structural signature:
    #
    #   request A: pre-compaction context -> large state_snapshot completion
    #   request B: smaller post-compaction context -> normal small completion
    #
    # Both requests are emitted by ONE CLI turn. Because this harness sets
    # --max-tool-calls 0 and disallows delegation, a second model request is
    # not attributable to a tool loop.
    for ($Index = 0; $Index -lt ($Records.Count - 1); $Index++) {
        $First = $Records[$Index]
        $Second = $Records[$Index + 1]

        if (
            -not $First.RequestLike -or
            -not $Second.RequestLike -or
            $null -eq $First.PromptTokens -or
            $null -eq $Second.PromptTokens -or
            $null -eq $First.CompletionTokens -or
            $null -eq $Second.CompletionTokens
        ) {
            continue
        }

        $PromptDrops = (
            [long]$Second.PromptTokens -lt
            [long]$First.PromptTokens
        )

        $SummarySizedCompletion = (
            [long]$First.CompletionTokens -ge 256
        )

        $NormalFollowupSmaller = (
            [long]$Second.CompletionTokens -lt
            [long]$First.CompletionTokens
        )

        $SnapshotBridge = (
            $First.HasStateSnapshot -and
            $Second.HasStateSnapshot
        )

        if (
            $PromptDrops -and
            $SummarySizedCompletion -and
            $NormalFollowupSmaller -and
            $SnapshotBridge
        ) {
            $Events += [pscustomobject]@{
                SourceFile = [string]$First.File
                PromptTokens = [long]$First.PromptTokens
                CompletionTokens = [long]$First.CompletionTokens
                PostPromptTokens = [long]$Second.PromptTokens
                EvidenceSource = "STRUCTURAL_MULTI_REQUEST_STATE_SNAPSHOT"
            }

            # The lifecycle harness expects at most one compaction sequence
            # in a single turn.
            break
        }
    }

    return @($Events)
}


function Convert-ContextLifecycleAuditValue {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return "NA"
    }

    return [string]$Value
}

function Get-ContextLifecycleOpenAiAudit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [pscustomobject]@{
            FileCount = 0
            TotalBytes = 0
            RequestLikeFileCount = 0
            UsageFileCount = 0
            MaxPromptTokens = $null
            MaxCompletionTokens = $null
            FileLines = @()
        }
    }

    $Files = @(
        Get-ChildItem `
            -LiteralPath $Path `
            -File `
            -Recurse `
            -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc, FullName
    )

    $TotalBytes = [long]0
    $RequestLikeFileCount = 0
    $UsageFileCount = 0
    $MaxPromptTokens = $null
    $MaxCompletionTokens = $null
    $FileLines = New-Object "System.Collections.Generic.List[string]"

    $PromptPattern = '"(?:prompt_tokens|promptTokenCount|input_tokens|inputTokens)"\s*:\s*(\d+)'
    $CompletionPattern = '"(?:completion_tokens|candidatesTokenCount|output_tokens|outputTokens)"\s*:\s*(\d+)'

    foreach ($File in $Files) {
        $TotalBytes += [long]$File.Length

        try {
            $Text = [System.IO.File]::ReadAllText($File.FullName)
        }
        catch {
            $Text = ""
        }

        $HasMessages = (
            $Text.IndexOf(
                '"messages"',
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasInput = (
            $Text.IndexOf(
                '"input"',
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $RequestLike = ($HasMessages -or $HasInput)

        if ($RequestLike) {
            $RequestLikeFileCount++
        }

        $PromptMatches = [regex]::Matches(
            $Text,
            $PromptPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $CompletionMatches = [regex]::Matches(
            $Text,
            $CompletionPattern,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        $HasUsage = (
            $PromptMatches.Count -gt 0 -or
            $CompletionMatches.Count -gt 0
        )

        if ($HasUsage) {
            $UsageFileCount++
        }

        $PromptValues = New-Object "System.Collections.Generic.List[string]"
        foreach ($Match in $PromptMatches) {
            [void]$PromptValues.Add(
                [string]$Match.Groups[1].Value
            )
            $Value = [long]$Match.Groups[1].Value
            if ($null -eq $MaxPromptTokens -or $Value -gt $MaxPromptTokens) { $MaxPromptTokens = $Value }
        }

        $CompletionValues = New-Object "System.Collections.Generic.List[string]"
        foreach ($Match in $CompletionMatches) {
            [void]$CompletionValues.Add(
                [string]$Match.Groups[1].Value
            )
            $Value = [long]$Match.Groups[1].Value
            if ($null -eq $MaxCompletionTokens -or $Value -gt $MaxCompletionTokens) { $MaxCompletionTokens = $Value }
        }

        $HasExactDirective = (
            $Text.IndexOf(
                "Produce the compact <state_snapshot> XML directly",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasPromptAnchor = (
            $Text.IndexOf(
                "You summarize the active coding-agent state when context compaction is required.",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasStateSnapshot = (
            $Text.IndexOf(
                "<state_snapshot>",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasChatCompression = (
            $Text.IndexOf(
                "chat-compression",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $HasCompressionWord = (
            $Text.IndexOf(
                "compression",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -ge 0
        )

        $PromptText = "NONE"
        if ($PromptValues.Count -gt 0) {
            $PromptText = $PromptValues.ToArray() -join ","
        }

        $CompletionText = "NONE"
        if ($CompletionValues.Count -gt 0) {
            $CompletionText = $CompletionValues.ToArray() -join ","
        }

        [void]$FileLines.Add(
            (
                "OPENAI_FILE name=" +
                $File.Name +
                " bytes=" +
                $File.Length +
                " request_like=" +
                $RequestLike +
                " usage=" +
                $HasUsage +
                " prompt_tokens=" +
                $PromptText +
                " completion_tokens=" +
                $CompletionText +
                " exact_directive=" +
                $HasExactDirective +
                " prompt_anchor=" +
                $HasPromptAnchor +
                " state_snapshot=" +
                $HasStateSnapshot +
                " chat_compression=" +
                $HasChatCompression +
                " compression_word=" +
                $HasCompressionWord
            )
        )
    }

    return [pscustomobject]@{
        FileCount = $Files.Count
        TotalBytes = $TotalBytes
        RequestLikeFileCount = $RequestLikeFileCount
        UsageFileCount = $UsageFileCount
        MaxPromptTokens = $MaxPromptTokens
        MaxCompletionTokens = $MaxCompletionTokens
        FileLines = @($FileLines.ToArray())
    }
}

function Invoke-ContextLifecycleOpenAiAudit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-BenchmarkIdle

    if (Test-PortListener -Port $Port) {
        throw (
            "CONTEXT_LIFECYCLE_AUDIT_PORT_NOT_FREE port=" +
            $Port
        )
    }

    $Candidate = New-AgenticConfirmationConfig `
        -Parameters $Parameters `
        -PromptBudget $ConfirmPromptReasoningBudget `
        -AlgorithmBudget $ConfirmAlgorithmReasoningBudget `
        -TestBudget $ConfirmTestReasoningBudget `
        -GrowthBudget $ConfirmGrowthBudget

    $LocalShaBefore = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaBefore = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $BeforeProjects = Get-QwenProjectDirectorySnapshot

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-context-openai-audit-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path $TempRoot "server.stdout.log"
    $StderrPath = Join-Path $TempRoot "server.stderr.log"

    $Process = $null
    $SessionId = [Guid]::NewGuid().ToString()
    $PreviousCumulativePrompt = $null
    $PreviousCumulativeOutput = $null
    $FailureReason = $null

    $ContextSize = [int]$Candidate["ctx-size"]
    $BasePacketChars = [int][Math]::Round($ContextSize * 0.24)

    if ($BasePacketChars -lt 7000) {
        $BasePacketChars = 7000
    }

    if ($BasePacketChars -gt 14000) {
        $BasePacketChars = 14000
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " CONTEXT LIFECYCLE OPENAI LOG AUDIT"
    Write-Host "========================================"
    Write-Host "MODE=SHORT_DIAGNOSTIC_ONLY"
    Write-Host "MAX_TURNS=4"
    Write-Host "RAW_LOG_CONTENT_PRINTED=NO"
    Write-Host "RAW_LOG_CONTENT_PERSISTED=NO"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host (
        "AUDIT_CANDIDATE prompt=" +
        $Candidate["prompt-reasoning-budget"] +
        " algorithm=" +
        $Candidate["algorithm-reasoning-budget"] +
        " test=" +
        $Candidate["test-reasoning-budget"] +
        " growth=" +
        $Candidate["max-context-growth-tokens-per-turn"] +
        " context=" +
        $Candidate["ctx-size"]
    )

    try {
        Write-ContextLifecycleBenchmarkWorkspace `
            -Path $TempRoot `
            -Parameters $Candidate

        $ArgumentLine = Get-BenchmarkRouterArgumentLine `
            -Parameters $Candidate

        Assert-LocalPath $StdoutPath
        Assert-LocalPath $StderrPath
        $Process = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ArgumentLine `
            -WorkingDirectory (Split-Path $ServerExe -Parent) `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($null -eq $Process) {
            throw "CONTEXT_LIFECYCLE_AUDIT_ROUTER_START=FAIL"
        }

        Wait-BenchmarkRouterReady -Process $Process

        for ($Turn = 1; $Turn -le 4; $Turn++) {
            $Packet = New-ContextLifecyclePacket `
                -Turn $Turn `
                -TargetChars $BasePacketChars

            $TurnOpenAiDir = Join-Path `
                $TempRoot `
                ("openai-turn-" + $Turn.ToString("D2"))

            Assert-LocalTree $TurnOpenAiDir

            [void](
                New-Item `
                    -ItemType Directory `
                    -Path $TurnOpenAiDir `
                    -Force
            )

            $QwenArgs = @(
                "--output-format", "stream-json",
                "--approval-mode", "yolo",
                "--model", [string]$ModelAlias,
                "--debug",
                "--openai-logging",
                "--openai-logging-dir", $TurnOpenAiDir,
                "--max-tool-calls", "0"
            )

            if ($Turn -eq 1) {
                $QwenArgs += @(
                    "--session-id",
                    $SessionId
                )
            }
            else {
                $QwenArgs += @(
                    "--resume",
                    $SessionId
                )
            }

            Push-Location $TempRoot

            try {
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"

                try {
                    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

                    $QwenOutput = (
                        [string]$Packet.Text |
                        & $QwenCodeCli @QwenArgs 2>&1 |
                        Out-String
                    )

                    $Timer.Stop()
                    $ExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            if ($ExitCode -ne 0) {
                $FailureReason = (
                    "QWEN_EXIT_CODE_" +
                    $ExitCode +
                    "_TURN_" +
                    $Turn
                )
                break
            }

            $Cumulative = Get-ContextLifecycleCumulativeMetrics `
                -Text $QwenOutput

            $RequestPrompt = $null
            $OutputDelta = $null

            if ($null -ne $Cumulative.PromptTokens) {
                if ($null -eq $PreviousCumulativePrompt) {
                    $RequestPrompt = [long]$Cumulative.PromptTokens
                }
                else {
                    $RequestPrompt = (
                        [long]$Cumulative.PromptTokens -
                        [long]$PreviousCumulativePrompt
                    )
                }

                $PreviousCumulativePrompt = [long]$Cumulative.PromptTokens
            }

            if ($null -ne $Cumulative.CompletionTokens) {
                if ($null -eq $PreviousCumulativeOutput) {
                    $OutputDelta = [long]$Cumulative.CompletionTokens
                }
                else {
                    $OutputDelta = (
                        [long]$Cumulative.CompletionTokens -
                        [long]$PreviousCumulativeOutput
                    )
                }

                $PreviousCumulativeOutput = [long]$Cumulative.CompletionTokens
            }

            $Audit = Get-ContextLifecycleOpenAiAudit `
                -Path $TurnOpenAiDir

            $RequestPromptText = Convert-ContextLifecycleAuditValue `
                -Value $RequestPrompt

            $OutputDeltaText = Convert-ContextLifecycleAuditValue `
                -Value $OutputDelta

            Write-Host ""
            Write-Host (
                "AUDIT_TURN index=" +
                $Turn +
                " wall=" +
                $Timer.Elapsed.TotalSeconds.ToString(
                    "F3",
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) +
                "s request_prompt=" +
                $RequestPromptText +
                " output_delta=" +
                $OutputDeltaText +
                " log_files=" +
                $Audit.FileCount +
                " request_like_files=" +
                $Audit.RequestLikeFileCount +
                " usage_files=" +
                $Audit.UsageFileCount +
                " total_bytes=" +
                $Audit.TotalBytes
            )

            foreach ($Line in $Audit.FileLines) {
                Write-Host $Line
            }
        }
    }
    catch {
        if ($null -eq $FailureReason) {
            $FailureReason = $_.Exception.Message
        }
    }
    finally {
        try {
            Stop-BenchmarkRouterProcess -Process $Process
        }
        finally {
            if (Test-Path -LiteralPath $TempRoot) {
                Assert-LocalTree $TempRoot
                Remove-Item `
                    -LiteralPath $TempRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Remove-NewQwenProjectDirectories `
                -Before $BeforeProjects
        }
    }

    $LocalShaAfter = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAfter = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if (
        $LocalShaAfter -ne $LocalShaBefore -or
        $SettingsShaAfter -ne $SettingsShaBefore
    ) {
        throw "CONTEXT_LIFECYCLE_AUDIT_PRODUCTION_CONFIG_CHANGED"
    }

    if ($null -ne $FailureReason) {
        Write-Host (
            "CONTEXT_LIFECYCLE_OPENAI_AUDIT=FAIL reason=" +
            $FailureReason
        )
        throw (
            "CONTEXT_LIFECYCLE_OPENAI_AUDIT_FAILED: " +
            $FailureReason
        )
    }

    Write-Host ""
    Write-Host "CONTEXT_LIFECYCLE_OPENAI_AUDIT=PASS"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "PERSISTENT_BENCHMARK_ARTIFACTS=NO"

    Assert-BenchmarkIdle
}


function New-ContextLifecycleRecallPrompt {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Sentinels
    )

    $Keys = New-Object "System.Collections.Generic.List[string]"

    foreach ($Sentinel in $Sentinels) {
        $Equals = $Sentinel.IndexOf(
            "=",
            [System.StringComparison]::Ordinal
        )

        if ($Equals -le 0) {
            throw (
                "CONTEXT_LIFECYCLE_INVALID_SENTINEL_FOR_RECALL: " +
                $Sentinel
            )
        }

        [void]$Keys.Add(
            $Sentinel.Substring(0,$Equals)
        )
    }

    return (
        "LOCALAI CONTEXT LIFECYCLE RETENTION CHECK`n`n" +
        "Do not call tools. Do not delegate. Do not inspect files.`n`n" +
        "Without asking for previous messages again, return the current " +
        "values of all durable KEEP invariants still retained by this session.`n`n" +
        "Required keys:`n" +
        (($Keys.ToArray()) -join "`n") +
        "`n`nReturn one compact JSON object only. Do not include explanations."
    )
}


function Get-ContextLifecycleRolloverMechanismContext {
    param(
        [Parameter(Mandatory = $true)]
        [int]$ProductionContext
    )

    if ($ProductionContext -lt 16384) {
        throw (
            "CONTEXT_LIFECYCLE_ROLLOVER_CONTEXT_TOO_SMALL production=" +
            $ProductionContext
        )
    }

    $Scaled = [int](
        [Math]::Floor(
            ($ProductionContext * 0.80) / 1024.0
        ) * 1024
    )

    $Floor = [Math]::Min(
        $ProductionContext,
        24576
    )

    $Ceiling = [Math]::Min(
        $ProductionContext,
        32768
    )

    $Candidate = [Math]::Max(
        $Floor,
        [Math]::Min(
            $Ceiling,
            $Scaled
        )
    )

    if ($Candidate -gt $ProductionContext) {
        $Candidate = $ProductionContext
    }

    return [int]$Candidate
}

function New-ContextLifecyclePendingPressurePacket {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Turn,

        [Parameter(Mandatory = $true)]
        [int]$TargetChars
    )

    if ($TargetChars -lt 12000) {
        throw "CONTEXT_LIFECYCLE_PENDING_PRESSURE_PACKET_TOO_SMALL"
    }

    $KeepDigest = Get-ContextLifecycleDigest `
        -Text ("localai-rollover-pending-pressure-" + $Turn)

    $Keep = (
        "KEEP_T" +
        $Turn.ToString("D2") +
        "=INV-" +
        $KeepDigest
    )

    $Builder = New-Object System.Text.StringBuilder

    [void]$Builder.AppendLine("LOCALAI ROLLOVER PENDING-REQUEST PRESSURE")
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine("Do not call tools. Do not delegate.")
    [void]$Builder.AppendLine(
        "Treat this durable invariant as current-session state:"
    )
    [void]$Builder.AppendLine($Keep)
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine(
        "The opaque payload below belongs to THIS CURRENT USER REQUEST. " +
        "It is not prior transcript and must remain part of the pending request " +
        "until this request is answered. Do not repeat the payload."
    )
    [void]$Builder.AppendLine("OPAQUE_PENDING_PAYLOAD_BEGIN")

    $Sha = [System.Security.Cryptography.SHA256]::Create()

    try {
        $Counter = 0

        while ($Builder.Length -lt ($TargetChars - 260)) {
            $Seed = (
                "localai-rollover-pressure;" +
                $Turn +
                ";" +
                $Counter
            )

            $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
            $Hash = $Sha.ComputeHash($Bytes)
            $Hex = [System.BitConverter]::ToString($Hash).Replace("-","")

            [void]$Builder.Append($Hex)
            $Counter++
        }
    }
    finally {
        $Sha.Dispose()
    }

    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine("OPAQUE_PENDING_PAYLOAD_END")
    [void]$Builder.AppendLine("")
    [void]$Builder.AppendLine(
        (
            "Reply with exactly: ACK T" +
            $Turn.ToString("D2") +
            " " +
            $Keep
        )
    )

    return [pscustomobject]@{
        Text = $Builder.ToString()
        Sentinel = $Keep
        CharCount = $Builder.Length
    }
}


function Get-ContextLifecycleRolloverEvidence {
    param(
        [AllowEmptyString()]
        [string]$Text = "",

        [AllowEmptyCollection()]
        [object[]]$Files = @()
    )

    $Sources = New-Object "System.Collections.Generic.List[string]"

    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        [void]$Sources.Add($Text)
    }

    foreach ($File in $Files) {
        try {
            [void]$Sources.Add(
                [System.IO.File]::ReadAllText(
                    [string]$File.FullName
                )
            )
        }
        catch {
        }
    }

    $Combined = $Sources.ToArray() -join "`n"

    $RequiredMatches = [regex]::Matches(
        $Combined,
        'LOCALAI_CONTEXT_ROLLOVER_REQUIRED:\s*reason=([^;\r\n]+)[^;\r\n]*(?:;\s*prompt_id=[^;\r\n]*)?(?:;\s*before=(\d+))?(?:;\s*after=(\d+))?(?:;\s*safe_target=(\d+))?(?:;\s*passes=(\d+))?',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $CompletedMatches = [regex]::Matches(
        $Combined,
        '\[LOCALAI_CONTEXT_ROLLOVER_V4\]\s+same-session fresh-chat rollover completed;\s*passes=(\d+);\s*history_entries=(\d+)',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )

    $Reason = $null
    $RequiredPasses = 0
    $BeforeTokens = $null
    $AfterTokens = $null
    $SafeTarget = $null

    if ($RequiredMatches.Count -gt 0) {
        $Last = $RequiredMatches[$RequiredMatches.Count - 1]
        $Reason = [string]$Last.Groups[1].Value

        if ($Last.Groups[2].Success) {
            $BeforeTokens = [long]$Last.Groups[2].Value
        }

        if ($Last.Groups[3].Success) {
            $AfterTokens = [long]$Last.Groups[3].Value
        }

        if ($Last.Groups[4].Success) {
            $SafeTarget = [long]$Last.Groups[4].Value
        }

        if ($Last.Groups[5].Success) {
            $RequiredPasses = [int]$Last.Groups[5].Value
        }
    }

    $CompletedPasses = 0
    $HistoryEntries = 0

    foreach ($Match in $CompletedMatches) {
        $Passes = [int]$Match.Groups[1].Value
        $Entries = [int]$Match.Groups[2].Value

        if ($Passes -gt $CompletedPasses) {
            $CompletedPasses = $Passes
        }

        if ($Entries -gt $HistoryEntries) {
            $HistoryEntries = $Entries
        }
    }

    return [pscustomobject]@{
        RequiredObserved = ($RequiredMatches.Count -gt 0)
        RequiredCount = $RequiredMatches.Count
        Reason = $Reason
        BeforeTokens = $BeforeTokens
        AfterTokens = $AfterTokens
        SafeTarget = $SafeTarget
        RequiredPasses = $RequiredPasses
        CompletedObserved = ($CompletedMatches.Count -gt 0)
        CompletedCount = $CompletedMatches.Count
        CompletedPasses = $CompletedPasses
        HistoryEntries = $HistoryEntries
    }
}

function Get-ContextLifecycleTurnUsage {
    param([AllowEmptyString()][string]$Text, [string]$Path)
    $Cumulative = Get-ContextLifecycleCumulativeMetrics -Text $Text
    $Audit = Get-ContextLifecycleOpenAiAudit -Path $Path
    $PromptTokens = $Audit.MaxPromptTokens
    $CompletionTokens = $Audit.MaxCompletionTokens
    $Source = 'OPENAI_LOG_MAX_PER_REQUEST'
    if ($null -eq $PromptTokens -and $null -eq $CompletionTokens) {
        $Source = if ($null -ne $Cumulative.PromptTokens -or $null -ne $Cumulative.CompletionTokens) { 'QWEN_STREAM_MAX_CUMULATIVE_ONLY' } else { 'MISSING' }
    }
    $Status = if ($null -eq $PromptTokens -and $null -eq $CompletionTokens) { 'MISSING' }
        elseif ($null -eq $PromptTokens -or $null -eq $CompletionTokens) { 'PARTIAL' } else { 'OBSERVED' }
    return [pscustomobject]@{
        Source = $Source; Status = $Status; PromptTokens = $PromptTokens; CompletionTokens = $CompletionTokens
        CumulativePromptTokens = $Cumulative.PromptTokens; CumulativeCompletionTokens = $Cumulative.CompletionTokens
        UsageFileCount = $Audit.UsageFileCount
        RequestFileCount = $Audit.RequestLikeFileCount
    }
}

function Get-ContextLifecycleCliProof {
    param([AllowEmptyString()][string]$Text, [string]$SessionId, [string]$Model,
        [int]$RequestFiles, [int]$ApiResponseDelta, [string]$ExpectedAck = '')
    function Test-ScalarField {
        param($Object, [string]$Name, [type]$Kind)
        if ($null -eq $Object) { return $false }
        $Property = $Object.PSObject.Properties[$Name]
        return ($null -ne $Property -and $Kind.IsInstanceOfType($Property.Value))
    }
    $Results = @(); $AssistantText = ''; $Malformed = $false; $ToolOutput = $false; $TerminalSeen = $false
    $TypeCounts = [ordered]@{ system=0; user=0; assistant=0; result=0; stream_event=0; control_request=0; control_response=0; UNKNOWN=0 }
    foreach ($Line in [regex]::Split($Text, '\r?\n')) {
        if (-not $Line.TrimStart().StartsWith('{')) { continue }
        try { $Event = $Line | ConvertFrom-Json -ErrorAction Stop }
        catch {
            $TypeCounts.UNKNOWN++
            if ($Line -match '"type"\s*:\s*"(?:result|assistant)"') { $Malformed = $true }
            continue
        }
        $TypeProperty = $Event.PSObject.Properties['type']
        if ($null -ne $TypeProperty -and -not (Test-ScalarField $Event 'type' ([string]))) { $Malformed = $true; $TypeCounts.UNKNOWN++; continue }
        $Type = Get-ObjectPropertyValue $Event 'type'
        $CountType = if ($Type -is [string] -and $TypeCounts.Keys -ccontains $Type) { $Type } else { 'UNKNOWN' }
        $TypeCounts[$CountType]++
        if ($Type -ceq 'result') { $Results += $Event; $TerminalSeen = $true; continue }
        $Message = Get-ObjectPropertyValue $Event 'message'
        if ($Type -ceq 'assistant' -and (-not (Test-ScalarField $Event 'session_id' ([string])) -or
            -not (Test-ScalarField $Event 'message' ([pscustomobject])) -or -not (Test-ScalarField $Message 'role' ([string])) -or
            -not (Test-ScalarField $Message 'model' ([string])) -or -not (Test-ScalarField $Message 'content' ([array])))) { $Malformed = $true; continue }
        if ($Type -cne 'assistant' -or (Get-ObjectPropertyValue $Event 'session_id') -cne $SessionId -or
            $null -eq $Event.PSObject.Properties['parent_tool_use_id'] -or $null -ne $Event.parent_tool_use_id -or
            (Get-ObjectPropertyValue $Message 'role') -cne 'assistant' -or (Get-ObjectPropertyValue $Message 'model') -cne $Model) { continue }
        if ($TerminalSeen) { $Malformed = $true }
        $Parts = @()
        foreach ($Block in @(Get-ObjectPropertyValue $Message 'content')) {
            if (-not (Test-ScalarField $Block 'type' ([string]))) { $Malformed = $true; continue }
            if ((Get-ObjectPropertyValue $Block 'type') -ceq 'tool_use') { $ToolOutput = $true }
            if ((Get-ObjectPropertyValue $Block 'type') -ceq 'text') {
                if (Test-ScalarField $Block 'text' ([string])) { $Parts += $Block.text } else { $Malformed = $true }
            }
        }
        $AssistantText = ($Parts -join '').Trim()
    }
    $Failure = $null; $Status = 'MISSING'; $Subtype = 'UNKNOWN'; $IsErrorToken = 'UNKNOWN'; $NumTurns = 0; $ErrorText = ''
    if ($Results.Count -eq 1 -and (Test-ScalarField $Results[0] 'is_error' ([bool]))) { $IsErrorToken = if ($Results[0].is_error) { 'TRUE' } else { 'FALSE' } }
    if ($Malformed) { $Failure = 'CLI_RESULT_MALFORMED'; $Status = 'MALFORMED' }
    elseif ($Results.Count -eq 0) { $Failure = 'CLI_RESULT_MISSING' }
    elseif ($Results.Count -ne 1) { $Failure = 'CLI_RESULT_AMBIGUOUS'; $Status = 'AMBIGUOUS' }
    else {
        $Result = $Results[0]
        $RawSubtype = Get-ObjectPropertyValue $Result 'subtype'
        if ((Test-ScalarField $Result 'subtype' ([string])) -and $RawSubtype -cin @('success','error_during_execution','error_max_turns','error_max_budget_usd')) { $Subtype = $RawSubtype }
        $IsError = Get-ObjectPropertyValue $Result 'is_error'
        $NumTurns = Get-ObjectPropertyValue $Result 'num_turns'
        $ErrorText = [string](Get-ObjectPropertyValue (Get-ObjectPropertyValue $Result 'error') 'message')
        if (-not (Test-ScalarField $Result 'session_id' ([string])) -or (Get-ObjectPropertyValue $Result 'session_id') -cne $SessionId -or
            -not (Test-ScalarField $Result 'is_error' ([bool])) -or
            (-not (Test-ScalarField $Result 'num_turns' ([int])) -and -not (Test-ScalarField $Result 'num_turns' ([long]))) -or $Subtype -eq 'UNKNOWN') {
            $Failure = 'CLI_RESULT_MALFORMED'; $Status = 'MALFORMED'; $NumTurns = 0
        }
        elseif ($IsError -or $Subtype -ne 'success') { $Failure = 'CLI_RESULT_ERROR'; $Status = 'ERROR' }
        elseif ($NumTurns -le 0) { $Failure = 'CLI_RESULT_NO_MODEL_TURN'; $Status = 'EMPTY' }
        elseif (-not (Test-ScalarField $Result 'result' ([string]))) { $Failure = 'CLI_RESULT_MALFORMED'; $Status = 'MALFORMED' }
        elseif ($AssistantText.Length -gt 0 -and -not $Result.result.Trim().Equals($AssistantText, [StringComparison]::Ordinal)) { $Failure = 'CLI_RESULT_MALFORMED'; $Status = 'MALFORMED' }
        else { $Status = 'SUCCESS' }
    }
    # Never expose provider error text; stdout success can still contain an API error.
    $ErrorCategory = switch -Regex ($ErrorText + "`n" + $AssistantText) {
        '(?i)context.{0,40}(?:length|window|size|exceed)|(?:too many|maximum).{0,20}tokens' { 'CONTEXT_LIMIT'; break }
        '(?i)unauthorized|authentication|invalid api key' { 'AUTHENTICATION'; break }
        '(?i)rate.?limit|too many requests' { 'RATE_LIMIT'; break }
        default { if ($Status -eq 'ERROR') { 'OTHER' } else { 'NONE' } }
    }
    $RequestSource = if ($RequestFiles -gt 0) { 'FRESH_OPENAI_REQUEST_LOG' }
        elseif ($ApiResponseDelta -gt 0) { 'API_RESPONSE_TELEMETRY_DELTA' } else { 'MISSING' }
    if ($null -eq $Failure) {
        if ($ToolOutput) { $Failure = 'CLI_UNEXPECTED_TOOL_OUTPUT' }
        elseif ([string]::IsNullOrWhiteSpace($AssistantText)) { $Failure = 'CLI_ASSISTANT_TEXT_MISSING' }
        elseif ($ErrorCategory -ne 'NONE') { $Failure = 'CLI_ASSISTANT_ERROR' }
        elseif ($RequestSource -eq 'MISSING') { $Failure = 'CLI_NO_NEW_MODEL_REQUEST' }
        elseif ($ExpectedAck.Length -gt 0 -and -not $AssistantText.Equals($ExpectedAck, [StringComparison]::Ordinal)) { $Failure = 'CLI_ACK_MISMATCH' }
    }
    return [pscustomobject]@{
        FailureReason = $Failure; ResultStatus = $Status; ResultSubtype = $Subtype; NumTurns = $NumTurns
        ErrorCategory = $ErrorCategory; AssistantText = $AssistantText; RequestSource = $RequestSource
        IsError = $IsErrorToken; AssistantTextPresent = ($AssistantText.Length -gt 0)
        EventTypes = ($TypeCounts.GetEnumerator() | ForEach-Object { $_.Key + ':' + $_.Value }) -join ','
    }
}

function Invoke-ContextLifecycleRolloverStress {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-BenchmarkIdle

    if (Test-PortListener -Port $Port) {
        throw (
            "CONTEXT_LIFECYCLE_ROLLOVER_PORT_NOT_FREE port=" +
            $Port
        )
    }

    $Candidate = New-AgenticConfirmationConfig `
        -Parameters $Parameters `
        -PromptBudget $ConfirmPromptReasoningBudget `
        -AlgorithmBudget $ConfirmAlgorithmReasoningBudget `
        -TestBudget $ConfirmTestReasoningBudget `
        -GrowthBudget $ConfirmGrowthBudget

    $ProductionContext = [int]$Candidate["ctx-size"]
    $MechanismContext = Get-ContextLifecycleRolloverMechanismContext `
        -ProductionContext $ProductionContext

    $Candidate["ctx-size"] = [string]$MechanismContext

    $MaximumReasoning = [Math]::Max(
        1024,
        [int][Math]::Floor($MechanismContext * 0.95)
    )

    foreach ($Budget in @(
        [int]$Candidate["prompt-reasoning-budget"],
        [int]$Candidate["algorithm-reasoning-budget"],
        [int]$Candidate["test-reasoning-budget"]
    )) {
        if ($Budget -gt $MaximumReasoning) {
            throw (
                "CONTEXT_LIFECYCLE_ROLLOVER_REASONING_EXCEEDS_TEMP_CONTEXT budget=" +
                $Budget +
                " max=" +
                $MaximumReasoning
            )
        }
    }

    $LocalShaBefore = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaBefore = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $BeforeJsonl = Get-QwenJsonlSnapshot
    $BeforeProjects = Get-QwenProjectDirectorySnapshot

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-context-rollover-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path $TempRoot "server.stdout.log"
    $StderrPath = Join-Path $TempRoot "server.stderr.log"

    $Process = $null
    $SessionId = [Guid]::NewGuid().ToString()
    $Sentinels = New-Object "System.Collections.Generic.List[string]"
    $FailureReason = $null
    $FinalTelemetry = $null
    $RolloverTurn = 0
    $PostRolloverTurns = 0
    $RolloverCompleted = $false
    $RolloverRequired = $false
    $PreviousRequiredCount = 0
    $PreviousCompletedCount = 0
    $CompletionPasses = 0
    $CompletionHistoryEntries = 0
    $RequiredReason = $null
    $RequiredBefore = $null
    $RequiredAfter = $null
    $RequiredSafeTarget = $null
    $CompactionRequestTurns = 0
    $MaxDiscoveryTurns = 7
    $DiscoveryTurns = 0
    $ExecutedTurns = 0
    $ProcessedTurns = 0
    $ProcessedPressureAttempts = 0
    $PreviousCumulativePrompt = $null
    $PreviousCumulativeCompletion = $null
    $RetentionCalls = 0
    $NotExercisedReason = $null
    $RequiredPostRolloverTurns = 2
    $PressureAttempt = 0
    $FirstCompactionObserved = $false

    $BasePacketChars = [int][Math]::Round(
        $MechanismContext * 0.24
    )

    if ($BasePacketChars -lt 6500) {
        $BasePacketChars = 6500
    }

    if ($BasePacketChars -gt 8500) {
        $BasePacketChars = 8500
    }

    # Experimental bounded current-request pressure: deliberately avoid the
    # previously observed context-limit at 29350 high-entropy characters.
    # These are intentionally CHAR targets, not token targets. The payload is
    # deterministic high-entropy hex rather than repetitive prose so BPE cannot
    # make it unrealistically cheap. The goal is to make the CURRENT pending
    # user request itself consume enough context that compacting prior history
    # cannot get below the real auto-compaction safe target.
    $PressurePacketChars = @(
        [int][Math]::Round($MechanismContext * 0.42),
        [int][Math]::Round($MechanismContext * 0.49),
        [int][Math]::Round($MechanismContext * 0.55)
    )

    for ($PressureIndex = 0; $PressureIndex -lt $PressurePacketChars.Count; $PressureIndex++) {
        if ($PressurePacketChars[$PressureIndex] -lt 13500) {
            $PressurePacketChars[$PressureIndex] = 13500
        }

        if ($PressurePacketChars[$PressureIndex] -gt 19000) {
            $PressurePacketChars[$PressureIndex] = 19000
        }
    }
    # Reserve the full pressure ladder and continuation even after late compaction.
    $MaxTurns = $MaxDiscoveryTurns + $PressurePacketChars.Count + $RequiredPostRolloverTurns

    Write-Host ""
    Write-Host "========================================"
    Write-Host " FORCED CONTEXT LIFECYCLE: ROLLOVER"
    Write-Host "========================================"
    Write-Host "SCOPE=ROOT_SAME_SESSION_FRESH_CHAT_ROLLOVER"
    Write-Host "TRIGGER=REAL_LOCALAI_CONTEXT_ROLLOVER_REQUIRED_PATH"
    Write-Host "ROLLOVER_REQUIRED_TOKEN_SOURCE=RUNTIME_EFFECTIVE_CONTEXT_ESTIMATE"
    Write-Host "RUNTIME_TEST_HOOKS=NONE"
    Write-Host "PRESSURE_POLICY=AFTER_FIRST_PROVEN_COMPACTION_BOUNDED_HIGH_ENTROPY_CURRENT_PENDING_REQUEST"
    Write-Host (
        "PRESSURE_PACKET_CHARS=" +
        ($PressurePacketChars -join ",")
    )
    Write-Host "TOOLS_ALLOWED=NO"
    Write-Host "DELEGATION_ALLOWED=NO"
    Write-Host "PRODUCTION_CONTEXT_MODIFIED=NO"
    Write-Host "MECHANISM_CONTEXT_TEMPORARY=YES"
    Write-Host (
        "PRODUCTION_CONTEXT=" +
        $ProductionContext
    )
    Write-Host (
        "MECHANISM_CONTEXT=" +
        $MechanismContext
    )
    Write-Host "MECHANISM_CONTEXT_POLICY=80_PERCENT_ROUNDED_CLAMP_24576_32768"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_RATIO_NOT_TUNED"
    Write-Host "PRODUCTION_CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
    Write-Host "ROLLOVER_REQUIRED_MINIMUM=1"
    Write-Host "ROLLOVER_COMPLETED_REQUIRED=1"
    Write-Host "DISCOVERY_TURN_LIMIT=$MaxDiscoveryTurns"
    Write-Host "PENDING_PRESSURE_ATTEMPT_LIMIT=$($PressurePacketChars.Count)"
    Write-Host "STRESS_TURN_LIMIT=$MaxTurns"
    Write-Host "RETENTION_CALL_LIMIT=1"
    Write-Host (
        "POST_ROLLOVER_TURNS_REQUIRED=" +
        $RequiredPostRolloverTurns
    )
    Write-Host "RETENTION_CHECK=KEYS_ONLY_RECALL_EXPECTED_VALUES_NOT_DISCLOSED"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host (
        "ROLLOVER_CANDIDATE prompt=" +
        $Candidate["prompt-reasoning-budget"] +
        " algorithm=" +
        $Candidate["algorithm-reasoning-budget"] +
        " test=" +
        $Candidate["test-reasoning-budget"] +
        " growth=" +
        $Candidate["max-context-growth-tokens-per-turn"] +
        " mechanism_context=" +
        $Candidate["ctx-size"]
    )

    try {
        Write-ContextLifecycleBenchmarkWorkspace `
            -Path $TempRoot `
            -Parameters $Candidate

        $ArgumentLine = Get-BenchmarkRouterArgumentLine `
            -Parameters $Candidate

        Assert-LocalPath $StdoutPath
        Assert-LocalPath $StderrPath
        $Process = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ArgumentLine `
            -WorkingDirectory (Split-Path $ServerExe -Parent) `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($null -eq $Process) {
            throw "CONTEXT_LIFECYCLE_ROLLOVER_ROUTER_START=FAIL"
        }

        Wait-BenchmarkRouterReady -Process $Process

        for ($Turn = 1; $Turn -le $MaxTurns; $Turn++) {
            $UsingPendingPressure = $false

            if ($RolloverCompleted) {
                $Phase = 'POST_ROLLOVER'
                $TargetChars = 1400
                $Packet = New-ContextLifecyclePacket `
                    -Turn $Turn `
                    -TargetChars $TargetChars
            }
            elseif ($FirstCompactionObserved) {
                if ($PressureAttempt -ge $PressurePacketChars.Count) {
                    $NotExercisedReason = 'PENDING_PRESSURE_LIMIT_REACHED'
                    break
                }
                $Phase = 'PENDING_PRESSURE'
                $TargetChars = [int]$PressurePacketChars[$PressureAttempt]
                $Packet = New-ContextLifecyclePendingPressurePacket `
                    -Turn $Turn `
                    -TargetChars $TargetChars
                $UsingPendingPressure = $true
                $PressureAttempt++
            }
            else {
                if ($DiscoveryTurns -ge $MaxDiscoveryTurns) {
                    $NotExercisedReason = 'FIRST_COMPACTION_NOT_OBSERVED'
                    break
                }
                $Phase = 'COMPACTION_DISCOVERY'
                $DiscoveryTurns++
                $TargetChars = $BasePacketChars
                $Packet = New-ContextLifecyclePacket `
                    -Turn $Turn `
                    -TargetChars $TargetChars
            }

            [void]$Sentinels.Add([string]$Packet.Sentinel)
            Write-Host "ROLLOVER_TURN_START index=$Turn phase=$Phase packet_chars=$($Packet.CharCount) pressure_attempt=$PressureAttempt"

            $TurnOpenAiDir = Join-Path `
                $TempRoot `
                ("openai-rollover-turn-" + $Turn.ToString("D2"))

            Assert-LocalTree $TurnOpenAiDir

            [void](
                New-Item `
                    -ItemType Directory `
                    -Path $TurnOpenAiDir `
                    -Force
            )

            $QwenArgs = @(
                "--output-format", "stream-json",
                "--approval-mode", "yolo",
                "--model", [string]$ModelAlias,
                "--debug",
                "--openai-logging",
                "--openai-logging-dir", $TurnOpenAiDir,
                "--max-tool-calls", "0"
            )

            if ($Turn -eq 1) {
                $QwenArgs += @(
                    "--session-id",
                    $SessionId
                )
            }
            else {
                $QwenArgs += @(
                    "--resume",
                    $SessionId
                )
            }

            Push-Location $TempRoot

            try {
                $ApiResponsesBefore = (Get-RoleAwareTelemetrySummary -Files @(Get-ChangedQwenJsonlFiles -Before $BeforeJsonl)).ApiResponses
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"

                try {
                    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

                    $QwenOutput = (
                        [string]$Packet.Text |
                        & $QwenCodeCli @QwenArgs 2>&1 |
                        Out-String
                    )

                    $Timer.Stop()
                    $ExitCode = $LASTEXITCODE
                    $ExecutedTurns++
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            $Usage = Get-ContextLifecycleTurnUsage -Text $QwenOutput -Path $TurnOpenAiDir
            $CumulativeChange = if ($null -eq $Usage.CumulativePromptTokens -and $null -eq $Usage.CumulativeCompletionTokens) { 'MISSING' }
                elseif ($null -eq $PreviousCumulativePrompt -and $null -eq $PreviousCumulativeCompletion) { 'INITIAL' }
                elseif ($Usage.CumulativePromptTokens -ne $PreviousCumulativePrompt -or $Usage.CumulativeCompletionTokens -ne $PreviousCumulativeCompletion) { 'CHANGED' } else { 'UNCHANGED' }
            $PreviousCumulativePrompt = $Usage.CumulativePromptTokens
            $PreviousCumulativeCompletion = $Usage.CumulativeCompletionTokens

            if ($ExitCode -ne 0) {
                Write-Host ("ROLLOVER_TURN index=$Turn phase=$Phase exit_code=$ExitCode usage_source=$($Usage.Source) usage_status=$($Usage.Status)" +
                    " prompt_tokens=$(Convert-ContextLifecycleAuditValue $Usage.PromptTokens) completion_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CompletionTokens)" +
                    " openai_request_files=$($Usage.RequestFileCount) openai_usage_files=$($Usage.UsageFileCount)" +
                    " cli_cumulative_prompt_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CumulativePromptTokens) cli_cumulative_completion_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CumulativeCompletionTokens) cumulative_usage_change=$CumulativeChange")
                $FailureReason = (
                    "QWEN_EXIT_CODE_" +
                    $ExitCode +
                    "_TURN_" +
                    $Turn
                )

                $Cli = Get-ContextLifecycleCliProof -Text $QwenOutput -SessionId $SessionId -Model $ModelAlias -RequestFiles $Usage.RequestFileCount -ApiResponseDelta 0
                Write-Host "ROLLOVER_CLI_ERROR result_status=$($Cli.ResultStatus) result_subtype=$($Cli.ResultSubtype) is_error=$($Cli.IsError) event_types=$($Cli.EventTypes) assistant_text_present=$($Cli.AssistantTextPresent) error_category=$($Cli.ErrorCategory) request_evidence=$($Cli.RequestSource) api_response_delta=UNKNOWN"
                break
            }

            $OpenAiEvents = @(
                Get-ContextLifecycleOpenAiCompactionEvents `
                    -Path $TurnOpenAiDir
            )

            $CompactionBefore = $null
            $CompactionAfter = $null
            $CompactionSummaryOutput = $null

            if ($OpenAiEvents.Count -gt 0) {
                $CompactionRequestTurns++

                $PrimaryCompaction = $OpenAiEvents[0]

                if ($null -ne $PrimaryCompaction.PromptTokens) {
                    $CompactionBefore = [long]$PrimaryCompaction.PromptTokens
                }

                if ($null -ne $PrimaryCompaction.PostPromptTokens) {
                    $CompactionAfter = [long]$PrimaryCompaction.PostPromptTokens
                }

                if ($null -ne $PrimaryCompaction.CompletionTokens) {
                    $CompactionSummaryOutput = [long]$PrimaryCompaction.CompletionTokens
                }

                if (-not $FirstCompactionObserved) {
                    $FirstCompactionObserved = $true
                }
            }

            Start-Sleep -Milliseconds 350

            $ChangedJsonl = @(
                Get-ChangedQwenJsonlFiles `
                    -Before $BeforeJsonl
            )

            $Telemetry = Get-RoleAwareTelemetrySummary `
                -Files $ChangedJsonl

            $FinalTelemetry = $Telemetry
            $ApiDelta = [Math]::Max(0, $Telemetry.ApiResponses - $ApiResponsesBefore)
            $ExpectedAck = 'ACK T' + $Turn.ToString('D2') + ' ' + $Packet.Sentinel
            $Cli = Get-ContextLifecycleCliProof -Text $QwenOutput -SessionId $SessionId -Model $ModelAlias `
                -RequestFiles $Usage.RequestFileCount -ApiResponseDelta $ApiDelta -ExpectedAck $ExpectedAck
            Write-Host ("ROLLOVER_CLI_PROOF index=$Turn phase=$Phase result_status=$($Cli.ResultStatus) result_subtype=$($Cli.ResultSubtype) num_turns=$($Cli.NumTurns)" +
                " is_error=$($Cli.IsError) event_types=$($Cli.EventTypes) assistant_text_present=$($Cli.AssistantTextPresent)" +
                " request_evidence=$($Cli.RequestSource) api_response_delta=$ApiDelta error_category=$($Cli.ErrorCategory) verified=$($null -eq $Cli.FailureReason)")
            if ($null -ne $Cli.FailureReason) { $FailureReason = $Cli.FailureReason }
            else {
                $ProcessedTurns++
                if ($UsingPendingPressure) { $ProcessedPressureAttempts++ }
            }

            $Evidence = Get-ContextLifecycleRolloverEvidence `
                -Text $QwenOutput `
                -Files $ChangedJsonl
            $TurnEvidence = Get-ContextLifecycleRolloverEvidence -Text $QwenOutput

            $CompletedNow = (
                $Evidence.CompletedObserved -or
                $Telemetry.ContextRolloverCompletedCount -gt 0
            )
            if ($Evidence.RequiredObserved -or $Telemetry.ContextRolloverRequiredCount -gt 0) { $RolloverRequired = $true }
            # Historical markers remain in resumed JSONL; only new turn evidence
            # or an increase in cumulative telemetry indicates another rollover.
            if ($null -eq $FailureReason -and -not $RolloverCompleted -and ($TurnEvidence.RequiredCount -gt 1 -or $TurnEvidence.CompletedCount -gt 1 -or
                $Telemetry.ContextRolloverCompletedCount -gt 1)) {
                $FailureReason = 'MULTIPLE_ROLLOVERS_ON_FIRST_COMPLETED_TURN'
            }
            elseif ($null -eq $FailureReason -and $RolloverCompleted -and ($TurnEvidence.RequiredObserved -or $TurnEvidence.CompletedObserved -or
                $Telemetry.ContextRolloverRequiredCount -gt $PreviousRequiredCount -or
                $Telemetry.ContextRolloverCompletedCount -gt $PreviousCompletedCount)) {
                $FailureReason = 'ROLLOVER_REPEATED_DURING_CONTINUATION'
            }
            $PreviousRequiredCount = [Math]::Max($PreviousRequiredCount, $Telemetry.ContextRolloverRequiredCount)
            $PreviousCompletedCount = [Math]::Max($PreviousCompletedCount, $Telemetry.ContextRolloverCompletedCount)

            if ($Evidence.RequiredObserved) {
                $RequiredReason = $Evidence.Reason
                $RequiredBefore = $Evidence.BeforeTokens
                $RequiredAfter = $Evidence.AfterTokens
                $RequiredSafeTarget = $Evidence.SafeTarget
            }

            if ($Evidence.CompletedPasses -gt $CompletionPasses) {
                $CompletionPasses = $Evidence.CompletedPasses
            }

            if ($Evidence.HistoryEntries -gt $CompletionHistoryEntries) {
                $CompletionHistoryEntries = $Evidence.HistoryEntries
            }

            if (
                $CompletedNow -and
                -not $RolloverCompleted
            ) {
                $RolloverCompleted = $true
                $RolloverTurn = $Turn
            }
            elseif ($RolloverCompleted -and $null -eq $FailureReason -and $Telemetry.MaxTokensCount -eq 0 -and
                $Telemetry.NoVisibleProgressCount -eq 0 -and $Telemetry.ToolCalls -eq 0) {
                $PostRolloverTurns++
            }

            Write-Host (
                "ROLLOVER_TURN index=" +
                $Turn +
                " phase=" + $Phase +
                " packet_chars=" +
                $Packet.CharCount +
                " wall=" +
                $Timer.Elapsed.TotalSeconds.ToString(
                    "F3",
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) +
                " compaction_request_turn=" +
                ($OpenAiEvents.Count -gt 0) +
                " compaction_before=" +
                $(if ($null -eq $CompactionBefore) { "NA" } else { [string]$CompactionBefore }) +
                " compaction_after=" +
                $(if ($null -eq $CompactionAfter) { "NA" } else { [string]$CompactionAfter }) +
                " compaction_summary_output=" +
                $(if ($null -eq $CompactionSummaryOutput) { "NA" } else { [string]$CompactionSummaryOutput }) +
                " pending_pressure=" +
                $UsingPendingPressure +
                " pressure_attempt=" +
                $PressureAttempt +
                " usage_source=" + $Usage.Source +
                " usage_status=" + $Usage.Status +
                " prompt_tokens=" + (Convert-ContextLifecycleAuditValue $Usage.PromptTokens) +
                " completion_tokens=" + (Convert-ContextLifecycleAuditValue $Usage.CompletionTokens) +
                " cli_cumulative_prompt_tokens=" + (Convert-ContextLifecycleAuditValue $Usage.CumulativePromptTokens) +
                " cli_cumulative_completion_tokens=" + (Convert-ContextLifecycleAuditValue $Usage.CumulativeCompletionTokens) +
                " openai_usage_files=" + $Usage.UsageFileCount +
                " openai_request_files=" + $Usage.RequestFileCount +
                " cumulative_usage_change=" + $CumulativeChange +
                " exit_code=" + $ExitCode +
                " required_marker=" +
                $Evidence.RequiredObserved +
                " completed_marker=" +
                $Evidence.CompletedObserved +
                " telemetry_required=" +
                $Telemetry.ContextRolloverRequiredCount +
                " telemetry_completed=" +
                $Telemetry.ContextRolloverCompletedCount +
                " completed_passes=" +
                $CompletionPasses +
                " history_entries=" +
                $CompletionHistoryEntries +
                " post_rollover_turns=" +
                $PostRolloverTurns +
                " max_tokens=" +
                $Telemetry.MaxTokensCount +
                " no_visible_progress=" +
                $Telemetry.NoVisibleProgressCount +
                " tool_calls=" +
                $Telemetry.ToolCalls
            )
            if ($null -ne $FailureReason) { break }

            if ($Telemetry.MaxTokensCount -gt 0) {
                $FailureReason = "MAX_TOKENS_OBSERVED"
                break
            }

            if ($Telemetry.NoVisibleProgressCount -gt 0) {
                $FailureReason = "NO_VISIBLE_PROGRESS_OBSERVED"
                break
            }

            if ($Telemetry.ToolCalls -gt 0) {
                $FailureReason = "UNEXPECTED_TOOL_CALLS"
                break
            }

            if (
                $RolloverCompleted -and
                $PostRolloverTurns -ge
                $RequiredPostRolloverTurns
            ) {
                break
            }
        }

        if (
            $null -eq $FailureReason -and
            -not $RolloverCompleted
        ) {
            if ($RolloverRequired) {
                $FailureReason = 'ROLLOVER_REQUIRED_WITHOUT_COMPLETION'
            }
            else {
                $FailureReason = 'ROLLOVER_NOT_EXERCISED'
                if ($null -eq $NotExercisedReason) { $NotExercisedReason = 'STRESS_TURN_LIMIT_REACHED' }
            }
        }
        if ($null -eq $FailureReason -and -not $RolloverRequired) { $FailureReason = 'ROLLOVER_REQUIRED_EVIDENCE_MISSING' }

        if (
            $null -eq $FailureReason -and
            $CompletionPasses -le 0 -and
            $CompactionRequestTurns -le 0
        ) {
            $FailureReason = "ROLLOVER_WITHOUT_PROVEN_COMPACTION_PASS"
        }

        if (
            $null -eq $FailureReason -and
            $PostRolloverTurns -lt
            $RequiredPostRolloverTurns
        ) {
            $FailureReason = "POST_ROLLOVER_CONTINUATION_MISSING"
        }

        if ($null -eq $FailureReason) {
            $RecallPrompt = New-ContextLifecycleRecallPrompt `
                -Sentinels $Sentinels.ToArray()

            $RecallOpenAiDir = Join-Path $TempRoot "openai-rollover-recall"

            Assert-LocalTree $RecallOpenAiDir

            [void](
                New-Item `
                    -ItemType Directory `
                    -Path $RecallOpenAiDir `
                    -Force
            )

            $RecallArgs = @(
                "--output-format", "stream-json",
                "--approval-mode", "yolo",
                "--model", [string]$ModelAlias,
                "--debug",
                "--openai-logging",
                "--openai-logging-dir", $RecallOpenAiDir,
                "--max-tool-calls", "0",
                "--resume", $SessionId
            )

            Push-Location $TempRoot

            try {
                $ApiResponsesBefore = (Get-RoleAwareTelemetrySummary -Files @(Get-ChangedQwenJsonlFiles -Before $BeforeJsonl)).ApiResponses
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"

                try {
                    $RecallOutput = (
                        $RecallPrompt |
                        & $QwenCodeCli @RecallArgs 2>&1 |
                        Out-String
                    )
                    $RecallExit = $LASTEXITCODE
                    $RetentionCalls++
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            $Usage = Get-ContextLifecycleTurnUsage -Text $RecallOutput -Path $RecallOpenAiDir
            $CumulativeChange = if ($null -eq $Usage.CumulativePromptTokens -and $null -eq $Usage.CumulativeCompletionTokens) { 'MISSING' }
                elseif ($null -eq $PreviousCumulativePrompt -and $null -eq $PreviousCumulativeCompletion) { 'INITIAL' }
                elseif ($Usage.CumulativePromptTokens -ne $PreviousCumulativePrompt -or $Usage.CumulativeCompletionTokens -ne $PreviousCumulativeCompletion) { 'CHANGED' } else { 'UNCHANGED' }
            $RecallTelemetry = Get-RoleAwareTelemetrySummary -Files @(Get-ChangedQwenJsonlFiles -Before $BeforeJsonl)
            $ApiDelta = [Math]::Max(0, $RecallTelemetry.ApiResponses - $ApiResponsesBefore)
            $Cli = Get-ContextLifecycleCliProof -Text $RecallOutput -SessionId $SessionId -Model $ModelAlias `
                -RequestFiles $Usage.RequestFileCount -ApiResponseDelta $ApiDelta
            Write-Host ("ROLLOVER_RETENTION phase=RETENTION exit_code=$RecallExit usage_source=$($Usage.Source) usage_status=$($Usage.Status)" +
                " prompt_tokens=$(Convert-ContextLifecycleAuditValue $Usage.PromptTokens) completion_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CompletionTokens)" +
                " cli_cumulative_prompt_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CumulativePromptTokens) cli_cumulative_completion_tokens=$(Convert-ContextLifecycleAuditValue $Usage.CumulativeCompletionTokens)" +
                " openai_usage_files=$($Usage.UsageFileCount) openai_request_files=$($Usage.RequestFileCount) cumulative_usage_change=$CumulativeChange")
            Write-Host "ROLLOVER_CLI_PROOF phase=RETENTION result_status=$($Cli.ResultStatus) result_subtype=$($Cli.ResultSubtype) is_error=$($Cli.IsError) event_types=$($Cli.EventTypes) assistant_text_present=$($Cli.AssistantTextPresent) request_evidence=$($Cli.RequestSource) api_response_delta=$ApiDelta error_category=$($Cli.ErrorCategory) verified=$($null -eq $Cli.FailureReason)"
            if ($RecallExit -ne 0) {
                $FailureReason = (
                    "RETENTION_RECALL_EXIT_CODE_" +
                    $RecallExit
                )
            }
            else {
                if ($null -ne $Cli.FailureReason) { $FailureReason = $Cli.FailureReason }
                $Missing = @(
                    $Sentinels.ToArray() |
                    Where-Object {
                        $Cli.AssistantText.IndexOf(
                            [string]$_,
                            [System.StringComparison]::Ordinal
                        ) -lt 0
                    }
                )

                if ($null -eq $FailureReason -and $Missing.Count -gt 0) {
                    Write-Host (
                        "MISSING_SENTINELS=" +
                        ($Missing -join ",")
                    )
                    $FailureReason = "RETENTION_SENTINELS_MISSING"
                }
            }

            Start-Sleep -Milliseconds 350

            $ChangedJsonl = @(
                Get-ChangedQwenJsonlFiles `
                    -Before $BeforeJsonl
            )

            $FinalTelemetry = Get-RoleAwareTelemetrySummary `
                -Files $ChangedJsonl
            $RecallEvidence = Get-ContextLifecycleRolloverEvidence -Text $RecallOutput
            if ($null -eq $FailureReason) {
                if ($RecallEvidence.RequiredObserved -or $RecallEvidence.CompletedObserved -or
                    $FinalTelemetry.ContextRolloverRequiredCount -gt $PreviousRequiredCount -or
                    $FinalTelemetry.ContextRolloverCompletedCount -gt $PreviousCompletedCount) { $FailureReason = 'ROLLOVER_DURING_RETENTION' }
                elseif ($FinalTelemetry.MaxTokensCount -gt 0) { $FailureReason = 'MAX_TOKENS_OBSERVED' }
                elseif ($FinalTelemetry.NoVisibleProgressCount -gt 0) { $FailureReason = 'NO_VISIBLE_PROGRESS_OBSERVED' }
                elseif ($FinalTelemetry.ToolCalls -gt 0) { $FailureReason = 'UNEXPECTED_TOOL_CALLS' }
            }
        }
    }
    catch {
        if ($null -eq $FailureReason) {
            $FailureReason = $_.Exception.Message
        }
    }
    finally {
        try {
            Stop-BenchmarkRouterProcess -Process $Process
        }
        finally {
            if (Test-Path -LiteralPath $TempRoot) {
                Assert-LocalTree $TempRoot
                Remove-Item `
                    -LiteralPath $TempRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Remove-NewQwenProjectDirectories `
                -Before $BeforeProjects
        }
    }

    $LocalShaAfter = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAfter = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if (
        $LocalShaAfter -ne $LocalShaBefore -or
        $SettingsShaAfter -ne $SettingsShaBefore
    ) {
        throw "CONTEXT_LIFECYCLE_ROLLOVER_PRODUCTION_CONFIG_CHANGED"
    }

    if ($null -eq $FinalTelemetry) {
        $FinalTelemetry = [pscustomobject]@{
            ContextRolloverRequiredCount = 0
            ContextRolloverCompletedCount = 0
            ContextCompactionNoProgressCount = 0
            MaxTokensCount = 0
            NoVisibleProgressCount = 0
            ToolCalls = 0
        }
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " CONTEXT LIFECYCLE ROLLOVER RESULT"
    Write-Host "========================================"
    Write-Host (
        "PRODUCTION_CONTEXT=" +
        $ProductionContext
    )
    Write-Host (
        "MECHANISM_CONTEXT=" +
        $MechanismContext
    )
    Write-Host (
        "ROLLOVER_TURN=" +
        $RolloverTurn
    )
    Write-Host (
        "ROLLOVER_COMPLETED=" +
        $RolloverCompleted
    )
    Write-Host "ROLLOVER_REQUIRED_OBSERVED=$RolloverRequired"
    Write-Host "EXECUTED_STRESS_TURNS=$ExecutedTurns"
    Write-Host "PROCESSED_STRESS_TURNS=$ProcessedTurns"
    Write-Host "PROCESSED_PRESSURE_ATTEMPTS=$ProcessedPressureAttempts"
    Write-Host "EXECUTED_RETENTION_CALLS=$RetentionCalls"
    Write-Host "DISCOVERY_TURNS=$DiscoveryTurns"
    Write-Host "STRESS_TURN_LIMIT=$MaxTurns"
    Write-Host (
        "ROLLOVER_COMPLETION_PASSES=" +
        $CompletionPasses
    )
    Write-Host (
        "ROLLOVER_HISTORY_ENTRIES=" +
        $CompletionHistoryEntries
    )
    Write-Host (
        "ROLLOVER_REQUIRED_REASON=" +
        $(
            if ([string]::IsNullOrWhiteSpace($RequiredReason)) {
                "NOT_EXPOSED_TO_HARNESS"
            }
            else {
                $RequiredReason
            }
        )
    )
    Write-Host (
        "ROLLOVER_REQUIRED_BEFORE=" +
        $(if ($null -eq $RequiredBefore) { "NA" } else { [string]$RequiredBefore })
    )
    Write-Host (
        "ROLLOVER_REQUIRED_AFTER=" +
        $(if ($null -eq $RequiredAfter) { "NA" } else { [string]$RequiredAfter })
    )
    Write-Host (
        "ROLLOVER_SAFE_TARGET=" +
        $(if ($null -eq $RequiredSafeTarget) { "NA" } else { [string]$RequiredSafeTarget })
    )
    Write-Host (
        "COMPACTION_REQUEST_TURNS=" +
        $CompactionRequestTurns
    )
    Write-Host (
        "PENDING_PRESSURE_ATTEMPTS=" +
        $PressureAttempt
    )
    Write-Host (
        "PRESSURE_PACKET_CHARS=" +
        ($PressurePacketChars -join ",")
    )
    Write-Host (
        "POST_ROLLOVER_TURNS=" +
        $PostRolloverTurns
    )
    Write-Host (
        "TELEMETRY_ROLLOVER_REQUIRED=" +
        $FinalTelemetry.ContextRolloverRequiredCount
    )
    Write-Host (
        "TELEMETRY_ROLLOVER_COMPLETED=" +
        $FinalTelemetry.ContextRolloverCompletedCount
    )
    Write-Host (
        "MAX_TOKENS=" +
        $FinalTelemetry.MaxTokensCount
    )
    Write-Host (
        "NO_VISIBLE_PROGRESS=" +
        $FinalTelemetry.NoVisibleProgressCount
    )

    if ($null -ne $FailureReason) {
        Write-Host "RETENTION_PASS=False"

        if ($FailureReason -eq "ROLLOVER_NOT_EXERCISED") {
            Write-Host "NOT_EXERCISED_REASON=$NotExercisedReason"
            Write-Host "CONTEXT_LIFECYCLE_ROLLOVER_STRESS=NOT_EXERCISED"
        }
        else {
            Write-Host (
                "CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=" +
                $FailureReason
            )
        }

        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"

        throw (
            "CONTEXT_LIFECYCLE_ROLLOVER_STRESS_FAILED: " +
            $FailureReason
        )
    }

    Write-Host "RETENTION_PASS=True"
    Write-Host "SAME_QWEN_SESSION_ID=PASS"
    Write-Host "FRESH_INTERNAL_CHAT=PASS"
    Write-Host "POST_ROLLOVER_CONTINUATION=PASS"
    Write-Host "ROLLOVER_SPIRAL=NOT_OBSERVED"
    Write-Host "CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "PERSISTENT_BENCHMARK_ARTIFACTS=NO"

    Assert-BenchmarkIdle
}

function Invoke-ContextLifecycleCompactionStress {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Assert-BenchmarkIdle

    if (Test-PortListener -Port $Port) {
        throw (
            "CONTEXT_LIFECYCLE_PORT_NOT_FREE port=" +
            $Port
        )
    }

    $Candidate = New-AgenticConfirmationConfig `
        -Parameters $Parameters `
        -PromptBudget $ConfirmPromptReasoningBudget `
        -AlgorithmBudget $ConfirmAlgorithmReasoningBudget `
        -TestBudget $ConfirmTestReasoningBudget `
        -GrowthBudget $ConfirmGrowthBudget

    $LocalShaBefore = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaBefore = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $BeforeJsonl = Get-QwenJsonlSnapshot
    $BeforeProjects = Get-QwenProjectDirectorySnapshot

    $TempRoot = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        (
            "qwen-context-lifecycle-" +
            [Guid]::NewGuid().ToString("N")
        )

    $StdoutPath = Join-Path $TempRoot "server.stdout.log"
    $StderrPath = Join-Path $TempRoot "server.stderr.log"

    $Process = $null
    $SessionId = [Guid]::NewGuid().ToString()
    $Sentinels = New-Object "System.Collections.Generic.List[string]"
    $CompactionTurns = New-Object "System.Collections.Generic.List[int]"
    $LifecycleEvents = New-Object "System.Collections.Generic.List[object]"
    $SecondCompactionTurn = 0
    $PostSecondCompactionTurns = 0
    $FinalTelemetry = $null
    $FailureReason = $null
    $PreviousCumulativePrompt = $null
    $PreviousCumulativeOutput = $null
    $MaxRequestPrompt = 0

    $ContextSize = [int]$Candidate["ctx-size"]
    $BasePacketChars = [int][Math]::Round($ContextSize * 0.24)

    if ($BasePacketChars -lt 7000) {
        $BasePacketChars = 7000
    }

    if ($BasePacketChars -gt 14000) {
        $BasePacketChars = 14000
    }

    $MaxTurns = 28
    $RequiredPostSecondTurns = 2

    Write-Host ""
    Write-Host "========================================"
    Write-Host " FORCED CONTEXT LIFECYCLE: COMPACTION"
    Write-Host "========================================"
    Write-Host "SCOPE=COMPACTION_PATH_ONLY"
    Write-Host "COMPACTION_DETECTOR=OPENAI_REQUEST_LOG_EXACT_DIRECTIVE"
    Write-Host "JSONL_LIFECYCLE_MARKERS=SUPPLEMENTAL_ONLY"
    Write-Host "ROLLOVER_EXPECTED=NO"
    Write-Host "MIN_DISTINCT_COMPACTION_TURNS=2"
    Write-Host (
        "POST_SECOND_COMPACTION_TURNS_REQUIRED=" +
        $RequiredPostSecondTurns
    )
    Write-Host "RETENTION_CHECK=ALL_DURABLE_KEEP_SENTINELS"
    Write-Host "TOOLS_ALLOWED=NO"
    Write-Host "DELEGATION_ALLOWED=NO"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host (
        "LIFECYCLE_CANDIDATE prompt=" +
        $Candidate["prompt-reasoning-budget"] +
        " algorithm=" +
        $Candidate["algorithm-reasoning-budget"] +
        " test=" +
        $Candidate["test-reasoning-budget"] +
        " growth=" +
        $Candidate["max-context-growth-tokens-per-turn"] +
        " context=" +
        $Candidate["ctx-size"]
    )
    Write-Host (
        "BASE_PACKET_CHARS=" +
        $BasePacketChars
    )

    try {
        Write-ContextLifecycleBenchmarkWorkspace `
            -Path $TempRoot `
            -Parameters $Candidate

        $ArgumentLine = Get-BenchmarkRouterArgumentLine `
            -Parameters $Candidate

        Assert-LocalPath $StdoutPath
        Assert-LocalPath $StderrPath
        $Process = Start-Process `
            -FilePath $ServerExe `
            -ArgumentList $ArgumentLine `
            -WorkingDirectory (Split-Path $ServerExe -Parent) `
            -RedirectStandardOutput $StdoutPath `
            -RedirectStandardError $StderrPath `
            -WindowStyle Hidden `
            -PassThru

        if ($null -eq $Process) {
            throw "CONTEXT_LIFECYCLE_ROUTER_START=FAIL"
        }

        Wait-BenchmarkRouterReady -Process $Process

        for ($Turn = 1; $Turn -le $MaxTurns; $Turn++) {
            if ($SecondCompactionTurn -gt 0) {
                $TargetChars = [int][Math]::Round(
                    $BasePacketChars * 0.15
                )

                if ($TargetChars -lt 1200) {
                    $TargetChars = 1200
                }
            }
            elseif ($CompactionTurns.Count -gt 0) {
                $TargetChars = [int][Math]::Round(
                    $BasePacketChars * 0.55
                )

                if ($TargetChars -lt 3000) {
                    $TargetChars = 3000
                }
            }
            else {
                $TargetChars = $BasePacketChars
            }

            $Packet = New-ContextLifecyclePacket `
                -Turn $Turn `
                -TargetChars $TargetChars

            [void]$Sentinels.Add([string]$Packet.Sentinel)

            $TurnOpenAiDir = Join-Path `
                $TempRoot `
                ("openai-turn-" + $Turn.ToString("D2"))

            Assert-LocalTree $TurnOpenAiDir

            [void](
                New-Item `
                    -ItemType Directory `
                    -Path $TurnOpenAiDir `
                    -Force
            )

            $QwenArgs = @(
                "--output-format", "stream-json",
                "--approval-mode", "yolo",
                "--model", [string]$ModelAlias,
                "--debug",
                "--openai-logging",
                "--openai-logging-dir", $TurnOpenAiDir,
                "--max-tool-calls", "0"
            )

            if ($Turn -eq 1) {
                $QwenArgs += @(
                    "--session-id",
                    $SessionId
                )
            }
            else {
                $QwenArgs += @(
                    "--resume",
                    $SessionId
                )
            }

            Push-Location $TempRoot

            try {
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"

                try {
                    $Timer = [System.Diagnostics.Stopwatch]::StartNew()

                    $QwenOutput = (
                        [string]$Packet.Text |
                        & $QwenCodeCli @QwenArgs 2>&1 |
                        Out-String
                    )

                    $Timer.Stop()
                    $ExitCode = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            if ($ExitCode -ne 0) {
                $FailureReason = (
                    "QWEN_EXIT_CODE_" +
                    $ExitCode +
                    "_TURN_" +
                    $Turn
                )

                if ($QwenOutput.Length -gt 0) {
                    Write-Host "=== QWEN OUTPUT TAIL ==="
                    $TailLength = [Math]::Min(
                        3000,
                        $QwenOutput.Length
                    )
                    Write-Host (
                        $QwenOutput.Substring(
                            $QwenOutput.Length - $TailLength,
                            $TailLength
                        )
                    )
                }

                break
            }

            $Cumulative = Get-ContextLifecycleCumulativeMetrics `
                -Text $QwenOutput

            $RequestPrompt = $null
            $OutputDelta = $null

            if ($null -ne $Cumulative.PromptTokens) {
                if ($null -eq $PreviousCumulativePrompt) {
                    $RequestPrompt = [long]$Cumulative.PromptTokens
                }
                else {
                    $RequestPrompt = (
                        [long]$Cumulative.PromptTokens -
                        [long]$PreviousCumulativePrompt
                    )
                }

                $PreviousCumulativePrompt = [long]$Cumulative.PromptTokens
            }

            if ($null -ne $Cumulative.CompletionTokens) {
                if ($null -eq $PreviousCumulativeOutput) {
                    $OutputDelta = [long]$Cumulative.CompletionTokens
                }
                else {
                    $OutputDelta = (
                        [long]$Cumulative.CompletionTokens -
                        [long]$PreviousCumulativeOutput
                    )
                }

                $PreviousCumulativeOutput = [long]$Cumulative.CompletionTokens
            }

            if (
                $null -ne $RequestPrompt -and
                $RequestPrompt -gt $MaxRequestPrompt
            ) {
                $MaxRequestPrompt = [long]$RequestPrompt
            }

            $OpenAiEvents = @(
                Get-ContextLifecycleOpenAiCompactionEvents `
                    -Path $TurnOpenAiDir
            )

            $CompInputTotal = [long]0
            $CompOutputTotal = [long]0
            $PostCompactionPrompt = $null
            $CompactionEvidenceSource = "NONE"

            if ($OpenAiEvents.Count -gt 0) {
                $PrimaryCompaction = $OpenAiEvents[0]

                if ($null -ne $PrimaryCompaction.PromptTokens) {
                    $CompInputTotal = [long]$PrimaryCompaction.PromptTokens
                }

                if ($null -ne $PrimaryCompaction.CompletionTokens) {
                    $CompOutputTotal = [long]$PrimaryCompaction.CompletionTokens
                }

                if ($null -ne $PrimaryCompaction.PostPromptTokens) {
                    $PostCompactionPrompt = [long]$PrimaryCompaction.PostPromptTokens
                }

                $CompactionEvidenceSource = [string]$PrimaryCompaction.EvidenceSource

                [void]$CompactionTurns.Add($Turn)

                if (
                    $CompactionTurns.Count -eq 2 -and
                    $SecondCompactionTurn -eq 0
                ) {
                    $SecondCompactionTurn = $Turn
                }

                [void]$LifecycleEvents.Add(
                    [pscustomobject]@{
                        Turn = $Turn
                        BeforeTokens = $CompInputTotal
                        AfterTokens = $PostCompactionPrompt
                        CompactionRequests = $OpenAiEvents.Count
                        CompactionOutputTokens = $CompOutputTotal
                        EvidenceSource = $CompactionEvidenceSource
                    }
                )
            }
            elseif ($SecondCompactionTurn -gt 0) {
                $PostSecondCompactionTurns++
            }

            Start-Sleep -Milliseconds 350

            $ChangedJsonl = @(
                Get-ChangedQwenJsonlFiles `
                    -Before $BeforeJsonl
            )

            $Telemetry = Get-RoleAwareTelemetrySummary `
                -Files $ChangedJsonl

            $FinalTelemetry = $Telemetry

            Write-Host (
                "LIFECYCLE_TURN index=" +
                $Turn +
                " packet_chars=" +
                $Packet.CharCount +
                " wall=" +
                $Timer.Elapsed.TotalSeconds.ToString(
                    "F3",
                    [System.Globalization.CultureInfo]::InvariantCulture
                ) +
                "s request_prompt=" +
                $(
                    if ($null -eq $RequestPrompt) {
                        "NA"
                    }
                    else {
                        [string]$RequestPrompt
                    }
                ) +
                " openai_compaction_events=" +
                $OpenAiEvents.Count +
                " compaction_evidence=" +
                $CompactionEvidenceSource +
                " comp_input=" +
                $CompInputTotal +
                " post_compact_prompt=" +
                $(
                    if ($null -eq $PostCompactionPrompt) {
                        "NA"
                    }
                    else {
                        [string]$PostCompactionPrompt
                    }
                ) +
                " distinct_compaction_turns=" +
                $CompactionTurns.Count +
                " rollover_required=" +
                $Telemetry.ContextRolloverRequiredCount +
                " rollover_completed=" +
                $Telemetry.ContextRolloverCompletedCount +
                " max_tokens=" +
                $Telemetry.MaxTokensCount +
                " no_visible_progress=" +
                $Telemetry.NoVisibleProgressCount +
                " tool_calls=" +
                $Telemetry.ToolCalls
            )

            if ($Telemetry.ContextRolloverRequiredCount -gt 0) {
                $FailureReason = "UNEXPECTED_ROLLOVER_REQUIRED"
                break
            }

            if ($Telemetry.ContextRolloverCompletedCount -gt 0) {
                $FailureReason = "UNEXPECTED_ROLLOVER_COMPLETED"
                break
            }

            if ($Telemetry.ContextCompactionNoProgressCount -gt 0) {
                $FailureReason = "COMPACTION_NO_PROGRESS_OBSERVED"
                break
            }

            if ($Telemetry.MaxTokensCount -gt 0) {
                $FailureReason = "MAX_TOKENS_OBSERVED"
                break
            }

            if ($Telemetry.NoVisibleProgressCount -gt 0) {
                $FailureReason = "NO_VISIBLE_PROGRESS_OBSERVED"
                break
            }

            if ($Telemetry.ToolCalls -gt 0) {
                $FailureReason = "UNEXPECTED_TOOL_CALLS"
                break
            }

            if (
                $SecondCompactionTurn -gt 0 -and
                $PostSecondCompactionTurns -ge
                $RequiredPostSecondTurns
            ) {
                break
            }
        }

        if ($null -eq $FailureReason) {
            if ($CompactionTurns.Count -lt 2) {
                if ($MaxRequestPrompt -le 0) {
                    $FailureReason = (
                        "HARNESS_USAGE_TELEMETRY_UNAVAILABLE_NO_COMPACTION_PROOF"
                    )
                }
                else {
                    $FailureReason = (
                        "LESS_THAN_TWO_OPENAI_PROVEN_COMPACTION_TURNS max_request_prompt=" +
                        $MaxRequestPrompt
                    )
                }
            }
            elseif (
                $PostSecondCompactionTurns -lt
                $RequiredPostSecondTurns
            ) {
                $FailureReason = "POST_SECOND_COMPACTION_CONTINUATION_MISSING"
            }
        }

        if ($null -eq $FailureReason) {
            foreach ($Event in $LifecycleEvents) {
                if (
                    $Event.BeforeTokens -le 0 -or
                    $null -eq $Event.AfterTokens -or
                    $Event.AfterTokens -le 0 -or
                    $Event.AfterTokens -ge $Event.BeforeTokens
                ) {
                    $FailureReason = (
                        "INVALID_COMPACTION_REDUCTION turn=" +
                        $Event.Turn +
                        " before=" +
                        $Event.BeforeTokens +
                        " after=" +
                        $Event.AfterTokens
                    )
                    break
                }
            }
        }

        if (
            $null -eq $FailureReason -and
            $CompactionTurns.Count -ge 2
        ) {
            $Gap = (
                [int]$CompactionTurns[1] -
                [int]$CompactionTurns[0]
            )

            if ($Gap -le 1) {
                $FailureReason = "IMMEDIATE_RECOMPACTION_SPIRAL"
            }
        }

        if ($null -eq $FailureReason) {
            $RecallPrompt = New-ContextLifecycleRecallPrompt `
                -Sentinels $Sentinels.ToArray()

            $RecallOpenAiDir = Join-Path $TempRoot "openai-recall"

            Assert-LocalTree $RecallOpenAiDir

            [void](
                New-Item `
                    -ItemType Directory `
                    -Path $RecallOpenAiDir `
                    -Force
            )

            $RecallArgs = @(
                "--output-format", "stream-json",
                "--approval-mode", "yolo",
                "--model", [string]$ModelAlias,
                "--debug",
                "--openai-logging",
                "--openai-logging-dir", $RecallOpenAiDir,
                "--max-tool-calls", "0",
                "--resume", $SessionId
            )

            Push-Location $TempRoot

            try {
                $OldPreference = $ErrorActionPreference
                $ErrorActionPreference = "Continue"

                try {
                    $RecallOutput = (
                        $RecallPrompt |
                        & $QwenCodeCli @RecallArgs 2>&1 |
                        Out-String
                    )
                    $RecallExit = $LASTEXITCODE
                }
                finally {
                    $ErrorActionPreference = $OldPreference
                }
            }
            finally {
                Pop-Location
            }

            if ($RecallExit -ne 0) {
                $FailureReason = (
                    "RETENTION_RECALL_EXIT_CODE_" +
                    $RecallExit
                )
            }
            else {
                $Missing = @(
                    $Sentinels.ToArray() |
                    Where-Object {
                        $RecallOutput.IndexOf(
                            [string]$_,
                            [System.StringComparison]::Ordinal
                        ) -lt 0
                    }
                )

                if ($Missing.Count -gt 0) {
                    Write-Host (
                        "MISSING_SENTINELS=" +
                        ($Missing -join ",")
                    )
                    $FailureReason = "RETENTION_SENTINELS_MISSING"
                }
            }

            Start-Sleep -Milliseconds 350

            $ChangedJsonl = @(
                Get-ChangedQwenJsonlFiles `
                    -Before $BeforeJsonl
            )

            $FinalTelemetry = Get-RoleAwareTelemetrySummary `
                -Files $ChangedJsonl
        }
    }
    catch {
        if ($null -eq $FailureReason) {
            $FailureReason = $_.Exception.Message
        }
    }
    finally {
        try {
            Stop-BenchmarkRouterProcess -Process $Process
        }
        finally {
            if (Test-Path -LiteralPath $TempRoot) {
                Assert-LocalTree $TempRoot
                Remove-Item `
                    -LiteralPath $TempRoot `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }

            Remove-NewQwenProjectDirectories `
                -Before $BeforeProjects
        }
    }

    $LocalShaAfter = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAfter = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if (
        $LocalShaAfter -ne $LocalShaBefore -or
        $SettingsShaAfter -ne $SettingsShaBefore
    ) {
        throw "CONTEXT_LIFECYCLE_PRODUCTION_CONFIG_CHANGED"
    }

    if ($null -eq $FinalTelemetry) {
        $FinalTelemetry = [pscustomobject]@{
            ContextRolloverRequiredCount = 0
            ContextRolloverCompletedCount = 0
            ContextCompactionNoProgressCount = 0
            MaxTokensCount = 0
            NoVisibleProgressCount = 0
            ToolCalls = 0
        }
    }

    $HighWatermark = 0
    $PostCompactionMax = 0

    foreach ($Event in $LifecycleEvents) {
        if ($Event.BeforeTokens -gt $HighWatermark) {
            $HighWatermark = [long]$Event.BeforeTokens
        }

        if (
            $null -ne $Event.AfterTokens -and
            $Event.AfterTokens -gt $PostCompactionMax
        ) {
            $PostCompactionMax = [long]$Event.AfterTokens
        }
    }

    Write-Host ""
    Write-Host "========================================"
    Write-Host " CONTEXT LIFECYCLE COMPACTION RESULT"
    Write-Host "========================================"
    Write-Host "COMPACTION_PROOF_SOURCE=OPENAI_REQUEST_LOG_STRUCTURAL_OR_EXACT_DIRECTIVE"
    Write-Host (
        "DISTINCT_COMPACTION_TURNS=" +
        $CompactionTurns.Count
    )
    Write-Host (
        "COMPACTION_TURN_INDEXES=" +
        (($CompactionTurns.ToArray()) -join ",")
    )
    Write-Host (
        "COMPACTION_REQUEST_EVENTS=" +
        $LifecycleEvents.Count
    )
    Write-Host (
        "CONTEXT_HIGH_WATERMARK=" +
        $HighWatermark
    )
    Write-Host (
        "POST_COMPACTION_MAX=" +
        $PostCompactionMax
    )
    Write-Host (
        "MAX_REQUEST_PROMPT_OBSERVED=" +
        $MaxRequestPrompt
    )
    Write-Host (
        "POST_SECOND_COMPACTION_TURNS=" +
        $PostSecondCompactionTurns
    )
    Write-Host (
        "ROLLOVER_REQUIRED=" +
        $FinalTelemetry.ContextRolloverRequiredCount
    )
    Write-Host (
        "ROLLOVER_COMPLETED=" +
        $FinalTelemetry.ContextRolloverCompletedCount
    )
    Write-Host (
        "COMPACTION_NO_PROGRESS=" +
        $FinalTelemetry.ContextCompactionNoProgressCount
    )
    Write-Host (
        "MAX_TOKENS=" +
        $FinalTelemetry.MaxTokensCount
    )
    Write-Host (
        "NO_VISIBLE_PROGRESS=" +
        $FinalTelemetry.NoVisibleProgressCount
    )

    foreach ($Event in $LifecycleEvents) {
        Write-Host (
            "COMPACTION_EVIDENCE turn=" +
            $Event.Turn +
            " before=" +
            $Event.BeforeTokens +
            " after=" +
            $Event.AfterTokens +
            " evidence=" +
            $Event.EvidenceSource +
            " requests=" +
            $Event.CompactionRequests +
            " summary_output=" +
            $Event.CompactionOutputTokens
        )
    }

    if ($null -ne $FailureReason) {
        Write-Host "RETENTION_PASS=False"
        Write-Host (
            "CONTEXT_LIFECYCLE_COMPACTION_STRESS=FAIL reason=" +
            $FailureReason
        )
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        throw (
            "CONTEXT_LIFECYCLE_COMPACTION_STRESS_FAILED: " +
            $FailureReason
        )
    }

    Write-Host "RETENTION_PASS=True"
    Write-Host "POST_COMPACTION_CONTINUATION=PASS"
    Write-Host "RECOMPACTION_SPIRAL=NOT_OBSERVED"
    Write-Host "CONTEXT_LIFECYCLE_COMPACTION_STRESS=PASS"
    Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
    Write-Host "PERSISTENT_BENCHMARK_ARTIFACTS=NO"

    Assert-BenchmarkIdle
}

function Invoke-AdaptivePlannerSelfTest {
    $FakePass = [pscustomobject]@{
        Pass = $true
        Reason = $null
    }

    if (
        (Get-AdaptiveFailureClass -Measurement $FakePass) -ne
        "PASS"
    ) {
        throw "ADAPTIVE_SELFTEST_FAILURE_CLASS_PASS"
    }

    $FakeQuality = [pscustomobject]@{
        Pass = $false
        Reason = "EXTERNAL_TEST_EXIT_CODE_1"
    }

    if (
        (Get-AdaptiveFailureClass -Measurement $FakeQuality) -ne
        "QUALITY"
    ) {
        throw "ADAPTIVE_SELFTEST_FAILURE_CLASS_QUALITY"
    }

    $FakeTimeout = [pscustomobject]@{
        Pass = $false
        Reason = "QWEN_EXIT_CODE_55"
    }

    if (
        (Get-AdaptiveFailureClass -Measurement $FakeTimeout) -ne
        "TIMEOUT"
    ) {
        throw "ADAPTIVE_SELFTEST_FAILURE_CLASS_TIMEOUT"
    }

    $Midpoint = Get-AdaptiveBudgetMidpoint `
        -Lower 6144 `
        -Upper 8192 `
        -Quantum 512

    if ($Midpoint -ne 7168) {
        throw (
            "ADAPTIVE_SELFTEST_MIDPOINT expected=7168 actual=" +
            $Midpoint
        )
    }

    $ContextQuality = @(
        Get-AdaptiveContextCandidateSet `
            -Current 40960 `
            -Mode "QUALITY"
    )

    if (
        ($ContextQuality -join ",") -ne
        "24576,32768,40960,49152"
    ) {
        throw (
            "ADAPTIVE_SELFTEST_CONTEXT_QUALITY actual=" +
            ($ContextQuality -join ",")
        )
    }

    $ContextExtended = @(
        Get-AdaptiveContextCandidateSet `
            -Current 40960 `
            -Mode "EXTENDED"
    )

    if (
        ($ContextExtended -join ",") -ne
        "32768,40960,49152,57344,65536"
    ) {
        throw (
            "ADAPTIVE_SELFTEST_CONTEXT_EXTENDED actual=" +
            ($ContextExtended -join ",")
        )
    }

    $TestParameters = Copy-BenchmarkParameters `
        -Parameters $Parameters

    $TestParameters["spec-ngram-mod-n-min"] = "48"
    $TestParameters["spec-ngram-mod-n-max"] = "64"
    $TestParameters["spec-ngram-mod-n-match"] = "16"
    $TestParameters["spec-draft-p-min"] = "0.025"

    $Ngram = @(
        Get-AdaptiveNgramCandidateSet `
            -Parameters $TestParameters |
        ForEach-Object {
            $_.Min.ToString() +
            "/" +
            $_.Max.ToString() +
            "/" +
            $_.Match.ToString()
        }
    )

    if (
        ($Ngram -join ",") -ne
        "48/64/24,32/64/16,48/64/16"
    ) {
        throw (
            "ADAPTIVE_SELFTEST_NGRAM actual=" +
            ($Ngram -join ",")
        )
    }

    $Pmin = @(
        Get-AdaptivePminCandidateSet `
            -Parameters $TestParameters
    )

    if (($Pmin -join ",") -ne "0,0.025,0.05") {
        throw (
            "ADAPTIVE_SELFTEST_PMIN actual=" +
            ($Pmin -join ",")
        )
    }

    $ExpectedSeedFingerprint = Get-AdaptivePlatformFingerprint `
        -Parameters $TestParameters

    $script:AutotuneSeedPlatformFingerprint = $null

    $ActualSeedFingerprint = Initialize-AutotuneSeedPlatformFingerprint `
        -Parameters $TestParameters

    if (
        [string]::IsNullOrWhiteSpace(
            [string]$script:AutotuneSeedPlatformFingerprint
        ) -or
        [string]$ActualSeedFingerprint -ne
        [string]$ExpectedSeedFingerprint
    ) {
        throw "ADAPTIVE_SELFTEST_AGENTIC_SEED_INIT"
    }

    $EfficientReference = [pscustomobject]@{
        Pass = $true
        WallSeconds = 338.851
        ApiResponses = 23
        ToolCalls = 29
        PromptResponses = 2
        AlgorithmResponses = 18
        TestResponses = 3
        GrowthLimitCount = 0
        PartialSideEffectsCount = 0
        ContextCompactionNoProgressCount = 0
        PromptSumThoughts = 1089
        AlgorithmSumThoughts = 11127
        TestSumThoughts = 2088
    }

    $InefficientLower = [pscustomobject]@{
        Pass = $true
        WallSeconds = 1100.329
        ApiResponses = 49
        ToolCalls = 64
        PromptResponses = 4
        AlgorithmResponses = 41
        TestResponses = 4
        GrowthLimitCount = 2
        PartialSideEffectsCount = 2
        ContextCompactionNoProgressCount = 0
        PromptSumThoughts = 11582
        AlgorithmSumThoughts = 36189
        TestSumThoughts = 535
    }

    $KneeCheck = Get-AgenticEfficiencyComparison `
        -Candidate $InefficientLower `
        -Reference $EfficientReference

    if (-not $KneeCheck.Regression) {
        throw "ADAPTIVE_SELFTEST_AGENTIC_EFFICIENCY_KNEE"
    }

    if (
        -not (Test-AgenticEfficiencyDominates `
            -Left $EfficientReference `
            -Right $InefficientLower)
    ) {
        throw "ADAPTIVE_SELFTEST_AGENTIC_PARETO_DOMINANCE"
    }

    $Repeatable = [pscustomobject]@{
        Pass = $true
        WallSeconds = 420.0
        ApiResponses = 25
        ToolCalls = 31
        PromptResponses = 2
        AlgorithmResponses = 19
        TestResponses = 4
        GrowthLimitCount = 0
        PartialSideEffectsCount = 0
        ContextCompactionNoProgressCount = 0
        PromptSumThoughts = 1400
        AlgorithmSumThoughts = 12000
        TestSumThoughts = 2200
    }

    $RobustCheck = Get-AgenticRobustnessComparison `
        -First $EfficientReference `
        -Second $Repeatable

    if (-not $RobustCheck.Confirmed) {
        throw "ADAPTIVE_SELFTEST_AGENTIC_ROBUSTNESS"
    }

    $HighVarianceRepeat = [pscustomobject]@{
        Pass = $true
        WallSeconds = 820.0
        ApiResponses = 52
        ToolCalls = 66
        PromptResponses = 6
        AlgorithmResponses = 39
        TestResponses = 7
        GrowthLimitCount = 2
        PartialSideEffectsCount = 2
        ContextCompactionNoProgressCount = 0
        PromptSumThoughts = 8200
        AlgorithmSumThoughts = 30000
        TestSumThoughts = 9000
    }

    $HighVarianceCheck = Get-AgenticRobustnessComparison `
        -First $EfficientReference `
        -Second $HighVarianceRepeat

    if (
        $HighVarianceCheck.Confirmed -or
        $HighVarianceCheck.Reason -ne
        "TRAJECTORY_EFFICIENCY_VARIANCE_HIGH"
    ) {
        throw "ADAPTIVE_SELFTEST_AGENTIC_EFFICIENCY_VARIANCE_GATE"
    }

    $TargetedConfirmConfig = New-AgenticConfirmationConfig `
        -Parameters $TestParameters `
        -PromptBudget 4608 `
        -AlgorithmBudget 4608 `
        -TestBudget 4096 `
        -GrowthBudget 24576

    if (
        [int]$TargetedConfirmConfig["prompt-reasoning-budget"] -ne 4608 -or
        [int]$TargetedConfirmConfig["algorithm-reasoning-budget"] -ne 4608 -or
        [int]$TargetedConfirmConfig["test-reasoning-budget"] -ne 4096 -or
        [int]$TargetedConfirmConfig["max-context-growth-tokens-per-turn"] -ne 24576
    ) {
        throw "ADAPTIVE_SELFTEST_TARGETED_CONFIRMATION_CONFIG"
    }

    Write-Host "ADAPTIVE_SELFTEST_AGENTIC_EFFICIENCY_KNEE=PASS"
    Write-Host "ADAPTIVE_SELFTEST_AGENTIC_PARETO_DOMINANCE=PASS"
    Write-Host "ADAPTIVE_SELFTEST_AGENTIC_ROBUSTNESS=PASS"
    $LifecycleSynthetic = @"
[LOCALAI_CONTEXT_LIFECYCLE] compaction pass 1: 32000 -> 17000
[LOCALAI_CONTEXT_LIFECYCLE] compaction pass 1: 31900 -> 16800
"@

    $LifecycleParsed = @(
        Get-ContextLifecycleEventsFromText `
            -Text $LifecycleSynthetic
    )

    if (
        $LifecycleParsed.Count -ne 2 -or
        $LifecycleParsed[0].BeforeTokens -ne 32000 -or
        $LifecycleParsed[0].AfterTokens -ne 17000 -or
        $LifecycleParsed[1].BeforeTokens -ne 31900 -or
        $LifecycleParsed[1].AfterTokens -ne 16800
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_EVENT_PARSER"
    }

    $LifecyclePacket = New-ContextLifecyclePacket `
        -Turn 3 `
        -TargetChars 1800

    if (
        $LifecyclePacket.CharCount -lt 1600 -or
        $LifecyclePacket.Text.IndexOf(
            $LifecyclePacket.Sentinel,
            [System.StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_PACKET"
    }

    Write-Host "ADAPTIVE_SELFTEST_AGENTIC_EFFICIENCY_VARIANCE_GATE=PASS"
    $DetectorTemp = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("localai-lifecycle-detector-selftest-" + [Guid]::NewGuid().ToString("N"))

    $DetectorSingleTemp = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("localai-lifecycle-detector-negative-" + [Guid]::NewGuid().ToString("N"))

    try {
        Assert-LocalTree $DetectorTemp
        [void](New-Item -ItemType Directory -Path $DetectorTemp -Force)
        Assert-LocalTree $DetectorSingleTemp
        [void](New-Item -ItemType Directory -Path $DetectorSingleTemp -Force)

        # Mirrors the observed production log shape:
        # 25563/1476 -> 19189/101 within one no-tools CLI turn.
        Assert-LocalPath (Join-Path $DetectorTemp "001-compaction.json")
        [System.IO.File]::WriteAllText(
            (Join-Path $DetectorTemp "001-compaction.json"),
            '{"messages":[{"content":"<state_snapshot>durable state</state_snapshot>"}],"usage":{"prompt_tokens":25563,"completion_tokens":1476}}',
            (New-Object System.Text.UTF8Encoding($false))
        )

        Assert-LocalPath (Join-Path $DetectorTemp "002-post.json")
        [System.IO.File]::WriteAllText(
            (Join-Path $DetectorTemp "002-post.json"),
            '{"messages":[{"content":"<state_snapshot>durable state</state_snapshot>"}],"usage":{"prompt_tokens":19189,"completion_tokens":101}}',
            (New-Object System.Text.UTF8Encoding($false))
        )

        $DetectorEvents = @(
            Get-ContextLifecycleOpenAiCompactionEvents `
                -Path $DetectorTemp
        )

        if (
            $DetectorEvents.Count -ne 1 -or
            $DetectorEvents[0].PromptTokens -ne 25563 -or
            $DetectorEvents[0].CompletionTokens -ne 1476 -or
            $DetectorEvents[0].PostPromptTokens -ne 19189 -or
            $DetectorEvents[0].EvidenceSource -ne
            "STRUCTURAL_MULTI_REQUEST_STATE_SNAPSHOT"
        ) {
            throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_STRUCTURAL_DETECTOR"
        }

        # A normal post-compaction request can contain state_snapshot by
        # itself. That MUST NOT be misclassified as a fresh compaction.
        Assert-LocalPath (Join-Path $DetectorSingleTemp "001-normal.json")
        [System.IO.File]::WriteAllText(
            (Join-Path $DetectorSingleTemp "001-normal.json"),
            '{"messages":[{"content":"<state_snapshot>durable state</state_snapshot>"}],"usage":{"prompt_tokens":25902,"completion_tokens":88}}',
            (New-Object System.Text.UTF8Encoding($false))
        )

        $NegativeEvents = @(
            Get-ContextLifecycleOpenAiCompactionEvents `
                -Path $DetectorSingleTemp
        )

        if ($NegativeEvents.Count -ne 0) {
            throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_STRUCTURAL_FALSE_POSITIVE"
        }

        $UsageSynthetic = @'
{"usage":{"prompt_tokens":12000,"completion_tokens":100}}
{"usage":{"prompt_tokens":33000,"completion_tokens":250}}
'@

        $UsageCheck = Get-ContextLifecycleCumulativeMetrics `
            -Text $UsageSynthetic

        if (
            $UsageCheck.PromptTokens -ne 33000 -or
            $UsageCheck.CompletionTokens -ne 250
        ) {
            throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_USAGE_PARSER"
        }
    }
    finally {
        foreach ($Path in @($DetectorTemp,$DetectorSingleTemp)) {
            if (Test-Path -LiteralPath $Path) {
                Assert-LocalTree $Path
                Remove-Item `
                    -LiteralPath $Path `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }

    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_COMPACTION=PASS"
    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_OPENAI_DETECTOR=PASS"
    $RecallSelftestSentinels = @(
        "KEEP_T01=INV-AAAAAAAAAAAAAAAA",
        "KEEP_T02=INV-BBBBBBBBBBBBBBBB"
    )

    $RecallSelftestPrompt = New-ContextLifecycleRecallPrompt `
        -Sentinels $RecallSelftestSentinels

    if (
        $RecallSelftestPrompt.IndexOf(
            "KEEP_T01",
            [System.StringComparison]::Ordinal
        ) -lt 0 -or
        $RecallSelftestPrompt.IndexOf(
            "KEEP_T02",
            [System.StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_RECALL_KEYS_MISSING"
    }

    foreach ($SecretValue in @(
        "INV-AAAAAAAAAAAAAAAA",
        "INV-BBBBBBBBBBBBBBBB"
    )) {
        if (
            $RecallSelftestPrompt.IndexOf(
                $SecretValue,
                [System.StringComparison]::Ordinal
            ) -ge 0
        ) {
            throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_RECALL_VALUE_LEAK"
        }
    }

    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_STRUCTURAL_DETECTOR=PASS"
    $RolloverContextA = Get-ContextLifecycleRolloverMechanismContext `
        -ProductionContext 40960

    $RolloverContextB = Get-ContextLifecycleRolloverMechanismContext `
        -ProductionContext 32768

    $RolloverContextC = Get-ContextLifecycleRolloverMechanismContext `
        -ProductionContext 65536

    if (
        $RolloverContextA -ne 24576 -or
        $RolloverContextB -ne 24576 -or
        $RolloverContextC -ne 32768
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER_CONTEXT"
    }

    $RolloverSynthetic = @'
LOCALAI_CONTEXT_ROLLOVER_REQUIRED: reason=insufficient_compaction_progress; prompt_id=x; before=18000; after=17950; safe_target=15672; passes=2; compression_status=COMPRESSED
[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=2; history_entries=7
'@

    $RolloverEvidence = Get-ContextLifecycleRolloverEvidence `
        -Text $RolloverSynthetic

    if (
        -not $RolloverEvidence.RequiredObserved -or
        $RolloverEvidence.Reason -ne "insufficient_compaction_progress" -or
        $RolloverEvidence.BeforeTokens -ne 18000 -or
        $RolloverEvidence.AfterTokens -ne 17950 -or
        $RolloverEvidence.SafeTarget -ne 15672 -or
        -not $RolloverEvidence.CompletedObserved -or
        $RolloverEvidence.CompletedPasses -ne 2 -or
        $RolloverEvidence.HistoryEntries -ne 7
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER_EVIDENCE"
    }

    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_RETENTION_RECALL=PASS"
    $PressureSelftestContext = 24576
    $PressureSelftest = @(
        [int][Math]::Round($PressureSelftestContext * 1.20),
        [int][Math]::Round($PressureSelftestContext * 1.50),
        [int][Math]::Round($PressureSelftestContext * 1.80)
    )

    $PressurePacket = New-ContextLifecyclePendingPressurePacket `
        -Turn 9 `
        -TargetChars $PressureSelftest[0]

    if (
        $PressureSelftest.Count -ne 3 -or
        $PressureSelftest[0] -ge $PressureSelftest[1] -or
        $PressureSelftest[1] -ge $PressureSelftest[2] -or
        $PressurePacket.CharCount -lt ($PressureSelftest[0] - 512) -or
        $PressurePacket.CharCount -gt ($PressureSelftest[0] + 512) -or
        $PressurePacket.Text.IndexOf(
            $PressurePacket.Sentinel,
            [System.StringComparison]::Ordinal
        ) -lt 0
    ) {
        throw "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER_PRESSURE_SCHEDULE"
    }

    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER=PASS"
    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER_PRESSURE=PASS"
    Write-Host "ADAPTIVE_SELFTEST_CONTEXT_LIFECYCLE_ROLLOVER_PRESSURE_PACKET_TOLERANCE=PASS"
    Write-Host "ADAPTIVE_SELFTEST_TARGETED_CONFIRMATION_CONFIG=PASS"

    Write-Host "ADAPTIVE_SELFTEST_FAILURE_CLASSIFICATION=PASS"
    Write-Host "ADAPTIVE_SELFTEST_BRACKET_6144_8192=7168"
    Write-Host "ADAPTIVE_SELFTEST_DYNAMIC_NGRAM=PASS"
    Write-Host "ADAPTIVE_SELFTEST_DYNAMIC_PMIN=PASS"
    Write-Host "ADAPTIVE_SELFTEST_DYNAMIC_CONTEXT=PASS"
    Write-Host "ADAPTIVE_SELFTEST_AGENTIC_SEED_INIT=PASS"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "ADAPTIVE_PLANNER_SELFTEST=PASS"
}

function Invoke-AdaptiveSingleRoleBudgetStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [object]$BaselineMeasurement,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PROMPT","ALGORITHM","TEST")]
        [string]$Role,

        [AllowEmptyString()]
        [string]$ExplicitCandidates = ""
    )

    $Key = Get-RoleBudgetKey -Role $Role
    $Current = [int]$Parameters[$Key]
    $ObservedMax = Get-RoleMaxThoughts `
        -Measurement $BaselineMeasurement `
        -Role $Role

    Write-Host ""
    Write-Host (
        "ROLE_BUDGET_STAGE role=" +
        $Role +
        " current=" +
        $Current +
        " observed_max_thoughts=" +
        $ObservedMax
    )

    if (
        [string]::IsNullOrWhiteSpace($ExplicitCandidates) -and
        $ObservedMax -lt [int][Math]::Floor($Current * 0.70) -and
        $BaselineMeasurement.MaxTokensCount -eq 0
    ) {
        Write-Host (
            "ROLE_BUDGET_STAGE_SKIPPED role=" +
            $Role +
            " reason=HEADROOM_SUFFICIENT"
        )

        return [pscustomobject]@{
            Config = $Parameters
            Measurement = $BaselineMeasurement
            SelectedBudget = $Current
        }
    }

    $Candidates = @(
        Get-ReasoningBudgetCandidateSet `
            -Current $Current `
            -ContextWindowSize ([int]$Parameters["ctx-size"]) `
            -ExplicitCandidates $ExplicitCandidates
    )

    Write-Host (
        "ROLE_BUDGET_CANDIDATES role=" +
        $Role +
        " values=" +
        ($Candidates -join ",")
    )

    $Records = @()

    foreach ($Candidate in $Candidates) {
        if ([int]$Candidate -eq $Current) {
            $Config = $Parameters
            $Measurement = $BaselineMeasurement
        }
        else {
            $Config = Set-RoleBudgetInConfig `
                -Parameters $Parameters `
                -Role $Role `
                -Budget ([int]$Candidate)

            $Measurement = Invoke-RoleAwareAgentMeasurement `
                -Parameters $Config `
                -Label (
                    $Role.ToLowerInvariant() +
                    "_budget_" +
                    $Candidate
                ) `
                -Workload "STRESS"
        }

        $Eligible = (
            $Measurement.Pass -and
            $Measurement.MaxTokensCount -eq 0 -and
            $Measurement.NoVisibleProgressCount -eq 0
        )

        $Records += [pscustomobject]@{
            Budget = [int]$Candidate
            Config = $Config
            Measurement = $Measurement
            Eligible = $Eligible
        }
    }

    $EligibleRecords = @(
        $Records |
        Where-Object { $_.Eligible } |
        Sort-Object `
            @{Expression = { $_.Measurement.GrowthLimitCount }; Descending = $false},
            @{Expression = { $_.Measurement.WallSeconds }; Descending = $false},
            @{Expression = { $_.Budget }; Descending = $false}
    )

    if ($EligibleRecords.Count -lt 1) {
        throw ("ROLE_BUDGET_NO_ELIGIBLE_CANDIDATE role=" + $Role)
    }

    $Winner = $EligibleRecords[0]

    $CurrentRecord = @(
        $EligibleRecords |
        Where-Object { $_.Budget -eq $Current }
    )

    if ($CurrentRecord.Count -gt 0) {
        $CurrentCandidate = $CurrentRecord[0]

        if (
            $CurrentCandidate.Measurement.GrowthLimitCount -eq
            $Winner.Measurement.GrowthLimitCount -and
            $CurrentCandidate.Measurement.WallSeconds -le
            ($Winner.Measurement.WallSeconds * 1.05)
        ) {
            $Winner = $CurrentCandidate
            Write-Host (
                "ROLE_BUDGET_CURRENT_PREFERENCE_USED role=" +
                $Role +
                " band=5%"
            )
        }
    }

    Write-Host (
        "ROLE_BUDGET_WINNER role=" +
        $Role +
        " budget=" +
        $Winner.Budget +
        " wall=" +
        $Winner.Measurement.WallSeconds.ToString(
            "F3",
            [System.Globalization.CultureInfo]::InvariantCulture
        ) +
        "s growth_limit=" +
        $Winner.Measurement.GrowthLimitCount
    )

    return [pscustomobject]@{
        Config = $Winner.Config
        Measurement = $Winner.Measurement
        SelectedBudget = $Winner.Budget
    }
}

function Invoke-AdaptiveGrowthBudgetStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters,

        [Parameter(Mandatory = $true)]
        [object]$BaselineMeasurement,

        [AllowEmptyString()]
        [string]$ExplicitCandidates = ""
    )

    $Current = [int]$Parameters["max-context-growth-tokens-per-turn"]

    Write-Host ""
    Write-Host (
        "GROWTH_BUDGET_STAGE current=" +
        $Current +
        " observed_growth_limit=" +
        $BaselineMeasurement.GrowthLimitCount
    )

    if (
        [string]::IsNullOrWhiteSpace($ExplicitCandidates) -and
        $BaselineMeasurement.GrowthLimitCount -eq 0
    ) {
        Write-Host "GROWTH_BUDGET_STAGE_SKIPPED reason=NO_GROWTH_LIMIT_OBSERVED"

        return [pscustomobject]@{
            Config = $Parameters
            Measurement = $BaselineMeasurement
            SelectedBudget = $Current
        }
    }

    $Candidates = @(
        Get-GrowthBudgetCandidateSet `
            -Current $Current `
            -ExplicitCandidates $ExplicitCandidates
    )

    if ([string]::IsNullOrWhiteSpace($ExplicitCandidates)) {
        $Candidates = @(
            $Candidates |
            Where-Object { [int]$_ -ge $Current }
        )
    }

    Write-Host (
        "GROWTH_BUDGET_CANDIDATES=" +
        ($Candidates -join ",")
    )

    $Records = @()

    foreach ($Candidate in $Candidates) {
        if ([int]$Candidate -eq $Current) {
            $Config = $Parameters
            $Measurement = $BaselineMeasurement
        }
        else {
            $Config = Copy-BenchmarkParameters -Parameters $Parameters
            $Config["max-context-growth-tokens-per-turn"] = [string]$Candidate

            $Measurement = Invoke-RoleAwareAgentMeasurement `
                -Parameters $Config `
                -Label ("growth_budget_" + $Candidate) `
                -Workload "STRESS"
        }

        $Eligible = (
            $Measurement.Pass -and
            $Measurement.MaxTokensCount -eq 0 -and
            $Measurement.NoVisibleProgressCount -eq 0
        )

        $Records += [pscustomobject]@{
            Budget = [int]$Candidate
            Config = $Config
            Measurement = $Measurement
            Eligible = $Eligible
        }
    }

    $EligibleRecords = @(
        $Records |
        Where-Object { $_.Eligible } |
        Sort-Object `
            @{Expression = { $_.Measurement.GrowthLimitCount }; Descending = $false},
            @{Expression = { $_.Measurement.WallSeconds }; Descending = $false},
            @{Expression = { $_.Budget }; Descending = $false}
    )

    if ($EligibleRecords.Count -lt 1) {
        throw "GROWTH_BUDGET_NO_ELIGIBLE_CANDIDATE"
    }

    $Winner = $EligibleRecords[0]

    $CurrentRecord = @(
        $EligibleRecords |
        Where-Object { $_.Budget -eq $Current }
    )

    if ($CurrentRecord.Count -gt 0) {
        $CurrentCandidate = $CurrentRecord[0]

        if (
            $CurrentCandidate.Measurement.GrowthLimitCount -eq
            $Winner.Measurement.GrowthLimitCount -and
            $CurrentCandidate.Measurement.WallSeconds -le
            ($Winner.Measurement.WallSeconds * 1.05)
        ) {
            $Winner = $CurrentCandidate
            Write-Host "GROWTH_BUDGET_CURRENT_PREFERENCE_USED=YES band=5%"
        }
    }

    Write-Host (
        "GROWTH_BUDGET_WINNER=" +
        $Winner.Budget +
        " wall=" +
        $Winner.Measurement.WallSeconds.ToString(
            "F3",
            [System.Globalization.CultureInfo]::InvariantCulture
        ) +
        "s growth_limit=" +
        $Winner.Measurement.GrowthLimitCount
    )

    return [pscustomobject]@{
        Config = $Winner.Config
        Measurement = $Winner.Measurement
        SelectedBudget = $Winner.Budget
    }
}

function Invoke-AdaptiveReasoningGrowthStage {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " REASONING / TURN-GROWTH STAGE"
    Write-Host "========================================"
    Write-Host "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
    Write-Host "REASONING_BUDGET=ADAPTIVE_REQUEST_LEVEL"
    Write-Host "TURN_GROWTH_BUDGET=ADAPTIVE_ONLY_WHEN_NEEDED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"

    $Baseline = Invoke-RoleAwareAgentMeasurement `
        -Parameters $Parameters `
        -Label "reasoning_growth_baseline" `
        -Workload "STRESS"

    if (-not $Baseline.Pass) {
        throw (
            "REASONING_GROWTH_BASELINE_FAIL reason=" +
            $Baseline.Reason
        )
    }

    $AlgorithmStressFloor = [int][Math]::Floor(
        [int]$Parameters["algorithm-reasoning-budget"] * 0.80
    )

    if ($Baseline.AlgorithmMaxThoughts -lt $AlgorithmStressFloor) {
        throw (
            "ALGORITHM_REASONING_STRESS_INSUFFICIENT observed=" +
            $Baseline.AlgorithmMaxThoughts +
            " required_min=" +
            $AlgorithmStressFloor
        )
    }

    Write-Host (
        "ALGORITHM_REASONING_STRESS_COVERAGE=PASS observed=" +
        $Baseline.AlgorithmMaxThoughts +
        " required_min=" +
        $AlgorithmStressFloor
    )

    $AlgorithmResult = Invoke-AdaptiveSingleRoleBudgetStage `
        -Parameters $Parameters `
        -BaselineMeasurement $Baseline `
        -Role "ALGORITHM" `
        -ExplicitCandidates $AlgorithmReasoningBudgetCandidates

    $PromptResult = Invoke-AdaptiveSingleRoleBudgetStage `
        -Parameters $AlgorithmResult.Config `
        -BaselineMeasurement $AlgorithmResult.Measurement `
        -Role "PROMPT" `
        -ExplicitCandidates $PromptReasoningBudgetCandidates

    $TestResult = Invoke-AdaptiveSingleRoleBudgetStage `
        -Parameters $PromptResult.Config `
        -BaselineMeasurement $PromptResult.Measurement `
        -Role "TEST" `
        -ExplicitCandidates $TestReasoningBudgetCandidates

    $GrowthResult = Invoke-AdaptiveGrowthBudgetStage `
        -Parameters $TestResult.Config `
        -BaselineMeasurement $TestResult.Measurement `
        -ExplicitCandidates $GrowthBudgetCandidates

    return [pscustomobject]@{
        Config = $GrowthResult.Config
        Measurement = $GrowthResult.Measurement
    }
}

function Invoke-ReasoningGrowthSelfTest {
    $Reasoning = @(
        Get-ReasoningBudgetCandidateSet `
            -Current 8192 `
            -ContextWindowSize 40960
    )

    $ExpectedReasoning = @(6144,8192,10240)

    if (
        ($Reasoning -join ",") -ne
        ($ExpectedReasoning -join ",")
    ) {
        throw (
            "SELFTEST_REASONING_CANDIDATES_FAIL actual=" +
            ($Reasoning -join ",")
        )
    }

    $Growth = @(
        Get-GrowthBudgetCandidateSet `
            -Current 24576
    )

    $ExpectedGrowth = @(16384,24576,32768)

    if (
        ($Growth -join ",") -ne
        ($ExpectedGrowth -join ",")
    ) {
        throw (
            "SELFTEST_GROWTH_CANDIDATES_FAIL actual=" +
            ($Growth -join ",")
        )
    }

    $SettingsText = [System.IO.File]::ReadAllText($SettingsPath)

    $CandidateText = Set-ManagedProviderBenchmarkStateInSettings `
        -Text $SettingsText `
        -ContextWindowSize 40960 `
        -PromptReasoningBudgetTokens 6144 `
        -AlgorithmReasoningBudgetTokens 7168 `
        -TestReasoningBudgetTokens 4096 `
        -MaxContextGrowthTokensPerTurn 28672

    $TempPath = Join-Path `
        ([System.IO.Path]::GetTempPath()) `
        ("qwen-settings-selftest-" + [Guid]::NewGuid().ToString("N") + ".json")

    try {
        $Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        Assert-LocalPath $TempPath
        [System.IO.File]::WriteAllText(
            $TempPath,
            $CandidateText,
            $Utf8NoBom
        )

        Test-ManagedProviderBenchmarkState `
            -Path $TempPath `
            -ContextWindowSize 40960 `
            -PromptReasoningBudgetTokens 6144 `
            -AlgorithmReasoningBudgetTokens 7168 `
            -TestReasoningBudgetTokens 4096 `
            -MaxContextGrowthTokensPerTurn 28672
    }
    finally {
        if (Test-Path -LiteralPath $TempPath) {
            Assert-LocalTree $TempPath
            Remove-Item -LiteralPath $TempPath -Force
        }
    }

    Write-Output "SELFTEST_REASONING_CANDIDATES=6144,8192,10240"
    Write-Output "SELFTEST_GROWTH_CANDIDATES=16384,24576,32768"
    Write-Output "SELFTEST_SETTINGS_ROLE_SYNC=PASS"
    Write-Output "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Output "REASONING_GROWTH_SELFTEST=PASS"
}

function Invoke-ReasoningGrowthSmoke {
    $Result = Invoke-RoleAwareAgentMeasurement `
        -Parameters $Parameters `
        -Label "reasoning_growth_smoke" `
        -Workload "STRESS"

    if (-not $Result.Pass) {
        throw (
            "REASONING_GROWTH_SMOKE_FAIL reason=" +
            $Result.Reason
        )
    }

    $StressFloor = [int][Math]::Floor(
        [int]$Parameters["algorithm-reasoning-budget"] * 0.80
    )

    if ($Result.AlgorithmMaxThoughts -lt $StressFloor) {
        throw (
            "REASONING_GROWTH_SMOKE_INSUFFICIENT_ALGORITHM_STRESS observed=" +
            $Result.AlgorithmMaxThoughts +
            " required_min=" +
            $StressFloor
        )
    }

    Write-Host (
        "REASONING_GROWTH_STRESS_COVERAGE=PASS observed=" +
        $Result.AlgorithmMaxThoughts +
        " required_min=" +
        $StressFloor
    )
    Write-Host "REASONING_GROWTH_SMOKE=PASS"
}

function Get-FullRecommendationFromConfig {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Config
    )

    return [ordered]@{
        "ctx-size" = [string]$Config["ctx-size"]
        "spec-draft-p-min" = [string]$Config["spec-draft-p-min"]
        "spec-ngram-mod-n-min" = [string]$Config["spec-ngram-mod-n-min"]
        "spec-ngram-mod-n-max" = [string]$Config["spec-ngram-mod-n-max"]
        "spec-ngram-mod-n-match" = [string]$Config["spec-ngram-mod-n-match"]
        "cache-type-k" = [string]$Config["cache-type-k"]
        "cache-type-v" = [string]$Config["cache-type-v"]
        "prompt-reasoning-budget" = [string]$Config["prompt-reasoning-budget"]
        "algorithm-reasoning-budget" = [string]$Config["algorithm-reasoning-budget"]
        "test-reasoning-budget" = [string]$Config["test-reasoning-budget"]
        "max-context-growth-tokens-per-turn" = [string]$Config["max-context-growth-tokens-per-turn"]
    }
}

function Invoke-ReasoningGrowthOnlyBenchmark {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $LocalConfigShaAtBegin = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAtBegin = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $Current = Get-FullRecommendationFromConfig `
        -Config $Parameters

    $Result = Invoke-AdaptiveReasoningGrowthStage `
        -Parameters $Parameters

    $Recommended = Get-FullRecommendationFromConfig `
        -Config $Result.Config

    Write-Host ""
    Write-Host "========================================"
    Write-Host " REASONING / GROWTH RECOMMENDATION"
    Write-Host "========================================"
    Write-Host (
        "RECOMMENDED_PROMPT_REASONING_BUDGET=" +
        $Recommended["prompt-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_ALGORITHM_REASONING_BUDGET=" +
        $Recommended["algorithm-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_TEST_REASONING_BUDGET=" +
        $Recommended["test-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN=" +
        $Recommended["max-context-growth-tokens-per-turn"]
    )
    Write-Host "RECOMMENDED_REASONING_EFFORT=UNCHANGED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"

    $Changed = @()

    foreach ($Name in $Recommended.Keys) {
        if (
            [string]$Current[$Name] -ne
            [string]$Recommended[$Name]
        ) {
            $Changed += $Name
        }
    }

    if ($Changed.Count -eq 0) {
        Write-Host "APPLY_REQUIRED=NO_ALREADY_MATCHES"
        Write-Host "REASONING_GROWTH_TUNE=PASS"
        return
    }

    $LocalShaBeforePrompt = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaBeforePrompt = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($LocalShaBeforePrompt -ne $LocalConfigShaAtBegin) {
        throw "LOCAL_CONFIG_CHANGED_DURING_REASONING_GROWTH_BENCHMARK"
    }

    if ($SettingsShaBeforePrompt -ne $SettingsShaAtBegin) {
        throw "SETTINGS_CHANGED_DURING_REASONING_GROWTH_BENCHMARK"
    }

    Write-Host (
        "APPLY_CANDIDATE_FLAGS=" +
        ($Changed -join ",")
    )

    $Answer = Read-Host `
        "Apply the tested reasoning/growth recommendation to config\local.ps1 and synchronize Qwen Code role metadata? [Y/N]"

    $Normalized = $Answer.Trim().ToUpperInvariant()

    if (
        $Normalized -ne "Y" -and
        $Normalized -ne "YES"
    ) {
        Write-Host "APPLY_RESULT=DECLINED"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        Write-Host "REASONING_GROWTH_TUNE=PASS"
        return
    }

    Assert-BenchmarkIdle

    Invoke-TransactionalBenchmarkApply `
        -Recommended $Recommended `
        -ExpectedLocalConfigSha $LocalConfigShaAtBegin `
        -ExpectedSettingsSha $SettingsShaAtBegin

    Write-Host "REASONING_GROWTH_TUNE=PASS"
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

    Assert-LocalTree $TempRoot

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

                Assert-LocalPath $StdoutPath
                Assert-LocalPath $StderrPath
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
            Assert-LocalTree $TempRoot
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


# =============================================================================
# BENCHMARK MODULE: adaptive candidate generation
# =============================================================================

function Get-AdaptiveNgramCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $CurrentMin = [int]$Parameters["spec-ngram-mod-n-min"]
    $CurrentMax = [int]$Parameters["spec-ngram-mod-n-max"]
    $CurrentMatch = [int]$Parameters["spec-ngram-mod-n-match"]

    $LowerMin = [Math]::Max(8,$CurrentMin - 16)
    $HigherMatch = [Math]::Min($CurrentMin,$CurrentMatch + 8)
    $LowerMatch = [Math]::Min($CurrentMatch,$LowerMin)

    $Raw = @(
        [pscustomobject]@{
            Min = $CurrentMin
            Max = $CurrentMax
            Match = $HigherMatch
        },
        [pscustomobject]@{
            Min = $LowerMin
            Max = $CurrentMax
            Match = $LowerMatch
        },
        [pscustomobject]@{
            Min = $CurrentMin
            Max = $CurrentMax
            Match = $CurrentMatch
        }
    )

    $Seen = @{}
    $Result = @()

    foreach ($Candidate in $Raw) {
        $Key = (
            $Candidate.Min.ToString() +
            "/" +
            $Candidate.Max.ToString() +
            "/" +
            $Candidate.Match.ToString()
        )

        if (-not $Seen.ContainsKey($Key)) {
            $Seen[$Key] = $true
            $Result += $Candidate
        }
    }

    return @($Result)
}

function Get-AdaptivePminCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    $Current = ConvertTo-InvariantDouble `
        -Value ([string]$Parameters["spec-draft-p-min"])

    $Step = [Math]::Min(
        0.05,
        [Math]::Max(0.005,$Current)
    )

    $Values = @(
        [Math]::Max(0.0,$Current - $Step),
        $Current,
        [Math]::Min(1.0,$Current + $Step)
    )

    return @(
        $Values |
        ForEach-Object {
            $_.ToString(
                "0.###",
                [System.Globalization.CultureInfo]::InvariantCulture
            )
        } |
        Sort-Object {
            ConvertTo-InvariantDouble -Value $_
        } -Unique
    )
}

function Get-AdaptiveContextCandidateSet {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Current,

        [ValidateSet("QUALITY","EXTENDED")]
        [string]$Mode
    )

    if ($Mode -eq "QUALITY") {
        $Multipliers = @(0.60,0.80,1.00,1.20)
    }
    else {
        $Multipliers = @(0.80,1.00,1.20,1.40,1.60)
    }

    $Values = @()

    foreach ($Multiplier in $Multipliers) {
        $Values += Round-BenchmarkIntegerCandidate `
            -Value ($Current * $Multiplier) `
            -Quantum 4096 `
            -Minimum 8192 `
            -Maximum 131072
    }

    return @(
        $Values |
        Sort-Object -Unique
    )
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
        Get-AdaptiveNgramCandidateSet `
            -Parameters $Parameters
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
        Get-AdaptivePminCandidateSet `
            -Parameters $Parameters
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
        Get-AdaptiveContextCandidateSet `
            -Current ([int]$Parameters["ctx-size"]) `
            -Mode "QUALITY"
    )

    $ExtendedContexts = @(
        Get-AdaptiveContextCandidateSet `
            -Current ([int]$Parameters["ctx-size"]) `
            -Mode "EXTENDED"
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

    # Replace only the value token after each line's flag prefix.
    # Preserve whitespace, continuation
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

function Set-ManagedProviderBenchmarkStateInSettings {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$ContextWindowSize,

        [Parameter(Mandatory = $true)]
        [int]$PromptReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$AlgorithmReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$TestReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$MaxContextGrowthTokensPerTurn
    )

    foreach ($Value in @(
        $ContextWindowSize,
        $PromptReasoningBudgetTokens,
        $AlgorithmReasoningBudgetTokens,
        $TestReasoningBudgetTokens,
        $MaxContextGrowthTokensPerTurn
    )) {
        if ($Value -le 0) {
            throw "SETTINGS_BENCHMARK_STATE_NONPOSITIVE"
        }
    }

    $Settings = $Text | ConvertFrom-Json

    if (
        $null -eq $Settings.modelProviders -or
        $null -eq $Settings.modelProviders.openai
    ) {
        throw "SETTINGS_OPENAI_PROVIDERS_MISSING"
    }

    if ($null -eq $Settings.model) {
        throw "SETTINGS_MODEL_MISSING"
    }

    $BudgetByAlias = [ordered]@{
        ([string]$ModelAlias) = $PromptReasoningBudgetTokens
        ([string]$AlgorithmModelAlias) = $AlgorithmReasoningBudgetTokens
        ([string]$TestModelAlias) = $TestReasoningBudgetTokens
    }

    foreach ($Alias in $BudgetByAlias.Keys) {
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

        $Provider = $Matches[0]

        if ($null -eq $Provider.generationConfig) {
            throw (
                "SETTINGS_GENERATION_CONFIG_MISSING alias=" +
                $Alias
            )
        }

        $Provider.generationConfig.contextWindowSize = $ContextWindowSize

        if ($null -eq $Provider.generationConfig.extra_body) {
            $Provider.generationConfig |
                Add-Member `
                    -NotePropertyName "extra_body" `
                    -NotePropertyValue ([pscustomobject]@{}) `
                    -Force
        }

        $Provider.generationConfig.extra_body |
            Add-Member `
                -NotePropertyName "thinking_budget_tokens" `
                -NotePropertyValue ([int]$BudgetByAlias[$Alias]) `
                -Force
    }

    $Settings.model |
        Add-Member `
            -NotePropertyName "maxContextGrowthTokensPerTurn" `
            -NotePropertyValue $MaxContextGrowthTokensPerTurn `
            -Force

    return ($Settings | ConvertTo-Json -Depth 30)
}

function Test-ManagedProviderBenchmarkState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$ContextWindowSize,

        [Parameter(Mandatory = $true)]
        [int]$PromptReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$AlgorithmReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$TestReasoningBudgetTokens,

        [Parameter(Mandatory = $true)]
        [int]$MaxContextGrowthTokensPerTurn
    )

    $Settings = Get-Content `
        -LiteralPath $Path `
        -Raw |
        ConvertFrom-Json

    $ExpectedBudget = [ordered]@{
        ([string]$ModelAlias) = $PromptReasoningBudgetTokens
        ([string]$AlgorithmModelAlias) = $AlgorithmReasoningBudgetTokens
        ([string]$TestModelAlias) = $TestReasoningBudgetTokens
    }

    foreach ($Alias in $ExpectedBudget.Keys) {
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

        $Provider = $Matches[0]

        if (
            [int]$Provider.generationConfig.contextWindowSize -ne
            $ContextWindowSize
        ) {
            throw (
                "SETTINGS_CONTEXT_MISMATCH alias=" +
                $Alias
            )
        }

        if (
            [int]$Provider.generationConfig.extra_body.thinking_budget_tokens -ne
            [int]$ExpectedBudget[$Alias]
        ) {
            throw (
                "SETTINGS_REASONING_BUDGET_MISMATCH alias=" +
                $Alias +
                " expected=" +
                $ExpectedBudget[$Alias] +
                " actual=" +
                $Provider.generationConfig.extra_body.thinking_budget_tokens
            )
        }
    }

    if (
        [int]$Settings.model.maxContextGrowthTokensPerTurn -ne
        $MaxContextGrowthTokensPerTurn
    ) {
        throw (
            "SETTINGS_GROWTH_BUDGET_MISMATCH expected=" +
            $MaxContextGrowthTokensPerTurn +
            " actual=" +
            $Settings.model.maxContextGrowthTokensPerTurn
        )
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
        "prompt-reasoning-budget" = "PromptReasoningBudgetTokens"
        "algorithm-reasoning-budget" = "AlgorithmReasoningBudgetTokens"
        "test-reasoning-budget" = "TestReasoningBudgetTokens"
        "max-context-growth-tokens-per-turn" = "MaxContextGrowthTokensPerTurn"
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

    $SettingsText = Set-ManagedProviderBenchmarkStateInSettings `
        -Text $SettingsText `
        -ContextWindowSize ([int]$Recommended["ctx-size"]) `
        -PromptReasoningBudgetTokens ([int]$Recommended["prompt-reasoning-budget"]) `
        -AlgorithmReasoningBudgetTokens ([int]$Recommended["algorithm-reasoning-budget"]) `
        -TestReasoningBudgetTokens ([int]$Recommended["test-reasoning-budget"]) `
        -MaxContextGrowthTokensPerTurn ([int]$Recommended["max-context-growth-tokens-per-turn"])

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
        Assert-LocalPath $LocalTemp
        [System.IO.File]::WriteAllText($LocalTemp,$LocalText,$LocalEncoding)
        Assert-LocalPath $SettingsTemp
        [System.IO.File]::WriteAllText($SettingsTemp,$SettingsText,$SettingsEncoding)

        Test-PowerShellFileParse -Path $LocalTemp

        Test-ManagedProviderBenchmarkState `
            -Path $SettingsTemp `
            -ContextWindowSize ([int]$Recommended["ctx-size"]) `
            -PromptReasoningBudgetTokens ([int]$Recommended["prompt-reasoning-budget"]) `
            -AlgorithmReasoningBudgetTokens ([int]$Recommended["algorithm-reasoning-budget"]) `
            -TestReasoningBudgetTokens ([int]$Recommended["test-reasoning-budget"]) `
            -MaxContextGrowthTokensPerTurn ([int]$Recommended["max-context-growth-tokens-per-turn"])

        foreach ($localWritePath in @($LocalTemp, $ConfigPath, $LocalRestore)) { Assert-LocalPath $localWritePath }
        [System.IO.File]::Replace($LocalTemp,$ConfigPath,$LocalRestore)
        $LocalReplaced = $true

        foreach ($localWritePath in @($SettingsTemp, $SettingsPath, $SettingsRestore)) { Assert-LocalPath $localWritePath }
        [System.IO.File]::Replace($SettingsTemp,$SettingsPath,$SettingsRestore)
        $SettingsReplaced = $true

        Test-PowerShellFileParse -Path $ConfigPath

        Test-ManagedProviderBenchmarkState `
            -Path $SettingsPath `
            -ContextWindowSize ([int]$Recommended["ctx-size"]) `
            -PromptReasoningBudgetTokens ([int]$Recommended["prompt-reasoning-budget"]) `
            -AlgorithmReasoningBudgetTokens ([int]$Recommended["algorithm-reasoning-budget"]) `
            -TestReasoningBudgetTokens ([int]$Recommended["test-reasoning-budget"]) `
            -MaxContextGrowthTokensPerTurn ([int]$Recommended["max-context-growth-tokens-per-turn"])

        Write-Output (
            "APPLY_NEW_LOCAL_CONFIG_SHA256=" +
            (Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256).Hash.ToUpperInvariant()
        )

        Write-Output (
            "APPLY_NEW_SETTINGS_SHA256=" +
            (Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256).Hash.ToUpperInvariant()
        )

        Write-Output "APPLY_ROLE_REASONING_BUDGET_SYNC=PASS"
        Write-Output "APPLY_GROWTH_BUDGET_SYNC=PASS"
        Write-Output "CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
        Write-Output "APPLY_RESULT=PASS"
    }
    catch {
        if ($SettingsReplaced) {
            Assert-LocalPath $SettingsPath
            [System.IO.File]::WriteAllBytes($SettingsPath,$OriginalSettingsBytes)
        }

        if ($LocalReplaced) {
            Assert-LocalPath $ConfigPath
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
                Assert-LocalTree $Path
                Remove-Item `
                    -LiteralPath $Path `
                    -Force `
                    -ErrorAction SilentlyContinue
            }
        }
    }
}


# =============================================================================
# BENCHMARK MODULE: one-invocation full autotune orchestration
# =============================================================================

function Invoke-FullConvergentBenchmark {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.IDictionary]$Parameters
    )

    Write-Host ""
    Write-Host "========================================"
    Write-Host " FULL CONVERGENT QWEN AUTOTUNE"
    Write-Host "========================================"
    Write-Host "EXECUTION_MODEL=one invocation; cheap screening first; expensive stress evidence reused"
    Write-Host "PRODUCTION_CONFIG_MODIFIED_BEFORE_APPROVAL=NO"
    Write-Host "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"

    Assert-BenchmarkIdle

    $LocalConfigShaAtBegin = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAtBegin = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $CurrentAtBegin = Get-FullRecommendationFromConfig `
        -Config $Parameters

    $null = Initialize-AutotuneSeedPlatformFingerprint `
        -Parameters $Parameters

    $TotalTimer = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Host ""
    Write-Host "AUTOTUNE_PHASE=CHEAP_AND_CAPACITY_SCREENING"

    $NgramConfig = Invoke-AdaptiveNgramStage -Parameters $Parameters
    Assert-BenchmarkIdle

    $PminConfig = Invoke-AdaptivePminStage -Parameters $NgramConfig
    Assert-BenchmarkIdle

    $ContextResult = Invoke-AdaptiveContextStage -Parameters $PminConfig
    Assert-BenchmarkIdle

    Write-Host ""
    Write-Host "AUTOTUNE_PHASE=AGENTIC_HARNESS_VALIDATION"
    Invoke-AgenticHarnessSelfTest
    Assert-BenchmarkIdle

    Write-Host ""
    Write-Host "AUTOTUNE_PHASE=EXPENSIVE_SHARED_STRESS_EVIDENCE"

    $ReasoningResult = Invoke-ConvergentReasoningGrowthStage `
        -Parameters $ContextResult.Config

    $TotalTimer.Stop()

    if (-not $ReasoningResult.Safe) {
        Write-Host ""
        Write-Host "========================================"
        Write-Host " FINAL AUTOTUNE STATUS"
        Write-Host "========================================"
        Write-Host "BENCHMARK_EXECUTION=PASS"
        Write-Host "RECOMMENDATION_STATUS=NO_SAFE_CANDIDATE"
        Write-Host ("RECOMMENDATION_REASON=" + $ReasoningResult.Status)
        Write-Host "APPLY_ALLOWED=NO"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        Write-Host "CONTEXT_OUTPUT_MARGIN_CHANGED=NO"
        Write-Host (
            "EXPENSIVE_STRESS_SESSIONS_USED=" +
            $ReasoningResult.StressSessions
        )
        return
    }

    $Recommended = Get-FullRecommendationFromConfig `
        -Config $ReasoningResult.Config

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
    Write-Host (
        "RECOMMENDED_PROMPT_REASONING_BUDGET=" +
        $Recommended["prompt-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_ALGORITHM_REASONING_BUDGET=" +
        $Recommended["algorithm-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_TEST_REASONING_BUDGET=" +
        $Recommended["test-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN=" +
        $Recommended["max-context-growth-tokens-per-turn"]
    )
    Write-Host "RECOMMENDED_REASONING_EFFORT=UNCHANGED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host (
        "EXPENSIVE_STRESS_SESSIONS_USED=" +
        $ReasoningResult.StressSessions
    )

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

    $Changed = @()

    Write-Host ""
    Write-Host "CURRENT -> RECOMMENDED:"

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

    Write-Host "BENCHMARK_EXECUTION=PASS"

    if ($Changed.Count -eq 0) {
        Write-Host "RECOMMENDATION_STATUS=KEEP_CURRENT"
        Write-Host "APPLY_REQUIRED=NO_ALREADY_MATCHES"
        Write-Host "APPLY_ALLOWED=NO"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        return
    }

    Write-Host "RECOMMENDATION_STATUS=FOUND"
    Write-Host "RECOMMENDATION_CONFIDENCE=QUALITY_GATED_SINGLE_STRESS_PER_CANDIDATE"
    Write-Host "APPLY_ALLOWED=YES"
    Write-Host ("APPLY_CANDIDATE_FLAGS=" + ($Changed -join ","))

    $LocalShaBeforePrompt = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()
    $SettingsShaBeforePrompt = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    if ($LocalShaBeforePrompt -ne $LocalConfigShaAtBegin) {
        throw "LOCAL_CONFIG_CHANGED_DURING_AUTOTUNE"
    }

    if ($SettingsShaBeforePrompt -ne $SettingsShaAtBegin) {
        throw "SETTINGS_CHANGED_DURING_AUTOTUNE"
    }

    if ($RecommendationOnly) {
        Write-Host "APPLY_RESULT=SKIPPED_RECOMMENDATION_ONLY"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        return
    }

    $Answer = Read-Host `
        "Apply the tested recommendation to config\local.ps1 and synchronize Qwen Code context/reasoning/growth metadata? [Y/N]"

    $NormalizedAnswer = $Answer.Trim().ToUpperInvariant()

    if (
        $NormalizedAnswer -ne "Y" -and
        $NormalizedAnswer -ne "YES"
    ) {
        Write-Host "APPLY_RESULT=DECLINED"
        Write-Host "PRODUCTION_CONFIG_MODIFIED=NO"
        return
    }

    Assert-BenchmarkIdle

    Invoke-TransactionalBenchmarkApply `
        -Recommended $Recommended `
        -ExpectedLocalConfigSha $LocalConfigShaAtBegin `
        -ExpectedSettingsSha $SettingsShaAtBegin

    Write-Host "AUTOTUNE_APPLY=PASS"
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
    Write-Host "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
    Write-Host "REASONING_BUDGET=AUTOTUNED_WHEN_ROLE_PRESSURE_REQUIRES"
    Write-Host "TURN_GROWTH_BUDGET=AUTOTUNED_WHEN_GROWTH_LIMIT_REQUIRES"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
    Write-Host "THREADS_BATCH_UBATCH=UNCHANGED_ESTABLISHED_BASELINE"

    Assert-BenchmarkIdle

    $LocalConfigShaAtBegin = (
        Get-FileHash -LiteralPath $ConfigPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $SettingsShaAtBegin = (
        Get-FileHash -LiteralPath $SettingsPath -Algorithm SHA256
    ).Hash.ToUpperInvariant()

    $CurrentAtBegin = Get-FullRecommendationFromConfig `
        -Config $Parameters

    $TotalTimer = [System.Diagnostics.Stopwatch]::StartNew()

    $NgramConfig = Invoke-AdaptiveNgramStage `
        -Parameters $Parameters

    Assert-BenchmarkIdle

    $PminConfig = Invoke-AdaptivePminStage `
        -Parameters $NgramConfig

    Assert-BenchmarkIdle

    $ContextResult = Invoke-AdaptiveContextStage `
        -Parameters $PminConfig

    Assert-BenchmarkIdle

    $ReasoningGrowthResult = Invoke-AdaptiveReasoningGrowthStage `
        -Parameters $ContextResult.Config

    Assert-BenchmarkIdle

    $RecommendedConfig = $ReasoningGrowthResult.Config

    $Recommended = Get-FullRecommendationFromConfig `
        -Config $RecommendedConfig

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
    Write-Host (
        "RECOMMENDED_PROMPT_REASONING_BUDGET=" +
        $Recommended["prompt-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_ALGORITHM_REASONING_BUDGET=" +
        $Recommended["algorithm-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_TEST_REASONING_BUDGET=" +
        $Recommended["test-reasoning-budget"]
    )
    Write-Host (
        "RECOMMENDED_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN=" +
        $Recommended["max-context-growth-tokens-per-turn"]
    )
    Write-Host "RECOMMENDED_REASONING_EFFORT=UNCHANGED"
    Write-Host "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
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
            "  " +
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
    Write-Host (
        "APPLY_CANDIDATE_FLAGS=" +
        ($Changed -join ",")
    )

    $Answer = Read-Host `
        "Apply the primary tested recommendation to config\local.ps1 and synchronize Qwen Code context/reasoning/growth metadata? [Y/N]"

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
try {
    $ServerOptions = Get-BenchmarkServerOptions -Text $StartText
    Write-Output 'SERVER_ARGUMENT_LINKAGE=PASS'
}
catch {
    Write-Output 'BENCHMARK_PREFLIGHT=FAIL'
    Write-Output ('ERROR=' + $_.Exception.Message)
    exit 1
}

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
    "reasoning-budget",
    "prompt-reasoning-budget",
    "algorithm-reasoning-budget",
    "test-reasoning-budget",
    "max-context-growth-tokens-per-turn"
)

$TunableMap = [ordered]@{
    "prompt-reasoning-budget" = "PromptReasoningBudgetTokens"
    "algorithm-reasoning-budget" = "AlgorithmReasoningBudgetTokens"
    "test-reasoning-budget" = "TestReasoningBudgetTokens"
    "max-context-growth-tokens-per-turn" = "MaxContextGrowthTokensPerTurn"
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
            $Value = [string]$ServerOptions[$Name]
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

try {
    Test-ManagedProviderBenchmarkState `
        -Path $SettingsPath `
        -ContextWindowSize ([int]$Parameters["ctx-size"]) `
        -PromptReasoningBudgetTokens ([int]$Parameters["prompt-reasoning-budget"]) `
        -AlgorithmReasoningBudgetTokens ([int]$Parameters["algorithm-reasoning-budget"]) `
        -TestReasoningBudgetTokens ([int]$Parameters["test-reasoning-budget"]) `
        -MaxContextGrowthTokensPerTurn ([int]$Parameters["max-context-growth-tokens-per-turn"])

    Write-Output "QWEN_CODE_ROLE_REASONING_GROWTH_SYNC=PASS"
}
catch {
    Write-Output "QWEN_CODE_ROLE_REASONING_GROWTH_SYNC=FAIL"
    Add-Failure -List $Failures -Message $_.Exception.Message
}

$RequiredSwitchOnly = @(
    "jinja",
    "reasoning-preserve"
)

foreach ($Name in $RequiredSwitchOnly) {
    $Count = [int]$ServerOptions[$Name]

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

    SERVER_REASONING_BUDGET_UNLIMITED = (
        $Parameters["reasoning-budget"] -eq "-1"
    )

    PROMPT_REASONING_BUDGET_POSITIVE = (
        [int]$Parameters["prompt-reasoning-budget"] -gt 0
    )

    ALGORITHM_REASONING_BUDGET_POSITIVE = (
        [int]$Parameters["algorithm-reasoning-budget"] -gt 0
    )

    TEST_REASONING_BUDGET_POSITIVE = (
        [int]$Parameters["test-reasoning-budget"] -gt 0
    )

    TURN_GROWTH_BUDGET_POSITIVE = (
        [int]$Parameters["max-context-growth-tokens-per-turn"] -gt 0
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
    "--models-preset",
    "--models-max",
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
Write-Output "NGRAM_CANDIDATES=DYNAMIC_AROUND_CURRENT"
Write-Output "PMIN_CANDIDATES=DYNAMIC_AROUND_CURRENT"
Write-Output "CONTEXT_Q8Q8=DYNAMIC_SCALED_AROUND_CURRENT"
Write-Output "EXTENDED_Q8Q5=DYNAMIC_SCALED_AROUND_CURRENT_CAPACITY_ONLY"
Write-Output "ROLE_REASONING_SEARCH=SHARED_STRESS_EVIDENCE_EFFICIENCY_KNEE_BRACKET_CONFIRMATION"
Write-Output "ROLE_REASONING_TUNING_WORKLOAD=ISOLATED_COOKIE_WORKFLOW_STRESS"
Write-Output ("ROLE_REASONING_STRESS_MAX_WALL_TIME=" + $StressMaxWallTimeMinutes + "m")
Write-Output ("MAX_EXPENSIVE_STRESS_SESSIONS=" + $MaxAdaptiveStressSessions)
Write-Output "AGENTIC_ONLY_AUTOTUNE=AVAILABLE_SKIP_NGRAM_PMIN_CONTEXT"
Write-Output "AGENTIC_TARGETED_CONFIRMATION=AVAILABLE_EXPLICIT_CANDIDATE_REPEAT_ONLY"
Write-Output "ORCHESTRATION_ENDURANCE_STRESS=AVAILABLE_ROLE_ROUTING_RECOVERY_COMPACTION_TERMINAL"
Write-Output "ORCHESTRATION_ENDURANCE_REPORT_ROOT=$QwenRoot\.localai\results\orchestration-endurance"
Write-Output "ORCHESTRATION_ENDURANCE_TEMP_WORKSPACE=SYSTEM_TEMP_CLEANED"
Write-Output "ORCHESTRATION_ENDURANCE_RECOVERY=VALIDATE_IF_GROWTH_LIMIT_OBSERVED"
Write-Output "ORCHESTRATION_ENDURANCE_ROLLOVER=DYNAMIC_NOT_REQUIRED_NON_BLOCKING"
Write-Output "AGENTIC_CORE_TESTS=BLOCKING_INCLUDES_DEFAULT_PROFILE_NO_FLAG_CASE"
Write-Output "AGENTIC_EXTENDED_TESTS=NON_BLOCKING"
Write-Output "AGENTIC_EXTERNAL_TEST_ENCODING=UTF8_DETERMINISTIC"
Write-Output "CONTEXT_LIFECYCLE_TELEMETRY=COMPACTION_ROLLOVER_GROWTH"
Write-Output "CONTEXT_LIFECYCLE_COMPACTION_STRESS=AVAILABLE_FORCED_TWO_COMPACTIONS_RETENTION_CONTINUATION"
Write-Output "CONTEXT_LIFECYCLE_COMPACTION_DETECTOR=OPENAI_REQUEST_LOG_STRUCTURAL_MULTI_REQUEST_WITH_EXACT_DIRECTIVE_FALLBACK"
Write-Output "CONTEXT_LIFECYCLE_OPENAI_AUDIT=AVAILABLE_SHORT_FOUR_TURN_LOG_SHAPE_DIAGNOSTIC"
Write-Output "CONTEXT_LIFECYCLE_RETENTION_CHECK=KEYS_ONLY_RECALL_EXPECTED_VALUES_NOT_DISCLOSED"
Write-Output "CONTEXT_LIFECYCLE_ROLLOVER_STRESS=AVAILABLE_REAL_HANDLER_HIGH_ENTROPY_CURRENT_PENDING_REQUEST_NO_RUNTIME_TEST_HOOK"
Write-Output "CONTEXT_LIFECYCLE_ROLLOVER_MODE=SAME_SESSION_FRESH_INTERNAL_CHAT"
Write-Output "AGENTIC_SELECTION=QUALITY_GATE_THEN_PARETO_EFFICIENCY_KNEE_THEN_REPEAT_CONFIRMATION"
Write-Output "AGENTIC_ROBUSTNESS=QUALITY_PLUS_SYMMETRIC_EFFICIENCY_STABILITY"
Write-Output "AGENTIC_EVIDENCE_CHECKPOINT=CRASH_RESUME_ONLY_FINGERPRINT_GATED"
Write-Output "PROMPT_TEST_REDUCTION=GROUPED_HEADROOM_ONLY_IF_FULL_SESSION_EFFICIENCY_DOES_NOT_REGRESS"
Write-Output "TURN_GROWTH_SEARCH=PRESSURE_GATED_AND_NET_AGENTIC_GAIN_REQUIRED"
Write-Output "FAILURE_CLASSIFICATION=QUALITY,TIMEOUT,REASONING_PRESSURE,HARDWARE_CAPACITY,HARNESS,ENVIRONMENT,EXECUTION"
Write-Output "REASONING_EFFORT=FIXED_NOT_AUTOTUNED"
Write-Output "CONTEXT_OUTPUT_MARGIN_POLICY=LOCKED_5_PERCENT_NOT_BENCHMARKED"
Write-Output "VRAM_MIN_FREE_MB=512"
Write-Output "THREAD_BATCH_UBATCH=FIXED_ESTABLISHED_BASELINE"
Write-Output "APPLY_TARGET=config\local.ps1 + Qwen Code provider context/reasoning/growth metadata"
Write-Output "APPLY_MODE=WHITELISTED_TRANSACTIONAL_LOCAL_CONFIG_AND_SETTINGS_SYNC"
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

if ($ReasoningGrowthSelfTest) {
    Invoke-ReasoningGrowthSelfTest
    exit 0
}

if ($AdaptivePlannerSelfTest) {
    Invoke-AdaptivePlannerSelfTest
    exit 0
}

if ($AgenticHarnessSelfTest) {
    Invoke-AgenticHarnessSelfTest
    exit 0
}

if ($OrchestrationEnduranceSelfTest) {
    Invoke-OrchestrationEnduranceSelfTest
    exit 0
}

if ($OrchestrationEnduranceStress) {
    Invoke-OrchestrationEnduranceStress `
        -Parameters $Parameters
    exit 0
}

if ($AgenticAutoTune) {
    Invoke-AgenticOnlyAutoTune `
        -Parameters $Parameters
    exit 0
}

if ($AgenticCandidateConfirmation) {
    Invoke-AgenticCandidateConfirmation `
        -Parameters $Parameters
    exit 0
}

if ($ContextLifecycleCompactionStress) {
    Invoke-ContextLifecycleCompactionStress `
        -Parameters $Parameters
    exit 0
}

if ($ContextLifecycleOpenAiAudit) {
    Invoke-ContextLifecycleOpenAiAudit `
        -Parameters $Parameters
    exit 0
}

if ($ContextLifecycleRolloverStress) {
    Invoke-ContextLifecycleRolloverStress `
        -Parameters $Parameters
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

if ($ReasoningGrowthSmoke) {
    Invoke-ReasoningGrowthSmoke
    exit 0
}

if ($ReasoningGrowthTune) {
    Invoke-ReasoningGrowthOnlyBenchmark `
        -Parameters $Parameters
    exit 0
}

if ($ContextKvSweep) {
    Invoke-ContextKvSweep `
        -Parameters $Parameters
    exit 0
}

if ($AutoTune) {
    Write-Host "AUTOTUNE_MODE=EXPLICIT"
}
else {
    Write-Host "AUTOTUNE_MODE=DEFAULT"
}

Invoke-FullConvergentBenchmark `
    -Parameters $Parameters

}
finally {
    if (Get-Command Restore-LocalEnvironment -ErrorAction SilentlyContinue) { Restore-LocalEnvironment }
}
