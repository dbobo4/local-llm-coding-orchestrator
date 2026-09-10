# Local machine configuration example. Copy this file to local.ps1 and adjust paths as needed.

$QwenRoot = if ($env:QWEN_ROOT) { $env:QWEN_ROOT } else { "C:\LocalAI\qwen" }
$QwenCodeRoot = if ($env:QWEN_CODE_ROOT) { $env:QWEN_CODE_ROOT } else { Join-Path $QwenRoot "runtime\qwen-code\standalone\qwen-code" }
$LlamaCppRoot = if ($env:LLAMA_CPP_ROOT) { $env:LLAMA_CPP_ROOT } else { Join-Path $QwenRoot "runtime\llama.cpp" }
$ModelPath = if ($env:MODEL_PATH) { $env:MODEL_PATH } else { Join-Path $QwenRoot "models\Qwen3.8-27B\Qwen3.8-27B-UD-Q3_K_XL.gguf" }
$QwenUserRoot = if ($env:QWEN_USER_ROOT) { $env:QWEN_USER_ROOT } else { Join-Path $HOME ".qwen" }
$OrchestrationRoot = if ($env:ORCHESTRATION_ROOT) { $env:ORCHESTRATION_ROOT } else { Join-Path $QwenUserRoot "orchestration" }

$QwenCodeCli = Join-Path $QwenCodeRoot "bin\qwen.cmd"
$LlamaServerExe = Join-Path $LlamaCppRoot "llama-server.exe"

$ModelAlias = "qwen3.8-27b-local"
$AlgorithmModelAlias = "qwen3.8-27b-algorithm"
$TestModelAlias = "qwen3.8-27b-test"
$ChatModelAlias = "qwen3.8-27b-chat"

$PromptReasoningEffort = "xhigh"
$AlgorithmReasoningEffort = "xhigh"
$TestReasoningEffort = "medium"
$ServerHost = "127.0.0.1"
$ServerPort = 8080

# Benchmark-tunable inference settings.
# The unified benchmark may update only these local values after explicit approval.
$ContextWindowSize = 40960
$SpecDraftPMin = "0.025"
$SpecNgramModNMin = 48
$SpecNgramModNMax = 64
$SpecNgramModNMatch = 16
$CacheTypeK = "q8_0"
$CacheTypeV = "q8_0"
