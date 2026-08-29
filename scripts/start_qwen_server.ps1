$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$ServerExe = $LlamaServerExe

if (-not (Test-Path $ServerExe -PathType Leaf)) {
    throw "llama-server.exe not found: $ServerExe"
}

if (-not (Test-Path $ModelPath -PathType Leaf)) {
    throw "Qwen model not found: $ModelPath"
}

Write-Host "========================================"
Write-Host " Local Qwen Server"
Write-Host "========================================"
Write-Host "Model:   Qwen3.8-27B UD-Q3_K_XL + MTP2 + ngram-mod"
Write-Host "Alias:   $ModelAlias"
Write-Host "Context: 49152"
Write-Host "Reason:  xhigh"
Write-Host "API:     http://${ServerHost}:${ServerPort}/v1"
Write-Host "========================================"
Write-Host ""

& $ServerExe `
    --model $ModelPath `
    --alias $ModelAlias `
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
