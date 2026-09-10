$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

if ([string]::IsNullOrWhiteSpace([string]$AlgorithmModelAlias)) {
    $AlgorithmModelAlias = "qwen3.8-27b-algorithm"
}

if ([string]::IsNullOrWhiteSpace([string]$TestModelAlias)) {
    $TestModelAlias = "qwen3.8-27b-test"
}

if ([string]::IsNullOrWhiteSpace([string]$ChatModelAlias)) {
    $ChatModelAlias = "qwen3.8-27b-chat"
}

$RoleModelAliases = @(
    $ModelAlias
    $AlgorithmModelAlias
    $TestModelAlias
)

$AllModelNames = @(
    $ChatModelAlias
) + @($RoleModelAliases)

if (@($AllModelNames | Select-Object -Unique).Count -ne 4) {
    throw "PROMPT, ALGORITHM, TEST, and CHAT model names must be unique."
}

foreach ($modelName in $AllModelNames) {
    if (
        [string]::IsNullOrWhiteSpace([string]$modelName) -or
        [string]$modelName -match '[,\[\]\r\n]'
    ) {
        throw "Invalid model name for llama.cpp router preset: '$modelName'"
    }
}

$ServerExe = $LlamaServerExe
$ModelsPreset = Join-Path $QwenRoot "config\qwen_models.ini"

if (-not (Test-Path $ServerExe -PathType Leaf)) {
    throw "llama-server.exe not found: $ServerExe"
}

if (-not (Test-Path $ModelPath -PathType Leaf)) {
    throw "Qwen model not found: $ModelPath"
}

$PresetRoot = Split-Path $ModelsPreset -Parent

New-Item `
    -Path $PresetRoot `
    -ItemType Directory `
    -Force |
Out-Null

$PresetModelPath = (
    [System.IO.Path]::GetFullPath(
        $ModelPath
    )
).Replace(
    "\",
    "/"
)

$PresetText = @(
    "version = 1"
    ""
    "[$ChatModelAlias]"
    "model = $PresetModelPath"
    ("alias = " + ($RoleModelAliases -join ","))
    "load-on-startup = true"
    ""
) -join [Environment]::NewLine

[System.IO.File]::WriteAllText(
    $ModelsPreset,
    $PresetText,
    (New-Object System.Text.UTF8Encoding($false))
)

Write-Host "========================================"
Write-Host " Local Qwen Server"
Write-Host "========================================"
Write-Host "Model:    Qwen3.8-27B UD-Q3_K_XL + MTP2 + ngram-mod"
Write-Host "Model ID: $ChatModelAlias"
Write-Host "Aliases:  $($RoleModelAliases -join ', ')"
Write-Host "Context:  49152"
Write-Host "Reason:   xhigh"
Write-Host "API:      http://${ServerHost}:${ServerPort}/v1"
Write-Host "========================================"
Write-Host ""

& $ServerExe `
    --models-preset $ModelsPreset `
    --models-max 1 `
    --host $ServerHost `
    --port $ServerPort `
    --ctx-size 49152 `
    --parallel 1 `
    --n-gpu-layers 99 `
    --fit off `
    --spec-type draft-mtp,ngram-mod `
    --spec-draft-n-max 2 `
    --spec-draft-p-min 0.025 `
    --spec-ngram-mod-n-min 32 `
    --spec-ngram-mod-n-max 64 `
    --spec-ngram-mod-n-match 16 `
    --threads 20 `
    --threads-batch 20 `
    --spec-draft-threads 20 `
    --spec-draft-threads-batch 20 `
    --flash-attn on `
    --cache-type-k q8_0 `
    --cache-type-v q8_0 `
    --batch-size 1024 `
    --ubatch-size 512 `
    --jinja `
    --reasoning on `
    --reasoning-effort xhigh `
    --reasoning-budget -1 `
    --reasoning-preserve
