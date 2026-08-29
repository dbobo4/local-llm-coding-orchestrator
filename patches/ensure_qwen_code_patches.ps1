$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath"
}

. $ConfigPath

$ChunksRoot = Join-Path $QwenCodeRoot "lib\chunks"
$BackupRoot = Join-Path $QwenRoot "backups\qwen-code-patches"

$KnownValidatedPatchedSha256 =
    "753C03204D5B6388DCB9885ED5766AC496B449BDA291D27EFB5A110E159DB7ED"

if (-not (Test-Path $ChunksRoot -PathType Container)) {
    throw "Qwen Code chunks directory not found: $ChunksRoot"
}

function Get-NewLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    if ($Text.Contains("`r`n")) {
        return "`r`n"
    }

    return "`n"
}

function Read-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $bytes = [System.IO.File]::ReadAllBytes($Path)

    $hasBom =
        $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF

    if ($hasBom) {
        $text = [System.Text.Encoding]::UTF8.GetString(
            $bytes,
            3,
            $bytes.Length - 3
        )
    }
    else {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    return [PSCustomObject]@{
        Text   = $text
        HasBom = $hasBom
    }
}

function Write-Utf8File {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [bool]$HasBom
    )

    $encoding = New-Object System.Text.UTF8Encoding($HasBom)

    [System.IO.File]::WriteAllText(
        $Path,
        $Text,
        $encoding
    )
}

function Find-UniqueRuntimeFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Anchor,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $matches = @(
        Get-ChildItem $ChunksRoot -File -Filter "*.js" |
            Select-String -SimpleMatch -Pattern $Anchor |
            Select-Object -ExpandProperty Path -Unique
    )

    if ($matches.Count -ne 1) {
        throw (
            "$Purpose runtime location is not uniquely identifiable. " +
            "Expected 1 matching JS chunk, found $($matches.Count). " +
            "No runtime files were modified."
        )
    }

    return $matches[0]
}

function Get-NodeExecutable {
    $bundledNode = Join-Path $QwenCodeRoot "node\node.exe"

    if (Test-Path $bundledNode -PathType Leaf) {
        return $bundledNode
    }

    $nodeCommand = Get-Command node -ErrorAction SilentlyContinue

    if ($null -eq $nodeCommand) {
        throw "node.exe was not found. Runtime syntax validation cannot run."
    }

    return $nodeCommand.Source
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

function Get-Patch1State {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $executeMarker = "await subagent.execute(contextState, signal);"
    $executeIndex = $Text.IndexOf(
        $executeMarker,
        [System.StringComparison]::Ordinal
    )

    if ($executeIndex -lt 0) {
        return "incompatible"
    }

    if (
        $Text.IndexOf(
            $executeMarker,
            $executeIndex + $executeMarker.Length,
            [System.StringComparison]::Ordinal
        ) -ge 0
    ) {
        return "incompatible"
    }

    $windowStart = [Math]::Max(0, $executeIndex - 3000)
    $window = $Text.Substring(
        $windowStart,
        $executeIndex - $windowStart
    )

    if (
        -not $window.Contains(
            "const startHookOutput = await hookSystem.fireSubagentStartEvent("
        )
    ) {
        return "incompatible"
    }

    $hookMarker =
        'contextState.set("hook_context", additionalContext);'

    $hookIndex = $window.LastIndexOf(
        $hookMarker,
        [System.StringComparison]::Ordinal
    )

    if ($hookIndex -lt 0) {
        return "incompatible"
    }

    $taskPromptMarker =
        '`${String(contextState.get("task_prompt"))}'

    $afterHook = $window.Substring($hookIndex)

    if ($afterHook.Contains($taskPromptMarker)) {
        return "patched"
    }

    return "unpatched"
}

function Apply-Patch1 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $nl = Get-NewLine $Text

    $executeMarker = "await subagent.execute(contextState, signal);"
    $executeIndex = $Text.IndexOf(
        $executeMarker,
        [System.StringComparison]::Ordinal
    )

    if ($executeIndex -lt 0) {
        throw "Patch 1 execution marker not found."
    }

    $windowStart = [Math]::Max(0, $executeIndex - 3000)

    $hookMarker =
        'contextState.set("hook_context", additionalContext);'

    $hookIndex = $Text.LastIndexOf(
        $hookMarker,
        $executeIndex,
        $executeIndex - $windowStart + 1,
        [System.StringComparison]::Ordinal
    )

    if ($hookIndex -lt 0) {
        throw "Patch 1 insertion point not found."
    }

    $replacement =
        'contextState.set("hook_context", additionalContext);' + $nl +
        '            contextState.set(' + $nl +
        '              "task_prompt",' + $nl +
        '              `${String(contextState.get("task_prompt"))}' + $nl +
        $nl +
        '${String(additionalContext)}`' + $nl +
        '            );'

    return (
        $Text.Substring(0, $hookIndex) +
        $replacement +
        $Text.Substring($hookIndex + $hookMarker.Length)
    )
}

function Get-Patch2State {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $methodStartMarker =
        "async _executeToolCallBody(scheduledCall, signal, span) {"

    $methodStart = $Text.IndexOf(
        $methodStartMarker,
        [System.StringComparison]::Ordinal
    )

    if ($methodStart -lt 0) {
        return "incompatible"
    }

    $guardMarker =
        "const toolInvocationGuard = this.config.getToolInvocationGuard?.();"

    $guardIndex = $Text.IndexOf(
        $guardMarker,
        $methodStart,
        [System.StringComparison]::Ordinal
    )

    if ($guardIndex -lt 0) {
        return "incompatible"
    }

    $methodRegion = $Text.Substring(
        $methodStart,
        $guardIndex - $methodStart
    )

    $fireHookStart =
        $Text.IndexOf(
            "async function firePreToolUseHook(",
            [System.StringComparison]::Ordinal
        )

    $fireHookEnd =
        $Text.IndexOf(
            '__name(firePreToolUseHook, "firePreToolUseHook");',
            [System.StringComparison]::Ordinal
        )

    if (
        $fireHookStart -lt 0 -or
        $fireHookEnd -lt 0 -or
        $fireHookEnd -le $fireHookStart
    ) {
        return "incompatible"
    }

    $fireHookRegion = $Text.Substring(
        $fireHookStart,
        $fireHookEnd - $fireHookStart
    )

    $hasUpdatedInputReturn =
        $fireHookRegion.Contains(
            'const updatedInput = response.output?.hookSpecificOutput?.["tool_input"];'
        ) -and
        $fireHookRegion.Contains(
            '{ updatedInput }'
        )

    $hasLetInvocation =
        $methodRegion.Contains(
            "let invocation = scheduledCall.invocation;"
        )

    $hasConstInvocation =
        $methodRegion.Contains(
            "const invocation = scheduledCall.invocation;"
        )

    $hasUpdatedInputApplication =
        $methodRegion.Contains(
            "if (preHookResult.updatedInput && typeof preHookResult.updatedInput === `"object`" && !Array.isArray(preHookResult.updatedInput)) {"
        ) -and
        $methodRegion.Contains(
            "invocation = updatedCall.invocation;"
        )

    $unpatchedReturn =
        $fireHookRegion.Contains(
            "const additionalContext = preToolOutput.getAdditionalContext();"
        ) -and
        -not $hasUpdatedInputReturn

    if (
        $hasUpdatedInputReturn -and
        $hasLetInvocation -and
        -not $hasConstInvocation -and
        $hasUpdatedInputApplication
    ) {
        return "patched"
    }

    if (
        $unpatchedReturn -and
        $hasConstInvocation -and
        -not $hasLetInvocation -and
        -not $hasUpdatedInputApplication
    ) {
        return "unpatched"
    }

    return "incompatible"
}

function Apply-Patch2 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $nl = Get-NewLine $Text

    $oldReturn =
        '    const additionalContext = preToolOutput.getAdditionalContext();' + $nl +
        '    return {' + $nl +
        '      shouldProceed: true,' + $nl +
        '      additionalContext' + $nl +
        '    };'

    $newReturn =
        '    const additionalContext = preToolOutput.getAdditionalContext();' + $nl +
        '    const updatedInput = response.output?.hookSpecificOutput?.["tool_input"];' + $nl +
        '    return {' + $nl +
        '      shouldProceed: true,' + $nl +
        '      additionalContext,' + $nl +
        '      ...updatedInput && typeof updatedInput === "object" && !Array.isArray(updatedInput) ? { updatedInput } : {}' + $nl +
        '    };'

    $returnCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($oldReturn)
        )).Count

    if ($returnCount -ne 1) {
        throw (
            "Patch 2 PreToolUse return block is not uniquely identifiable. " +
            "Found $returnCount compatible blocks."
        )
    }

    $Text = $Text.Replace(
        $oldReturn,
        $newReturn
    )

    $constInvocation =
        "    const invocation = scheduledCall.invocation;"

    $letInvocation =
        "    let invocation = scheduledCall.invocation;"

    $invocationCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($constInvocation)
        )).Count

    if ($invocationCount -ne 1) {
        throw (
            "Patch 2 invocation declaration is not uniquely identifiable. " +
            "Found $invocationCount compatible declarations."
        )
    }

    $Text = $Text.Replace(
        $constInvocation,
        $letInvocation
    )

    $guardMarker =
        "    const toolInvocationGuard = this.config.getToolInvocationGuard?.();"

    $guardCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($guardMarker)
        )).Count

    if ($guardCount -ne 1) {
        throw (
            "Patch 2 guard insertion point is not uniquely identifiable. " +
            "Found $guardCount compatible guard markers."
        )
    }

    $rewriteBlock =
        '      if (preHookResult.updatedInput && typeof preHookResult.updatedInput === "object" && !Array.isArray(preHookResult.updatedInput)) {' + $nl +
        '        if (!this.setArgsInternal(callId, {' + $nl +
        '          ...toolInput,' + $nl +
        '          ...preHookResult.updatedInput' + $nl +
        '        })) {' + $nl +
        '          return;' + $nl +
        '        }' + $nl +
        '        const updatedCall = this.toolCalls.find((call) => call.request.callId === callId);' + $nl +
        '        if (!updatedCall || !("invocation" in updatedCall) || !updatedCall.invocation) {' + $nl +
        '          return;' + $nl +
        '        }' + $nl +
        '        invocation = updatedCall.invocation;' + $nl +
        '      }' + $nl +
        '    }' + $nl

    $preGuardNeedle =
        '    }' + $nl +
        $guardMarker

    $preGuardReplacement =
        $rewriteBlock +
        $guardMarker

    $methodStart =
        $Text.IndexOf(
            "async _executeToolCallBody(scheduledCall, signal, span) {",
            [System.StringComparison]::Ordinal
        )

    $guardIndex =
        $Text.IndexOf(
            $guardMarker,
            $methodStart,
            [System.StringComparison]::Ordinal
        )

    if ($methodStart -lt 0 -or $guardIndex -lt 0) {
        throw "Patch 2 method boundaries not found."
    }

    $preGuardIndex =
        $Text.IndexOf(
            $preGuardNeedle,
            $methodStart,
            [System.StringComparison]::Ordinal
        )

    if (
        $preGuardIndex -lt $methodStart
    ) {
        throw "Patch 2 updated-input insertion point not found."
    }

    $Text =
        $Text.Substring(0, $preGuardIndex) +
        $preGuardReplacement +
        $Text.Substring(
            $preGuardIndex + $preGuardNeedle.Length
        )

    return $Text
}

$patch1File = Find-UniqueRuntimeFile `
    -Anchor "await subagent.execute(contextState, signal);" `
    -Purpose "Patch 1"

$patch2File = Find-UniqueRuntimeFile `
    -Anchor "async _executeToolCallBody(scheduledCall, signal, span) {" `
    -Purpose "Patch 2"

$runtimeFiles = @(
    @(
        $patch1File
        $patch2File
    ) | Select-Object -Unique
)

$fileState = @{}

foreach ($path in $runtimeFiles) {
    $loaded = Read-Utf8File $path

    $fileState[$path] = [PSCustomObject]@{
        Path    = $path
        Text    = $loaded.Text
        HasBom  = $loaded.HasBom
    }
}

$patch1State = Get-Patch1State $fileState[$patch1File].Text
$patch2State = Get-Patch2State $fileState[$patch2File].Text

Write-Host "========================================"
Write-Host " Qwen Code Runtime Patch Integrity"
Write-Host "========================================"
Write-Host "Patch 1 file: $patch1File"
Write-Host "Patch 1:      $patch1State"
Write-Host "Patch 2 file: $patch2File"
Write-Host "Patch 2:      $patch2State"

if (
    $runtimeFiles.Count -eq 1
) {
    $sha = Get-FileSha256 $runtimeFiles[0]

    Write-Host "SHA256:       $sha"
    Write-Host (
        "Validated baseline: " +
        ($sha -eq $KnownValidatedPatchedSha256)
    )
}

Write-Host "========================================"

if (
    $patch1State -eq "incompatible" -or
    $patch2State -eq "incompatible"
) {
    throw (
        "QWEN_PATCH_STATUS=INCOMPATIBLE. " +
        "The installed Qwen Code runtime does not match the known safe " +
        "patched or unpatched structures. No files were modified. " +
        "Review the new runtime before updating the patch rules."
    )
}

if (
    $patch1State -eq "patched" -and
    $patch2State -eq "patched"
) {
    Write-Host "QWEN_PATCH_STATUS=OK"
    exit 0
}

if (
    ($patch1State -ne "patched" -and $patch1State -ne "unpatched") -or
    ($patch2State -ne "patched" -and $patch2State -ne "unpatched")
) {
    throw "QWEN_PATCH_STATUS=INCOMPATIBLE. Unexpected patch state."
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot $timestamp

New-Item $backupDir -ItemType Directory -Force | Out-Null

foreach ($path in $runtimeFiles) {
    $backupPath = Join-Path $backupDir ([System.IO.Path]::GetFileName($path))
    Copy-Item $path $backupPath -Force
}

Write-Host "Backup:       $backupDir"

try {
    if ($patch1State -eq "unpatched") {
        $state = $fileState[$patch1File]
        $state.Text = Apply-Patch1 $state.Text
    }

    if ($patch2State -eq "unpatched") {
        $state = $fileState[$patch2File]
        $state.Text = Apply-Patch2 $state.Text
    }

    foreach ($path in $runtimeFiles) {
        $state = $fileState[$path]

        Write-Utf8File `
            -Path $path `
            -Text $state.Text `
            -HasBom $state.HasBom
    }

    $nodeExe = Get-NodeExecutable

    foreach ($path in $runtimeFiles) {
        & $nodeExe --check $path

        if ($LASTEXITCODE -ne 0) {
            throw "node --check failed for: $path"
        }
    }

    foreach ($path in $runtimeFiles) {
        $reloaded = Read-Utf8File $path
        $fileState[$path].Text = $reloaded.Text
    }

    $finalPatch1State =
        Get-Patch1State $fileState[$patch1File].Text

    $finalPatch2State =
        Get-Patch2State $fileState[$patch2File].Text

    if (
        $finalPatch1State -ne "patched" -or
        $finalPatch2State -ne "patched"
    ) {
        throw (
            "Post-patch integrity verification failed. " +
            "Patch 1=$finalPatch1State, Patch 2=$finalPatch2State"
        )
    }

    Write-Host "PATCH_1=OK"
    Write-Host "PATCH_2=OK"

    foreach ($path in $runtimeFiles) {
        Write-Host (
            "SHA256 " +
            ([System.IO.Path]::GetFileName($path)) +
            " = " +
            (Get-FileSha256 $path)
        )
    }

    Write-Host "QWEN_PATCH_STATUS=APPLIED"
}
catch {
    Write-Warning "Patch application failed. Restoring runtime backup."

    foreach ($path in $runtimeFiles) {
        $backupPath =
            Join-Path $backupDir ([System.IO.Path]::GetFileName($path))

        if (Test-Path $backupPath -PathType Leaf) {
            Copy-Item $backupPath $path -Force
        }
    }

    throw
}
