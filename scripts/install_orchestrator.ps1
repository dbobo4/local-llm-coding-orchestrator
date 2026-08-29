$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path $PSScriptRoot -Parent
$ConfigPath = Join-Path $RepoRoot "config\local.ps1"
$SettingsTemplatePath = Join-Path $RepoRoot "config\settings.example.json"

if (-not (Test-Path $ConfigPath -PathType Leaf)) {
    throw "Missing config file: $ConfigPath. Copy config\local.example.ps1 to config\local.ps1 and edit it first."
}

if (-not (Test-Path $SettingsTemplatePath -PathType Leaf)) {
    throw "Missing settings template: $SettingsTemplatePath"
}

. $ConfigPath

$SourceQwenMd = Join-Path $RepoRoot "orchestration\QWEN.md"
$SourceAlgorithmAgent = Join-Path $RepoRoot "orchestration\agents\algorithm-agent.md"
$SourceTestAgent = Join-Path $RepoRoot "orchestration\agents\test-agent.md"
$SourceDispatcher = Join-Path $RepoRoot "orchestration\hook_dispatcher.py"
$SourceMaintenance = Join-Path $RepoRoot "orchestration\maintenance_hook.py"
$SourceMemoryProtocol = Join-Path $RepoRoot "orchestration\memory_protocol.py"
$SourceMemoryStore = Join-Path $RepoRoot "orchestration\memory_store.py"
$SourceProjectIdentity = Join-Path $RepoRoot "orchestration\project_identity.py"
$SourceProjectRegistry = Join-Path $RepoRoot "orchestration\project_registry.py"
$SourceWorkflowState = Join-Path $RepoRoot "orchestration\workflow_state.py"

$RequiredFiles = @(
    $SourceQwenMd,
    $SourceAlgorithmAgent,
    $SourceTestAgent,
    $SourceDispatcher,
    $SourceMaintenance,
    $SourceMemoryProtocol,
    $SourceMemoryStore,
    $SourceProjectIdentity,
    $SourceProjectRegistry,
    $SourceWorkflowState
)

foreach ($file in $RequiredFiles) {
    if (-not (Test-Path $file -PathType Leaf)) {
        throw "Missing repository file: $file"
    }
}

$AgentsRoot = Join-Path $QwenUserRoot "agents"
$SettingsPath = Join-Path $QwenUserRoot "settings.json"

New-Item -ItemType Directory -Force -Path $QwenUserRoot, $AgentsRoot, $OrchestrationRoot | Out-Null

$Targets = @{
    $SourceQwenMd         = Join-Path $QwenUserRoot "QWEN.md"
    $SourceAlgorithmAgent = Join-Path $AgentsRoot "algorithm-agent.md"
    $SourceTestAgent      = Join-Path $AgentsRoot "test-agent.md"
    $SourceDispatcher     = Join-Path $OrchestrationRoot "hook_dispatcher.py"
    $SourceMaintenance    = Join-Path $OrchestrationRoot "maintenance_hook.py"
    $SourceMemoryProtocol = Join-Path $OrchestrationRoot "memory_protocol.py"
    $SourceMemoryStore    = Join-Path $OrchestrationRoot "memory_store.py"
    $SourceProjectIdentity = Join-Path $OrchestrationRoot "project_identity.py"
    $SourceProjectRegistry = Join-Path $OrchestrationRoot "project_registry.py"
    $SourceWorkflowState   = Join-Path $OrchestrationRoot "workflow_state.py"
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"
$BackupRoot = Join-Path $QwenRoot "backups\orchestrator-install\$Timestamp"
$FilesToBackup = @($Targets.Values) + @($SettingsPath)
$ExistingFiles = @($FilesToBackup | Where-Object { Test-Path $_ -PathType Leaf })

if ($ExistingFiles.Count -gt 0) {
    New-Item -ItemType Directory -Force -Path $BackupRoot | Out-Null

    foreach ($file in $ExistingFiles) {
        $safeName = ($file -replace '[:\\\/]', '_')
        Copy-Item $file (Join-Path $BackupRoot $safeName) -Force
    }
}

foreach ($entry in $Targets.GetEnumerator()) {
    Copy-Item $entry.Key $entry.Value -Force
}

$template = Get-Content $SettingsTemplatePath -Raw | ConvertFrom-Json

$dispatcherPath = Join-Path $OrchestrationRoot "hook_dispatcher.py"
$maintenancePath = Join-Path $OrchestrationRoot "maintenance_hook.py"
$stopServerPath = Join-Path $RepoRoot "scripts\stop_qwen_server.ps1"

$dispatcherCommand = 'python "' + $dispatcherPath + '"'
$maintenanceCommand = 'python "' + $maintenancePath + '"'
$stopServerCommand = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $stopServerPath + '"'

foreach ($eventName in @("SubagentStart","UserPromptSubmit","SessionStart","SessionEnd","SubagentStop","Stop")) {
    foreach ($eventGroup in $template.hooks.$eventName) {
        foreach ($hook in $eventGroup.hooks) {
            if ($hook.name -eq "qwen-orchestration-dispatcher") {
                $hook.command = $dispatcherCommand
            }
            elseif ($hook.name -eq "qwen-server-stop") {
                $hook.command = $stopServerCommand
            }
        }
    }
}

foreach ($eventGroup in $template.hooks.PreToolUse) {
    foreach ($hook in $eventGroup.hooks) {
        if ($hook.name -eq "qwen-orchestration-maintenance") {
            $hook.command = $maintenanceCommand
        }
    }
}

$template.modelProviders.openai[0].id = $ModelAlias
$template.modelProviders.openai[0].name = "$ModelAlias Local"
$template.modelProviders.openai[0].baseUrl = "http://${ServerHost}:${ServerPort}/v1"
$template.model.name = $ModelAlias

function Ensure-ObjectProperty($Object, [string]$Name) {
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        $value = [pscustomobject]@{}
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $value -Force
        return $value
    }
    return $property.Value
}

if (Test-Path $SettingsPath -PathType Leaf) {
    $settings = Get-Content $SettingsPath -Raw | ConvertFrom-Json

    # Preserve other providers; replace only the provider managed by this project.
    $modelProviders = Ensure-ObjectProperty $settings "modelProviders"
    $existingOpenAI = @()
    if ($null -ne $modelProviders.PSObject.Properties["openai"]) {
        $existingOpenAI = @($modelProviders.openai)
    }
    $openAIProviders = @($existingOpenAI | Where-Object { $_.id -ne $ModelAlias }) + @($template.modelProviders.openai[0])
    $modelProviders | Add-Member -NotePropertyName "openai" -NotePropertyValue @($openAIProviders) -Force

    # Preserve unrelated environment variables.
    $envSettings = Ensure-ObjectProperty $settings "env"
    $envSettings | Add-Member -NotePropertyName "LOCAL_QWEN_API_KEY" -NotePropertyValue $template.env.LOCAL_QWEN_API_KEY -Force

    # Update only the authentication field required by the local OpenAI-compatible provider.
    $security = Ensure-ObjectProperty $settings "security"
    $auth = Ensure-ObjectProperty $security "auth"
    $auth | Add-Member -NotePropertyName "selectedType" -NotePropertyValue $template.security.auth.selectedType -Force

    # Preserve unrelated model and agent options.
    $model = Ensure-ObjectProperty $settings "model"
    foreach ($name in @("name","reasoningEffort","maxSubagentDepth")) {
        $model | Add-Member -NotePropertyName $name -NotePropertyValue $template.model.$name -Force
    }
    $agents = Ensure-ObjectProperty $settings "agents"
    $agents | Add-Member -NotePropertyName "maxParallelAgents" -NotePropertyValue $template.agents.maxParallelAgents -Force

    # Keep existing deny rules and add the orchestrator-specific agent restrictions.
    $permissions = Ensure-ObjectProperty $settings "permissions"
    $existingDeny = @()
    if ($null -ne $permissions.PSObject.Properties["deny"]) {
        $existingDeny = @($permissions.deny)
    }
    $mergedDeny = @(@($existingDeny) + @($template.permissions.deny))
    $mergedDeny = @($mergedDeny | Select-Object -Unique)
    $permissions | Add-Member -NotePropertyName "deny" -NotePropertyValue $mergedDeny -Force

    # Disable only the managed memory features required by this orchestration design.
    $memory = Ensure-ObjectProperty $settings "memory"
    foreach ($name in $template.memory.PSObject.Properties.Name) {
        $memory | Add-Member -NotePropertyName $name -NotePropertyValue $template.memory.$name -Force
    }

    $settings | Add-Member -NotePropertyName "disableAllHooks" -NotePropertyValue $false -Force

    # Preserve third-party hooks. Replace only hooks owned by this project.
    $hooks = Ensure-ObjectProperty $settings "hooks"
    $managedHookNames = @("qwen-orchestration-dispatcher","qwen-server-stop","qwen-orchestration-maintenance")
    foreach ($eventName in $template.hooks.PSObject.Properties.Name) {
        $preservedGroups = @()
        $existingEvent = $hooks.PSObject.Properties[$eventName]
        if ($null -ne $existingEvent) {
            foreach ($group in @($existingEvent.Value)) {
                if ($null -eq $group.PSObject.Properties["hooks"]) {
                    $preservedGroups += $group
                    continue
                }
                $keptHooks = @($group.hooks | Where-Object { $managedHookNames -notcontains $_.name })
                if ($keptHooks.Count -gt 0) {
                    $group.hooks = @($keptHooks)
                    $preservedGroups += $group
                }
            }
        }
        $mergedGroups = @($preservedGroups) + @($template.hooks.$eventName)
        $hooks | Add-Member -NotePropertyName $eventName -NotePropertyValue @($mergedGroups) -Force
    }
}
else {
    $settings = $template
}

$json = $settings | ConvertTo-Json -Depth 30
[IO.File]::WriteAllText(
    $SettingsPath,
    $json,
    (New-Object Text.UTF8Encoding($false))
)

$verify = Get-Content $SettingsPath -Raw | ConvertFrom-Json

if ($verify.model.name -ne $ModelAlias) {
    throw "Installation verification failed: model alias"
}

if ($verify.model.reasoningEffort -ne "xhigh") {
    throw "Installation verification failed: reasoning effort"
}

$verifyProvider = @($verify.modelProviders.openai | Where-Object { $_.id -eq $ModelAlias }) | Select-Object -First 1
if ($null -eq $verifyProvider -or $verifyProvider.generationConfig.contextWindowSize -ne 49152) {
    throw "Installation verification failed: context window"
}

if ($verify.hooks.SessionEnd[0].hooks.Count -ne 2) {
    throw "Installation verification failed: SessionEnd hooks"
}

if ($verify.hooks.PreToolUse[0].matcher -ne "run_shell_command") {
    throw "Installation verification failed: PreToolUse hook"
}

Write-Host "ORCHESTRATOR_INSTALL=PASS"
Write-Host "QWEN_USER_ROOT=$QwenUserRoot"
Write-Host "ORCHESTRATION_ROOT=$OrchestrationRoot"
Write-Host "SETTINGS=$SettingsPath"

if ($ExistingFiles.Count -gt 0) {
    Write-Host "BACKUP=$BackupRoot"
}
