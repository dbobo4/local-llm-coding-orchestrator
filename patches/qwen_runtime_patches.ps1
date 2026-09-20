param(
    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"

$PatchManagerRevision = 1
$Root = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $Root "config\local.ps1"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "Missing local configuration: $ConfigPath"
}

. $ConfigPath

$RuntimeRoot = $QwenCodeRoot
$ManagedRelativeFiles = @(
    "lib\chunks\chunk-PZ66FRIC.js",
    "lib\chunks\chunk-ZEYFMJQA.js",
    "lib\chunks\chunk-DJPASAUV.js",
    "lib\bundled\qc-helper\docs\configuration\settings.md"
)

$RequiredRuntimeMarkers = @(
    "LOCALAI_CONTEXT_ROLLOVER",
    "LOCALAI_SPECIALIST_CONTEXT_ROLLOVER",
    "LOCALAI_TURN_GROWTH_BUDGET_V5",
    "LOCALAI_SPECIALIST_GROWTH_TERMINATION_V5_5",
    "LOCALAI_TURN_GROWTH_LIMIT_REACHED",
    "LOCALAI_CONTEXT_ROLLOVER_REQUIRED",
    "COMPACT_MAX_OUTPUT_TOKENS",
    "localAiCompactUntilSafe"
)

function Get-ManagerNodeExecutable {
    $bundled = Join-Path $QwenCodeRoot "node\node.exe"
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($null -eq $cmd) { throw "node.exe was not found." }
    return $cmd.Source
}

function Assert-ManagedRuntimeFiles {
    foreach ($relative in $ManagedRelativeFiles) {
        $path = Join-Path $RuntimeRoot $relative
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "Managed Qwen runtime file is missing: $path"
        }
    }
}

function Test-QwenRuntimePatchState {
    Assert-ManagedRuntimeFiles
    $chunk = Join-Path $RuntimeRoot "lib\chunks\chunk-PZ66FRIC.js"
    $text = [IO.File]::ReadAllText($chunk)
    foreach ($marker in $RequiredRuntimeMarkers) {
        if (-not $text.Contains($marker)) {
            throw "Runtime verification failed; marker missing: $marker"
        }
    }
    $docs = Join-Path $RuntimeRoot "lib\bundled\qc-helper\docs\configuration\settings.md"
    if (-not ([IO.File]::ReadAllText($docs)).Contains("model.maxContextGrowthTokensPerTurn")) {
        throw "Runtime verification failed; context-growth documentation marker missing."
    }
    $node = Get-ManagerNodeExecutable
    foreach ($relative in $ManagedRelativeFiles | Where-Object { $_ -like "*.js" }) {
        $path = Join-Path $RuntimeRoot $relative
        & $node --check $path
        if ($LASTEXITCODE -ne 0) { throw "node --check failed: $path" }
    }
    Write-Host "QWEN_RUNTIME_PATCH_VERIFY=PASS"
}

# PATCH BLOCK: compatibility-and-compression
function Invoke-CompatibilityAndCompressionPatch {
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
    "8854D92C278AD63603C1E2695A2BE74B198A7D3AB3358074E0FAEAA9CF36AA8D"

$KnownValidatedNormalizedSha256 =
    "C701EF0FDF6AD974DE89A5F00C18527D4CCD7BD17F48AA95AE63E0CE0B81A3CE"

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

function Get-NormalizedTextSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $loaded = Read-Utf8File $Path

    $normalized =
        $loaded.Text.Replace("`r`n", "`n").Replace("`r", "`n")

    $bytes =
        [System.Text.Encoding]::UTF8.GetBytes($normalized)

    $sha256 =
        [System.Security.Cryptography.SHA256]::Create()

    try {
        return (
            [System.BitConverter]::ToString(
                $sha256.ComputeHash($bytes)
            ).Replace("-", "")
        )
    }
    finally {
        $sha256.Dispose()
    }
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


function ConvertFrom-CompressionBase64 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($Value)
    )
}

function Convert-CompressionTemplateNewLines {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    $normalized =
        $Text.Replace("`r`n", "`n").Replace("`r", "`n")

    return $normalized.Replace("`n", $NewLine)
}

function Get-CompressionOptimizationSpec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $nl = Get-NewLine $Text

    $unpatchedPromptRaw =
        ConvertFrom-CompressionBase64 `
            -Value "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7CiAgcmV0dXJuIGAKWW91IGFyZSB0aGUgY29tcG9uZW50IHRoYXQgc3VtbWFyaXplcyBhIGNvbnZlcnNhdGlvbiB3aGVuIGl0cyBjb250ZXh0IHdpbmRvdyBpcyBhYm91dCB0byBvdmVyZmxvdy4gVGhlIHN1bW1hcnkgeW91IHByb2R1Y2Ugd2lsbCBiZWNvbWUgdGhlIGFnZW50J3MgT05MWSBtZW1vcnkgb2YgZXZlcnl0aGluZyB0aGF0IGhhcHBlbmVkIGJlZm9yZSB0aGlzIHBvaW50LiBUaGUgYWdlbnQgd2lsbCByZXN1bWUgaXRzIHdvcmsgYmFzZWQgc29sZWx5IG9uIHRoaXMgc3VtbWFyeSBwbHVzIGEgc21hbGwgbnVtYmVyIG9mIHJlc3RvcmVkIGZpbGUgLyBpbWFnZSBhdHRhY2htZW50cyB0aGF0IGZvbGxvdy4KCkZpcnN0LCB3cmFwIHlvdXIgcmVhc29uaW5nIGluIGFuIDxhbmFseXNpcz4gYmxvY2suIEluc2lkZSBpdCwgd2FsayB0aHJvdWdoIHRoZSBjb252ZXJzYXRpb24gY2hyb25vbG9naWNhbGx5IGFuZCBpZGVudGlmeSwgZm9yIGVhY2ggc2VjdGlvbjogdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50LCB5b3VyIGFwcHJvYWNoIHRvIHRob3NlIHJlcXVlc3RzLCBrZXkgZGVjaXNpb25zIC8gdGVjaG5pY2FsIGNvbmNlcHRzIC8gY29kZSBwYXR0ZXJucywgc3BlY2lmaWMgZGV0YWlscyAoZmlsZSBuYW1lcywgY29kZSBzbmlwcGV0cywgZnVuY3Rpb24gc2lnbmF0dXJlcywgZmlsZSBlZGl0cyksIGVycm9ycyBhbmQgaG93IHRoZXkgd2VyZSBmaXhlZCwgYW5kIGFueSBzcGVjaWZpYyB1c2VyIGZlZWRiYWNrIFx1MjAxNCBlc3BlY2lhbGx5IHdoZW4gdGhlIHVzZXIgdG9sZCB5b3UgdG8gZG8gc29tZXRoaW5nIGRpZmZlcmVudGx5LiBUaGUgPGFuYWx5c2lzPiBibG9jayBpcyBzdHJpcHBlZCBiZWZvcmUgdGhlIHN1bW1hcnkgcmVhY2hlcyB0aGUgbmV4dCBhZ2VudDsgaXQgaXMgcHVyZWx5IGEgZHJhZnRpbmcgc2NyYXRjaHBhZCB0byBpbXByb3ZlIHRoZSBzdW1tYXJ5IHRoYXQgZm9sbG93cy4KClRoZW4gcHJvZHVjZSB0aGUgZmluYWwgc3VtbWFyeSBhcyB0aGUgRVhBQ1QgWE1MIHN0cnVjdHVyZSBiZWxvdy4gQmUgZGVuc2UuIE9taXQgY29udmVyc2F0aW9uYWwgZmlsbGVyLgoKPHN0YXRlX3NuYXBzaG90PgogICAgPHByaW1hcnlfcmVxdWVzdF9hbmRfaW50ZW50PgogICAgICAgIDwhLS0gQ2FwdHVyZSBhbGwgb2YgdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50cyBpbiBkZXRhaWwuIFF1b3RlIHRoZSB1c2VyJ3MgZXhhY3QgcGhyYXNpbmcgd2hlcmUgaW50ZW50IGlzIGF0IHN0YWtlLiAtLT4KICAgIDwvcHJpbWFyeV9yZXF1ZXN0X2FuZF9pbnRlbnQ+CgogICAgPGtleV90ZWNobmljYWxfY29uY2VwdHM+CiAgICAgICAgPCEtLSBMaXN0IGFsbCBpbXBvcnRhbnQgdGVjaG5pY2FsIGNvbmNlcHRzLCB0ZWNobm9sb2dpZXMsIGFuZCBmcmFtZXdvcmtzIGRpc2N1c3NlZC4gLS0+CiAgICA8L2tleV90ZWNobmljYWxfY29uY2VwdHM+CgogICAgPGZpbGVzX2FuZF9jb2RlX3NlY3Rpb25zPgogICAgICAgIDwhLS0gRW51bWVyYXRlIHNwZWNpZmljIGZpbGVzIGFuZCBjb2RlIHNlY3Rpb25zIGV4YW1pbmVkLCBtb2RpZmllZCwgb3IgY3JlYXRlZC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHRoZSBtb3N0IHJlY2VudCBtZXNzYWdlcy4gSW5jbHVkZSBmdWxsIGNvZGUgc25pcHBldHMgd2hlcmUgYXBwbGljYWJsZSwgYW5kIGEgc3VtbWFyeSBvZiB3aHkgdGhpcyBmaWxlIHJlYWQgb3IgZWRpdCBpcyBpbXBvcnRhbnQuIC0tPgogICAgPC9maWxlc19hbmRfY29kZV9zZWN0aW9ucz4KCiAgICA8ZXJyb3JzX2FuZF9maXhlcz4KICAgICAgICA8IS0tIExpc3QgZXZlcnkgZXJyb3IgZW5jb3VudGVyZWQgYW5kIGhvdyBpdCB3YXMgZml4ZWQuIEluY2x1ZGUgdGhlIHZlcmJhdGltIGVycm9yIG1lc3NhZ2Ugd2hlbiBpdCB3YXMgcXVvdGVkIHRvIHRoZSBhZ2VudC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHNwZWNpZmljIHVzZXIgZmVlZGJhY2sgb24gdGhlIGVycm9yLCBlc3BlY2lhbGx5IGlmIHRoZSB1c2VyIHRvbGQgeW91IHRvIGRvIHNvbWV0aGluZyBkaWZmZXJlbnRseS4gLS0+CiAgICA8L2Vycm9yc19hbmRfZml4ZXM+CgogICAgPHByb2JsZW1fc29sdmluZz4KICAgICAgICA8IS0tIERvY3VtZW50IHByb2JsZW1zIHNvbHZlZCBhbmQgYW55IG9uZ29pbmcgdHJvdWJsZXNob290aW5nIGVmZm9ydHMuIC0tPgogICAgPC9wcm9ibGVtX3NvbHZpbmc+CgogICAgPGFsbF91c2VyX21lc3NhZ2VzPgogICAgICAgIDwhLS0gTGlzdCBBTEwgdXNlciBtZXNzYWdlcyB0aGF0IGFyZSBub3QgdG9vbCByZXN1bHRzLCBpbiBjaHJvbm9sb2dpY2FsIG9yZGVyLiBUaGVzZSBhcmUgY3JpdGljYWwgZm9yIHVuZGVyc3RhbmRpbmcgdGhlIHVzZXIncyBmZWVkYmFjayBhbmQgc2hpZnRpbmcgaW50ZW50LiBJbmNsdWRlIHNob3J0IG1lc3NhZ2VzIGxpa2UgIm9rIiBvciAiY29udGludWUiIFx1MjAxNCB0aGV5IGFyZSBzaWduYWwuIC0tPgogICAgPC9hbGxfdXNlcl9tZXNzYWdlcz4KCiAgICA8cGVuZGluZ190YXNrcz4KICAgICAgICA8IS0tIE91dGxpbmUgYW55IHBlbmRpbmcgdGFza3MgdGhhdCB0aGUgdXNlciBoYXMgZXhwbGljaXRseSBhc2tlZCB0aGUgYWdlbnQgdG8gd29yayBvbiBidXQgdGhhdCBhcmUgbm90IHlldCBjb21wbGV0ZS4gLS0+CiAgICA8L3BlbmRpbmdfdGFza3M+CgogICAgPGN1cnJlbnRfd29yaz4KICAgICAgICA8IS0tIERlc2NyaWJlIGluIGRldGFpbCBwcmVjaXNlbHkgd2hhdCB0aGUgYWdlbnQgd2FzIHdvcmtpbmcgb24gaW1tZWRpYXRlbHkgYmVmb3JlIHRoaXMgc3VtbWFyeSB3YXMgcmVxdWVzdGVkLCBwYXlpbmcgc3BlY2lhbCBhdHRlbnRpb24gdG8gdGhlIG1vc3QgcmVjZW50IG1lc3NhZ2VzIGZyb20gYm90aCB1c2VyIGFuZCBhc3Npc3RhbnQuIEluY2x1ZGUgZmlsZSBuYW1lcyBhbmQgY29kZSBzbmlwcGV0cyB3aGVyZSBhcHBsaWNhYmxlLiAtLT4KICAgIDwvY3VycmVudF93b3JrPgoKICAgIDxuZXh0X3N0ZXA+CiAgICAgICAgPCEtLSBMaXN0IHRoZSBzaW5nbGUgbmV4dCBzdGVwIHRoZSBhZ2VudCB3aWxsIHRha2UsIHJlbGF0ZWQgdG8gdGhlIG1vc3QgcmVjZW50IHdvcmsuIFRoZSBzdGVwIE1VU1QgYmUgRElSRUNUTFkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgbW9zdCByZWNlbnQgZXhwbGljaXQgcmVxdWVzdCBhbmQgdGhlIHRhc2sgdGhlIGFnZW50IHdhcyB3b3JraW5nIG9uIGltbWVkaWF0ZWx5IGJlZm9yZSB0aGlzIHN1bW1hcnkuIElmIHRoZSBsYXN0IHRhc2sgd2FzIGNvbmNsdWRlZCwgbGlzdCBhIG5leHQgc3RlcCBvbmx5IGlmIGl0IGlzIGV4cGxpY2l0bHkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgcmVxdWVzdCBcdTIwMTQgZG8gTk9UIHN0YXJ0IHRhbmdlbnRpYWwgb3Igb2xkZXIgd29yayB3aXRob3V0IGNvbmZpcm1pbmcgd2l0aCB0aGUgdXNlciBmaXJzdC4gSWYgdGhlcmUgaXMgYSBuZXh0IHN0ZXAsIGluY2x1ZGUgZGlyZWN0IHF1b3RlcyBmcm9tIHRoZSBtb3N0IHJlY2VudCBjb252ZXJzYXRpb24gc2hvd2luZyBleGFjdGx5IHdoYXQgdGFzayB5b3Ugd2VyZSB3b3JraW5nIG9uIGFuZCB3aGVyZSB5b3UgbGVmdCBvZmYuIC0tPgogICAgPC9uZXh0X3N0ZXA+Cjwvc3RhdGVfc25hcHNob3Q+CmAudHJpbSgpOwp9Cl9fbmFtZShnZXRDb21wcmVzc2lvblByb21wdCwgImdldENvbXByZXNzaW9uUHJvbXB0Iik7"

    $patchedPromptRaw =
        ConvertFrom-CompressionBase64 `
            -Value "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7CiAgcmV0dXJuIGAKWW91IHN1bW1hcml6ZSB0aGUgYWN0aXZlIGNvZGluZy1hZ2VudCBzdGF0ZSB3aGVuIGNvbnRleHQgY29tcGFjdGlvbiBpcyByZXF1aXJlZC4KClRoZSBzdW1tYXJ5IGJlY29tZXMgdGhlIGFnZW50J3Mgd29ya2luZyBtZW1vcnkgYWZ0ZXIgY29tcGFjdGlvbi4gUHJlc2VydmUgb25seSBpbmZvcm1hdGlvbiByZXF1aXJlZCB0byBjb250aW51ZSB0aGUgY3VycmVudCB0YXNrIGNvcnJlY3RseS4gRG8gbm90IHByZXNlcnZlIGNvbnZlcnNhdGlvbiBoaXN0b3J5IGZvciBpdHMgb3duIHNha2UuCgpQcm9kdWNlIG9ubHkgdGhpcyBYTUwgc3RydWN0dXJlOgoKPHN0YXRlX3NuYXBzaG90PgogIDxnb2FsPgogICAgQ3VycmVudCB1c2VyIGdvYWwgYW5kIGFjY2VwdGFuY2UgY3JpdGVyaWEuCiAgPC9nb2FsPgogIDxkdXJhYmxlX2NvbnN0cmFpbnRzPgogICAgT25seSBjb25zdHJhaW50cywgaW52YXJpYW50cywgaW50ZXJmYWNlcywgYW5kIGRlY2lzaW9ucyB0aGF0IHN0aWxsIGFmZmVjdCB0aGUgd29yay4KICA8L2R1cmFibGVfY29uc3RyYWludHM+CiAgPGN1cnJlbnRfc3RhdGU+CiAgICBXaGF0IGlzIGFscmVhZHkgaW1wbGVtZW50ZWQgb3IgdmVyaWZpZWQuIE1lbnRpb24gb25seSByZWxldmFudCBmaWxlcywgc3ltYm9scywgY29tbWFuZHMsIGFuZCBvdXRjb21lcy4KICA8L2N1cnJlbnRfc3RhdGU+CiAgPG9wZW5faXNzdWVzPgogICAgVW5yZXNvbHZlZCBlcnJvcnMsIGZhaWxlZCBjaGVja3MsIG9yIHVuY2VydGFpbnRpZXMgdGhhdCBzdGlsbCBtYXR0ZXIuCiAgPC9vcGVuX2lzc3Vlcz4KICA8bmV4dF9zdGVwPgogICAgVGhlIHNpbmdsZSBpbW1lZGlhdGUgbmV4dCBhY3Rpb24uCiAgPC9uZXh0X3N0ZXA+Cjwvc3RhdGVfc25hcHNob3Q+CgpDb21wcmVzc2lvbiBydWxlczoKLSBUYXJnZXQgcm91Z2hseSA4MDAtMTUwMCB0b2tlbnM7IHN0YXkgd2VsbCBiZWxvdyB0aGUgb3V0cHV0IGxpbWl0LgotIERvIG5vdCByZXByb2R1Y2UgZnVsbCB1c2VyIG1lc3NhZ2VzLgotIERvIG5vdCByZXByb2R1Y2UgZnVsbCBzb3VyY2UgZmlsZXMgb3IgbG9uZyBjb2RlIHNuaXBwZXRzLgotIERvIG5vdCBsaXN0IHJvdXRpbmUgdG9vbCBjYWxscyBvciB0cmFuc2llbnQgZXhwbG9yYXRpb24uCi0gRG8gbm90IHJlcGVhdCBjb21wbGV0ZWQgaGlzdG9yeSB1bmxlc3MgaXQgY29uc3RyYWlucyB0aGUgcmVtYWluaW5nIHdvcmsuCi0gUHJlZmVyIGV4YWN0IGZpbGUgcGF0aHMsIHN5bWJvbCBuYW1lcywgY29tbWFuZHMsIGFuZCBjb25jaXNlIGZhY3RzIHdoZW4gdGhleSBhcmUgbmVjZXNzYXJ5IHRvIHJlc3VtZS4KLSBQcmVzZXJ2ZSB1bnJlc29sdmVkIGZhaWx1cmVzIGFuZCB0aGUgZXhhY3QgdGVjaG5pY2FsIGNvbmRpdGlvbiBuZWVkZWQgdG8gY29udGludWUuCi0gTm8gcHJvc2Ugb3V0c2lkZSA8c3RhdGVfc25hcHNob3Q+LgpgLnRyaW0oKTsKfQpfX25hbWUoZ2V0Q29tcHJlc3Npb25Qcm9tcHQsICJnZXRDb21wcmVzc2lvblByb21wdCIpOw=="

    return [PSCustomObject]@{
        PromptStartMarker =
            "function getCompressionPrompt() {"

        PromptEndMarker =
            '__name(getCompressionPrompt, "getCompressionPrompt");'

        UnpatchedPrompt =
            Convert-CompressionTemplateNewLines `
                -Text $unpatchedPromptRaw `
                -NewLine $nl

        PatchedPrompt =
            Convert-CompressionTemplateNewLines `
                -Text $patchedPromptRaw `
                -NewLine $nl

        UnpatchedCap =
            ConvertFrom-CompressionBase64 `
                -Value "dmFyIENPTVBBQ1RfTUFYX09VVFBVVF9UT0tFTlMgPSAyZTQ7"

        LegacyCap =
            ConvertFrom-CompressionBase64 `
                -Value "dmFyIENPTVBBQ1RfTUFYX09VVFBVVF9UT0tFTlMgPSA0MDk2Ow=="

        PatchedCap =
            ConvertFrom-CompressionBase64 `
                -Value "dmFyIENPTVBBQ1RfTUFYX09VVFBVVF9UT0tFTlMgPSAzMDcyOw=="

        UnpatchedDirective =
            ConvertFrom-CompressionBase64 `
                -Value "dmFyIENPTVBSRVNTSU9OX1JFUVVFU1RfRElSRUNUSVZFID0gIkZpcnN0LCByZWFzb24gaW4geW91ciA8YW5hbHlzaXM+IGJsb2NrLiBUaGVuLCBwcm9kdWNlIHRoZSA8c3RhdGVfc25hcHNob3Q+IFhNTC4iOw=="

        PatchedDirective =
            ConvertFrom-CompressionBase64 `
                -Value "dmFyIENPTVBSRVNTSU9OX1JFUVVFU1RfRElSRUNUSVZFID0gIlByb2R1Y2UgdGhlIGNvbXBhY3QgPHN0YXRlX3NuYXBzaG90PiBYTUwgZGlyZWN0bHkuIERvIG5vdCBpbmNsdWRlIGFuIDxhbmFseXNpcz4gYmxvY2suIjs="
    }
}

function Get-CompressionOptimizationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $capPrefix =
        "var COMPACT_MAX_OUTPUT_TOKENS = "

    $directivePrefix =
        "var COMPRESSION_REQUEST_DIRECTIVE = "

    $reservePrefix =
        "var SUMMARY_RESERVE = "

    $stockCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 2e4;"

    $legacyCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 4096;"

    $v32Cap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 3072;"

    $targetCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 2048;"

    $stockDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "First, reason in your <analysis> block. Then, produce the <state_snapshot> XML.";'

    $optimizedDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce the compact <state_snapshot> XML directly. Do not include an <analysis> block.";'

    $aggressiveDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce one canonical replacement <state_snapshot> in roughly 600-1000 tokens. Omit analysis, transcript, and superseded history.";'

    $defaultReserve =
        "var SUMMARY_RESERVE = COMPACT_MAX_OUTPUT_TOKENS;"

    $targetReserve =
        "var SUMMARY_RESERVE = 3072;"

    if (
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $capPrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $directivePrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $reservePrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker "function getCompressionPrompt() {"
        )
    ) {
        return "incompatible"
    }

    $blocks =
        Get-CompressionPromptBlocks

    $hasStockCap = $Text.Contains($stockCap)
    $hasLegacyCap = $Text.Contains($legacyCap)
    $hasV32Cap = $Text.Contains($v32Cap)
    $hasTargetCap = $Text.Contains($targetCap)

    if (
        (
            [int]$hasStockCap +
            [int]$hasLegacyCap +
            [int]$hasV32Cap +
            [int]$hasTargetCap
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasStockDirective = $Text.Contains($stockDirective)
    $hasOptimizedDirective = $Text.Contains($optimizedDirective)
    $hasAggressiveDirective = $Text.Contains($aggressiveDirective)

    if (
        (
            [int]$hasStockDirective +
            [int]$hasOptimizedDirective +
            [int]$hasAggressiveDirective
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasStockPrompt = $Text.Contains($blocks.Stock)
    $hasOptimizedPrompt = $Text.Contains($blocks.Optimized)
    $hasAggressivePrompt = $Text.Contains($blocks.Aggressive)

    if (
        (
            [int]$hasStockPrompt +
            [int]$hasOptimizedPrompt +
            [int]$hasAggressivePrompt
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasDefaultReserve = $Text.Contains($defaultReserve)
    $hasTargetReserve = $Text.Contains($targetReserve)

    if (
        (
            [int]$hasDefaultReserve +
            [int]$hasTargetReserve
        ) -ne 1
    ) {
        return "incompatible"
    }

    if (
        $hasStockCap -and
        $hasStockDirective -and
        $hasStockPrompt -and
        $hasDefaultReserve
    ) {
        return "unpatched"
    }

    if (
        $hasLegacyCap -and
        $hasOptimizedDirective -and
        $hasOptimizedPrompt -and
        $hasDefaultReserve
    ) {
        return "legacy"
    }

    if (
        $hasV32Cap -and
        $hasOptimizedDirective -and
        $hasOptimizedPrompt -and
        $hasDefaultReserve
    ) {
        return "v32"
    }

    if (
        $hasTargetCap -and
        $hasAggressiveDirective -and
        $hasAggressivePrompt -and
        $hasTargetReserve
    ) {
        return "patched"
    }

    return "incompatible"
}

function Apply-CompressionOptimization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $state =
        Get-CompressionOptimizationState $Text

    if ($state -eq "patched") {
        return $Text
    }

    if (
        $state -ne "v32" -and
        $state -ne "legacy" -and
        $state -ne "unpatched"
    ) {
        throw (
            "Compression optimization cannot be " +
            "applied from state: $state"
        )
    }

    $blocks =
        Get-CompressionPromptBlocks

    $oldCap = switch ($state) {
        "unpatched" { "var COMPACT_MAX_OUTPUT_TOKENS = 2e4;" }
        "legacy" { "var COMPACT_MAX_OUTPUT_TOKENS = 4096;" }
        "v32" { "var COMPACT_MAX_OUTPUT_TOKENS = 3072;" }
    }

    $oldDirective = if ($state -eq "unpatched") {
        'var COMPRESSION_REQUEST_DIRECTIVE = "First, reason in your <analysis> block. Then, produce the <state_snapshot> XML.";'
    }
    else {
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce the compact <state_snapshot> XML directly. Do not include an <analysis> block.";'
    }

    $oldPrompt = if ($state -eq "unpatched") {
        $blocks.Stock
    }
    else {
        $blocks.Optimized
    }

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldCap `
            -New "var COMPACT_MAX_OUTPUT_TOKENS = 2048;" `
            -Purpose "Compression aggressiveness cap"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldDirective `
            -New 'var COMPRESSION_REQUEST_DIRECTIVE = "Produce one canonical replacement <state_snapshot> in roughly 600-1000 tokens. Omit analysis, transcript, and superseded history.";' `
            -Purpose "Compression aggressiveness directive"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldPrompt `
            -New $blocks.Aggressive `
            -Purpose "Compression aggressiveness prompt"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old "var SUMMARY_RESERVE = COMPACT_MAX_OUTPUT_TOKENS;" `
            -New "var SUMMARY_RESERVE = 3072;" `
            -Purpose "Compression aggressiveness threshold reserve"

    $finalState =
        Get-CompressionOptimizationState $Text

    if ($finalState -ne "patched") {
        throw (
            "Compression optimization did not " +
            "reach patched state. Final=$finalState"
        )
    }

    return $Text
}



function Convert-LfTemplateToRuntimeNewLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    return $Template.Replace("`r`n", "`n").Replace("`n", $NewLine)
}

function Test-UniqueOrdinalMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Marker
    )

    $first = $Text.IndexOf(
        $Marker,
        [System.StringComparison]::Ordinal
    )

    if ($first -lt 0) {
        return $false
    }

    $second = $Text.IndexOf(
        $Marker,
        $first + $Marker.Length,
        [System.StringComparison]::Ordinal
    )

    return $second -lt 0
}

function Replace-UniqueOrdinalMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Old,

        [Parameter(Mandatory = $true)]
        [string]$New,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $first = $Text.IndexOf(
        $Old,
        [System.StringComparison]::Ordinal
    )

    if ($first -lt 0) {
        throw "$Purpose marker not found."
    }

    $second = $Text.IndexOf(
        $Old,
        $first + $Old.Length,
        [System.StringComparison]::Ordinal
    )

    if ($second -ge 0) {
        throw "$Purpose marker is not unique."
    }

    return (
        $Text.Substring(0, $first) +
        $New +
        $Text.Substring($first + $Old.Length)
    )
}

function Replace-UniqueOrdinalRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Start,

        [Parameter(Mandatory = $true)]
        [string]$End,

        [Parameter(Mandatory = $true)]
        [string]$New,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $startIndex = $Text.IndexOf($Start, [System.StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        throw "$Purpose start marker not found."
    }

    $secondStart = $Text.IndexOf(
        $Start,
        $startIndex + $Start.Length,
        [System.StringComparison]::Ordinal
    )
    if ($secondStart -ge 0) {
        throw "$Purpose start marker is not unique."
    }

    $endIndex = $Text.IndexOf(
        $End,
        $startIndex + $Start.Length,
        [System.StringComparison]::Ordinal
    )
    if ($endIndex -lt 0) {
        throw "$Purpose end marker not found."
    }

    return (
        $Text.Substring(0, $startIndex) +
        $New +
        $Text.Substring($endIndex)
    )
}

function Get-CompressionPromptBlocks {
    $stock =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7CiAgcmV0dXJuIGAKWW91IGFyZSB0aGUgY29tcG9uZW50IHRoYXQgc3VtbWFyaXplcyBhIGNvbnZlcnNhdGlvbiB3aGVuIGl0cyBjb250ZXh0IHdpbmRvdyBpcyBhYm91dCB0byBvdmVyZmxvdy4gVGhlIHN1bW1hcnkgeW91IHByb2R1Y2Ugd2lsbCBiZWNvbWUgdGhlIGFnZW50J3MgT05MWSBtZW1vcnkgb2YgZXZlcnl0aGluZyB0aGF0IGhhcHBlbmVkIGJlZm9yZSB0aGlzIHBvaW50LiBUaGUgYWdlbnQgd2lsbCByZXN1bWUgaXRzIHdvcmsgYmFzZWQgc29sZWx5IG9uIHRoaXMgc3VtbWFyeSBwbHVzIGEgc21hbGwgbnVtYmVyIG9mIHJlc3RvcmVkIGZpbGUgLyBpbWFnZSBhdHRhY2htZW50cyB0aGF0IGZvbGxvdy4KCkZpcnN0LCB3cmFwIHlvdXIgcmVhc29uaW5nIGluIGFuIDxhbmFseXNpcz4gYmxvY2suIEluc2lkZSBpdCwgd2FsayB0aHJvdWdoIHRoZSBjb252ZXJzYXRpb24gY2hyb25vbG9naWNhbGx5IGFuZCBpZGVudGlmeSwgZm9yIGVhY2ggc2VjdGlvbjogdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50LCB5b3VyIGFwcHJvYWNoIHRvIHRob3NlIHJlcXVlc3RzLCBrZXkgZGVjaXNpb25zIC8gdGVjaG5pY2FsIGNvbmNlcHRzIC8gY29kZSBwYXR0ZXJucywgc3BlY2lmaWMgZGV0YWlscyAoZmlsZSBuYW1lcywgY29kZSBzbmlwcGV0cywgZnVuY3Rpb24gc2lnbmF0dXJlcywgZmlsZSBlZGl0cyksIGVycm9ycyBhbmQgaG93IHRoZXkgd2VyZSBmaXhlZCwgYW5kIGFueSBzcGVjaWZpYyB1c2VyIGZlZWRiYWNrIFx1MjAxNCBlc3BlY2lhbGx5IHdoZW4gdGhlIHVzZXIgdG9sZCB5b3UgdG8gZG8gc29tZXRoaW5nIGRpZmZlcmVudGx5LiBUaGUgPGFuYWx5c2lzPiBibG9jayBpcyBzdHJpcHBlZCBiZWZvcmUgdGhlIHN1bW1hcnkgcmVhY2hlcyB0aGUgbmV4dCBhZ2VudDsgaXQgaXMgcHVyZWx5IGEgZHJhZnRpbmcgc2NyYXRjaHBhZCB0byBpbXByb3ZlIHRoZSBzdW1tYXJ5IHRoYXQgZm9sbG93cy4KClRoZW4gcHJvZHVjZSB0aGUgZmluYWwgc3VtbWFyeSBhcyB0aGUgRVhBQ1QgWE1MIHN0cnVjdHVyZSBiZWxvdy4gQmUgZGVuc2UuIE9taXQgY29udmVyc2F0aW9uYWwgZmlsbGVyLgoKPHN0YXRlX3NuYXBzaG90PgogICAgPHByaW1hcnlfcmVxdWVzdF9hbmRfaW50ZW50PgogICAgICAgIDwhLS0gQ2FwdHVyZSBhbGwgb2YgdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50cyBpbiBkZXRhaWwuIFF1b3RlIHRoZSB1c2VyJ3MgZXhhY3QgcGhyYXNpbmcgd2hlcmUgaW50ZW50IGlzIGF0IHN0YWtlLiAtLT4KICAgIDwvcHJpbWFyeV9yZXF1ZXN0X2FuZF9pbnRlbnQ+CgogICAgPGtleV90ZWNobmljYWxfY29uY2VwdHM+CiAgICAgICAgPCEtLSBMaXN0IGFsbCBpbXBvcnRhbnQgdGVjaG5pY2FsIGNvbmNlcHRzLCB0ZWNobm9sb2dpZXMsIGFuZCBmcmFtZXdvcmtzIGRpc2N1c3NlZC4gLS0+CiAgICA8L2tleV90ZWNobmljYWxfY29uY2VwdHM+CgogICAgPGZpbGVzX2FuZF9jb2RlX3NlY3Rpb25zPgogICAgICAgIDwhLS0gRW51bWVyYXRlIHNwZWNpZmljIGZpbGVzIGFuZCBjb2RlIHNlY3Rpb25zIGV4YW1pbmVkLCBtb2RpZmllZCwgb3IgY3JlYXRlZC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHRoZSBtb3N0IHJlY2VudCBtZXNzYWdlcy4gSW5jbHVkZSBmdWxsIGNvZGUgc25pcHBldHMgd2hlcmUgYXBwbGljYWJsZSwgYW5kIGEgc3VtbWFyeSBvZiB3aHkgdGhpcyBmaWxlIHJlYWQgb3IgZWRpdCBpcyBpbXBvcnRhbnQuIC0tPgogICAgPC9maWxlc19hbmRfY29kZV9zZWN0aW9ucz4KCiAgICA8ZXJyb3JzX2FuZF9maXhlcz4KICAgICAgICA8IS0tIExpc3QgZXZlcnkgZXJyb3IgZW5jb3VudGVyZWQgYW5kIGhvdyBpdCB3YXMgZml4ZWQuIEluY2x1ZGUgdGhlIHZlcmJhdGltIGVycm9yIG1lc3NhZ2Ugd2hlbiBpdCB3YXMgcXVvdGVkIHRvIHRoZSBhZ2VudC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHNwZWNpZmljIHVzZXIgZmVlZGJhY2sgb24gdGhlIGVycm9yLCBlc3BlY2lhbGx5IGlmIHRoZSB1c2VyIHRvbGQgeW91IHRvIGRvIHNvbWV0aGluZyBkaWZmZXJlbnRseS4gLS0+CiAgICA8L2Vycm9yc19hbmRfZml4ZXM+CgogICAgPHByb2JsZW1fc29sdmluZz4KICAgICAgICA8IS0tIERvY3VtZW50IHByb2JsZW1zIHNvbHZlZCBhbmQgYW55IG9uZ29pbmcgdHJvdWJsZXNob290aW5nIGVmZm9ydHMuIC0tPgogICAgPC9wcm9ibGVtX3NvbHZpbmc+CgogICAgPGFsbF91c2VyX21lc3NhZ2VzPgogICAgICAgIDwhLS0gTGlzdCBBTEwgdXNlciBtZXNzYWdlcyB0aGF0IGFyZSBub3QgdG9vbCByZXN1bHRzLCBpbiBjaHJvbm9sb2dpY2FsIG9yZGVyLiBUaGVzZSBhcmUgY3JpdGljYWwgZm9yIHVuZGVyc3RhbmRpbmcgdGhlIHVzZXIncyBmZWVkYmFjayBhbmQgc2hpZnRpbmcgaW50ZW50LiBJbmNsdWRlIHNob3J0IG1lc3NhZ2VzIGxpa2UgIm9rIiBvciAiY29udGludWUiIFx1MjAxNCB0aGV5IGFyZSBzaWduYWwuIC0tPgogICAgPC9hbGxfdXNlcl9tZXNzYWdlcz4KCiAgICA8cGVuZGluZ190YXNrcz4KICAgICAgICA8IS0tIE91dGxpbmUgYW55IHBlbmRpbmcgdGFza3MgdGhhdCB0aGUgdXNlciBoYXMgZXhwbGljaXRseSBhc2tlZCB0aGUgYWdlbnQgdG8gd29yayBvbiBidXQgdGhhdCBhcmUgbm90IHlldCBjb21wbGV0ZS4gLS0+CiAgICA8L3BlbmRpbmdfdGFza3M+CgogICAgPGN1cnJlbnRfd29yaz4KICAgICAgICA8IS0tIERlc2NyaWJlIGluIGRldGFpbCBwcmVjaXNlbHkgd2hhdCB0aGUgYWdlbnQgd2FzIHdvcmtpbmcgb24gaW1tZWRpYXRlbHkgYmVmb3JlIHRoaXMgc3VtbWFyeSB3YXMgcmVxdWVzdGVkLCBwYXlpbmcgc3BlY2lhbCBhdHRlbnRpb24gdG8gdGhlIG1vc3QgcmVjZW50IG1lc3NhZ2VzIGZyb20gYm90aCB1c2VyIGFuZCBhc3Npc3RhbnQuIEluY2x1ZGUgZmlsZSBuYW1lcyBhbmQgY29kZSBzbmlwcGV0cyB3aGVyZSBhcHBsaWNhYmxlLiAtLT4KICAgIDwvY3VycmVudF93b3JrPgoKICAgIDxuZXh0X3N0ZXA+CiAgICAgICAgPCEtLSBMaXN0IHRoZSBzaW5nbGUgbmV4dCBzdGVwIHRoZSBhZ2VudCB3aWxsIHRha2UsIHJlbGF0ZWQgdG8gdGhlIG1vc3QgcmVjZW50IHdvcmsuIFRoZSBzdGVwIE1VU1QgYmUgRElSRUNUTFkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgbW9zdCByZWNlbnQgZXhwbGljaXQgcmVxdWVzdCBhbmQgdGhlIHRhc2sgdGhlIGFnZW50IHdhcyB3b3JraW5nIG9uIGltbWVkaWF0ZWx5IGJlZm9yZSB0aGlzIHN1bW1hcnkuIElmIHRoZSBsYXN0IHRhc2sgd2FzIGNvbmNsdWRlZCwgbGlzdCBhIG5leHQgc3RlcCBvbmx5IGlmIGl0IGlzIGV4cGxpY2l0bHkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgcmVxdWVzdCBcdTIwMTQgZG8gTk9UIHN0YXJ0IHRhbmdlbnRpYWwgb3Igb2xkZXIgd29yayB3aXRob3V0IGNvbmZpcm1pbmcgd2l0aCB0aGUgdXNlciBmaXJzdC4gSWYgdGhlcmUgaXMgYSBuZXh0IHN0ZXAsIGluY2x1ZGUgZGlyZWN0IHF1b3RlcyBmcm9tIHRoZSBtb3N0IHJlY2VudCBjb252ZXJzYXRpb24gc2hvd2luZyBleGFjdGx5IHdoYXQgdGFzayB5b3Ugd2VyZSB3b3JraW5nIG9uIGFuZCB3aGVyZSB5b3UgbGVmdCBvZmYuIC0tPgogICAgPC9uZXh0X3N0ZXA+Cjwvc3RhdGVfc25hcHNob3Q+CmAudHJpbSgpOwp9Cl9fbmFtZShnZXRDb21wcmVzc2lvblByb21wdCwgImdldENvbXByZXNzaW9uUHJvbXB0Iik7"
            )
        )

    $optimized =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7DQogIHJldHVybiBgDQpZb3Ugc3VtbWFyaXplIHRoZSBhY3RpdmUgY29kaW5nLWFnZW50IHN0YXRlIHdoZW4gY29udGV4dCBjb21wYWN0aW9uIGlzIHJlcXVpcmVkLg0KDQpUaGUgc3VtbWFyeSBiZWNvbWVzIHRoZSBhZ2VudCdzIHdvcmtpbmcgbWVtb3J5IGFmdGVyIGNvbXBhY3Rpb24uIFByZXNlcnZlIG9ubHkgaW5mb3JtYXRpb24gcmVxdWlyZWQgdG8gY29udGludWUgdGhlIGN1cnJlbnQgdGFzayBjb3JyZWN0bHkuIERvIG5vdCBwcmVzZXJ2ZSBjb252ZXJzYXRpb24gaGlzdG9yeSBmb3IgaXRzIG93biBzYWtlLg0KDQpQcm9kdWNlIG9ubHkgdGhpcyBYTUwgc3RydWN0dXJlOg0KDQo8c3RhdGVfc25hcHNob3Q+DQogIDxnb2FsPg0KICAgIEN1cnJlbnQgdXNlciBnb2FsIGFuZCBhY2NlcHRhbmNlIGNyaXRlcmlhLg0KICA8L2dvYWw+DQogIDxkdXJhYmxlX2NvbnN0cmFpbnRzPg0KICAgIE9ubHkgY29uc3RyYWludHMsIGludmFyaWFudHMsIGludGVyZmFjZXMsIGFuZCBkZWNpc2lvbnMgdGhhdCBzdGlsbCBhZmZlY3QgdGhlIHdvcmsuDQogIDwvZHVyYWJsZV9jb25zdHJhaW50cz4NCiAgPGN1cnJlbnRfc3RhdGU+DQogICAgV2hhdCBpcyBhbHJlYWR5IGltcGxlbWVudGVkIG9yIHZlcmlmaWVkLiBNZW50aW9uIG9ubHkgcmVsZXZhbnQgZmlsZXMsIHN5bWJvbHMsIGNvbW1hbmRzLCBhbmQgb3V0Y29tZXMuDQogIDwvY3VycmVudF9zdGF0ZT4NCiAgPG9wZW5faXNzdWVzPg0KICAgIFVucmVzb2x2ZWQgZXJyb3JzLCBmYWlsZWQgY2hlY2tzLCBvciB1bmNlcnRhaW50aWVzIHRoYXQgc3RpbGwgbWF0dGVyLg0KICA8L29wZW5faXNzdWVzPg0KICA8bmV4dF9zdGVwPg0KICAgIFRoZSBzaW5nbGUgaW1tZWRpYXRlIG5leHQgYWN0aW9uLg0KICA8L25leHRfc3RlcD4NCjwvc3RhdGVfc25hcHNob3Q+DQoNCkNvbXByZXNzaW9uIHJ1bGVzOg0KLSBUYXJnZXQgcm91Z2hseSA4MDAtMTUwMCB0b2tlbnM7IHN0YXkgd2VsbCBiZWxvdyB0aGUgb3V0cHV0IGxpbWl0Lg0KLSBEbyBub3QgcmVwcm9kdWNlIGZ1bGwgdXNlciBtZXNzYWdlcy4NCi0gRG8gbm90IHJlcHJvZHVjZSBmdWxsIHNvdXJjZSBmaWxlcyBvciBsb25nIGNvZGUgc25pcHBldHMuDQotIERvIG5vdCBsaXN0IHJvdXRpbmUgdG9vbCBjYWxscyBvciB0cmFuc2llbnQgZXhwbG9yYXRpb24uDQotIERvIG5vdCByZXBlYXQgY29tcGxldGVkIGhpc3RvcnkgdW5sZXNzIGl0IGNvbnN0cmFpbnMgdGhlIHJlbWFpbmluZyB3b3JrLg0KLSBQcmVmZXIgZXhhY3QgZmlsZSBwYXRocywgc3ltYm9sIG5hbWVzLCBjb21tYW5kcywgYW5kIGNvbmNpc2UgZmFjdHMgd2hlbiB0aGV5IGFyZSBuZWNlc3NhcnkgdG8gcmVzdW1lLg0KLSBQcmVzZXJ2ZSB1bnJlc29sdmVkIGZhaWx1cmVzIGFuZCB0aGUgZXhhY3QgdGVjaG5pY2FsIGNvbmRpdGlvbiBuZWVkZWQgdG8gY29udGludWUuDQotIE5vIHByb3NlIG91dHNpZGUgPHN0YXRlX3NuYXBzaG90Pi4NCmAudHJpbSgpOw0KfQ0KX19uYW1lKGdldENvbXByZXNzaW9uUHJvbXB0LCAiZ2V0Q29tcHJlc3Npb25Qcm9tcHQiKTs="
            )
        )

    $aggressive =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7DQogIHJldHVybiBgDQpZb3UgY3JlYXRlIGEgY2Fub25pY2FsIHJlcGxhY2VtZW50IHN0YXRlIGZvciBhbiBhY3RpdmUgY29kaW5nLWFnZW50IHdoZW4gY29udGV4dCBjb21wYWN0aW9uIGlzIHJlcXVpcmVkLg0KDQpUaGUgb3V0cHV0IHJlcGxhY2VzIHByaW9yIGNvbXBhY3RlZCBtZW1vcnkuIERvIG5vdCBuYXJyYXRlIG9yIHN1bW1hcml6ZSB0aGUgY29udmVyc2F0aW9uLiBSZWNvbnN0cnVjdCBvbmx5IHRoZSBzbWFsbGVzdCBzdGF0ZSBzdWZmaWNpZW50IHRvIGNvbnRpbnVlIGNvcnJlY3RseSBmcm9tIHRoZSBuZXh0IG1vZGVsIGN5Y2xlLg0KDQpQcm9kdWNlIG9ubHkgdGhpcyBYTUwgc3RydWN0dXJlOg0KDQo8c3RhdGVfc25hcHNob3Q+DQogIDxnb2FsPg0KICAgIEN1cnJlbnQgdXNlciBnb2FsIGFuZCBhY2NlcHRhbmNlIGNyaXRlcmlhIHRoYXQgc3RpbGwgbWF0dGVyLg0KICA8L2dvYWw+DQogIDxkdXJhYmxlX2NvbnN0cmFpbnRzPg0KICAgIE9ubHkgbGl2ZSBjb25zdHJhaW50cywgaW52YXJpYW50cywgaW50ZXJmYWNlcywgZGVjaXNpb25zLCBhbmQgZXhhY3QgZW52aXJvbm1lbnQgZmFjdHMgcmVxdWlyZWQgZm9yIHNhZmUgY29udGludWF0aW9uLg0KICA8L2R1cmFibGVfY29uc3RyYWludHM+DQogIDxjdXJyZW50X3N0YXRlPg0KICAgIFRoZSBsYXRlc3QgcmVzdWx0aW5nIHN0YXRlOiB3aGF0IGlzIGltcGxlbWVudGVkLCBhcHBsaWVkLCB2ZXJpZmllZCwgb3IgY3VycmVudGx5IGFjdGl2ZS4gUmVjb3JkIG91dGNvbWVzLCBub3QgY2hyb25vbG9neS4NCiAgPC9jdXJyZW50X3N0YXRlPg0KICA8b3Blbl9pc3N1ZXM+DQogICAgT25seSB1bnJlc29sdmVkIGJsb2NrZXJzLCBmYWlsZWQgY2hlY2tzLCBvciB1bmNlcnRhaW50aWVzIHRoYXQgc3RpbGwgYWZmZWN0IHRoZSBuZXh0IGFjdGlvbi4NCiAgPC9vcGVuX2lzc3Vlcz4NCiAgPG5leHRfc3RlcD4NCiAgICBFeGFjdGx5IG9uZSBpbW1lZGlhdGUgbmV4dCBhY3Rpb24uDQogIDwvbmV4dF9zdGVwPg0KPC9zdGF0ZV9zbmFwc2hvdD4NCg0KQ2Fub25pY2FsIHJlcGxhY2VtZW50IHJ1bGVzOg0KLSBUYXJnZXQgcm91Z2hseSA2MDAtMTAwMCB0b2tlbnM7IHNob3J0ZXIgaXMgYmV0dGVyIHdoZW4gY29tcGxldGUuDQotIEVtaXQgb25lIGZyZXNoIGNhbm9uaWNhbCBzbmFwc2hvdC4gTmV2ZXIgcXVvdGUsIHByZXNlcnZlLCBvciBkZXNjcmliZSBhbiBvbGRlciA8c3RhdGVfc25hcHNob3Q+IGFzIGhpc3RvcmljYWwgdGV4dC4NCi0gTWVyZ2UgZHVwbGljYXRlIGZhY3RzLiBJZiBhIG5ld2VyIGZhY3Qgc3VwZXJzZWRlcyBhbiBvbGRlciBmYWN0LCBrZWVwIG9ubHkgdGhlIG5ld2VzdCB2YWxpZCBmYWN0Lg0KLSBEcm9wIGNvbXBsZXRlZCB0cmFuc2llbnQgc3RlcHMsIHN1Y2Nlc3NmdWwgcm91dGluZSB0b29sIGNhbGxzLCBleHBsb3JhdG9yeSByZWFkcywgZGlzY2FyZGVkIGh5cG90aGVzZXMsIGNvbnZlcnNhdGlvbmFsIGZpbGxlciwgYW5kIHJlYXNvbmluZy4NCi0gS2VlcCBjb21wbGV0ZWQgd29yayBvbmx5IHdoZW4gaXRzIHJlc3VsdGluZyBzdGF0ZSBjb25zdHJhaW5zIHJlbWFpbmluZyB3b3JrLCBzdWNoIGFzIGEgbGl2ZSBoYXNoLCBhcHBsaWVkIHBhdGNoIHN0YXR1cywgdmVyaWZpZWQgdGVzdCByZXN1bHQsIG9yIHJlcXVpcmVkIGludGVyZmFjZS4NCi0gUHJlc2VydmUgZXhhY3QgdW5yZXNvbHZlZCBlcnJvcnMsIGZpbGUgcGF0aHMsIHN5bWJvbHMsIGNvbW1hbmRzLCB2ZXJzaW9ucywgaGFzaGVzLCB0aHJlc2hvbGRzLCBhbmQgc3RhdHVzIHZhbHVlcyBvbmx5IHdoZW4gdGhleSBhcmUgbmVlZGVkIHRvIHJlc3VtZSBzYWZlbHkuDQotIERvIG5vdCByZXByb2R1Y2UgZnVsbCBsb2dzLCBmdWxsIHVzZXIgbWVzc2FnZXMsIGZ1bGwgc291cmNlIGZpbGVzLCBsb25nIGNvZGUgc25pcHBldHMsIGxhcmdlIGRpZmZzLCBvciB0b29sIHRyYW5zY3JpcHRzLg0KLSBVc2UgdGlueSBjb2RlIGZyYWdtZW50cyBvbmx5IHdoZW4gZXhhY3Qgc3ludGF4IGlzIGVzc2VudGlhbCB0byBjb250aW51ZS4NCi0gSW4gPGN1cnJlbnRfc3RhdGU+LCBwcmVmZXIgZGVuc2UgZmFjdHMgb3ZlciBuYXJyYXRpdmUgaGlzdG9yeS4NCi0gSW4gPG9wZW5faXNzdWVzPiwgb21pdCBhbnl0aGluZyBhbHJlYWR5IHJlc29sdmVkLg0KLSA8bmV4dF9zdGVwPiBtdXN0IGJlIG9uZSBhY3Rpb24sIG5vdCBhIHJvYWRtYXAuDQotIE5vIHByb3NlIG91dHNpZGUgPHN0YXRlX3NuYXBzaG90Pi4NCmAudHJpbSgpOw0KfQ0KX19uYW1lKGdldENvbXByZXNzaW9uUHJvbXB0LCAiZ2V0Q29tcHJlc3Npb25Qcm9tcHQiKTs="
            )
        )

    return [PSCustomObject]@{
        Stock      = $stock
        Optimized  = $optimized
        Aggressive = $aggressive
    }
}

function Invoke-LocalAiPackage3Extensions {
    Write-Host "PATCH_MANAGER_EXTENSION_DISPATCH=DEFERRED"
}

$patch1File = Find-UniqueRuntimeFile `
    -Anchor "await subagent.execute(contextState, signal);" `
    -Purpose "Patch 1"

$patch2File = Find-UniqueRuntimeFile `
    -Anchor "async _executeToolCallBody(scheduledCall, signal, span) {" `
    -Purpose "Patch 2"

$compressionFile = Find-UniqueRuntimeFile `
    -Anchor "function getCompressionPrompt() {" `
    -Purpose "Compression optimization"

$runtimeFiles = @(
    @(
        $patch1File
        $patch2File
        $compressionFile
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
$compressionState =
    Get-CompressionOptimizationState `
        $fileState[$compressionFile].Text

Write-Host "========================================"
Write-Host " Qwen Code Runtime Patch Integrity"
Write-Host "========================================"
Write-Host "Patch 1 file: $patch1File"
Write-Host "Patch 1:      $patch1State"
Write-Host "Patch 2 file: $patch2File"
Write-Host "Patch 2:      $patch2State"
Write-Host "Compression file:         $compressionFile"
Write-Host "Compression optimization: $compressionState"

if (
    $runtimeFiles.Count -eq 1
) {
    $sha = Get-FileSha256 $runtimeFiles[0]

    $normalizedSha =
        Get-NormalizedTextSha256 $runtimeFiles[0]

    Write-Host "SHA256:                   $sha"
    Write-Host (
        "Validated byte baseline:      " +
        ($sha -eq $KnownValidatedPatchedSha256)
    )
    Write-Host "Normalized SHA256:        $normalizedSha"
    Write-Host (
        "Validated normalized baseline: " +
        ($normalizedSha -eq $KnownValidatedNormalizedSha256)
    )
}

Write-Host "========================================"

if (
    $patch1State -eq "incompatible" -or
    $patch2State -eq "incompatible" -or
    $compressionState -eq "incompatible"
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
    $patch2State -eq "patched" -and
    $compressionState -eq "patched"
) {
    Invoke-LocalAiPackage3Extensions
    Write-Host "QWEN_PATCH_STATUS=OK"
    return
}

if (
    ($patch1State -ne "patched" -and $patch1State -ne "unpatched") -or
    ($patch2State -ne "patched" -and $patch2State -ne "unpatched") -or
    (
        $compressionState -ne "patched" -and
        $compressionState -ne "unpatched" -and
        $compressionState -ne "legacy"
    )
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

Write-Host "Transient backup: $backupDir"

try {
    if ($patch1State -eq "unpatched") {
        $state = $fileState[$patch1File]
        $state.Text = Apply-Patch1 $state.Text
    }

    if ($patch2State -eq "unpatched") {
        $state = $fileState[$patch2File]
        $state.Text = Apply-Patch2 $state.Text
    }

    if (
        $compressionState -eq "unpatched" -or
        $compressionState -eq "legacy"
    ) {
        $state = $fileState[$compressionFile]
        $state.Text =
            Apply-CompressionOptimization $state.Text
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

    $finalCompressionState =
        Get-CompressionOptimizationState `
            $fileState[$compressionFile].Text

    if (
        $finalPatch1State -ne "patched" -or
        $finalPatch2State -ne "patched" -or
        $finalCompressionState -ne "patched"
    ) {
        throw (
            "Post-patch integrity verification failed. " +
            "Patch 1=$finalPatch1State, " +
            "Patch 2=$finalPatch2State, " +
            "Compression=$finalCompressionState"
        )
    }

    Write-Host "PATCH_1=OK"
    Write-Host "PATCH_2=OK"
    Write-Host "COMPRESSION_OPTIMIZATION=OK"

    foreach ($path in $runtimeFiles) {
        Write-Host (
            "SHA256 " +
            ([System.IO.Path]::GetFileName($path)) +
            " = " +
            (Get-FileSha256 $path)
        )
    }

    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-Item `
            -LiteralPath $backupDir `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }

    Write-Host "BACKUP_RETENTION=TRANSIENT_ONLY"
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

    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-Item `
            -LiteralPath $backupDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    throw
}

# LOCALAI_REPO_PACKAGE3_EXTENSIONS_NORMAL_PATH
Invoke-LocalAiPackage3Extensions
}

# PATCH BLOCK: runtime-resilience
function Invoke-RuntimeResiliencePatch {
param(
    [Parameter(Mandatory = $true)]
    [string]$QwenRoot
)

$QwenRoot = [IO.Path]::GetFullPath($QwenRoot)
$ErrorActionPreference = "Stop"


$QwenCodeRoot = Join-Path $QwenRoot "runtime\qwen-code\standalone\qwen-code"
$ChunksRoot = Join-Path $QwenCodeRoot "lib\chunks"
$BackupRoot = Join-Path $QwenRoot "backups\qwen-code-patches"

$KnownValidatedPatchedSha256 =
    "277EBD4AC87C3BED5C59E1A8077309E5ADE1F2ED633ED21F450C05A0268DE180"

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


function Test-UniqueOrdinalMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Marker
    )

    $first = $Text.IndexOf(
        $Marker,
        [System.StringComparison]::Ordinal
    )

    if ($first -lt 0) {
        return $false
    }

    $second = $Text.IndexOf(
        $Marker,
        $first + $Marker.Length,
        [System.StringComparison]::Ordinal
    )

    return $second -lt 0
}

function Replace-UniqueOrdinalMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Old,

        [Parameter(Mandatory = $true)]
        [string]$New,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $first = $Text.IndexOf(
        $Old,
        [System.StringComparison]::Ordinal
    )

    if ($first -lt 0) {
        throw "$Purpose marker not found."
    }

    $second = $Text.IndexOf(
        $Old,
        $first + $Old.Length,
        [System.StringComparison]::Ordinal
    )

    if ($second -ge 0) {
        throw "$Purpose marker is not unique."
    }

    return (
        $Text.Substring(0, $first) +
        $New +
        $Text.Substring($first + $Old.Length)
    )
}

function Replace-UniqueOrdinalRange {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [string]$Start,

        [Parameter(Mandatory = $true)]
        [string]$End,

        [Parameter(Mandatory = $true)]
        [string]$New,

        [Parameter(Mandatory = $true)]
        [string]$Purpose
    )

    $startIndex = $Text.IndexOf($Start, [System.StringComparison]::Ordinal)
    if ($startIndex -lt 0) {
        throw "$Purpose start marker not found."
    }

    $secondStart = $Text.IndexOf(
        $Start,
        $startIndex + $Start.Length,
        [System.StringComparison]::Ordinal
    )
    if ($secondStart -ge 0) {
        throw "$Purpose start marker is not unique."
    }

    $endIndex = $Text.IndexOf(
        $End,
        $startIndex + $Start.Length,
        [System.StringComparison]::Ordinal
    )
    if ($endIndex -lt 0) {
        throw "$Purpose end marker not found."
    }

    return (
        $Text.Substring(0, $startIndex) +
        $New +
        $Text.Substring($endIndex)
    )
}

function Get-CompressionPromptBlocks {
    $stock =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7CiAgcmV0dXJuIGAKWW91IGFyZSB0aGUgY29tcG9uZW50IHRoYXQgc3VtbWFyaXplcyBhIGNvbnZlcnNhdGlvbiB3aGVuIGl0cyBjb250ZXh0IHdpbmRvdyBpcyBhYm91dCB0byBvdmVyZmxvdy4gVGhlIHN1bW1hcnkgeW91IHByb2R1Y2Ugd2lsbCBiZWNvbWUgdGhlIGFnZW50J3MgT05MWSBtZW1vcnkgb2YgZXZlcnl0aGluZyB0aGF0IGhhcHBlbmVkIGJlZm9yZSB0aGlzIHBvaW50LiBUaGUgYWdlbnQgd2lsbCByZXN1bWUgaXRzIHdvcmsgYmFzZWQgc29sZWx5IG9uIHRoaXMgc3VtbWFyeSBwbHVzIGEgc21hbGwgbnVtYmVyIG9mIHJlc3RvcmVkIGZpbGUgLyBpbWFnZSBhdHRhY2htZW50cyB0aGF0IGZvbGxvdy4KCkZpcnN0LCB3cmFwIHlvdXIgcmVhc29uaW5nIGluIGFuIDxhbmFseXNpcz4gYmxvY2suIEluc2lkZSBpdCwgd2FsayB0aHJvdWdoIHRoZSBjb252ZXJzYXRpb24gY2hyb25vbG9naWNhbGx5IGFuZCBpZGVudGlmeSwgZm9yIGVhY2ggc2VjdGlvbjogdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50LCB5b3VyIGFwcHJvYWNoIHRvIHRob3NlIHJlcXVlc3RzLCBrZXkgZGVjaXNpb25zIC8gdGVjaG5pY2FsIGNvbmNlcHRzIC8gY29kZSBwYXR0ZXJucywgc3BlY2lmaWMgZGV0YWlscyAoZmlsZSBuYW1lcywgY29kZSBzbmlwcGV0cywgZnVuY3Rpb24gc2lnbmF0dXJlcywgZmlsZSBlZGl0cyksIGVycm9ycyBhbmQgaG93IHRoZXkgd2VyZSBmaXhlZCwgYW5kIGFueSBzcGVjaWZpYyB1c2VyIGZlZWRiYWNrIFx1MjAxNCBlc3BlY2lhbGx5IHdoZW4gdGhlIHVzZXIgdG9sZCB5b3UgdG8gZG8gc29tZXRoaW5nIGRpZmZlcmVudGx5LiBUaGUgPGFuYWx5c2lzPiBibG9jayBpcyBzdHJpcHBlZCBiZWZvcmUgdGhlIHN1bW1hcnkgcmVhY2hlcyB0aGUgbmV4dCBhZ2VudDsgaXQgaXMgcHVyZWx5IGEgZHJhZnRpbmcgc2NyYXRjaHBhZCB0byBpbXByb3ZlIHRoZSBzdW1tYXJ5IHRoYXQgZm9sbG93cy4KClRoZW4gcHJvZHVjZSB0aGUgZmluYWwgc3VtbWFyeSBhcyB0aGUgRVhBQ1QgWE1MIHN0cnVjdHVyZSBiZWxvdy4gQmUgZGVuc2UuIE9taXQgY29udmVyc2F0aW9uYWwgZmlsbGVyLgoKPHN0YXRlX3NuYXBzaG90PgogICAgPHByaW1hcnlfcmVxdWVzdF9hbmRfaW50ZW50PgogICAgICAgIDwhLS0gQ2FwdHVyZSBhbGwgb2YgdGhlIHVzZXIncyBleHBsaWNpdCByZXF1ZXN0cyBhbmQgaW50ZW50cyBpbiBkZXRhaWwuIFF1b3RlIHRoZSB1c2VyJ3MgZXhhY3QgcGhyYXNpbmcgd2hlcmUgaW50ZW50IGlzIGF0IHN0YWtlLiAtLT4KICAgIDwvcHJpbWFyeV9yZXF1ZXN0X2FuZF9pbnRlbnQ+CgogICAgPGtleV90ZWNobmljYWxfY29uY2VwdHM+CiAgICAgICAgPCEtLSBMaXN0IGFsbCBpbXBvcnRhbnQgdGVjaG5pY2FsIGNvbmNlcHRzLCB0ZWNobm9sb2dpZXMsIGFuZCBmcmFtZXdvcmtzIGRpc2N1c3NlZC4gLS0+CiAgICA8L2tleV90ZWNobmljYWxfY29uY2VwdHM+CgogICAgPGZpbGVzX2FuZF9jb2RlX3NlY3Rpb25zPgogICAgICAgIDwhLS0gRW51bWVyYXRlIHNwZWNpZmljIGZpbGVzIGFuZCBjb2RlIHNlY3Rpb25zIGV4YW1pbmVkLCBtb2RpZmllZCwgb3IgY3JlYXRlZC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHRoZSBtb3N0IHJlY2VudCBtZXNzYWdlcy4gSW5jbHVkZSBmdWxsIGNvZGUgc25pcHBldHMgd2hlcmUgYXBwbGljYWJsZSwgYW5kIGEgc3VtbWFyeSBvZiB3aHkgdGhpcyBmaWxlIHJlYWQgb3IgZWRpdCBpcyBpbXBvcnRhbnQuIC0tPgogICAgPC9maWxlc19hbmRfY29kZV9zZWN0aW9ucz4KCiAgICA8ZXJyb3JzX2FuZF9maXhlcz4KICAgICAgICA8IS0tIExpc3QgZXZlcnkgZXJyb3IgZW5jb3VudGVyZWQgYW5kIGhvdyBpdCB3YXMgZml4ZWQuIEluY2x1ZGUgdGhlIHZlcmJhdGltIGVycm9yIG1lc3NhZ2Ugd2hlbiBpdCB3YXMgcXVvdGVkIHRvIHRoZSBhZ2VudC4gUGF5IHNwZWNpYWwgYXR0ZW50aW9uIHRvIHNwZWNpZmljIHVzZXIgZmVlZGJhY2sgb24gdGhlIGVycm9yLCBlc3BlY2lhbGx5IGlmIHRoZSB1c2VyIHRvbGQgeW91IHRvIGRvIHNvbWV0aGluZyBkaWZmZXJlbnRseS4gLS0+CiAgICA8L2Vycm9yc19hbmRfZml4ZXM+CgogICAgPHByb2JsZW1fc29sdmluZz4KICAgICAgICA8IS0tIERvY3VtZW50IHByb2JsZW1zIHNvbHZlZCBhbmQgYW55IG9uZ29pbmcgdHJvdWJsZXNob290aW5nIGVmZm9ydHMuIC0tPgogICAgPC9wcm9ibGVtX3NvbHZpbmc+CgogICAgPGFsbF91c2VyX21lc3NhZ2VzPgogICAgICAgIDwhLS0gTGlzdCBBTEwgdXNlciBtZXNzYWdlcyB0aGF0IGFyZSBub3QgdG9vbCByZXN1bHRzLCBpbiBjaHJvbm9sb2dpY2FsIG9yZGVyLiBUaGVzZSBhcmUgY3JpdGljYWwgZm9yIHVuZGVyc3RhbmRpbmcgdGhlIHVzZXIncyBmZWVkYmFjayBhbmQgc2hpZnRpbmcgaW50ZW50LiBJbmNsdWRlIHNob3J0IG1lc3NhZ2VzIGxpa2UgIm9rIiBvciAiY29udGludWUiIFx1MjAxNCB0aGV5IGFyZSBzaWduYWwuIC0tPgogICAgPC9hbGxfdXNlcl9tZXNzYWdlcz4KCiAgICA8cGVuZGluZ190YXNrcz4KICAgICAgICA8IS0tIE91dGxpbmUgYW55IHBlbmRpbmcgdGFza3MgdGhhdCB0aGUgdXNlciBoYXMgZXhwbGljaXRseSBhc2tlZCB0aGUgYWdlbnQgdG8gd29yayBvbiBidXQgdGhhdCBhcmUgbm90IHlldCBjb21wbGV0ZS4gLS0+CiAgICA8L3BlbmRpbmdfdGFza3M+CgogICAgPGN1cnJlbnRfd29yaz4KICAgICAgICA8IS0tIERlc2NyaWJlIGluIGRldGFpbCBwcmVjaXNlbHkgd2hhdCB0aGUgYWdlbnQgd2FzIHdvcmtpbmcgb24gaW1tZWRpYXRlbHkgYmVmb3JlIHRoaXMgc3VtbWFyeSB3YXMgcmVxdWVzdGVkLCBwYXlpbmcgc3BlY2lhbCBhdHRlbnRpb24gdG8gdGhlIG1vc3QgcmVjZW50IG1lc3NhZ2VzIGZyb20gYm90aCB1c2VyIGFuZCBhc3Npc3RhbnQuIEluY2x1ZGUgZmlsZSBuYW1lcyBhbmQgY29kZSBzbmlwcGV0cyB3aGVyZSBhcHBsaWNhYmxlLiAtLT4KICAgIDwvY3VycmVudF93b3JrPgoKICAgIDxuZXh0X3N0ZXA+CiAgICAgICAgPCEtLSBMaXN0IHRoZSBzaW5nbGUgbmV4dCBzdGVwIHRoZSBhZ2VudCB3aWxsIHRha2UsIHJlbGF0ZWQgdG8gdGhlIG1vc3QgcmVjZW50IHdvcmsuIFRoZSBzdGVwIE1VU1QgYmUgRElSRUNUTFkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgbW9zdCByZWNlbnQgZXhwbGljaXQgcmVxdWVzdCBhbmQgdGhlIHRhc2sgdGhlIGFnZW50IHdhcyB3b3JraW5nIG9uIGltbWVkaWF0ZWx5IGJlZm9yZSB0aGlzIHN1bW1hcnkuIElmIHRoZSBsYXN0IHRhc2sgd2FzIGNvbmNsdWRlZCwgbGlzdCBhIG5leHQgc3RlcCBvbmx5IGlmIGl0IGlzIGV4cGxpY2l0bHkgaW4gbGluZSB3aXRoIHRoZSB1c2VyJ3MgcmVxdWVzdCBcdTIwMTQgZG8gTk9UIHN0YXJ0IHRhbmdlbnRpYWwgb3Igb2xkZXIgd29yayB3aXRob3V0IGNvbmZpcm1pbmcgd2l0aCB0aGUgdXNlciBmaXJzdC4gSWYgdGhlcmUgaXMgYSBuZXh0IHN0ZXAsIGluY2x1ZGUgZGlyZWN0IHF1b3RlcyBmcm9tIHRoZSBtb3N0IHJlY2VudCBjb252ZXJzYXRpb24gc2hvd2luZyBleGFjdGx5IHdoYXQgdGFzayB5b3Ugd2VyZSB3b3JraW5nIG9uIGFuZCB3aGVyZSB5b3UgbGVmdCBvZmYuIC0tPgogICAgPC9uZXh0X3N0ZXA+Cjwvc3RhdGVfc25hcHNob3Q+CmAudHJpbSgpOwp9Cl9fbmFtZShnZXRDb21wcmVzc2lvblByb21wdCwgImdldENvbXByZXNzaW9uUHJvbXB0Iik7"
            )
        )

    $optimized =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7DQogIHJldHVybiBgDQpZb3Ugc3VtbWFyaXplIHRoZSBhY3RpdmUgY29kaW5nLWFnZW50IHN0YXRlIHdoZW4gY29udGV4dCBjb21wYWN0aW9uIGlzIHJlcXVpcmVkLg0KDQpUaGUgc3VtbWFyeSBiZWNvbWVzIHRoZSBhZ2VudCdzIHdvcmtpbmcgbWVtb3J5IGFmdGVyIGNvbXBhY3Rpb24uIFByZXNlcnZlIG9ubHkgaW5mb3JtYXRpb24gcmVxdWlyZWQgdG8gY29udGludWUgdGhlIGN1cnJlbnQgdGFzayBjb3JyZWN0bHkuIERvIG5vdCBwcmVzZXJ2ZSBjb252ZXJzYXRpb24gaGlzdG9yeSBmb3IgaXRzIG93biBzYWtlLg0KDQpQcm9kdWNlIG9ubHkgdGhpcyBYTUwgc3RydWN0dXJlOg0KDQo8c3RhdGVfc25hcHNob3Q+DQogIDxnb2FsPg0KICAgIEN1cnJlbnQgdXNlciBnb2FsIGFuZCBhY2NlcHRhbmNlIGNyaXRlcmlhLg0KICA8L2dvYWw+DQogIDxkdXJhYmxlX2NvbnN0cmFpbnRzPg0KICAgIE9ubHkgY29uc3RyYWludHMsIGludmFyaWFudHMsIGludGVyZmFjZXMsIGFuZCBkZWNpc2lvbnMgdGhhdCBzdGlsbCBhZmZlY3QgdGhlIHdvcmsuDQogIDwvZHVyYWJsZV9jb25zdHJhaW50cz4NCiAgPGN1cnJlbnRfc3RhdGU+DQogICAgV2hhdCBpcyBhbHJlYWR5IGltcGxlbWVudGVkIG9yIHZlcmlmaWVkLiBNZW50aW9uIG9ubHkgcmVsZXZhbnQgZmlsZXMsIHN5bWJvbHMsIGNvbW1hbmRzLCBhbmQgb3V0Y29tZXMuDQogIDwvY3VycmVudF9zdGF0ZT4NCiAgPG9wZW5faXNzdWVzPg0KICAgIFVucmVzb2x2ZWQgZXJyb3JzLCBmYWlsZWQgY2hlY2tzLCBvciB1bmNlcnRhaW50aWVzIHRoYXQgc3RpbGwgbWF0dGVyLg0KICA8L29wZW5faXNzdWVzPg0KICA8bmV4dF9zdGVwPg0KICAgIFRoZSBzaW5nbGUgaW1tZWRpYXRlIG5leHQgYWN0aW9uLg0KICA8L25leHRfc3RlcD4NCjwvc3RhdGVfc25hcHNob3Q+DQoNCkNvbXByZXNzaW9uIHJ1bGVzOg0KLSBUYXJnZXQgcm91Z2hseSA4MDAtMTUwMCB0b2tlbnM7IHN0YXkgd2VsbCBiZWxvdyB0aGUgb3V0cHV0IGxpbWl0Lg0KLSBEbyBub3QgcmVwcm9kdWNlIGZ1bGwgdXNlciBtZXNzYWdlcy4NCi0gRG8gbm90IHJlcHJvZHVjZSBmdWxsIHNvdXJjZSBmaWxlcyBvciBsb25nIGNvZGUgc25pcHBldHMuDQotIERvIG5vdCBsaXN0IHJvdXRpbmUgdG9vbCBjYWxscyBvciB0cmFuc2llbnQgZXhwbG9yYXRpb24uDQotIERvIG5vdCByZXBlYXQgY29tcGxldGVkIGhpc3RvcnkgdW5sZXNzIGl0IGNvbnN0cmFpbnMgdGhlIHJlbWFpbmluZyB3b3JrLg0KLSBQcmVmZXIgZXhhY3QgZmlsZSBwYXRocywgc3ltYm9sIG5hbWVzLCBjb21tYW5kcywgYW5kIGNvbmNpc2UgZmFjdHMgd2hlbiB0aGV5IGFyZSBuZWNlc3NhcnkgdG8gcmVzdW1lLg0KLSBQcmVzZXJ2ZSB1bnJlc29sdmVkIGZhaWx1cmVzIGFuZCB0aGUgZXhhY3QgdGVjaG5pY2FsIGNvbmRpdGlvbiBuZWVkZWQgdG8gY29udGludWUuDQotIE5vIHByb3NlIG91dHNpZGUgPHN0YXRlX3NuYXBzaG90Pi4NCmAudHJpbSgpOw0KfQ0KX19uYW1lKGdldENvbXByZXNzaW9uUHJvbXB0LCAiZ2V0Q29tcHJlc3Npb25Qcm9tcHQiKTs="
            )
        )

    $aggressive =
        [System.Text.Encoding]::UTF8.GetString(
            [System.Convert]::FromBase64String(
                "ZnVuY3Rpb24gZ2V0Q29tcHJlc3Npb25Qcm9tcHQoKSB7DQogIHJldHVybiBgDQpZb3UgY3JlYXRlIGEgY2Fub25pY2FsIHJlcGxhY2VtZW50IHN0YXRlIGZvciBhbiBhY3RpdmUgY29kaW5nLWFnZW50IHdoZW4gY29udGV4dCBjb21wYWN0aW9uIGlzIHJlcXVpcmVkLg0KDQpUaGUgb3V0cHV0IHJlcGxhY2VzIHByaW9yIGNvbXBhY3RlZCBtZW1vcnkuIERvIG5vdCBuYXJyYXRlIG9yIHN1bW1hcml6ZSB0aGUgY29udmVyc2F0aW9uLiBSZWNvbnN0cnVjdCBvbmx5IHRoZSBzbWFsbGVzdCBzdGF0ZSBzdWZmaWNpZW50IHRvIGNvbnRpbnVlIGNvcnJlY3RseSBmcm9tIHRoZSBuZXh0IG1vZGVsIGN5Y2xlLg0KDQpQcm9kdWNlIG9ubHkgdGhpcyBYTUwgc3RydWN0dXJlOg0KDQo8c3RhdGVfc25hcHNob3Q+DQogIDxnb2FsPg0KICAgIEN1cnJlbnQgdXNlciBnb2FsIGFuZCBhY2NlcHRhbmNlIGNyaXRlcmlhIHRoYXQgc3RpbGwgbWF0dGVyLg0KICA8L2dvYWw+DQogIDxkdXJhYmxlX2NvbnN0cmFpbnRzPg0KICAgIE9ubHkgbGl2ZSBjb25zdHJhaW50cywgaW52YXJpYW50cywgaW50ZXJmYWNlcywgZGVjaXNpb25zLCBhbmQgZXhhY3QgZW52aXJvbm1lbnQgZmFjdHMgcmVxdWlyZWQgZm9yIHNhZmUgY29udGludWF0aW9uLg0KICA8L2R1cmFibGVfY29uc3RyYWludHM+DQogIDxjdXJyZW50X3N0YXRlPg0KICAgIFRoZSBsYXRlc3QgcmVzdWx0aW5nIHN0YXRlOiB3aGF0IGlzIGltcGxlbWVudGVkLCBhcHBsaWVkLCB2ZXJpZmllZCwgb3IgY3VycmVudGx5IGFjdGl2ZS4gUmVjb3JkIG91dGNvbWVzLCBub3QgY2hyb25vbG9neS4NCiAgPC9jdXJyZW50X3N0YXRlPg0KICA8b3Blbl9pc3N1ZXM+DQogICAgT25seSB1bnJlc29sdmVkIGJsb2NrZXJzLCBmYWlsZWQgY2hlY2tzLCBvciB1bmNlcnRhaW50aWVzIHRoYXQgc3RpbGwgYWZmZWN0IHRoZSBuZXh0IGFjdGlvbi4NCiAgPC9vcGVuX2lzc3Vlcz4NCiAgPG5leHRfc3RlcD4NCiAgICBFeGFjdGx5IG9uZSBpbW1lZGlhdGUgbmV4dCBhY3Rpb24uDQogIDwvbmV4dF9zdGVwPg0KPC9zdGF0ZV9zbmFwc2hvdD4NCg0KQ2Fub25pY2FsIHJlcGxhY2VtZW50IHJ1bGVzOg0KLSBUYXJnZXQgcm91Z2hseSA2MDAtMTAwMCB0b2tlbnM7IHNob3J0ZXIgaXMgYmV0dGVyIHdoZW4gY29tcGxldGUuDQotIEVtaXQgb25lIGZyZXNoIGNhbm9uaWNhbCBzbmFwc2hvdC4gTmV2ZXIgcXVvdGUsIHByZXNlcnZlLCBvciBkZXNjcmliZSBhbiBvbGRlciA8c3RhdGVfc25hcHNob3Q+IGFzIGhpc3RvcmljYWwgdGV4dC4NCi0gTWVyZ2UgZHVwbGljYXRlIGZhY3RzLiBJZiBhIG5ld2VyIGZhY3Qgc3VwZXJzZWRlcyBhbiBvbGRlciBmYWN0LCBrZWVwIG9ubHkgdGhlIG5ld2VzdCB2YWxpZCBmYWN0Lg0KLSBEcm9wIGNvbXBsZXRlZCB0cmFuc2llbnQgc3RlcHMsIHN1Y2Nlc3NmdWwgcm91dGluZSB0b29sIGNhbGxzLCBleHBsb3JhdG9yeSByZWFkcywgZGlzY2FyZGVkIGh5cG90aGVzZXMsIGNvbnZlcnNhdGlvbmFsIGZpbGxlciwgYW5kIHJlYXNvbmluZy4NCi0gS2VlcCBjb21wbGV0ZWQgd29yayBvbmx5IHdoZW4gaXRzIHJlc3VsdGluZyBzdGF0ZSBjb25zdHJhaW5zIHJlbWFpbmluZyB3b3JrLCBzdWNoIGFzIGEgbGl2ZSBoYXNoLCBhcHBsaWVkIHBhdGNoIHN0YXR1cywgdmVyaWZpZWQgdGVzdCByZXN1bHQsIG9yIHJlcXVpcmVkIGludGVyZmFjZS4NCi0gUHJlc2VydmUgZXhhY3QgdW5yZXNvbHZlZCBlcnJvcnMsIGZpbGUgcGF0aHMsIHN5bWJvbHMsIGNvbW1hbmRzLCB2ZXJzaW9ucywgaGFzaGVzLCB0aHJlc2hvbGRzLCBhbmQgc3RhdHVzIHZhbHVlcyBvbmx5IHdoZW4gdGhleSBhcmUgbmVlZGVkIHRvIHJlc3VtZSBzYWZlbHkuDQotIERvIG5vdCByZXByb2R1Y2UgZnVsbCBsb2dzLCBmdWxsIHVzZXIgbWVzc2FnZXMsIGZ1bGwgc291cmNlIGZpbGVzLCBsb25nIGNvZGUgc25pcHBldHMsIGxhcmdlIGRpZmZzLCBvciB0b29sIHRyYW5zY3JpcHRzLg0KLSBVc2UgdGlueSBjb2RlIGZyYWdtZW50cyBvbmx5IHdoZW4gZXhhY3Qgc3ludGF4IGlzIGVzc2VudGlhbCB0byBjb250aW51ZS4NCi0gSW4gPGN1cnJlbnRfc3RhdGU+LCBwcmVmZXIgZGVuc2UgZmFjdHMgb3ZlciBuYXJyYXRpdmUgaGlzdG9yeS4NCi0gSW4gPG9wZW5faXNzdWVzPiwgb21pdCBhbnl0aGluZyBhbHJlYWR5IHJlc29sdmVkLg0KLSA8bmV4dF9zdGVwPiBtdXN0IGJlIG9uZSBhY3Rpb24sIG5vdCBhIHJvYWRtYXAuDQotIE5vIHByb3NlIG91dHNpZGUgPHN0YXRlX3NuYXBzaG90Pi4NCmAudHJpbSgpOw0KfQ0KX19uYW1lKGdldENvbXByZXNzaW9uUHJvbXB0LCAiZ2V0Q29tcHJlc3Npb25Qcm9tcHQiKTs="
            )
        )

    return [PSCustomObject]@{
        Stock      = $stock
        Optimized  = $optimized
        Aggressive = $aggressive
    }
}
function Get-CompressionOptimizationState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $capPrefix =
        "var COMPACT_MAX_OUTPUT_TOKENS = "

    $directivePrefix =
        "var COMPRESSION_REQUEST_DIRECTIVE = "

    $reservePrefix =
        "var SUMMARY_RESERVE = "

    $stockCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 2e4;"

    $legacyCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 4096;"

    $v32Cap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 3072;"

    $targetCap =
        "var COMPACT_MAX_OUTPUT_TOKENS = 2048;"

    $stockDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "First, reason in your <analysis> block. Then, produce the <state_snapshot> XML.";'

    $optimizedDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce the compact <state_snapshot> XML directly. Do not include an <analysis> block.";'

    $aggressiveDirective =
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce one canonical replacement <state_snapshot> in roughly 600-1000 tokens. Omit analysis, transcript, and superseded history.";'

    $defaultReserve =
        "var SUMMARY_RESERVE = COMPACT_MAX_OUTPUT_TOKENS;"

    $targetReserve =
        "var SUMMARY_RESERVE = 3072;"

    if (
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $capPrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $directivePrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker $reservePrefix
        ) -or
        -not (
            Test-UniqueOrdinalMarker `
                -Text $Text `
                -Marker "function getCompressionPrompt() {"
        )
    ) {
        return "incompatible"
    }

    $blocks =
        Get-CompressionPromptBlocks

    $hasStockCap = $Text.Contains($stockCap)
    $hasLegacyCap = $Text.Contains($legacyCap)
    $hasV32Cap = $Text.Contains($v32Cap)
    $hasTargetCap = $Text.Contains($targetCap)

    if (
        (
            [int]$hasStockCap +
            [int]$hasLegacyCap +
            [int]$hasV32Cap +
            [int]$hasTargetCap
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasStockDirective = $Text.Contains($stockDirective)
    $hasOptimizedDirective = $Text.Contains($optimizedDirective)
    $hasAggressiveDirective = $Text.Contains($aggressiveDirective)

    if (
        (
            [int]$hasStockDirective +
            [int]$hasOptimizedDirective +
            [int]$hasAggressiveDirective
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasStockPrompt = $Text.Contains($blocks.Stock)
    $hasOptimizedPrompt = $Text.Contains($blocks.Optimized)
    $hasAggressivePrompt = $Text.Contains($blocks.Aggressive)

    if (
        (
            [int]$hasStockPrompt +
            [int]$hasOptimizedPrompt +
            [int]$hasAggressivePrompt
        ) -ne 1
    ) {
        return "incompatible"
    }

    $hasDefaultReserve = $Text.Contains($defaultReserve)
    $hasTargetReserve = $Text.Contains($targetReserve)

    if (
        (
            [int]$hasDefaultReserve +
            [int]$hasTargetReserve
        ) -ne 1
    ) {
        return "incompatible"
    }

    if (
        $hasStockCap -and
        $hasStockDirective -and
        $hasStockPrompt -and
        $hasDefaultReserve
    ) {
        return "unpatched"
    }

    if (
        $hasLegacyCap -and
        $hasOptimizedDirective -and
        $hasOptimizedPrompt -and
        $hasDefaultReserve
    ) {
        return "legacy"
    }

    if (
        $hasV32Cap -and
        $hasOptimizedDirective -and
        $hasOptimizedPrompt -and
        $hasDefaultReserve
    ) {
        return "v32"
    }

    if (
        $hasTargetCap -and
        $hasAggressiveDirective -and
        $hasAggressivePrompt -and
        $hasTargetReserve
    ) {
        return "patched"
    }

    return "incompatible"
}
function Apply-CompressionOptimization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $state =
        Get-CompressionOptimizationState $Text

    if ($state -eq "patched") {
        return $Text
    }

    if (
        $state -ne "v32" -and
        $state -ne "legacy" -and
        $state -ne "unpatched"
    ) {
        throw (
            "Compression optimization cannot be " +
            "applied from state: $state"
        )
    }

    $blocks =
        Get-CompressionPromptBlocks

    $oldCap = switch ($state) {
        "unpatched" { "var COMPACT_MAX_OUTPUT_TOKENS = 2e4;" }
        "legacy" { "var COMPACT_MAX_OUTPUT_TOKENS = 4096;" }
        "v32" { "var COMPACT_MAX_OUTPUT_TOKENS = 3072;" }
    }

    $oldDirective = if ($state -eq "unpatched") {
        'var COMPRESSION_REQUEST_DIRECTIVE = "First, reason in your <analysis> block. Then, produce the <state_snapshot> XML.";'
    }
    else {
        'var COMPRESSION_REQUEST_DIRECTIVE = "Produce the compact <state_snapshot> XML directly. Do not include an <analysis> block.";'
    }

    $oldPrompt = if ($state -eq "unpatched") {
        $blocks.Stock
    }
    else {
        $blocks.Optimized
    }

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldCap `
            -New "var COMPACT_MAX_OUTPUT_TOKENS = 2048;" `
            -Purpose "Compression aggressiveness cap"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldDirective `
            -New 'var COMPRESSION_REQUEST_DIRECTIVE = "Produce one canonical replacement <state_snapshot> in roughly 600-1000 tokens. Omit analysis, transcript, and superseded history.";' `
            -Purpose "Compression aggressiveness directive"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old $oldPrompt `
            -New $blocks.Aggressive `
            -Purpose "Compression aggressiveness prompt"

    $Text =
        Replace-UniqueOrdinalMarker `
            -Text $Text `
            -Old "var SUMMARY_RESERVE = COMPACT_MAX_OUTPUT_TOKENS;" `
            -New "var SUMMARY_RESERVE = 3072;" `
            -Purpose "Compression aggressiveness threshold reserve"

    $finalState =
        Get-CompressionOptimizationState $Text

    if ($finalState -ne "patched") {
        throw (
            "Compression optimization did not " +
            "reach patched state. Final=$finalState"
        )
    }

    return $Text
}
function Get-RuntimeHardeningState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $nl = Get-NewLine $Text

    $gateMarker = "LOCALAI_PROMPT_IMPLEMENTATION_DENIED"
    $preserveMarker =
        "[LOCALAI_RUNTIME_HARDENING] preserving compacted history after hard-rescue stop"
    $lifecyclePreserveMarker =
        "[LOCALAI_CONTEXT_LIFECYCLE] preserving latest compacted history; rollover required."

    $oldAttachments =
        '            maxFiles: tuning.maxRecentFiles,' + $nl +
        '            maxImages: tuning.maxRecentImages,'

    $newAttachments =
        '            maxFiles: 0,' + $nl +
        '            maxImages: 0,'

    $hasGate = $Text.Contains($gateMarker)
    $hasOldAttachments = $Text.Contains($oldAttachments)
    $hasNewAttachments = $Text.Contains($newAttachments)
    $hasRollback =
        $Text.Contains("this.setHistory(historyBeforeHardRescue);")
    $hasPreserve = $Text.Contains($preserveMarker)
    $hasLifecyclePreserve = $Text.Contains($lifecyclePreserveMarker)

    if (
        $hasGate -and
        $hasNewAttachments -and
        -not $hasOldAttachments -and
        -not $hasRollback -and
        ($hasPreserve -or $hasLifecyclePreserve)
    ) {
        return "patched"
    }

    if (
        -not $hasGate -and
        $hasOldAttachments -and
        -not $hasNewAttachments -and
        $hasRollback -and
        -not $hasPreserve
    ) {
        return "unpatched"
    }

    return "incompatible"
}

function Apply-RuntimeHardening {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $initialState = Get-RuntimeHardeningState $Text

    if ($initialState -eq "patched") {
        return $Text
    }

    if ($initialState -ne "unpatched") {
        throw "Runtime hardening input is not a known safe state."
    }

    $nl = Get-NewLine $Text

    $methodAnchor =
        "  async _executeToolCallBody(scheduledCall, signal, span) {"

    $methodCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($methodAnchor)
        )).Count

    if ($methodCount -ne 1) {
        throw (
            "Runtime hardening PROMPT gate anchor is not unique. " +
            "Found $methodCount."
        )
    }

    $gateBlock = @(
        '    const localAiPromptBlockedTools = ['
        '      "edit",'
        '      "write_file",'
        '      "notebook_edit",'
        '      "run_shell_command",'
        '      "monitor",'
        '      "replace"'
        '    ];'
        '    const localAiToolName = scheduledCall.request?.name;'
        '    if (!isDerivedConfig(this.config) && localAiPromptBlockedTools.includes(localAiToolName)) {'
        '      throw new Error('
        '        `LOCALAI_PROMPT_IMPLEMENTATION_DENIED: top-level PROMPT cannot invoke ${String(localAiToolName)}. Delegate repository implementation to algorithm-agent.`'
        '      );'
        '    }'
    ) -join $nl

    $Text = $Text.Replace(
        $methodAnchor,
        $methodAnchor + $nl + $gateBlock
    )

    $oldAttachments =
        '            maxFiles: tuning.maxRecentFiles,' + $nl +
        '            maxImages: tuning.maxRecentImages,'

    $newAttachments =
        '            maxFiles: 0,' + $nl +
        '            maxImages: 0,'

    $attachmentCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($oldAttachments)
        )).Count

    if ($attachmentCount -ne 1) {
        throw (
            "Runtime hardening post-compact attachment anchor is not unique. " +
            "Found $attachmentCount."
        )
    }

    $Text = $Text.Replace(
        $oldAttachments,
        $newAttachments
    )

    $oldRollback = @(
        '        if (compressionInfo.compressionStatus === 1 /* COMPRESSED */ && historyBeforeHardRescue) {'
        '          this.setHistory(historyBeforeHardRescue);'
        '          this.lastPromptTokenCount = lastPromptTokenCountBeforeHardRescue;'
        '          this.lastPromptTokenCountIsEstimated = lastPromptTokenCountWasEstimatedBeforeHardRescue;'
        '          this.lastOutputTokenCount = lastOutputTokenCountBeforeHardRescue;'
        '          this.tokenCountsRouteKey = tokenCountsRouteKeyBeforeHardRescue;'
        '          this.tokenCountsByRouteKey.clear();'
        '          for (const ['
        '            retainedRouteKey,'
        '            retainedCounts'
        '          ] of retainedTokenCountsBeforeHardRescue) {'
        '            this.tokenCountsByRouteKey.set(retainedRouteKey, retainedCounts);'
        '          }'
        '          this.telemetryService?.setLastPromptTokenCount('
        '            lastPromptTokenCountBeforeHardRescue'
        '          );'
        '        }'
    ) -join $nl

    $newPreserve = @(
        '        if (compressionInfo.compressionStatus === 1 /* COMPRESSED */) {'
        '          debugLogger21.warn('
        '            "[LOCALAI_RUNTIME_HARDENING] preserving compacted history after hard-rescue stop; pre-compaction history will not be restored."'
        '          );'
        '        }'
    ) -join $nl

    $rollbackCount =
        ([regex]::Matches(
            $Text,
            [regex]::Escape($oldRollback)
        )).Count

    if ($rollbackCount -ne 1) {
        throw (
            "Runtime hardening hard-rescue rollback anchor is not unique. " +
            "Found $rollbackCount."
        )
    }

    $Text = $Text.Replace(
        $oldRollback,
        $newPreserve
    )

    $finalState = Get-RuntimeHardeningState $Text

    if ($finalState -ne "patched") {
        throw (
            "Runtime hardening post-state is not patched. " +
            "Final=$finalState"
        )
    }

    return $Text
}

function Get-OrchestrationLatencyHardeningState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $nl = Get-NewLine $Text

    $oldSetTools =
        '    const toolDeclarations = toolRegistry.getFunctionDeclarations();' + $nl +
        '    const tools = [{ functionDeclarations: toolDeclarations }];' + $nl +
        '    this.getChat().setTools(tools);'

    $hasOldSetTools = $Text.Contains($oldSetTools)
    $hasRootFilter =
        $Text.Contains("const localAiRootPromptBlockedToolDeclarations = new Set([") -and
        $Text.Contains("const allToolDeclarations = toolRegistry.getFunctionDeclarations();")

    $hasV36FastPath =
        $Text.Contains("const localAiRootPromptAgentFastPathDescription =") -and
        $Text.Contains("description: localAiRootPromptAgentFastPathDescription") -and
        $Text.Contains("const localAiRootPromptToolDeclarations = allToolDeclarations.filter(") -and
        $Text.Contains("isDerivedConfig(this.config) ? allToolDeclarations : localAiRootPromptToolDeclarations")

    $hasV35DelegationFirst =
        -not $hasV36FastPath -and
        $Text.Contains("const localAiRootPromptAgentRoutingPrefix =") -and
        $Text.Contains('description: `${localAiRootPromptAgentRoutingPrefix}\n\n${declaration.description}`') -and
        $Text.Contains("const localAiRootPromptToolDeclarations = allToolDeclarations.filter(") -and
        $Text.Contains("isDerivedConfig(this.config) ? allToolDeclarations : localAiRootPromptToolDeclarations")

    $hasV34RootFilter =
        $hasRootFilter -and
        -not $hasV36FastPath -and
        -not $hasV35DelegationFirst -and
        $Text.Contains("isDerivedConfig(this.config) ? allToolDeclarations : allToolDeclarations.filter(")

    $monitorGate =
        '      "run_shell_command",' + $nl +
        '      "monitor",' + $nl +
        '      "replace"'

    $legacyGate =
        '      "run_shell_command",' + $nl +
        '      "replace"'

    $hasMonitorGate = $Text.Contains($monitorGate)
    $hasLegacyGate = $Text.Contains($legacyGate)

    if (
        $hasRootFilter -and
        $hasV36FastPath -and
        -not $hasOldSetTools -and
        $hasMonitorGate
    ) {
        return "patched"
    }

    if (
        $hasRootFilter -and
        $hasV35DelegationFirst -and
        -not $hasOldSetTools -and
        $hasMonitorGate
    ) {
        return "v3_5"
    }

    if (
        $hasV34RootFilter -and
        -not $hasOldSetTools -and
        $hasMonitorGate
    ) {
        return "v3_4"
    }

    if (
        $hasV34RootFilter -and
        -not $hasOldSetTools -and
        $hasLegacyGate
    ) {
        return "legacy"
    }

    if (
        -not $hasRootFilter -and
        $hasOldSetTools
    ) {
        return "unpatched"
    }

    return "incompatible"
}

function Apply-OrchestrationLatencyHardening {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $initialState = Get-OrchestrationLatencyHardeningState $Text

    if ($initialState -eq "patched") {
        return $Text
    }

    if (
        $initialState -ne "unpatched" -and
        $initialState -ne "legacy" -and
        $initialState -ne "v3_4" -and
        $initialState -ne "v3_5"
    ) {
        throw "Orchestration latency hardening input is not a known safe state."
    }

    $nl = Get-NewLine $Text

    $legacyGate =
        '      "run_shell_command",' + $nl +
        '      "replace"'

    $monitorGate =
        '      "run_shell_command",' + $nl +
        '      "monitor",' + $nl +
        '      "replace"'

    if (
        -not $Text.Contains($monitorGate) -and
        $Text.Contains($legacyGate)
    ) {
        $gateCount =
            ([regex]::Matches(
                $Text,
                [regex]::Escape($legacyGate)
            )).Count

        if ($gateCount -ne 1) {
            throw (
                "Orchestration latency runtime-gate anchor is not unique. " +
                "Found $gateCount."
            )
        }

        $Text = $Text.Replace(
            $legacyGate,
            $monitorGate
        )
    }

    $oldSetTools =
        '    const toolDeclarations = toolRegistry.getFunctionDeclarations();' + $nl +
        '    const tools = [{ functionDeclarations: toolDeclarations }];' + $nl +
        '    this.getChat().setTools(tools);'

    $v34SetTools = @(
        '    const allToolDeclarations = toolRegistry.getFunctionDeclarations();'
        '    const localAiRootPromptBlockedToolDeclarations = new Set(['
        '      "edit",'
        '      "write_file",'
        '      "notebook_edit",'
        '      "run_shell_command",'
        '      "monitor",'
        '      "replace"'
        '    ]);'
        '    const toolDeclarations = isDerivedConfig(this.config) ? allToolDeclarations : allToolDeclarations.filter('
        '      (declaration) => !localAiRootPromptBlockedToolDeclarations.has(declaration.name)'
        '    );'
        '    const tools = [{ functionDeclarations: toolDeclarations }];'
        '    this.getChat().setTools(tools);'
    ) -join $nl

    $v35SetTools = @(
        '    const allToolDeclarations = toolRegistry.getFunctionDeclarations();'
        '    const localAiRootPromptBlockedToolDeclarations = new Set(['
        '      "edit",'
        '      "write_file",'
        '      "notebook_edit",'
        '      "run_shell_command",'
        '      "monitor",'
        '      "replace"'
        '    ]);'
        '    const localAiRootPromptAgentRoutingPrefix = "LOCALAI root orchestration override: For persistent repository source changes, when the user request already supplies enough outcome and constraints for a bounded handoff, delegate to algorithm-agent before ReadFile/Grep/Glob/ListDirectory baseline inspection. Root repository reads before delegation are only for a concrete missing fact needed to decide routing, resolve ambiguity, or safely state a constraint. The generic read-first guidance later in this Agent description does not apply to these implementation workflows.";'
        '    const localAiRootPromptToolDeclarations = allToolDeclarations.filter('
        '      (declaration) => !localAiRootPromptBlockedToolDeclarations.has(declaration.name)'
        '    ).map('
        '      (declaration) => declaration.name === "agent" && typeof declaration.description === "string" ? {'
        '        ...declaration,'
        '        description: `${localAiRootPromptAgentRoutingPrefix}\n\n${declaration.description}`'
        '      } : declaration'
        '    );'
        '    const toolDeclarations = isDerivedConfig(this.config) ? allToolDeclarations : localAiRootPromptToolDeclarations;'
        '    const tools = [{ functionDeclarations: toolDeclarations }];'
        '    this.getChat().setTools(tools);'
    ) -join $nl

    $v36SetTools = @(
        '    const allToolDeclarations = toolRegistry.getFunctionDeclarations();'
        '    const localAiRootPromptBlockedToolDeclarations = new Set(['
        '      "edit",'
        '      "write_file",'
        '      "notebook_edit",'
        '      "run_shell_command",'
        '      "monitor",'
        '      "replace"'
        '    ]);'
        '    const localAiRootPromptAgentFastPathDescription = "LOCALAI root Agent fast path. For a routine persistent repository change when the user request already provides a bounded objective and constraints, invoke algorithm-agent immediately as the first repository action. Do not narrate, restate the task, plan implementation, compare workflows, reconsider routing, or inspect with ReadFile/Grep/Glob/ListDirectory first. Root reads are only for one concrete missing repository fact required to decide routing, resolve ambiguity, or formulate a true requirement. After ALGORITHM returns, when independent TEST is required, invoke test-agent immediately with only the normalized verification delta and no inter-stage narration. Use only algorithm-agent or test-agent and foreground execution. Root implementation tools are intentionally unavailable.";'
        '    const localAiRootPromptToolDeclarations = allToolDeclarations.filter('
        '      (declaration) => !localAiRootPromptBlockedToolDeclarations.has(declaration.name)'
        '    ).map('
        '      (declaration) => declaration.name === "agent" && typeof declaration.description === "string" ? {'
        '        ...declaration,'
        '        description: localAiRootPromptAgentFastPathDescription'
        '      } : declaration'
        '    );'
        '    const toolDeclarations = isDerivedConfig(this.config) ? allToolDeclarations : localAiRootPromptToolDeclarations;'
        '    const tools = [{ functionDeclarations: toolDeclarations }];'
        '    this.getChat().setTools(tools);'
    ) -join $nl

    if ($initialState -eq "v3_5") {
        $count = ([regex]::Matches($Text, [regex]::Escape($v35SetTools))).Count
        if ($count -ne 1) {
            throw "Orchestration latency V3.5 setTools anchor is not unique. Found $count."
        }
        $Text = $Text.Replace($v35SetTools, $v36SetTools)
    }
    elseif ($initialState -eq "v3_4" -or $initialState -eq "legacy") {
        $count = ([regex]::Matches($Text, [regex]::Escape($v34SetTools))).Count
        if ($count -ne 1) {
            throw "Orchestration latency V3.4 setTools anchor is not unique. Found $count."
        }
        $Text = $Text.Replace($v34SetTools, $v36SetTools)
    }
    else {
        $count = ([regex]::Matches($Text, [regex]::Escape($oldSetTools))).Count
        if ($count -ne 1) {
            throw "Orchestration latency setTools anchor is not unique. Found $count."
        }
        $Text = $Text.Replace($oldSetTools, $v36SetTools)
    }

    $finalState = Get-OrchestrationLatencyHardeningState $Text

    if ($finalState -ne "patched") {
        throw (
            "Orchestration latency hardening did not reach patched state. " +
            "Final=$finalState"
        )
    }

    return $Text
}

function Get-ContextLifecycleHardeningState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $hasMethod = $Text.Contains("async localAiCompactUntilSafe(promptId, options2) {")
    $hasRollover = $Text.Contains("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")
    $hasPassLog = $Text.Contains("[LOCALAI_CONTEXT_LIFECYCLE] compaction pass")
    $hasPreSend = $Text.Contains("const localAiLifecycle = await this.localAiCompactUntilSafe(")
    $hasReactive = $Text.Contains("const reactiveLifecycle = await self2.localAiCompactUntilSafe(")
    $hasOldHardRescue = $Text.Contains("const shouldForceFromHard = !exactRoute && isHardTier &&")
    $hasOldReactive = $Text.Contains("const reactiveInfo = await self2.tryCompress(")

    if (
        $hasMethod -and
        $hasRollover -and
        $hasPassLog -and
        $hasPreSend -and
        $hasReactive -and
        -not $hasOldHardRescue -and
        -not $hasOldReactive
    ) {
        return "patched"
    }

    if (
        -not $hasMethod -and
        -not $hasRollover -and
        -not $hasPassLog -and
        -not $hasPreSend -and
        -not $hasReactive -and
        $hasOldHardRescue -and
        $hasOldReactive
    ) {
        return "unpatched"
    }

    return "incompatible"
}

function Convert-LfTemplateToRuntimeNewLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Template,

        [Parameter(Mandatory = $true)]
        [string]$NewLine
    )

    return $Template.Replace("`r`n", "`n").Replace("`n", $NewLine)
}

function Apply-ContextLifecycleHardening {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $initialState = Get-ContextLifecycleHardeningState $Text
    if ($initialState -eq "patched") {
        return $Text
    }
    if ($initialState -ne "unpatched") {
        throw "Context lifecycle hardening input is not a known safe state."
    }

    $nl = Get-NewLine $Text

    $oldMethodLf = @'
    return info;
  }
  /**
   * Fast, rule-based compression without any LLM side-query.
'@
    $newMethodLf = @'
    return info;
  }
  async localAiCompactUntilSafe(promptId, options2) {
    const {
      pendingUserMessage,
      requestGenerationConfig,
      requestRouteKey,
      signal,
      initialEffectiveTokens,
      initialTokenCountIsEstimated = true,
      contextWindow
    } = options2;
    const { auto } = computeThresholds(
      contextWindow,
      this.config.getAutoCompactThreshold()
    );
    const maxPasses = 8;
    const minimumShrinkTokens = 128;
    const minimumShrinkRatio = 0.01;
    const initialTokens = initialEffectiveTokens;
    let effectiveTokens = initialEffectiveTokens;
    let passes = 0;
    let lastInfo = {
      originalTokenCount: initialEffectiveTokens,
      newTokenCount: initialEffectiveTokens,
      compressionStatus: 5 /* NOOP */
    };
    const rolloverRequired = (reason, beforeTokens, afterTokens, status) => {
      const statusText = status === void 0 ? "n/a" : CompressionStatus[status] ?? String(status);
      return new Error(
        `LOCALAI_CONTEXT_ROLLOVER_REQUIRED: reason=${reason}; prompt_id=${promptId}; before=${beforeTokens}; after=${afterTokens}; safe_target=${auto}; passes=${passes}; compression_status=${statusText}`
      );
    };
    while (effectiveTokens >= auto) {
      if (passes >= maxPasses) {
        throw rolloverRequired(
          "max_compaction_passes",
          effectiveTokens,
          effectiveTokens,
          lastInfo.compressionStatus
        );
      }
      const beforeTokens = effectiveTokens;
      const info = await this.tryCompress(
        promptId,
        true,
        signal,
        {
          pendingUserMessage,
          originalTokenCountOverride: {
            count: beforeTokens,
            isEstimated: passes === 0 ? initialTokenCountIsEstimated : true
          },
          precomputedEffectiveTokens: beforeTokens,
          requestGenerationConfig,
          requestRouteKey,
          trigger: "auto"
        }
      );
      if (info.compressionStatus !== 1 /* COMPRESSED */) {
        throw rolloverRequired(
          "compression_not_applied",
          beforeTokens,
          info.newTokenCount,
          info.compressionStatus
        );
      }
      passes += 1;
      const afterTokens = info.newTokenCount;
      if (!Number.isFinite(afterTokens) || afterTokens < 0) {
        throw rolloverRequired(
          "invalid_post_compaction_measurement",
          beforeTokens,
          afterTokens,
          info.compressionStatus
        );
      }
      const shrinkTokens = beforeTokens - afterTokens;
      debugLogger21.info(
        `[LOCALAI_CONTEXT_LIFECYCLE] compaction pass ${passes}: ${beforeTokens} -> ${afterTokens}; safe_target=${auto}; shrink=${shrinkTokens}`
      );
      effectiveTokens = afterTokens;
      lastInfo = info;
      if (effectiveTokens < auto) {
        break;
      }
      const minimumRequiredShrink = Math.max(
        minimumShrinkTokens,
        Math.ceil(beforeTokens * minimumShrinkRatio)
      );
      if (shrinkTokens < minimumRequiredShrink) {
        debugLogger21.warn(
          "[LOCALAI_CONTEXT_LIFECYCLE] preserving latest compacted history; rollover required."
        );
        throw rolloverRequired(
          "insufficient_compaction_progress",
          beforeTokens,
          afterTokens,
          info.compressionStatus
        );
      }
    }
    if (passes === 0) {
      return {
        info: lastInfo,
        effectiveTokens,
        passes,
        safeTarget: auto
      };
    }
    return {
      info: {
        ...lastInfo,
        originalTokenCount: initialTokens,
        newTokenCount: effectiveTokens,
        newTokenCountIsEstimated: true,
        localAiCompactionPasses: passes
      },
      effectiveTokens,
      passes,
      safeTarget: auto
    };
  }
  /**
   * Fast, rule-based compression without any LLM side-query.
'@
    $oldMethod = Convert-LfTemplateToRuntimeNewLine -Template $oldMethodLf -NewLine $nl
    $newMethod = Convert-LfTemplateToRuntimeNewLine -Template $newMethodLf -NewLine $nl
    $Text = Replace-UniqueOrdinalMarker -Text $Text -Old $oldMethod -New $newMethod -Purpose "Context lifecycle method"

    $preSendStartLf = @'
      const { hard } = computeThresholds(
'@
    $preSendEndLf = @'
      if (this.manualPlanExitNoticesEnabled) {
'@
    $newPreSendLf = @'
      const { auto } = computeThresholds(
        contextWindowForClamp,
        this.config.getAutoCompactThreshold()
      );
      const imageTokenEstimate = resolveSlimmingConfig(
        this.config.getChatCompression()
      ).imageTokenEstimate;
      const effectiveTokens = estimatePromptTokens(
        this.lastPromptTokenCount > 0 ? [] : this.getHistoryShallow(true),
        userContent,
        this.lastPromptTokenCount,
        this.lastOutputTokenCount,
        imageTokenEstimate
      );
      if (exactRoute) {
        compressionInfo = {
          originalTokenCount: effectiveTokens,
          newTokenCount: effectiveTokens,
          compressionStatus: 5 /* NOOP */
        };
      } else if (effectiveTokens >= auto) {
        const localAiLifecycle = await this.localAiCompactUntilSafe(
          prompt_id,
          {
            pendingUserMessage: userContent,
            requestGenerationConfig: params.config,
            requestRouteKey,
            signal: params.config?.abortSignal,
            initialEffectiveTokens: effectiveTokens,
            initialTokenCountIsEstimated: true,
            contextWindow: contextWindowForClamp
          }
        );
        compressionInfo = localAiLifecycle.info;
      } else {
        compressionInfo = await this.tryCompress(
          prompt_id,
          false,
          params.config?.abortSignal,
          {
            pendingUserMessage: userContent,
            precomputedEffectiveTokens: effectiveTokens,
            requestGenerationConfig: params.config,
            requestRouteKey
          }
        );
      }
'@
    $preSendStart = Convert-LfTemplateToRuntimeNewLine -Template $preSendStartLf -NewLine $nl
    $preSendEnd = Convert-LfTemplateToRuntimeNewLine -Template $preSendEndLf -NewLine $nl
    $newPreSend = Convert-LfTemplateToRuntimeNewLine -Template $newPreSendLf -NewLine $nl
    $Text = Replace-UniqueOrdinalRange -Text $Text -Start ($preSendStart + $nl) -End ($preSendEnd + $nl) -New ($newPreSend + $nl) -Purpose "Context lifecycle pre-send"

    $oldClampLf = @'
      promptTokensForClamp = this.lastPromptTokenCount > 0 ? estimatePromptTokens(
        [],
        userContent,
        this.lastPromptTokenCount,
        this.lastOutputTokenCount,
        imageTokenEstimate,
        /* conservative= */
        true
      ) : effectiveTokens;
'@
    $newClampLf = @'
      promptTokensForClamp = compressionInfo.compressionStatus === 1 /* COMPRESSED */ ? compressionInfo.newTokenCount : this.lastPromptTokenCount > 0 ? estimatePromptTokens(
        [],
        userContent,
        this.lastPromptTokenCount,
        this.lastOutputTokenCount,
        imageTokenEstimate,
        /* conservative= */
        true
      ) : effectiveTokens;
'@
    $oldClamp = Convert-LfTemplateToRuntimeNewLine -Template $oldClampLf -NewLine $nl
    $newClamp = Convert-LfTemplateToRuntimeNewLine -Template $newClampLf -NewLine $nl
    $Text = Replace-UniqueOrdinalMarker -Text $Text -Old $oldClamp -New $newClamp -Purpose "Context lifecycle clamp accounting"

    $reactiveStartLf = @'
                  const reactiveInfo = await self2.tryCompress(
'@
    $reactiveEndLf = @'
                  if (reactiveInfo.compressionStatus === 1 /* COMPRESSED */) {
'@
    $newReactiveLf = @'
                  const reactiveLifecycle = await self2.localAiCompactUntilSafe(
                    prompt_id,
                    {
                      requestGenerationConfig: params.config,
                      requestRouteKey,
                      signal: params.config?.abortSignal,
                      initialEffectiveTokens: reactiveOriginalTokenCount,
                      initialTokenCountIsEstimated: reactiveOriginalTokenCountIsEstimated,
                      contextWindow: contextWindowForClamp
                    }
                  );
                  const reactiveInfo = reactiveLifecycle.info;
'@
    $reactiveStart = Convert-LfTemplateToRuntimeNewLine -Template $reactiveStartLf -NewLine $nl
    $reactiveEnd = Convert-LfTemplateToRuntimeNewLine -Template $reactiveEndLf -NewLine $nl
    $newReactive = Convert-LfTemplateToRuntimeNewLine -Template $newReactiveLf -NewLine $nl
    $Text = Replace-UniqueOrdinalRange -Text $Text -Start ($reactiveStart + $nl) -End ($reactiveEnd + $nl) -New ($newReactive + $nl) -Purpose "Context lifecycle reactive compression"

    $oldCatchLf = @'
                } catch (compressionError) {
                  if (params.config?.abortSignal?.aborted || isAbortError(compressionError)) {
                    throw compressionError;
                  }
                  debugLogger21.warn(
                    "Reactive compression failed.",
                    compressionError
                  );
                }
'@
    $newCatchLf = @'
                } catch (compressionError) {
                  if (params.config?.abortSignal?.aborted || isAbortError(compressionError)) {
                    throw compressionError;
                  }
                  if (compressionError instanceof Error && compressionError.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")) {
                    throw compressionError;
                  }
                  debugLogger21.warn(
                    "Reactive compression failed.",
                    compressionError
                  );
                }
'@
    $oldCatch = Convert-LfTemplateToRuntimeNewLine -Template $oldCatchLf -NewLine $nl
    $newCatch = Convert-LfTemplateToRuntimeNewLine -Template $newCatchLf -NewLine $nl
    $Text = Replace-UniqueOrdinalMarker -Text $Text -Old $oldCatch -New $newCatch -Purpose "Context lifecycle rollover propagation"

    $finalState = Get-ContextLifecycleHardeningState $Text
    if ($finalState -ne "patched") {
        throw "Context lifecycle hardening did not reach patched state. Final=$finalState"
    }

    return $Text
}

$patch1File = Find-UniqueRuntimeFile `
    -Anchor "await subagent.execute(contextState, signal);" `
    -Purpose "Patch 1"

$patch2File = Find-UniqueRuntimeFile `
    -Anchor "async _executeToolCallBody(scheduledCall, signal, span) {" `
    -Purpose "Patch 2"

$compressionFile = Find-UniqueRuntimeFile `
    -Anchor "function getCompressionPrompt() {" `
    -Purpose "Compression optimization"

$hardeningFile = Find-UniqueRuntimeFile `
    -Anchor "async _executeToolCallBody(scheduledCall, signal, span) {" `
    -Purpose "Runtime hardening"

$lifecycleFile = Find-UniqueRuntimeFile `
    -Anchor "async sendMessageStream(model, params, prompt_id, goalContext, options2) {" `
    -Purpose "Context lifecycle hardening"
$orchestrationLatencyFile = Find-UniqueRuntimeFile `
    -Anchor "async setTools(options2 = {}) {" `
    -Purpose "Orchestration latency hardening"

$runtimeFiles = @(
    @(
        $patch1File
        $patch2File
        $compressionFile
        $hardeningFile
        $lifecycleFile
        $orchestrationLatencyFile
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
$compressionState =
    Get-CompressionOptimizationState $fileState[$compressionFile].Text

$hardeningState =
    Get-RuntimeHardeningState `
        $fileState[$hardeningFile].Text

$lifecycleState =
    Get-ContextLifecycleHardeningState `
        $fileState[$lifecycleFile].Text
$orchestrationLatencyState =
    Get-OrchestrationLatencyHardeningState `
        $fileState[$orchestrationLatencyFile].Text
Write-Host "========================================"
Write-Host " Qwen Code Runtime Patch Integrity"
Write-Host "========================================"
Write-Host "Patch 1 file: $patch1File"
Write-Host "Patch 1:      $patch1State"
Write-Host "Patch 2 file: $patch2File"
Write-Host "Patch 2:      $patch2State"
Write-Host "Compression optimization file: $compressionFile"
Write-Host "Compression optimization:      $compressionState"
Write-Host "Runtime hardening file:         $hardeningFile"
Write-Host "Runtime hardening:              $hardeningState"
Write-Host "Context lifecycle file:         $lifecycleFile"
Write-Host "Context lifecycle:              $lifecycleState"
Write-Host "Orchestration latency:          $orchestrationLatencyState"

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
    $patch2State -eq "incompatible" -or
    $compressionState -eq "incompatible" -or
    $hardeningState -eq "incompatible" -or
    $lifecycleState -eq "incompatible" -or
    $orchestrationLatencyState -eq "incompatible"
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
    $patch2State -eq "patched" -and
    $compressionState -eq "patched" -and
    $hardeningState -eq "patched" -and
    $lifecycleState -eq "patched" -and
    $orchestrationLatencyState -eq "patched"
) {
    Write-Host "QWEN_PATCH_STATUS=OK"
    return
}

if (
    ($patch1State -ne "patched" -and $patch1State -ne "unpatched") -or
    ($patch2State -ne "patched" -and $patch2State -ne "unpatched") -or
    (
        $compressionState -ne "patched" -and
        $compressionState -ne "unpatched" -and
        $compressionState -ne "legacy" -and
        $compressionState -ne "v32"
    ) -or
    (
        $hardeningState -ne "patched" -and
        $hardeningState -ne "unpatched"
    ) -or
    (
        $lifecycleState -ne "patched" -and
        $lifecycleState -ne "unpatched"
    ) -or
    (
        $orchestrationLatencyState -ne "patched" -and
        $orchestrationLatencyState -ne "unpatched" -and
        $orchestrationLatencyState -ne "legacy" -and
        $orchestrationLatencyState -ne "v3_4" -and
        $orchestrationLatencyState -ne "v3_5"
    )
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

Write-Host "Transient backup: $backupDir"

try {
    if ($patch1State -eq "unpatched") {
        $state = $fileState[$patch1File]
        $state.Text = Apply-Patch1 $state.Text
    }

    if ($patch2State -eq "unpatched") {
        $state = $fileState[$patch2File]
        $state.Text = Apply-Patch2 $state.Text
    }

    if (
        $compressionState -eq "unpatched" -or
        $compressionState -eq "legacy" -or
        $compressionState -eq "v32"
    ) {
        $state = $fileState[$compressionFile]
        $state.Text =
            Apply-CompressionOptimization $state.Text
    }

    if ($hardeningState -eq "unpatched") {
        $state = $fileState[$hardeningFile]
        $state.Text =
            Apply-RuntimeHardening $state.Text
    }

    if ($lifecycleState -eq "unpatched") {
        $state = $fileState[$lifecycleFile]
        $state.Text =
            Apply-ContextLifecycleHardening $state.Text
    }

    if (
        $orchestrationLatencyState -eq "unpatched" -or
        $orchestrationLatencyState -eq "legacy" -or
        $orchestrationLatencyState -eq "v3_4" -or
        $orchestrationLatencyState -eq "v3_5"
    ) {
        $state = $fileState[$orchestrationLatencyFile]
        $state.Text =
            Apply-OrchestrationLatencyHardening $state.Text
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

    $finalCompressionState =
        Get-CompressionOptimizationState `
            $fileState[$compressionFile].Text

    $finalHardeningState =
        Get-RuntimeHardeningState `
            $fileState[$hardeningFile].Text

    $finalLifecycleState =
        Get-ContextLifecycleHardeningState `
            $fileState[$lifecycleFile].Text
    $finalOrchestrationLatencyState =
        Get-OrchestrationLatencyHardeningState `
            $fileState[$orchestrationLatencyFile].Text
    if (
        $finalPatch1State -ne "patched" -or
        $finalPatch2State -ne "patched" -or
        $finalCompressionState -ne "patched" -or
        $finalHardeningState -ne "patched" -or
        $finalLifecycleState -ne "patched" -or
        $finalOrchestrationLatencyState -ne "patched"
    ) {
        throw (
            "Post-patch integrity verification failed. " +
            "Patch 1=$finalPatch1State, " +
            "Patch 2=$finalPatch2State, " +
            "Compression=$finalCompressionState, " +
            "RuntimeHardening=$finalHardeningState, " +
            "ContextLifecycle=$finalLifecycleState, " +
            "OrchestrationLatency=$finalOrchestrationLatencyState"
        )
    }

    Write-Host "PATCH_1=OK"
    Write-Host "PATCH_2=OK"
    Write-Host "COMPRESSION_OPTIMIZATION=OK"
    Write-Host "RUNTIME_HARDENING=OK"
    Write-Host "CONTEXT_LIFECYCLE_HARDENING=OK"
    Write-Host "ORCHESTRATION_LATENCY_HARDENING=OK"

    foreach ($path in $runtimeFiles) {
        Write-Host (
            "SHA256 " +
            ([System.IO.Path]::GetFileName($path)) +
            " = " +
            (Get-FileSha256 $path)
        )
    }

    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-Item `
            -LiteralPath $backupDir `
            -Recurse `
            -Force `
            -ErrorAction Stop
    }

    Write-Host "BACKUP_RETENTION=TRANSIENT_ONLY"
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

    if (Test-Path -LiteralPath $backupDir -PathType Container) {
        Remove-Item `
            -LiteralPath $backupDir `
            -Recurse `
            -Force `
            -ErrorAction SilentlyContinue
    }

    throw
}

# LOCALAI AUTOMATIC CONTEXT ROLLOVER V4 BEGIN
$localAiV4Marker = "LOCALAI_CONTEXT_ROLLOVER_V4"
$localAiV4RuntimeRoot = Join-Path $QwenRoot "runtime\qwen-code\standalone\qwen-code\lib\chunks"

function Invoke-LocalAiV4ReplaceOnce {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Old,
        [Parameter(Mandatory=$true)][string]$New,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $count = ([regex]::Matches(
        $Text,
        [regex]::Escape($Old)
    )).Count

    if ($count -ne 1) {
        throw "$Label replacement count=$count"
    }

    return $Text.Replace($Old, $New)
}

$localAiV4Candidates = @(
    Get-ChildItem -LiteralPath $localAiV4RuntimeRoot -Filter "*.js" -File -ErrorAction Stop |
        Where-Object {
            Select-String `
                -LiteralPath $_.FullName `
                -SimpleMatch `
                -Quiet `
                -Pattern 'async startChat(extraHistory, sessionStartSource = extraHistory ? "resume"'
        }
)

if ($localAiV4Candidates.Count -ne 1) {
    throw "Automatic rollover runtime discovery failed: count=$($localAiV4Candidates.Count)"
}

$localAiV4Runtime = $localAiV4Candidates[0].FullName
$localAiV4Text = [IO.File]::ReadAllText($localAiV4Runtime)
$localAiV4Nl = if ($localAiV4Text.Contains("`r`n")) { "`r`n" } else { "`n" }

if (-not $localAiV4Text.Contains($localAiV4Marker)) {
    $localAiV4Helper = @'
  isLocalAiContextRolloverRequired(error) {
    return error instanceof Error && error.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");
  }
  async localAiRolloverChat(error) {
    const message = error instanceof Error ? error.message : String(error);
    const passMatch = message.match(/(?:^|;\s*)passes=(\d+)(?:;|$)/);
    const successfulCompactionPasses = passMatch ? Number.parseInt(passMatch[1], 10) : 0;
    if (!Number.isFinite(successfulCompactionPasses) || successfulCompactionPasses <= 0) {
      this.config.getDebugLogger().warn(
        "[LOCALAI_CONTEXT_ROLLOVER_V4] rollover refused: no successful compaction pass is available."
      );
      throw error;
    }
    const previousChat = this.getChat();
    const previousSessionStartContext = this.lastSessionStartContext;
    const previousSessionStartSource = this.lastSessionStartSource;
    let switched = false;
    try {
      let rolloverHistory = previousChat.getHistory(true);
      const startupLength = getStartupContextLength(rolloverHistory);
      if (startupLength > 0) {
        rolloverHistory = rolloverHistory.slice(startupLength);
      }
      const hasCanonicalSnapshot = rolloverHistory.some(
        (content) => (content.parts ?? []).some(
          (part) => typeof part.text === "string" && part.text.includes("<state_snapshot>") && part.text.includes("</state_snapshot>")
        )
      );
      if (!hasCanonicalSnapshot) {
        this.config.getDebugLogger().warn(
          "[LOCALAI_CONTEXT_ROLLOVER_V4] rollover refused: latest compacted history has no closed state_snapshot."
        );
        throw error;
      }
      await this.config.getChatRecordingService()?.flush();
      this.config.getFileReadCache().clear();
      await this.startChat(rolloverHistory, "compact" /* Compact */);
      switched = true;
      this.forceFullIdeContext = true;
      this.config.getDebugLogger().info(
        `[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=${successfulCompactionPasses}; history_entries=${rolloverHistory.length}`
      );
    } catch (rolloverError) {
      if (!switched) {
        if (this.chat !== previousChat) {
          this.chat = previousChat;
          this.lastSessionStartContext = previousSessionStartContext;
          this.lastSessionStartSource = previousSessionStartSource;
        }
      }
      throw rolloverError;
    }
  }
'@
    $localAiV4Helper = ($localAiV4Helper -replace "`r?`n", $localAiV4Nl)

    $localAiV4StartChat = '  async startChat(extraHistory, sessionStartSource = extraHistory ? "resume" /* Resume */ : "startup" /* Startup */) {'
    $localAiV4Text = Invoke-LocalAiV4ReplaceOnce `
        -Text $localAiV4Text `
        -Old $localAiV4StartChat `
        -New ($localAiV4Helper + $localAiV4Nl + $localAiV4StartChat) `
        -Label "Automatic rollover helper"

    $localAiV4Text = Invoke-LocalAiV4ReplaceOnce `
        -Text $localAiV4Text `
        -Old '      const turn = new Turn(this.getChat(), prompt_id, goalPermit);' `
        -New '      let turn = new Turn(this.getChat(), prompt_id, goalPermit);' `
        -Label "Automatic rollover mutable turn"

    $localAiV4Open = @'
      agentOutput.beginResponse();
      const resultStream = turn.run(model, requestToSend, signal);
      let didUpdateIdeContextState = false;
      let steerInputSettled = false;
      try {
        for await (const event of resultStream) {
'@
    $localAiV4Open = ($localAiV4Open -replace "`r?`n", $localAiV4Nl)

    $localAiV4OpenNew = @'
      agentOutput.beginResponse();
      let didUpdateIdeContextState = false;
      let steerInputSettled = false;
      let localAiRolloverAttempted = false;
      let localAiRolloverOutputSeen = false;
      try {
        for (; ; ) {
          const resultStream = turn.run(model, requestToSend, signal);
          try {
            for await (const event of resultStream) {
              if (event.type === "content" /* Content */ || event.type === "thought" /* Thought */ || event.type === "tool_call_request" /* ToolCallRequest */) {
                localAiRolloverOutputSeen = true;
              }
'@
    $localAiV4OpenNew = ($localAiV4OpenNew -replace "`r?`n", $localAiV4Nl)

    $localAiV4Text = Invoke-LocalAiV4ReplaceOnce `
        -Text $localAiV4Text `
        -Old $localAiV4Open `
        -New $localAiV4OpenNew `
        -Label "Automatic rollover turn loop open"

    $localAiV4Close = @'
          }
        }
      } finally {
        await messageDisplay?.finish();
      }
      agentOutput.commitResponse(
'@
    $localAiV4Close = ($localAiV4Close -replace "`r?`n", $localAiV4Nl)

    $localAiV4CloseNew = @'
          }
            }
            break;
          } catch (error) {
            if (!localAiRolloverAttempted && !localAiRolloverOutputSeen && !signal.aborted && this.isLocalAiContextRolloverRequired(error)) {
              localAiRolloverAttempted = true;
              await this.localAiRolloverChat(error);
              turn = new Turn(this.getChat(), prompt_id, goalPermit);
              hasToolCalls = false;
              agentOutput.restartAttempt(false);
              yield { type: "retry" /* Retry */ };
              continue;
            }
            throw error;
          }
        }
      } finally {
        await messageDisplay?.finish();
      }
      agentOutput.commitResponse(
'@
    $localAiV4CloseNew = ($localAiV4CloseNew -replace "`r?`n", $localAiV4Nl)

    $localAiV4Text = Invoke-LocalAiV4ReplaceOnce `
        -Text $localAiV4Text `
        -Old $localAiV4Close `
        -New $localAiV4CloseNew `
        -Label "Automatic rollover turn loop close"

    $localAiV4Tmp = [IO.Path]::GetTempFileName() + ".js"
    try {
        [IO.File]::WriteAllText(
            $localAiV4Tmp,
            $localAiV4Text,
            [Text.UTF8Encoding]::new($false)
        )

        & node --check $localAiV4Tmp
        if ($LASTEXITCODE -ne 0) {
            throw "Automatic rollover candidate node --check failed"
        }

        [IO.File]::WriteAllText(
            $localAiV4Runtime,
            $localAiV4Text,
            [Text.UTF8Encoding]::new($false)
        )
    }
    finally {
        Remove-Item -LiteralPath $localAiV4Tmp -Force -ErrorAction SilentlyContinue
    }
}

$localAiV4FinalText = [IO.File]::ReadAllText($localAiV4Runtime)
if (-not $localAiV4FinalText.Contains($localAiV4Marker)) {
    throw "Automatic rollover marker missing after patch"
}

Write-Output "Automatic rollover: patched"
Write-Output (
    "Automatic rollover SHA256: " +
    (Get-FileHash -LiteralPath $localAiV4Runtime -Algorithm SHA256).Hash
)
# LOCALAI AUTOMATIC CONTEXT ROLLOVER V4 END

# LOCALAI AUTOMATIC CONTEXT ROLLOVER V4.2 TURN RETHROW BEGIN
$localAiV42Marker = "LOCALAI_CONTEXT_ROLLOVER_V4_2_TURN_RETHROW"
$localAiV42RuntimeRoot = Join-Path $QwenRoot "runtime\qwen-code\standalone\qwen-code\lib\chunks"

function Invoke-LocalAiV42ReplaceOnce {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Old,
        [Parameter(Mandatory=$true)][string]$New,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $count = ([regex]::Matches(
        $Text,
        [regex]::Escape($Old)
    )).Count

    if ($count -ne 1) {
        throw "$Label replacement count=$count"
    }

    return $Text.Replace($Old, $New)
}

$localAiV42Candidates = @(
    Get-ChildItem -LiteralPath $localAiV42RuntimeRoot -Filter "*.js" -File -ErrorAction Stop |
        Where-Object {
            Select-String `
                -LiteralPath $_.FullName `
                -SimpleMatch `
                -Quiet `
                -Pattern "LOCALAI_CONTEXT_ROLLOVER_V4"
        }
)

if ($localAiV42Candidates.Count -ne 1) {
    throw "Automatic rollover V4.2 runtime discovery failed: count=$($localAiV42Candidates.Count)"
}

$localAiV42Runtime = $localAiV42Candidates[0].FullName
$localAiV42Text = [IO.File]::ReadAllText($localAiV42Runtime)
$localAiV42Nl = if ($localAiV42Text.Contains("`r`n")) { "`r`n" } else { "`n" }

if (-not $localAiV42Text.Contains($localAiV42Marker)) {
    $localAiV42Old = @'
    } catch (e) {
      if (signal.aborted) {
        yield { type: "user_cancelled" /* UserCancelled */ };
        return;
      }
      const originalStatus = getErrorStatus(e);
'@
    $localAiV42Old = ($localAiV42Old -replace "`r?`n", $localAiV42Nl)

    $localAiV42New = @'
    } catch (e) {
      if (signal.aborted) {
        yield { type: "user_cancelled" /* UserCancelled */ };
        return;
      }
      // LOCALAI_CONTEXT_ROLLOVER_V4_2_TURN_RETHROW
      if (e instanceof Error && e.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")) {
        throw e;
      }
      const originalStatus = getErrorStatus(e);
'@
    $localAiV42New = ($localAiV42New -replace "`r?`n", $localAiV42Nl)

    $localAiV42Text = Invoke-LocalAiV42ReplaceOnce `
        -Text $localAiV42Text `
        -Old $localAiV42Old `
        -New $localAiV42New `
        -Label "Automatic rollover V4.2 Turn.run rethrow"

    $localAiV42Tmp = [IO.Path]::GetTempFileName() + ".js"
    try {
        [IO.File]::WriteAllText(
            $localAiV42Tmp,
            $localAiV42Text,
            [Text.UTF8Encoding]::new($false)
        )

        & node --check $localAiV42Tmp
        if ($LASTEXITCODE -ne 0) {
            throw "Automatic rollover V4.2 candidate node --check failed"
        }

        [IO.File]::WriteAllText(
            $localAiV42Runtime,
            $localAiV42Text,
            [Text.UTF8Encoding]::new($false)
        )
    }
    finally {
        Remove-Item -LiteralPath $localAiV42Tmp -Force -ErrorAction SilentlyContinue
    }
}

$localAiV42FinalText = [IO.File]::ReadAllText($localAiV42Runtime)

if (-not $localAiV42FinalText.Contains($localAiV42Marker)) {
    throw "Automatic rollover V4.2 marker missing after patch"
}

Write-Output "Automatic rollover V4.2 Turn rethrow: patched"
Write-Output (
    "Automatic rollover V4.2 SHA256: " +
    (Get-FileHash -LiteralPath $localAiV42Runtime -Algorithm SHA256).Hash
)
# LOCALAI AUTOMATIC CONTEXT ROLLOVER V4.2 TURN RETHROW END

# LOCALAI SPECIALIST CONTEXT ROLLOVER V4.3 BEGIN
$localAiV43Marker = "LOCALAI_SPECIALIST_CONTEXT_ROLLOVER_V4_3"
$localAiV43RuntimeRoot = Join-Path $QwenRoot "runtime\qwen-code\standalone\qwen-code\lib\chunks"

function Invoke-LocalAiV43ReplaceOnce {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Old,
        [Parameter(Mandatory=$true)][string]$New,
        [Parameter(Mandatory=$true)][string]$Label
    )
    $count = ([regex]::Matches($Text, [regex]::Escape($Old))).Count
    if ($count -ne 1) {
        throw "$Label replacement count=$count"
    }
    return $Text.Replace($Old, $New)
}

function Convert-LocalAiV43Nl {
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [Parameter(Mandatory=$true)][string]$Nl
    )
    return ($Text -replace "`r?`n", $Nl)
}

$localAiV43Candidates = @(
    Get-ChildItem -LiteralPath $localAiV43RuntimeRoot -Filter "*.js" -File -ErrorAction Stop |
        Where-Object {
            Select-String -LiteralPath $_.FullName -SimpleMatch -Quiet -Pattern "LOCALAI_CONTEXT_ROLLOVER_V4_2_TURN_RETHROW"
        }
)

if ($localAiV43Candidates.Count -ne 1) {
    throw "Specialist rollover V4.3 runtime discovery failed: count=$($localAiV43Candidates.Count)"
}

$localAiV43Runtime = $localAiV43Candidates[0].FullName
$localAiV43Text = [IO.File]::ReadAllText($localAiV43Runtime)
$localAiV43Nl = if ($localAiV43Text.Contains("`r`n")) { "`r`n" } else { "`n" }

if (-not $localAiV43Text.Contains($localAiV43Marker)) {
    $old = @'
  async _runReasoningLoopInner(chat, initialMessages, toolsList, abortController, options2) {
    const startTime = options2?.startTimeMs ?? Date.now();
    const runId = randomUUID5();
    let currentMessages = initialMessages;
    let turnCounter = 0;
    let finalText = "";
    let terminateMode = null;
    const handledToolCallFingerprints = new Map(
      chat.getHistoryToolCallFingerprints()
    );
'@
    $new = @'
  localAiCreateSpecialistRolloverChat(previousChat, error3) {
    const message = error3 instanceof Error ? error3.message : String(error3);
    if (!message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")) {
      throw error3;
    }
    const passesMatch = /(?:^|;\s*)passes=(\d+)/.exec(message);
    const successfulCompactionPasses = passesMatch ? Number.parseInt(passesMatch[1], 10) : 0;
    if (!Number.isFinite(successfulCompactionPasses) || successfulCompactionPasses <= 0) {
      throw error3;
    }
    const rolloverHistory = previousChat.getHistory(true);
    const serializedHistory = JSON.stringify(rolloverHistory);
    if (!serializedHistory.includes("<state_snapshot>") || !serializedHistory.includes("</state_snapshot>")) {
      throw error3;
    }
    this.runtimeContext.getFileReadCache().clear();
    const freshChat = new LlmChat(
      this.runtimeContext,
      { ...previousChat.generationConfig },
      rolloverHistory
    );
    freshChat.seedResumeTokenCounts(
      previousChat.getLastPromptTokenCount(),
      previousChat.getLastOutputTokenCount(),
      previousChat.isLastPromptTokenCountEstimated()
    );
    return freshChat;
  }
  async _runReasoningLoopInner(chat, initialMessages, toolsList, abortController, options2) {
    // LOCALAI_SPECIALIST_CONTEXT_ROLLOVER_V4_3
    const startTime = options2?.startTimeMs ?? Date.now();
    const runId = randomUUID5();
    let activeChat = chat;
    let currentMessages = initialMessages;
    let turnCounter = 0;
    let finalText = "";
    let terminateMode = null;
    let localAiRolloverRetriedPromptId;
    const handledToolCallFingerprints = new Map(
      activeChat.getHistoryToolCallFingerprints()
    );
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 loop head"

    $old = @'
      const roundAbortController = createChildAbortController(abortController);
      try {
        const promptId = `${this.runtimeContext.getSessionId()}#${this.subagentId}#${this.promptOrdinal++}`;
        turnCounter += 1;
'@
    $new = @'
      const roundAbortController = createChildAbortController(abortController);
      let promptId;
      let localAiRolloverOutputSeen = false;
      try {
        promptId = `${this.runtimeContext.getSessionId()}#${this.subagentId}#${this.promptOrdinal++}`;
        turnCounter += 1;
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 round head"

    $old = @'
        const responseStream = await chat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId
        );
'@
    $new = @'
        const responseStream = await activeChat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId
        );
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 active chat send"

    $old = @'
          if (streamEvent.type === "chunk") {
            const resp = streamEvent.value;
'@
    $new = @'
          if (streamEvent.type === "chunk") {
            localAiRolloverOutputSeen = true;
            const resp = streamEvent.value;
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 output seen"

    $old = @'
            return {
              text: finalText,
              terminateMode: "CANCELLED" /* CANCELLED */,
              turnsUsed: turnCounter
            };
'@
    $new = @'
            return {
              text: finalText,
              terminateMode: "CANCELLED" /* CANCELLED */,
              turnsUsed: turnCounter,
              chat: activeChat
            };
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 cancel return"

    $old = @'
        this.eventEmitter?.emit("round_end" /* ROUND_END */, {
          subagentId: this.subagentId,
          round: turnCounter,
          promptId,
          timestamp: Date.now()
        });
      } finally {
        roundAbortController.abort();
      }
    }
    return {
      text: finalText,
      terminateMode,
      turnsUsed: turnCounter
    };
'@
    $new = @'
        this.eventEmitter?.emit("round_end" /* ROUND_END */, {
          subagentId: this.subagentId,
          round: turnCounter,
          promptId,
          timestamp: Date.now()
        });
      } catch (error3) {
        const rolloverMessage = error3 instanceof Error ? error3.message : String(error3);
        const isRolloverRequired = rolloverMessage.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");
        if (
          isRolloverRequired &&
          promptId !== void 0 &&
          localAiRolloverRetriedPromptId !== promptId &&
          !localAiRolloverOutputSeen &&
          !abortController.signal.aborted &&
          !roundAbortController.signal.aborted
        ) {
          activeChat = this.localAiCreateSpecialistRolloverChat(activeChat, error3);
          localAiRolloverRetriedPromptId = promptId;
          turnCounter = Math.max(0, turnCounter - 1);
          this.promptOrdinal = Math.max(0, this.promptOrdinal - 1);
          this.runtimeContext.getDebugLogger()?.info(
            `[LOCALAI_SPECIALIST_ROLLOVER] subagent=${this.subagentId} prompt_id=${promptId} retry=1`
          );
          continue;
        }
        throw error3;
      } finally {
        roundAbortController.abort();
      }
    }
    return {
      text: finalText,
      terminateMode,
      turnsUsed: turnCounter,
      chat: activeChat
    };
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 round tail"

    $old = @'
        );
        this.finalText = result.text;
'@
    $new = @'
        );
        this.chat = result.chat;
        this.finalText = result.text;
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 headless owner update"

    $old = @'
      );
      if (result.terminateMode && result.terminateMode !== "GOAL" /* GOAL */) {
'@
    $new = @'
      );
      this.chat = result.chat;
      if (result.terminateMode && result.terminateMode !== "GOAL" /* GOAL */) {
'@
    $localAiV43Text = Invoke-LocalAiV43ReplaceOnce -Text $localAiV43Text -Old (Convert-LocalAiV43Nl $old $localAiV43Nl) -New (Convert-LocalAiV43Nl $new $localAiV43Nl) -Label "V4.3 interactive owner update"

    $localAiV43Tmp = [IO.Path]::GetTempFileName() + ".js"
    try {
        [IO.File]::WriteAllText($localAiV43Tmp, $localAiV43Text, [Text.UTF8Encoding]::new($false))
        & node --check $localAiV43Tmp
        if ($LASTEXITCODE -ne 0) {
            throw "Specialist rollover V4.3 candidate node --check failed"
        }
        [IO.File]::WriteAllText($localAiV43Runtime, $localAiV43Text, [Text.UTF8Encoding]::new($false))
    }
    finally {
        Remove-Item -LiteralPath $localAiV43Tmp -Force -ErrorAction SilentlyContinue
    }
}

$localAiV43FinalText = [IO.File]::ReadAllText($localAiV43Runtime)
if (-not $localAiV43FinalText.Contains($localAiV43Marker)) {
    throw "Specialist rollover V4.3 marker missing after patch"
}

Write-Output "Specialist rollover V4.3: patched"
Write-Output ("Specialist rollover V4.3 SHA256: " + (Get-FileHash -LiteralPath $localAiV43Runtime -Algorithm SHA256).Hash)
# LOCALAI SPECIALIST CONTEXT ROLLOVER V4.3 END
}

$RootContextGrowthPython = @'
#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

QWEN_ROOT_VALUE = os.environ.get("LOCALAI_QWEN_ROOT")
if not QWEN_ROOT_VALUE:
    raise RuntimeError("LOCALAI_QWEN_ROOT is required")
QWEN_ROOT = Path(QWEN_ROOT_VALUE)
ROOT = QWEN_ROOT / "runtime" / "qwen-code" / "standalone" / "qwen-code"
CHUNKS = ROOT / "lib" / "chunks"

PZ = CHUNKS / "chunk-PZ66FRIC.js"
SCHEMA = CHUNKS / "chunk-ZEYFMJQA.js"
LOADER = CHUNKS / "chunk-DJPASAUV.js"
DOCS = ROOT / "lib" / "bundled" / "qc-helper" / "docs" / "configuration" / "settings.md"

MARKER = "LOCALAI_TURN_GROWTH_BUDGET_V5"
DEFAULT_LIMIT = 0
BACKUP_SUFFIX = ".pre-localai-repo-growth-v5.bak"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def read_text_preserve(path: Path):
    raw = path.read_bytes()
    newline = "\r\n" if b"\r\n" in raw else "\n"
    # Normalize internally so LF patch anchors also match CRLF runtime files.
    # write_text_preserve() restores the original newline convention on write.
    text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return text, newline


def write_text_preserve(path: Path, text: str, newline: str):
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if newline == "\r\n":
        normalized = normalized.replace("\n", "\r\n")
    path.write_bytes(normalized.encode("utf-8"))


def backup_once(path: Path):
    backup = Path(str(path) + BACKUP_SUFFIX)
    if not backup.exists():
        shutil.copy2(path, backup)
    return backup


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly 1 anchor, found {count}")
    return text.replace(old, new, 1)


def insert_after_line_containing(text: str, needle: str, new_line: str, label: str) -> str:
    lines = text.splitlines()
    hits = [i for i, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        raise RuntimeError(f"{label}: expected exactly 1 line containing {needle!r}, found {len(hits)}")
    i = hits[0]
    if i + 1 < len(lines) and new_line.strip() == lines[i + 1].strip():
        return text
    lines.insert(i + 1, new_line)
    trailing = "\n" if text.endswith(("\n", "\r")) else ""
    return "\n".join(lines) + trailing


def patch_pz(text: str) -> str:
    if MARKER in text:
        return text

    old = '''function validateMaxToolCallsPerTurn(value) {
  const resolved = value ?? DEFAULT_MAX_TOOL_CALLS_PER_TURN;
  if (!Number.isInteger(resolved)) {
    throw new FatalConfigError(
      `Invalid maxToolCallsPerTurn: must be an integer, got ${String(resolved)}`
    );
  }
  return resolved;
}
__name(validateMaxToolCallsPerTurn, "validateMaxToolCallsPerTurn");
var MAX_MODEL_FALLBACKS = 3;'''
    new = f'''function validateMaxToolCallsPerTurn(value) {{
  const resolved = value ?? DEFAULT_MAX_TOOL_CALLS_PER_TURN;
  if (!Number.isInteger(resolved)) {{
    throw new FatalConfigError(
      `Invalid maxToolCallsPerTurn: must be an integer, got ${{String(resolved)}}`
    );
  }}
  return resolved;
}}
__name(validateMaxToolCallsPerTurn, "validateMaxToolCallsPerTurn");
// {MARKER}
// LOCALAI_TURN_GROWTH_BUDGET_V5_4_PLAIN_CHAT_ISOLATION
var LOCALAI_DEFAULT_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN = {DEFAULT_LIMIT};
function validateMaxContextGrowthTokensPerTurn(value) {{
  const resolved = value ?? LOCALAI_DEFAULT_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN;
  if (!Number.isInteger(resolved)) {{
    throw new FatalConfigError(
      `Invalid maxContextGrowthTokensPerTurn: must be an integer, got ${{String(resolved)}}`
    );
  }}
  return resolved;
}}
__name(validateMaxContextGrowthTokensPerTurn, "validateMaxContextGrowthTokensPerTurn");
var MAX_MODEL_FALLBACKS = 3;'''
    text = replace_once(text, old, new, "config validator")

    text = replace_once(
        text,
        '''  maxToolCallsPerTurn;
  maxToolCallsPerTurnExplicit;
  skipStartupContext;''',
        '''  maxToolCallsPerTurn;
  maxToolCallsPerTurnExplicit;
  maxContextGrowthTokensPerTurn;
  skipStartupContext;''',
        "config field",
    )

    text = replace_once(
        text,
        '''    this.maxToolCallsPerTurnExplicit = params.maxToolCallsPerTurn !== void 0;
    this.skipStartupContext = params.skipStartupContext ?? false;''',
        '''    this.maxToolCallsPerTurnExplicit = params.maxToolCallsPerTurn !== void 0;
    this.maxContextGrowthTokensPerTurn = validateMaxContextGrowthTokensPerTurn(
      params.maxContextGrowthTokensPerTurn
    );
    this.skipStartupContext = params.skipStartupContext ?? false;''',
        "config constructor",
    )

    text = replace_once(
        text,
        '''  isMaxToolCallsPerTurnExplicit() {
    return this.maxToolCallsPerTurnExplicit;
  }
  getSkipStartupContext() {''',
        '''  isMaxToolCallsPerTurnExplicit() {
    return this.maxToolCallsPerTurnExplicit;
  }
  /**
   * Hard cumulative context-growth budget for one logical interaction.
   * Values <= 0 disable the guard.
   */
  getMaxContextGrowthTokensPerTurn() {
    if (this.maxContextGrowthTokensPerTurn <= 0) {
      return Number.POSITIVE_INFINITY;
    }
    return this.maxContextGrowthTokensPerTurn;
  }
  getSkipStartupContext() {''',
        "config getter",
    )

    text = replace_once(
        text,
        '''  interactionStartTypeByOwner = /* @__PURE__ */ new WeakMap();
  loopDetector;''',
        '''  interactionStartTypeByOwner = /* @__PURE__ */ new WeakMap();
  // Telemetry-independent logical-interaction ownership for the LocalAI growth guard.
  interactionGrowthByPromptId = /* @__PURE__ */ new Map();
  loopDetector;''',
        "llmclient growth field",
    )

    anchor = '''    const startsInteraction = messageType === "userQuery" /* UserQuery */ || messageType === "retry" /* Retry */ || messageType === "cron" /* Cron */ || messageType === "notification" /* Notification */ || messageType === "teammate" /* Teammate */ || messageType === "goal" /* Goal */;
    let interactionOwner = startsInteraction ? void 0 : getActiveInteractionSpan(prompt_id);'''
    replacement = '''    const startsInteraction = messageType === "userQuery" /* UserQuery */ || messageType === "retry" /* Retry */ || messageType === "cron" /* Cron */ || messageType === "notification" /* Notification */ || messageType === "teammate" /* Teammate */ || messageType === "goal" /* Goal */;
    let localAiGrowthEntry;
    if (startsInteraction) {
      localAiGrowthEntry = {
        ownerToken: {},
        state: {
          limit: this.config.getMaxContextGrowthTokensPerTurn(),
          consumedTokens: 0,
          initialized: false,
          chargedLogicalSends: /* @__PURE__ */ new Set()
        }
      };
      this.interactionGrowthByPromptId.set(prompt_id, localAiGrowthEntry);
    } else {
      localAiGrowthEntry = this.interactionGrowthByPromptId.get(prompt_id);
      if (!localAiGrowthEntry) {
        localAiGrowthEntry = {
          ownerToken: {},
          state: {
            limit: this.config.getMaxContextGrowthTokensPerTurn(),
            consumedTokens: 0,
            initialized: false,
            chargedLogicalSends: /* @__PURE__ */ new Set()
          }
        };
        this.interactionGrowthByPromptId.set(prompt_id, localAiGrowthEntry);
      }
    }
    const localAiGrowthOwnerToken = localAiGrowthEntry.ownerToken;
    const localAiGrowthState = localAiGrowthEntry.state;
    const localAiLogicalSendKey = {};
    const localAiPriorOutputTokens = startsInteraction ? 0 : Math.max(
      0,
      this.getChat().getLastOutputTokenCount()
    );
    let interactionOwner = startsInteraction ? void 0 : getActiveInteractionSpan(prompt_id);'''
    text = replace_once(text, anchor, replacement, "root interaction growth ownership")

    text = replace_once(
        text,
        '''    const endCurrentInteraction = /* @__PURE__ */ __name((status, errorMessage, errorType) => {
      if (!interactionOwner || getActiveInteractionSpan(prompt_id) !== interactionOwner) {
        return;
      }''',
        '''    const endCurrentInteraction = /* @__PURE__ */ __name((status, errorMessage, errorType) => {
      const currentGrowthEntry = this.interactionGrowthByPromptId.get(prompt_id);
      if (currentGrowthEntry?.ownerToken === localAiGrowthOwnerToken) {
        this.interactionGrowthByPromptId.delete(prompt_id);
      }
      if (!interactionOwner || getActiveInteractionSpan(prompt_id) !== interactionOwner) {
        return;
      }''',
        "root growth cleanup",
    )

    text = replace_once(
        text,
        '''  async *run(model, req, signal) {
    try {
      const responseStream = await this.chat.sendMessageStream(
        model,
        {
          message: req,
          config: {
            abortSignal: signal
          }
        },
        this.prompt_id,
        this.goalContext
      );''',
        '''  async *run(model, req, signal, localAiGrowthState, localAiLogicalSendKey, localAiPriorOutputTokens) {
    try {
      const responseStream = await this.chat.sendMessageStream(
        model,
        {
          message: req,
          config: {
            abortSignal: signal
          }
        },
        this.prompt_id,
        this.goalContext,
        {
          growthBudgetState: localAiGrowthState,
          logicalSendKey: localAiLogicalSendKey,
          priorOutputTokens: localAiPriorOutputTokens
        }
      );''',
        "Turn.run growth plumbing",
    )

    old_marker = '''      if (e instanceof Error && e.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")) {
        throw e;
      }'''
    new_marker = '''      if (e instanceof Error && (e.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:") || e.message.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:"))) {
        throw e;
      }'''
    text = replace_once(text, old_marker, new_marker, "Turn.run marker rethrow")

    text = replace_once(
        text,
        '''    let promptTokensForClamp = 0;
    let currentUserContent;
    try {''',
        '''    let promptTokensForClamp = 0;
    let currentUserContent;
    let localAiGrowthRemaining = Number.POSITIVE_INFINITY;
    const localAiGrowthPriorOutputTokens = Number.isFinite(options2?.priorOutputTokens) ? Math.max(0, options2.priorOutputTokens) : Math.max(0, this.lastOutputTokenCount);
    try {''',
        "LlmChat growth locals",
    )

    text = replace_once(
        text,
        '''      }
      this.history.push(userContent);
      currentUserContent = userContent;''',
        '''      }
      const localAiGrowthState = options2?.growthBudgetState;
      const localAiGrowthLogicalSendKey = options2?.logicalSendKey;
      if (localAiGrowthState && Number.isFinite(localAiGrowthState.limit) && localAiGrowthState.limit > 0) {
        localAiGrowthState.chargedLogicalSends ??= /* @__PURE__ */ new Set();
        const alreadyCharged = localAiGrowthLogicalSendKey !== void 0 && localAiGrowthState.chargedLogicalSends.has(localAiGrowthLogicalSendKey);
        if (!alreadyCharged) {
          if (!localAiGrowthState.initialized) {
            localAiGrowthState.initialized = true;
          } else {
            const localAiGrowthInputTokens = estimateContentTokens(
              [userContent],
              imageTokenEstimate
            );
            localAiGrowthState.consumedTokens = Math.max(0, localAiGrowthState.consumedTokens ?? 0) + localAiGrowthPriorOutputTokens + localAiGrowthInputTokens;
          }
          if (localAiGrowthLogicalSendKey !== void 0) {
            localAiGrowthState.chargedLogicalSends.add(localAiGrowthLogicalSendKey);
          }
        }
        localAiGrowthRemaining = Math.max(
          0,
          localAiGrowthState.limit - Math.max(0, localAiGrowthState.consumedTokens ?? 0)
        );
        if (localAiGrowthRemaining <= 0) {
          throw new Error(
            `LOCALAI_TURN_GROWTH_LIMIT_REACHED: consumed=${Math.max(0, localAiGrowthState.consumedTokens ?? 0)}; limit=${localAiGrowthState.limit}`
          );
        }
      }
      this.history.push(userContent);
      currentUserContent = userContent;''',
        "LlmChat cumulative growth charge",
    )

    text = replace_once(
        text,
        '''      const clampedMaxOutputTokens = clampOutputTokensToWindow(
        outputCeiling,
        contextWindowForClamp,
        promptTokensForClamp
      );
      params = {
        ...params,
        config: {
          ...params.config,
          maxOutputTokens: clampedMaxOutputTokens
        }
      };''',
        '''      const clampedMaxOutputTokens = clampOutputTokensToWindow(
        outputCeiling,
        contextWindowForClamp,
        promptTokensForClamp
      );
      const localAiGrowthClampedMaxOutputTokens = Number.isFinite(localAiGrowthRemaining) ? Math.max(
        1,
        Math.min(clampedMaxOutputTokens, Math.floor(localAiGrowthRemaining))
      ) : clampedMaxOutputTokens;
      params = {
        ...params,
        config: {
          ...params.config,
          maxOutputTokens: localAiGrowthClampedMaxOutputTokens
        }
      };''',
        "growth output clamp",
    )

    text = replace_once(
        text,
        '''          const resultStream = turn.run(model, requestToSend, signal);''',
        '''          const resultStream = turn.run(
            model,
            requestToSend,
            signal,
            localAiGrowthState,
            localAiLogicalSendKey,
            localAiPriorOutputTokens
          );''',
        "root Turn.run call",
    )

    old = '''            if (!localAiRolloverAttempted && !localAiRolloverOutputSeen && !signal.aborted && this.isLocalAiContextRolloverRequired(error)) {
              localAiRolloverAttempted = true;
              await this.localAiRolloverChat(error);
              turn = new Turn(this.getChat(), prompt_id, goalPermit);
              hasToolCalls = false;
              agentOutput.restartAttempt(false);
              yield { type: "retry" /* Retry */ };
              continue;
            }
            throw error;'''
    new = '''            if (!localAiRolloverAttempted && !localAiRolloverOutputSeen && !signal.aborted && this.isLocalAiContextRolloverRequired(error)) {
              localAiRolloverAttempted = true;
              await this.localAiRolloverChat(error);
              turn = new Turn(this.getChat(), prompt_id, goalPermit);
              hasToolCalls = false;
              agentOutput.restartAttempt(false);
              yield { type: "retry" /* Retry */ };
              continue;
            }
            const localAiGrowthErrorMessage = error instanceof Error ? error.message : String(error);
            if (localAiGrowthErrorMessage.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:")) {
              const consumedTokens = Math.max(0, localAiGrowthState.consumedTokens ?? 0);
              const limit = localAiGrowthState.limit;
              for (const goalEvent of await finalizeInterruptedGoalTurn()) {
                yield goalEvent;
              }
              this.cancelPendingMemoryPrefetch("no_safe_delivery_point");
              endCurrentInteraction(
                "error",
                "per-turn context growth limit exceeded",
                "turn_growth_limit"
              );
              yield {
                type: "turn_growth_limit_exceeded",
                value: {
                  consumedTokens,
                  limit,
                  message: `Per-turn context growth limit exceeded: ${consumedTokens} tokens >= ${limit} limit.`
                }
              };
              return turn;
            }
            throw error;'''
    text = replace_once(text, old, new, "root controlled growth termination")

    text = replace_once(
        text,
        '''    let finalText = "";
    let terminateMode = null;
    let localAiRolloverRetriedPromptId;''',
        '''    let finalText = "";
    let terminateMode = null;
    const localAiGrowthState = {
      limit: this.runtimeContext.getMaxContextGrowthTokensPerTurn(),
      consumedTokens: 0,
      initialized: false,
      chargedLogicalSends: /* @__PURE__ */ new Set()
    };
    let localAiRolloverRetriedPromptId;''',
        "specialist growth state",
    )

    text = replace_once(
        text,
        '''        const responseStream = await activeChat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId
        );''',
        '''        const responseStream = await activeChat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId,
          void 0,
          {
            growthBudgetState: localAiGrowthState,
            logicalSendKey: promptId
          }
        );''',
        "specialist LlmChat plumbing",
    )

    text = replace_once(
        text,
        '''      } catch (error3) {
        const rolloverMessage = error3 instanceof Error ? error3.message : String(error3);
        const isRolloverRequired = rolloverMessage.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");''',
        '''      } catch (error3) {
        const rolloverMessage = error3 instanceof Error ? error3.message : String(error3);
        if (rolloverMessage.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:")) {
          terminateMode = "GROWTH_LIMIT";
          this.runtimeContext.getDebugLogger()?.warn(
            `[LOCALAI_TURN_GROWTH_LIMIT] subagent=${this.subagentId} consumed=${Math.max(0, localAiGrowthState.consumedTokens ?? 0)} limit=${localAiGrowthState.limit}`
          );
          break;
        }
        const isRolloverRequired = rolloverMessage.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");''',
        "specialist growth termination",
    )

    text = replace_once(
        text,
        '''    case "TIMEOUT" /* TIMEOUT */:
      return { text: "Agent stopped: time limit reached.", level: "warning" };''',
        '''    case "GROWTH_LIMIT":
      return {
        text: "Agent stopped: per-turn context growth limit reached.",
        level: "warning"
      };
    case "TIMEOUT" /* TIMEOUT */:
      return { text: "Agent stopped: time limit reached.", level: "warning" };''',
        "specialist terminateModeMessage",
    )

    return text


def patch_schema(text: str) -> str:
    if "maxContextGrowthTokensPerTurn:" in text:
        return text
    old = '''      maxToolCallsPerTurn: {
        type: "integer",
        label: "Max Tool Calls Per Turn",
        category: "Model",
        requiresRestart: false,
        default: DEFAULT_MAX_TOOL_CALLS_PER_TURN,
        description: "Per-turn tool-call cap (one model turn plus its tool-result continuations; blocking Stop-hook continuations such as /goal iterations start a fresh budget). When set explicitly, this value is a hard cap: the turn halts on the next tool call after it is reached (the released behavior). When left unset (default 100), the cap is adaptive: once the turn exceeds 100 it halts only when the model keeps repeating the same call (a stuck loop); a productive turn (diverse calls) continues up to a hard backstop of 1000, which always halts. The adaptive default applies to the interactive TUI, non-interactive (-p / JSON / stream-JSON) core-client runs, and daemon/ACP sessions alike. Daemon/ACP sessions evaluate the cap once per tool batch, before execution: a batch that would cross an explicit cap or the hard backstop is skipped whole, so a turn never executes past either (it can halt up to one batch short), while the adaptive soft cap is exceeded by design, up to the backstop. They also have no in-session disable. An always-on circuit breaker against runaway turns, independent of model.skipLoopDetection. Set to 0 or a negative value to disable the cap.",
        showInDialog: false
      },'''
    new = old + f'''
      maxContextGrowthTokensPerTurn: {{
        type: "integer",
        label: "Max Context Growth Tokens Per Turn",
        category: "Model",
        requiresRestart: false,
        default: {DEFAULT_LIMIT},
        description: "Hard cumulative context-growth budget for one logical interaction. The first model send establishes the baseline; later model output plus newly appended tool-result, hook, steer, reminder, and other continuation input consumes the budget. Compaction and automatic context rollover do not refund consumed growth. The remaining budget also clamps model output independently of the context-window output clamp. Disabled by default so generic Qwen Code behavior is unchanged; set a positive integer to enable.",
        showInDialog: false
      }},'''
    return replace_once(text, old, new, "settings schema")


def patch_loader(text: str) -> str:
    if "maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn" in text:
        return text
    return replace_once(
        text,
        '''    maxToolCallsPerTurn: settings.model?.maxToolCallsPerTurn,
    skipStartupContext: settings.model?.skipStartupContext ?? false,''',
        '''    maxToolCallsPerTurn: settings.model?.maxToolCallsPerTurn,
    maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn,
    skipStartupContext: settings.model?.skipStartupContext ?? false,''',
        "settings -> Config loader",
    )


def patch_docs(text: str) -> str:
    if "`model.maxContextGrowthTokensPerTurn`" in text:
        return text
    row = (
        "| `model.maxContextGrowthTokensPerTurn`                  | integer | "
        "Hard cumulative context-growth budget for one logical interaction. The first model send establishes the baseline; "
        "later model output plus newly appended continuation input consumes the budget. Compaction and automatic rollover "
        "do not refund consumed growth. Remaining budget also clamps model output. Disabled by default; set a positive integer to enable. "
        f"| `{DEFAULT_LIMIT}`      |"
    )
    return insert_after_line_containing(text, "`model.maxToolCallsPerTurn`", row, "settings docs")


def syntax_check(paths):
    node = shutil.which("node")
    if not node:
        print("NODE_SYNTAX_CHECK=SKIP (node not found)")
        return
    for path in paths:
        proc = subprocess.run(
            [node, "--check", str(path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"node --check failed for {path}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )
        print(f"NODE_CHECK {path.name}=PASS")


def verify():
    checks = {
        PZ: [
            MARKER,
            "maxContextGrowthTokensPerTurn",
            "interactionGrowthByPromptId",
            "LOCALAI_TURN_GROWTH_LIMIT_REACHED:",
            'type: "turn_growth_limit_exceeded"',
            'terminateMode = "GROWTH_LIMIT"',
            "growthBudgetState: localAiGrowthState",
        ],
        SCHEMA: ["maxContextGrowthTokensPerTurn:", f"default: {DEFAULT_LIMIT}"],
        LOADER: ["maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn"],
        DOCS: ["`model.maxContextGrowthTokensPerTurn`"],
    }
    for path, needles in checks.items():
        text, _ = read_text_preserve(path)
        for needle in needles:
            if needle not in text:
                raise RuntimeError(f"verification failed: {needle!r} missing from {path}")
    print("STATIC_VERIFY=PASS")


def main():
    ap = argparse.ArgumentParser(description="LocalAI V5 per-turn context-growth hardening patch")
    ap.add_argument("--check", action="store_true", help="verify an already-patched runtime without modifying files")
    args = ap.parse_args()

    for path in (PZ, SCHEMA, LOADER, DOCS):
        if not path.exists():
            raise FileNotFoundError(path)

    if args.check:
        verify()
        syntax_check([PZ, SCHEMA, LOADER])
        for p in (PZ, SCHEMA, LOADER, DOCS):
            print(f"SHA256 {p.name} {sha256(p)}")
        return 0

    originals = {}
    newtexts = {}

    for path in (PZ, SCHEMA, LOADER, DOCS):
        text, newline = read_text_preserve(path)
        originals[path] = (text, newline, sha256(path))
        backup = backup_once(path)
        print(f"BACKUP {path.name} -> {backup}")

    newtexts[PZ] = patch_pz(originals[PZ][0])
    newtexts[SCHEMA] = patch_schema(originals[SCHEMA][0])
    newtexts[LOADER] = patch_loader(originals[LOADER][0])
    newtexts[DOCS] = patch_docs(originals[DOCS][0])

    try:
        for path in (PZ, SCHEMA, LOADER, DOCS):
            write_text_preserve(path, newtexts[path], originals[path][1])

        verify()
        syntax_check([PZ, SCHEMA, LOADER])

    except Exception:
        print("PATCH_FAILED: restoring exact pre-patch bytes from backups", file=sys.stderr)
        for path in (PZ, SCHEMA, LOADER, DOCS):
            backup = Path(str(path) + BACKUP_SUFFIX)
            if backup.exists():
                shutil.copy2(backup, path)
                backup.unlink()
        raise

    print("")
    print("LOCALAI_TURN_GROWTH_BUDGET_V5=APPLIED")
    print(f"DEFAULT_LIMIT={DEFAULT_LIMIT}")
    for path in (PZ, SCHEMA, LOADER, DOCS):
        before = originals[path][2]
        after = sha256(path)
        print(f"SHA256 {path.name} BEFORE={before} AFTER={after}")
        backup = Path(str(path) + BACKUP_SUFFIX)
        if backup.exists():
            backup.unlink()

    print("BACKUP_RETENTION=TRANSIENT_ONLY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

$SpecialistGrowthTerminationPython = @'
from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

QWEN_ROOT_VALUE = os.environ.get("LOCALAI_QWEN_ROOT")
if not QWEN_ROOT_VALUE:
    raise RuntimeError("LOCALAI_QWEN_ROOT is required")

QWEN_ROOT = Path(QWEN_ROOT_VALUE)
RUNTIME = (
    QWEN_ROOT
    / "runtime"
    / "qwen-code"
    / "standalone"
    / "qwen-code"
    / "lib"
    / "chunks"
    / "chunk-PZ66FRIC.js"
)
MARKER = "LOCALAI_SPECIALIST_GROWTH_TERMINATION_V5_5"


def read_preserve(path: Path):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    payload = raw[3:] if bom else raw
    nl = "\r\n" if b"\r\n" in payload else "\n"
    text = payload.decode("utf-8").replace("\r\n", "\n")
    return raw, text, nl, bom


def encode_preserve(text: str, nl: str, bom: bool) -> bytes:
    if nl == "\r\n":
        text = text.replace("\n", "\r\n")
    raw = text.encode("utf-8")
    return (b"\xef\xbb\xbf" + raw) if bom else raw


def replace_exact(text: str, old: str, new: str, count: int, label: str) -> str:
    found = text.count(old)
    if found != count:
        raise RuntimeError(f"{label}: expected {count}, found {found}")
    return text.replace(old, new, count)


def node_check(path: Path):
    p = subprocess.run(
        ["node", "--check", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip())


def patch_runtime(rt: str) -> str:
    if MARKER in rt:
        return rt

    old = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal) {
    const input = {
      ...this.createBaseInput("SubagentStop" /* SubagentStop */),
      permission_mode: permissionMode,
      stop_hook_active: stopHookActive,
      agent_id: agentId,
      agent_type: agentType,
      agent_transcript_path: agentTranscriptPath,
      last_assistant_message: lastAssistantMessage,
      background_tasks: this.getBackgroundTaskSnapshot(),
      crons: this.getCronJobSnapshot()
    };'''
    new = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal, terminateReason) {
    // LOCALAI_SPECIALIST_GROWTH_TERMINATION_V5_5
    const input = {
      ...this.createBaseInput("SubagentStop" /* SubagentStop */),
      permission_mode: permissionMode,
      stop_hook_active: stopHookActive,
      agent_id: agentId,
      agent_type: agentType,
      agent_transcript_path: agentTranscriptPath,
      last_assistant_message: lastAssistantMessage,
      ...(terminateReason !== void 0 ? { terminate_reason: terminateReason } : {}),
      background_tasks: this.getBackgroundTaskSnapshot(),
      crons: this.getCronJobSnapshot()
    };'''
    rt = replace_exact(rt, old, new, 1, "payload builder")

    old = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal) {
    const result = await this.hookEventHandler.fireSubagentStopEvent(
      agentId,
      agentType,
      agentTranscriptPath,
      lastAssistantMessage,
      stopHookActive,
      permissionMode,
      signal
    );'''
    new = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal, terminateReason) {
    const result = await this.hookEventHandler.fireSubagentStopEvent(
      agentId,
      agentType,
      agentTranscriptPath,
      lastAssistantMessage,
      stopHookActive,
      permissionMode,
      signal,
      terminateReason
    );'''
    rt = replace_exact(rt, old, new, 1, "forwarding wrapper")

    old = '''          subagent.getFinalText(),
          stopHookActive,
          resolvedMode,
          signal
        );'''
    new = '''          subagent.getFinalText(),
          stopHookActive,
          resolvedMode,
          signal,
          subagent.getTerminateMode()
        );'''
    rt = replace_exact(rt, old, new, 2, "normal stop callsites")

    old = '''                  input["last_assistant_message"] || "",
                  input["stop_hook_active"] || false,
                  input["permission_mode"] || "default" /* Default */,
                  signal
                );'''
    new = '''                  input["last_assistant_message"] || "",
                  input["stop_hook_active"] || false,
                  input["permission_mode"] || "default" /* Default */,
                  signal,
                  input["terminate_reason"] || void 0
                );'''
    rt = replace_exact(rt, old, new, 1, "replay forwarding")

    old = '''        const visibleFinalText = finalText || "(subagent produced no model-visible output)";
        return {
          llmContent: [{ text: visibleFinalText + wtSuffix }],
          returnDisplay: this.currentDisplay
        };'''
    new = '''        if (terminateMode === "GROWTH_LIMIT") {
          return {
            llmContent: [{ text: (finalText || "Agent stopped: per-turn context growth limit reached.") + wtSuffix }],
            returnDisplay: this.currentDisplay
          };
        }
        const visibleFinalText = finalText || "(subagent produced no model-visible output)";
        return {
          llmContent: [{ text: visibleFinalText + wtSuffix }],
          returnDisplay: this.currentDisplay
        };'''
    rt = replace_exact(rt, old, new, 1, "parent-visible receipt")

    for needle in (
        MARKER,
        "terminate_reason: terminateReason",
        "subagent.getTerminateMode()",
        'input["terminate_reason"] || void 0',
        'terminateMode === "GROWTH_LIMIT"',
    ):
        if needle not in rt:
            raise RuntimeError(f"verification missing: {needle}")

    return rt


def main() -> int:
    if not RUNTIME.is_file():
        raise FileNotFoundError(RUNTIME)

    raw, text, nl, bom = read_preserve(RUNTIME)
    patched = patch_runtime(text)

    if patched == text:
        print(f"{MARKER}=ALREADY_APPLIED")
        return 0

    candidate = encode_preserve(patched, nl, bom)

    fd, tmp_name = tempfile.mkstemp(suffix=".js")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        tmp.write_bytes(candidate)
        node_check(tmp)
        RUNTIME.write_bytes(candidate)
        try:
            node_check(RUNTIME)
        except Exception:
            RUNTIME.write_bytes(raw)
            raise
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass

    print(f"{MARKER}=APPLIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
'@

$PatchRegistry = @(
    [pscustomobject]@{ Id = "compatibility-and-compression"; Revision = 1; Kind = "powershell" },
    [pscustomobject]@{ Id = "runtime-resilience"; Revision = 1; Kind = "powershell" },
    [pscustomobject]@{ Id = "root-context-growth"; Revision = 1; Kind = "python" },
    [pscustomobject]@{ Id = "specialist-growth-termination"; Revision = 1; Kind = "python" }
)

function Invoke-PatchBlock {
    param([Parameter(Mandatory=$true)]$Patch, [Parameter(Mandatory=$true)][string]$TempRoot)
    Write-Host "PATCH_BLOCK=$($Patch.Id) REVISION=$($Patch.Revision) STATUS=START"
    switch ($Patch.Id) {
        "compatibility-and-compression" { Invoke-CompatibilityAndCompressionPatch }
        "runtime-resilience" { Invoke-RuntimeResiliencePatch -QwenRoot $QwenRoot }
        "root-context-growth" {
            $path = Join-Path $TempRoot "root-context-growth.py"
            [IO.File]::WriteAllText($path, $RootContextGrowthPython, [Text.UTF8Encoding]::new($false))
            & python $path
            if ($LASTEXITCODE -ne 0) { throw "root-context-growth failed: exit=$LASTEXITCODE" }
        }
        "specialist-growth-termination" {
            $path = Join-Path $TempRoot "specialist-growth-termination.py"
            [IO.File]::WriteAllText($path, $SpecialistGrowthTerminationPython, [Text.UTF8Encoding]::new($false))
            & python $path
            if ($LASTEXITCODE -ne 0) { throw "specialist-growth-termination failed: exit=$LASTEXITCODE" }
        }
        default { throw "Unknown patch block: $($Patch.Id)" }
    }
    Write-Host "PATCH_BLOCK=$($Patch.Id) REVISION=$($Patch.Revision) STATUS=PASS"
}

if ($VerifyOnly) {
    Test-QwenRuntimePatchState
    Write-Host "QWEN_RUNTIME_PATCH_MANAGER=PASS"
    Write-Host "PATCH_MANAGER_REVISION=$PatchManagerRevision"
    exit 0
}

Assert-ManagedRuntimeFiles
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$TransactionRoot = Join-Path $env:TEMP "localai-qwen-runtime-patch-$Stamp"
$BackupRoot = Join-Path $TransactionRoot "rollback"
$PreviousQwenRoot = $env:LOCALAI_QWEN_ROOT

try {
    New-Item -ItemType Directory -Force -Path $TransactionRoot, $BackupRoot | Out-Null
    foreach ($relative in $ManagedRelativeFiles) {
        $source = Join-Path $RuntimeRoot $relative
        $backup = Join-Path $BackupRoot $relative
        New-Item -ItemType Directory -Force -Path (Split-Path $backup -Parent) | Out-Null
        Copy-Item -LiteralPath $source -Destination $backup -Force
    }
    $env:LOCALAI_QWEN_ROOT = $QwenRoot
    Write-Host "========================================"
    Write-Host " LocalAI Qwen Runtime Patch Manager"
    Write-Host "========================================"
    Write-Host "PATCH_MANAGER_REVISION=$PatchManagerRevision"
    foreach ($patch in $PatchRegistry) {
        Invoke-PatchBlock -Patch $patch -TempRoot $TransactionRoot
    }
    Test-QwenRuntimePatchState
    Write-Host "QWEN_RUNTIME_PATCH_STATUS=PASS"
    Write-Host "BACKUP_RETENTION=TRANSIENT_ONLY"
}
catch {
    Write-Warning "Unified patch transaction failed. Restoring exact pre-run runtime files."
    foreach ($relative in $ManagedRelativeFiles) {
        $backup = Join-Path $BackupRoot $relative
        $target = Join-Path $RuntimeRoot $relative
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            Copy-Item -LiteralPath $backup -Destination $target -Force
        }
    }
    Write-Host "QWEN_RUNTIME_PATCH_STATUS=FAIL"
    Write-Host "QWEN_RUNTIME_PATCH_ROLLBACK=ATTEMPTED"
    throw
}
finally {
    if ($null -eq $PreviousQwenRoot) {
        Remove-Item Env:LOCALAI_QWEN_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:LOCALAI_QWEN_ROOT = $PreviousQwenRoot
    }
    if (Test-Path -LiteralPath $TransactionRoot) {
        Remove-Item -LiteralPath $TransactionRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
