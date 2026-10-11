param([switch]$Initialize)

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot ".localai\config\local.ps1"

function Assert-LocalPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath($RepoRoot)
    if (-not $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $full.StartsWith($root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes this installation: $Path"
    }
    $candidate = $full
    while (-not [string]::IsNullOrWhiteSpace($candidate)) {
        try {
            $item = Get-Item -LiteralPath $candidate -Force -ErrorAction Stop
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not supported in installation paths: $candidate"
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] { }
        $candidate = Split-Path $candidate -Parent
    }
}

function Assert-LocalTree {
    param([string]$Path)
    Assert-LocalPath $Path
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([IO.Path]::GetFullPath($Path))
    while ($pending.Count -gt 0) {
        foreach ($item in @(Get-ChildItem -LiteralPath $pending.Pop() -Force -ErrorAction Stop)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not supported in installation paths: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

function New-LocalTempPath {
    param([string]$Extension = '.tmp')
    $directory = Join-Path $RepoRoot '.localai\tmp'
    Assert-LocalPath $directory
    $path = Join-Path $directory ([Guid]::NewGuid().ToString('N') + $Extension)
    Assert-LocalPath $path
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    return $path
}

$OriginalProfile = [string]$env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($OriginalProfile)) {
    throw "USERPROFILE is missing; the original profile boundary cannot be established safely."
}
if ([IO.Path]::GetFullPath($OriginalProfile).TrimEnd('\', '/').Equals([IO.Path]::GetFullPath((Join-Path $RepoRoot ".localai\home")), [StringComparison]::OrdinalIgnoreCase)) {
    $OriginalProfile = [string]$env:LOCALAI_ORIGINAL_USERPROFILE
    if ([string]::IsNullOrWhiteSpace($OriginalProfile)) {
        throw "LOCALAI_ORIGINAL_USERPROFILE is missing for an already scoped profile."
    }
}

$LocalAiEnvironment = [ordered]@{
    LOCALAI_INSTALL_ROOT = $RepoRoot
    USERPROFILE = Join-Path $RepoRoot ".localai\home"
    HOME = Join-Path $RepoRoot ".localai\home"
    APPDATA = Join-Path $RepoRoot ".localai\home\AppData\Roaming"
    LOCALAPPDATA = Join-Path $RepoRoot ".localai\home\AppData\Local"
    TEMP = Join-Path $RepoRoot ".localai\tmp"
    TMP = Join-Path $RepoRoot ".localai\tmp"
    TMPDIR = Join-Path $RepoRoot ".localai\tmp"
    QWEN_HOME = Join-Path $RepoRoot ".localai\qwen"
    QWEN_RUNTIME_DIR = Join-Path $RepoRoot ".localai\qwen-runtime"
    QWEN_CODE_MCP_APPROVALS_PATH = Join-Path $RepoRoot ".localai\qwen\mcpApprovals.json"
    QWEN_CODE_TRUSTED_FOLDERS_PATH = Join-Path $RepoRoot ".localai\qwen\trustedFolders.json"
    QWEN_CODE_SYSTEM_SETTINGS_PATH = Join-Path $RepoRoot ".localai\system-settings.json"
    QWEN_CODE_SYSTEM_DEFAULTS_PATH = Join-Path $RepoRoot ".localai\system-defaults.json"
    PYTHONDONTWRITEBYTECODE = "1"
    NODE_COMPILE_CACHE = Join-Path $RepoRoot ".localai\cache\node"
    CUDA_CACHE_PATH = Join-Path $RepoRoot ".localai\cache\cuda"
    NPM_CONFIG_CACHE = Join-Path $RepoRoot ".localai\cache\npm"
    LOCALAI_ORIGINAL_USERPROFILE = $OriginalProfile
}

Assert-LocalPath $ConfigPath
foreach ($entry in $LocalAiEnvironment.GetEnumerator()) {
    if ($entry.Key -notin @("PYTHONDONTWRITEBYTECODE", "LOCALAI_ORIGINAL_USERPROFILE")) { Assert-LocalPath $entry.Value }
}
# Native/runtime writers receive a tree without existing redirects at launch.
Assert-LocalTree (Join-Path $RepoRoot '.localai')
if ($null -eq $script:LocalAiOriginalEnvironment) {
    $ProfileCheck = @(& python -B (Join-Path $RepoRoot "scripts\install_local.py") check-workspace)
    if ($LASTEXITCODE -ne 0) { throw "The working directory cannot safely use isolated Qwen configuration." }
    if ($ProfileCheck.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$ProfileCheck[0])) {
        throw "The canonical original user profile could not be established."
    }
    $LocalAiEnvironment.LOCALAI_ORIGINAL_USERPROFILE = [string]$ProfileCheck[0]
}
if ($Initialize) {
    & python -B (Join-Path $RepoRoot "scripts\install_local.py")
    if ($LASTEXITCODE -ne 0) { throw "Local installation initialization failed." }
}
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Local installation is missing. Run qwen.cmd from this clone to initialize it."
}

if ($null -eq $script:LocalAiOriginalEnvironment) {
    $script:LocalAiOriginalEnvironment = @{}
    foreach ($name in $LocalAiEnvironment.Keys) {
        $script:LocalAiOriginalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
    }
}

foreach ($entry in $LocalAiEnvironment.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
}

function Restore-LocalEnvironment {
    if ($null -ne $script:LocalAiOriginalEnvironment) {
        foreach ($entry in $script:LocalAiOriginalEnvironment.GetEnumerator()) {
            [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, "Process")
        }
        $script:LocalAiOriginalEnvironment = $null
    }
}

function Test-LocalChatProxyOwnership {
    param($Response, [string]$InstancePath, [string]$ProxyScript, [string]$StateRoot, [int]$Port)
    Assert-LocalPath $InstancePath
    if (-not (Test-Path -LiteralPath $InstancePath -PathType Leaf)) { return $false }
    $instance = Get-Content -LiteralPath $InstancePath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$instance.pid -le 0 -or ($null -ne $Response -and [int]$instance.pid -ne [int]$Response.pid) -or
        [string]::IsNullOrWhiteSpace([string]$instance.shutdown_token)) { return $false }
    $process = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $([int]$instance.pid)" -ErrorAction Stop
    if ($null -eq $process) { return $false }
    $command = [string]$process.CommandLine
    foreach ($path in @($ProxyScript, $StateRoot)) {
        if ($command.IndexOf([IO.Path]::GetFullPath($path), [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    $owners = @(Get-NetTCPConnection -LocalAddress $ServerHost -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    return ($owners.Count -eq 1 -and [int]$owners[0] -eq [int]$instance.pid)
}

try {
. $ConfigPath

$ExpectedPaths = @{
    QwenRoot = $RepoRoot
    QwenCodeRoot = Join-Path $RepoRoot "runtime\qwen-code"
    LlamaCppRoot = Join-Path $RepoRoot "runtime\llama.cpp"
    ModelPath = Join-Path $RepoRoot "models\Qwen3.8-27B-UD-Q3_K_XL.gguf"
    QwenUserRoot = Join-Path $RepoRoot ".localai\qwen"
    OrchestrationRoot = Join-Path $RepoRoot ".localai\orchestration"
    QwenCodeCli = Join-Path $RepoRoot "runtime\qwen-code\bin\qwen.cmd"
    LlamaServerExe = Join-Path $RepoRoot "runtime\llama.cpp\llama-server.exe"
}

foreach ($entry in $ExpectedPaths.GetEnumerator()) {
    $actual = [IO.Path]::GetFullPath([string](Get-Variable -Name $entry.Key -ValueOnly))
    if (-not $actual.Equals([IO.Path]::GetFullPath($entry.Value), [StringComparison]::OrdinalIgnoreCase)) {
        Restore-LocalEnvironment
        throw "Installation paths must remain inside this clone: $($entry.Key)"
    }
    Assert-LocalPath $actual
}
}
catch {
    Restore-LocalEnvironment
    throw
}
