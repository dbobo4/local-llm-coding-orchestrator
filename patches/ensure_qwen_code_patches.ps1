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

    $spec = Get-CompressionOptimizationSpec $Text

    $promptStart = $Text.IndexOf(
        $spec.PromptStartMarker,
        [System.StringComparison]::Ordinal
    )
    if ($promptStart -lt 0) { return "incompatible" }

    $secondPromptStart = $Text.IndexOf(
        $spec.PromptStartMarker,
        $promptStart + $spec.PromptStartMarker.Length,
        [System.StringComparison]::Ordinal
    )
    if ($secondPromptStart -ge 0) { return "incompatible" }

    $promptEnd = $Text.IndexOf(
        $spec.PromptEndMarker,
        $promptStart,
        [System.StringComparison]::Ordinal
    )
    if ($promptEnd -lt 0) { return "incompatible" }

    $secondPromptEnd = $Text.IndexOf(
        $spec.PromptEndMarker,
        $promptEnd + $spec.PromptEndMarker.Length,
        [System.StringComparison]::Ordinal
    )
    if ($secondPromptEnd -ge 0) { return "incompatible" }

    $promptEnd += $spec.PromptEndMarker.Length
    $promptRegion = $Text.Substring($promptStart, $promptEnd - $promptStart)

    $unpatchedCapCount = ([regex]::Matches($Text, [regex]::Escape($spec.UnpatchedCap))).Count
    $legacyCapCount = ([regex]::Matches($Text, [regex]::Escape($spec.LegacyCap))).Count
    $patchedCapCount = ([regex]::Matches($Text, [regex]::Escape($spec.PatchedCap))).Count
    $unpatchedDirectiveCount = ([regex]::Matches($Text, [regex]::Escape($spec.UnpatchedDirective))).Count
    $patchedDirectiveCount = ([regex]::Matches($Text, [regex]::Escape($spec.PatchedDirective))).Count

    $isUnpatched =
        $promptRegion -eq $spec.UnpatchedPrompt -and
        $unpatchedCapCount -eq 1 -and
        $legacyCapCount -eq 0 -and
        $patchedCapCount -eq 0 -and
        $unpatchedDirectiveCount -eq 1 -and
        $patchedDirectiveCount -eq 0
    if ($isUnpatched) { return "unpatched" }

    $isLegacy =
        $promptRegion -eq $spec.PatchedPrompt -and
        $unpatchedCapCount -eq 0 -and
        $legacyCapCount -eq 1 -and
        $patchedCapCount -eq 0 -and
        $unpatchedDirectiveCount -eq 0 -and
        $patchedDirectiveCount -eq 1
    if ($isLegacy) { return "legacy" }

    $isPatched =
        $promptRegion -eq $spec.PatchedPrompt -and
        $unpatchedCapCount -eq 0 -and
        $legacyCapCount -eq 0 -and
        $patchedCapCount -eq 1 -and
        $unpatchedDirectiveCount -eq 0 -and
        $patchedDirectiveCount -eq 1
    if ($isPatched) { return "patched" }

    return "incompatible"
}

function Apply-CompressionOptimization {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $initialState = Get-CompressionOptimizationState $Text
    if ($initialState -eq "patched") { return $Text }

    if ($initialState -ne "unpatched" -and $initialState -ne "legacy") {
        throw "Compression optimization input is not a known safe state."
    }

    $spec = Get-CompressionOptimizationSpec $Text

    if ($initialState -eq "legacy") {
        $legacyCount = ([regex]::Matches($Text, [regex]::Escape($spec.LegacyCap))).Count
        if ($legacyCount -ne 1) { throw "Compression legacy cap is not unique." }
        $Text = $Text.Replace($spec.LegacyCap, $spec.PatchedCap)
    }
    else {
        $promptStart = $Text.IndexOf($spec.PromptStartMarker, [System.StringComparison]::Ordinal)
        $promptEnd = $Text.IndexOf($spec.PromptEndMarker, $promptStart, [System.StringComparison]::Ordinal)
        if ($promptStart -lt 0 -or $promptEnd -lt 0) {
            throw "Compression prompt boundaries not found."
        }
        $promptEnd += $spec.PromptEndMarker.Length
        $Text = $Text.Substring(0, $promptStart) + $spec.PatchedPrompt + $Text.Substring($promptEnd)
        $Text = $Text.Replace($spec.UnpatchedCap, $spec.PatchedCap)
        $Text = $Text.Replace($spec.UnpatchedDirective, $spec.PatchedDirective)
    }

    $finalState = Get-CompressionOptimizationState $Text
    if ($finalState -ne "patched") {
        throw "Compression optimization post-state is not patched. Final=$finalState"
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
    Write-Host "QWEN_PATCH_STATUS=OK"
    exit 0
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
