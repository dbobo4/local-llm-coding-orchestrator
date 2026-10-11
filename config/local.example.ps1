# CONFIG: setup copies this template to .localai/config/local.ps1.
# Installation paths always follow this clone; inference values below are editable.

$QwenRoot = if ($env:LOCALAI_INSTALL_ROOT) { $env:LOCALAI_INSTALL_ROOT } else { Split-Path $PSScriptRoot -Parent }
$QwenCodeRoot = Join-Path $QwenRoot "runtime\qwen-code"
$LlamaCppRoot = Join-Path $QwenRoot "runtime\llama.cpp"
$ModelPath = Join-Path $QwenRoot "models\Qwen3.8-27B-UD-Q3_K_XL.gguf"
$QwenUserRoot = Join-Path $QwenRoot ".localai\qwen"
$OrchestrationRoot = Join-Path $QwenRoot ".localai\orchestration"

$QwenCodeCli = Join-Path $QwenCodeRoot "bin\qwen.cmd"
$LlamaServerExe = Join-Path $LlamaCppRoot "llama-server.exe"

# qwen_server.ps1 derives .localai/config/qwen_models.ini from these settings.
$ModelAlias = "qwen3.8-27b-local"
$AlgorithmModelAlias = "qwen3.8-27b-algorithm"
$TestModelAlias = "qwen3.8-27b-test"
$ChatModelAlias = "qwen3.8-27b-chat"

$PromptReasoningEffort = "xhigh"
$AlgorithmReasoningEffort = "xhigh"
$TestReasoningEffort = "medium"
$ServerHost = "127.0.0.1"
$ServerPort = 8080
$ChatProxyPort = 8081

# Benchmark-tunable inference settings.
# The unified benchmark may update only these local values after explicit approval.
$ContextWindowSize = 40960
$PromptReasoningBudgetTokens = 4608
$AlgorithmReasoningBudgetTokens = 6144
$TestReasoningBudgetTokens = 6144
$MaxContextGrowthTokensPerTurn = 24576
$SpecDraftPMin = "0.025"
$SpecNgramModNMin = 48
$SpecNgramModNMax = 64
$SpecNgramModNMatch = 16
$CacheTypeK = "q8_0"
$CacheTypeV = "q8_0"
