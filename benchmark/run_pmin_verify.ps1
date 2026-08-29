$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$env:QWEN_ROOT = $QwenRoot
$env:MODEL_PATH = $ModelPath
$env:LLAMA_SERVER_EXE = $LlamaServerExe
$env:QWEN_CODE_CLI = $QwenCodeCli
$env:QWEN_SMOKE_ROOT = Join-Path $QwenRoot "runtime\qwen-code\smoke-test"
$env:STOP_QWEN_SERVER_PS1 = Join-Path $RepoRoot "scripts\stop_qwen_server.ps1"
$env:QWEN_HOST = $ServerHost
$env:QWEN_PORT = [string]$ServerPort
$env:QWEN_MODEL_ALIAS = $ModelAlias
$Benchmark = Join-Path $PSScriptRoot "qwen_pmin_final_verify_49k_v2.py"

if (-not (Test-Path $Benchmark -PathType Leaf)) {
    throw "Benchmark script not found: $Benchmark"
}

python $Benchmark @args
exit $LASTEXITCODE