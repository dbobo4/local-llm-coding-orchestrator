param(
    [switch]$CheckOnly,
    [ValidatePattern('^v?\d+\.\d+\.\d+$')]
    [string]$Version
)

$ErrorActionPreference = "Stop"

$Root = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $Root "config\local.ps1"
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Missing local configuration: $ConfigPath" }
. $ConfigPath

$Runtime = $QwenCodeRoot
$PackageJson = Join-Path $Runtime "package.json"
$SettingsPath = Join-Path $QwenUserRoot "settings.json"
$ApiUrl = "https://api.github.com/repos/QwenLM/qwen-code/releases/latest"

function Assert-UpdateTrue([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Normalize-QwenVersion([string]$Value) { return $Value.Trim().TrimStart("v") }

function Invoke-QwenCodeSafeUpdate {
    param([Parameter(Mandatory=$true)][string]$Version)
    $RuntimeParent = Join-Path $QwenRoot "runtime\qwen-code\standalone"
    $CurrentRuntime = Join-Path $RuntimeParent "qwen-code"
    $Patcher = Join-Path $QwenRoot "config\qwen_runtime_patches.ps1"
    $SettingsPath = Join-Path $env:USERPROFILE ".qwen\settings.json"
    $QwenMd = Join-Path $env:USERPROFILE ".qwen\QWEN.md"
    $AlgorithmAgent = Join-Path $env:USERPROFILE ".qwen\agents\algorithm-agent.md"
    $TestAgent = Join-Path $env:USERPROFILE ".qwen\agents\test-agent.md"
    $BackupRoot = Join-Path $QwenRoot "backups\qwen-code-updates"

    $ArchiveName = "qwen-code-win-x64.zip"
    $NormalizedVersion = $Version.TrimStart("v")
    $Tag = "v$NormalizedVersion"
    $BaseUrl = "https://github.com/QwenLM/qwen-code/releases/download/$Tag"

    $Stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
    $TempRoot = Join-Path $env:TEMP "qwen-code-safe-update-$Stamp"
    $ArchivePath = Join-Path $TempRoot $ArchiveName
    $ChecksumsPath = Join-Path $TempRoot "SHA256SUMS"
    $ExtractRoot = Join-Path $TempRoot "extract"
    $RollbackRuntime = Join-Path $RuntimeParent "qwen-code.pre-update-$Stamp"
    $RuntimeSwapped = $false

    function Write-Step([string]$Message) {
        Write-Host ""
        Write-Host "==> $Message"
    }

    function Assert-True([bool]$Condition, [string]$Message) {
        if (-not $Condition) { throw $Message }
    }

    function Read-Json([string]$Path) {
        Assert-True (Test-Path -LiteralPath $Path) "Missing JSON file: $Path"
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)
    }

    function Get-QwenVersion([string]$RuntimePath) {
        $PackagePath = Join-Path $RuntimePath "package.json"
        $Package = Read-Json $PackagePath
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$Package.version)) "package.json has no version: $PackagePath"
        return [string]$Package.version
    }

    function Assert-NoRunningQwen {
        $Needles = @([regex]::Escape($CurrentRuntime), 'qwen-code')
        $Matches = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
            $CommandLine = [string]$_.CommandLine
            if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
            foreach ($Needle in $Needles) { if ($CommandLine -match $Needle) { return $true } }
            return $false
        } | Where-Object {
            $_.ProcessId -ne $PID -and $_.Name -in @("qwen.exe", "node.exe", "cmd.exe", "powershell.exe", "pwsh.exe")
        })
        if ($Matches.Count -gt 0) {
            $Matches | Select-Object ProcessId, ParentProcessId, Name, CommandLine | Format-List | Out-Host
            throw "Active Qwen/Qwen Code process detected. Close all Qwen sessions before updating."
        }
    }

    function Assert-SettingsInvariants {
        $Settings = Read-Json $SettingsPath
        Assert-True ($null -ne $Settings.general) "settings.json is missing the general object."
        Assert-True ($Settings.general.enableAutoUpdate -eq $false) "general.enableAutoUpdate must remain false."
        Assert-True ($null -ne $Settings.mcpServers) "settings.json is missing mcpServers."
        Assert-True ($null -ne $Settings.mcpServers.context7) "settings.json is missing the context7 MCP server."
        Assert-True ([string]$Settings.mcpServers.context7.httpUrl -eq "https://mcp.context7.com/mcp") "Context7 MCP URL is missing or unexpected."

        foreach ($Path in @($QwenMd, $AlgorithmAgent, $TestAgent)) {
            Assert-True (Test-Path -LiteralPath $Path) "Missing orchestration file: $Path"
            $Text = [IO.File]::ReadAllText($Path)
            Assert-True ($Text.Contains("CONTEXT7 MCP POLICY")) "Context7 policy missing from: $Path"
        }

        foreach ($Path in @($AlgorithmAgent, $TestAgent)) {
            $Text = [IO.File]::ReadAllText($Path)
            $FrontMatter = [regex]::Match($Text, '(?s)\A---\r?\n(.*?)\r?\n---')
            Assert-True $FrontMatter.Success "Invalid YAML frontmatter in: $Path"
            foreach ($Tool in @("mcp__context7__query-docs", "mcp__context7__resolve-library-id")) {
                $Count = ([regex]::Matches($FrontMatter.Groups[1].Value, "(?m)^\s*-\s+$([regex]::Escape($Tool))\s*$")).Count
                Assert-True ($Count -eq 1) "Context7 tool '$Tool' is not present exactly once in agent frontmatter: $Path"
            }
        }
    }

    try {
        Write-Step "Preflight"
        Assert-True (Test-Path -LiteralPath $CurrentRuntime) "Current Qwen Code runtime is missing: $CurrentRuntime"
        Assert-True (Test-Path -LiteralPath $Patcher) "Patch integrity script is missing: $Patcher"
        Assert-NoRunningQwen
        Assert-SettingsInvariants

        $OldVersion = Get-QwenVersion $CurrentRuntime
        Write-Host "Current version: $OldVersion"
        Write-Host "Target version:  $NormalizedVersion"
        if ($OldVersion -eq $NormalizedVersion) { throw "Target version $NormalizedVersion is already installed. No update performed." }

        New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

        Write-Step "Download official GitHub release artifacts"
        $ArchiveUrl = "$BaseUrl/$ArchiveName"
        $ChecksumsUrl = "$BaseUrl/SHA256SUMS"
        Write-Host "Archive:   $ArchiveUrl"
        Write-Host "Checksums: $ChecksumsUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $ArchiveUrl -OutFile $ArchivePath
        Invoke-WebRequest -UseBasicParsing -Uri $ChecksumsUrl -OutFile $ChecksumsPath
        Assert-True (Test-Path -LiteralPath $ArchivePath) "Archive download failed."
        Assert-True (Test-Path -LiteralPath $ChecksumsPath) "SHA256SUMS download failed."

        Write-Step "Verify SHA-256"
        $ChecksumText = [IO.File]::ReadAllText($ChecksumsPath)
        $ChecksumMatch = [regex]::Match($ChecksumText, "(?im)^([0-9a-f]{64})\s+\*?$([regex]::Escape($ArchiveName))\s*$")
        Assert-True $ChecksumMatch.Success "Could not find $ArchiveName in SHA256SUMS."
        $ExpectedHash = $ChecksumMatch.Groups[1].Value.ToUpperInvariant()
        $ActualHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $ArchivePath).Hash.ToUpperInvariant()
        Write-Host "Expected: $ExpectedHash"
        Write-Host "Actual:   $ActualHash"
        Assert-True ($ExpectedHash -eq $ActualHash) "Release archive SHA-256 verification failed."

        Write-Step "Validate archive paths before extraction"

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $ExtractRootFull = [IO.Path]::GetFullPath($ExtractRoot + [IO.Path]::DirectorySeparatorChar)
        $Zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($Entry in $Zip.Entries) {
                Assert-True (-not [IO.Path]::IsPathRooted($Entry.FullName)) "Unsafe rooted ZIP entry: $($Entry.FullName)"
                $EntryTarget = [IO.Path]::GetFullPath((Join-Path $ExtractRoot $Entry.FullName))
                Assert-True ($EntryTarget.StartsWith($ExtractRootFull,[StringComparison]::OrdinalIgnoreCase)) "ZIP path traversal detected: $($Entry.FullName)"
            }
        }
        finally {
            $Zip.Dispose()
        }

        Write-Step "Extract and validate release layout"
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $ExtractRoot -Force

        $ReparsePoints = @(Get-ChildItem -LiteralPath $ExtractRoot -Recurse -Force | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
        Assert-True ($ReparsePoints.Count -eq 0) "Extracted release contains a reparse point/symlink."

        $CandidateRuntime = Join-Path $ExtractRoot "qwen-code"
        Assert-True (Test-Path -LiteralPath $CandidateRuntime) "Expected archive root 'qwen-code' was not found."
        foreach ($Required in @("package.json", "lib\cli.js", "bin\qwen.cmd", "node\node.exe")) {
            Assert-True (Test-Path -LiteralPath (Join-Path $CandidateRuntime $Required)) "New runtime is missing required file: $Required"
        }
        $CandidateVersion = Get-QwenVersion $CandidateRuntime
        Write-Host "Archive version: $CandidateVersion"
        Assert-True ($CandidateVersion -eq $NormalizedVersion) "Downloaded archive version does not match requested target."

        Write-Step "Swap runtime with rollback protection"
        Assert-True (-not (Test-Path -LiteralPath $RollbackRuntime)) "Rollback staging path already exists: $RollbackRuntime"
        Move-Item -LiteralPath $CurrentRuntime -Destination $RollbackRuntime
        $RuntimeSwapped = $true
        Copy-Item -LiteralPath $CandidateRuntime -Destination $CurrentRuntime -Recurse
        Assert-True (Test-Path -LiteralPath (Join-Path $CurrentRuntime "package.json")) "New production runtime copy failed."

        Write-Step "Apply and verify orchestration compatibility patches"
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Patcher
        $PatchExit = $LASTEXITCODE
        Assert-True ($PatchExit -eq 0) "Patch integrity gate failed for Qwen Code $NormalizedVersion."
        $InstalledVersion = Get-QwenVersion $CurrentRuntime
        Assert-True ($InstalledVersion -eq $NormalizedVersion) "Production runtime version check failed after patching."

        Write-Step "Verify external orchestration/settings invariants"
        Assert-SettingsInvariants

        Write-Step "Discard transactional rollback snapshot"

        # From this point the new runtime has already passed all production
        # validation. Do not use a partially deleted rollback tree for recovery.
        $RuntimeSwapped = $false

        if (Test-Path -LiteralPath $RollbackRuntime) {
            try {
                Remove-Item `
                    -LiteralPath $RollbackRuntime `
                    -Recurse `
                    -Force `
                    -ErrorAction Stop
            }
            catch {
                Write-Warning (
                    "Update succeeded, but transient rollback cleanup failed: " +
                    $_.Exception.Message
                )
            }
        }

        Write-Host ""
        Write-Host "========================================"
        Write-Host "QWEN_CODE_SAFE_UPDATE=PASS"
        Write-Host "OLD_VERSION=$OldVersion"
        Write-Host "NEW_VERSION=$InstalledVersion"
        Write-Host "ROLLBACK_BACKUP=NONE"
        Write-Host "BACKUP_RETENTION=TRANSIENT_ONLY"
        Write-Host "AUTO_UPDATE=False"
        Write-Host "CONTEXT7_CONFIG=OK"
        Write-Host "ORCHESTRATION_AGENT_CONFIG=OK"
        Write-Host "========================================"
    }
    catch {
        Write-Host ""
        Write-Host "========================================"
        Write-Host "QWEN_CODE_SAFE_UPDATE=FAIL"
        Write-Host "ERROR=$($_.Exception.Message)"
        Write-Host "========================================"

        if ($RuntimeSwapped) {
            Write-Host "Attempting automatic runtime rollback..."
            try {
                if (Test-Path -LiteralPath $CurrentRuntime) { Remove-Item -LiteralPath $CurrentRuntime -Recurse -Force }
                if (Test-Path -LiteralPath $RollbackRuntime) {
                    Move-Item -LiteralPath $RollbackRuntime -Destination $CurrentRuntime
                    Write-Host "QWEN_CODE_ROLLBACK=PASS"
                } else {
                    Write-Host "QWEN_CODE_ROLLBACK=FAIL: rollback runtime is missing."
                }
            }
            catch {
                Write-Host "QWEN_CODE_ROLLBACK=FAIL: $($_.Exception.Message)"
            }
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $TempRoot) {
            Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    Write-Host "========================================"
    Write-Host " Qwen Code Safe Update Manager"
    Write-Host "========================================"
    Assert-UpdateTrue (Test-Path -LiteralPath $PackageJson) "Missing production package.json: $PackageJson"
    Assert-UpdateTrue (Test-Path -LiteralPath $SettingsPath) "Missing Qwen user settings: $SettingsPath"
    Assert-UpdateTrue (Test-Path -LiteralPath (Join-Path $QwenRoot "config\qwen_runtime_patches.ps1")) "Missing runtime patch manager."
    $Settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
    Assert-UpdateTrue ($null -ne $Settings.general) "settings.json is missing general."
    Assert-UpdateTrue ($Settings.general.enableAutoUpdate -eq $false) "Qwen built-in auto-update must remain disabled."
    $Package = Get-Content -LiteralPath $PackageJson -Raw | ConvertFrom-Json
    $Current = Normalize-QwenVersion ([string]$Package.version)
    Assert-UpdateTrue ($Current -match '^\d+\.\d+\.\d+$') "Unexpected installed version: $Current"
    if ([string]::IsNullOrWhiteSpace($Version)) {
        Write-Host "Checking latest stable release..."
        $Headers = @{ "User-Agent" = "qwen-local-safe-updater"; "Accept" = "application/vnd.github+json" }
        $Release = Invoke-RestMethod -UseBasicParsing -Uri $ApiUrl -Headers $Headers
        Assert-UpdateTrue (-not [bool]$Release.draft) "GitHub latest release is marked as draft."
        Assert-UpdateTrue (-not [bool]$Release.prerelease) "GitHub latest release is marked as prerelease."
        $Target = Normalize-QwenVersion ([string]$Release.tag_name)
        Assert-UpdateTrue ($Target -match '^\d+\.\d+\.\d+$') "Latest stable tag is not plain semver: $($Release.tag_name)"
        $AssetNames = @($Release.assets | ForEach-Object { [string]$_.name })
        Assert-UpdateTrue ($AssetNames -contains "qwen-code-win-x64.zip") "Latest release is missing qwen-code-win-x64.zip."
        Assert-UpdateTrue ($AssetNames -contains "SHA256SUMS") "Latest release is missing SHA256SUMS."
    } else {
        $Target = Normalize-QwenVersion $Version
    }
    $CurrentSemVer = [version]$Current
    $TargetSemVer = [version]$Target
    Write-Host "CURRENT_VERSION=$Current"
    Write-Host "TARGET_VERSION=$Target"
    if ($CurrentSemVer -eq $TargetSemVer) { Write-Host "QWEN_UPDATE_STATUS=UP_TO_DATE"; exit 0 }
    if ($CurrentSemVer -gt $TargetSemVer) { Write-Host "QWEN_UPDATE_STATUS=LOCAL_NEWER_THAN_TARGET"; exit 0 }
    if ($CheckOnly) { Write-Host "QWEN_UPDATE_STATUS=UPDATE_AVAILABLE"; exit 0 }
    Write-Host "QWEN_UPDATE_STATUS=STARTING_SAFE_UPDATE"
    Invoke-QwenCodeSafeUpdate -Version $Target
    $AfterPackage = Get-Content -LiteralPath $PackageJson -Raw | ConvertFrom-Json
    $After = Normalize-QwenVersion ([string]$AfterPackage.version)
    Assert-UpdateTrue ($After -eq $Target) "Post-update version mismatch. Expected $Target, found $After."
    Write-Host "QWEN_UPDATE_STATUS=PASS"
    Write-Host "INSTALLED_VERSION=$After"
}
catch {
    Write-Host "QWEN_UPDATE_STATUS=FAIL"
    Write-Host "ERROR=$($_.Exception.Message)"
    exit 1
}
