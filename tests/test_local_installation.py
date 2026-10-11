"""Bounded Windows migration checks; no downloads, models, or GPU execution."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


REPO = Path(__file__).resolve().parents[1]
POWERSHELL = shutil.which("powershell.exe")


def ps_quote(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


class FixtureTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix=".tmp_localai migration ", dir=REPO)
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.clone = self.base / "arbitrary clone with spaces"
        self.clone.mkdir()
        self.user = self.base / "unrelated user home"
        self.old = self.base / "old installation"
        for root in (self.user / ".qwen", self.old):
            root.mkdir(parents=True)
            (root / "keep.txt").write_text("untouched", encoding="utf-8")
        self.project = self.user / "external working project"
        self.project.mkdir()
        self.env = os.environ.copy()
        for name in (
            "QWEN_ROOT", "QWEN_CODE_ROOT", "LLAMA_CPP_ROOT", "MODEL_PATH",
            "QWEN_USER_ROOT", "ORCHESTRATION_ROOT", "QWEN_HOME",
            "LOCALAI_QWEN_ROOT",
            "LOCALAI_INSTALL_ROOT",
        ):
            self.env.pop(name, None)
        self.env.update({
            "HOME": str(self.user),
            "USERPROFILE": str(self.user),
            "PYTHONDONTWRITEBYTECODE": "1",
            "QWEN_HOME": str(self.clone / ".localai" / "qwen"),
            "LOCALAI_ORIGINAL_USERPROFILE": str(self.user),
        })
        process_environment = patch.dict(os.environ, self.env, clear=True)
        process_environment.start()
        self.addCleanup(process_environment.stop)

    def assert_external_unchanged(self) -> None:
        for root in (self.user / ".qwen", self.old):
            self.assertEqual([p.name for p in root.iterdir()], ["keep.txt"])
            self.assertEqual((root / "keep.txt").read_text(), "untouched")
        self.assertEqual(list(self.project.iterdir()), [])

    def copy_sources(self) -> None:
        tracked = subprocess.run(
            ["git", "ls-files", "--", "config", "scripts", "orchestration", "patches", "benchmark"],
            cwd=REPO, capture_output=True, text=True, check=True,
        ).stdout.splitlines()
        for relative in tracked:
            target = self.clone / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / relative, target)
        # New migration source files are untracked until the user commits them.
        for relative in ("scripts/local_environment.ps1", "scripts/install_local.py", "orchestration/local_paths.py", "qwen.cmd"):
            if (REPO / relative).is_file():
                target = self.clone / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(REPO / relative, target)

    def powershell(self, source: str, *, check: bool = True) -> subprocess.CompletedProcess[str]:
        if POWERSHELL is None:
            self.skipTest("Windows PowerShell is required")
        script = self.base / "fixture.ps1"
        script.write_text('$ErrorActionPreference = "Stop"\n' + source, encoding="utf-8")
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
             "-File", str(script)],
            cwd=self.project, env=self.env, capture_output=True, text=True,
            timeout=30, check=False,
        )
        if check:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def python(self, source: str) -> subprocess.CompletedProcess[str]:
        # Repository-hosted fixtures deliberately emulate a non-Git external project.
        source = "import project_identity as fixture_identity; fixture_identity._find_git_root = lambda cwd: None\n" + source
        result = subprocess.run(
            [sys.executable, "-B", "-c", source], cwd=self.project,
            env={**self.env, "PYTHONPATH": str(self.clone / "orchestration")},
            capture_output=True, text=True, timeout=15, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result


class ExistingContracts(FixtureTest):
    def test_installer_keeps_local_settings_hooks_and_memory_on_repeat(self) -> None:
        self.copy_sources()
        state = self.clone / ".localai" / "qwen"
        config = self.clone / ".localai" / "config" / "local.ps1"
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / "config" / "local.example.ps1", config)
        (self.clone / "config" / "local.ps1").write_text("throw 'Legacy config must not be imported'", encoding="utf-8")
        invocation = f"""
function powershell.exe {{ $global:LASTEXITCODE = 0 }}
& {ps_quote(self.clone / 'scripts' / 'install_orchestrator.ps1')}
"""
        self.powershell(invocation)
        settings_path = state / "settings.json"
        settings = json.loads(settings_path.read_text())
        settings["fixturePreference"] = "keep"
        settings["mcpServers"]["context7"]["headers"] = {"X-Fixture-Key": "local-fixture"}
        settings["hooks"]["SessionStart"].insert(0, {
            "matcher": "*", "hooks": [{"name": "fixture-hook", "command": "fixture"}]
        })
        settings_path.write_text(json.dumps(settings), encoding="utf-8")
        memory = self.clone / ".localai" / "orchestration" / "memory" / "fixture.md"
        memory.parent.mkdir(parents=True)
        memory.write_text("persistent memory", encoding="utf-8")
        self.powershell(invocation)
        settings = json.loads(settings_path.read_text())
        self.assertEqual(settings["fixturePreference"], "keep")
        self.assertEqual(settings["mcpServers"]["context7"]["headers"], {"X-Fixture-Key": "local-fixture"})
        self.assertEqual(memory.read_text(), "persistent memory")
        start_hooks = [h for g in settings["hooks"]["SessionStart"] for h in g["hooks"]]
        self.assertEqual([h["name"] for h in start_hooks].count("fixture-hook"), 1)
        self.assertEqual([h["name"] for h in start_hooks].count("qwen-orchestration-dispatcher"), 1)
        for event in settings["hooks"].values():
            for group in event:
                for hook in group["hooks"]:
                    if hook["name"].startswith("qwen-"):
                        self.assertIn(str(self.clone), hook["command"])
        for name, alias in (("algorithm-agent.md", "qwen3.8-27b-algorithm"),
                            ("test-agent.md", "qwen3.8-27b-test")):
            self.assertIn(f"model: {alias}", (state / "agents" / name).read_text())
        self.assert_external_unchanged()

    def test_local_registry_memory_and_recovery_survive_restart(self) -> None:
        self.copy_sources()
        first = self.python("""
import json
from pathlib import Path
import project_identity as identity
import memory_store as memory
import workflow_state as workflow
p = identity.identify_project()
memory.replace_memory(p, 'algorithm_agent', 'Persistent fixture invariant')
s = workflow.create_state('fixture-session', 'fixture-turn', p.project_id)
workflow.mark_contract_ready(s)
workflow.select_implementation_workflow(s, require_test=True)
workflow.mark_algorithm_started(s)
workflow.set_algorithm_scope(s, files=['one.py', 'two.py'], objectives=['first', 'second'])
workflow.mark_growth_recovery_required(s)
assert s.partial_side_effects_possible
assert not workflow.can_finish_turn(s)[0]
print(json.dumps({'project_id': p.project_id, 'root': str(identity.ORCHESTRATION_ROOT)}))
""")
        created = json.loads(first.stdout)
        second = self.python("""
import json
import project_identity as identity
import memory_store as memory
import workflow_state as workflow
p = identity.identify_project()
s = workflow.load_state('fixture-session', 'fixture-turn')
assert memory.read_memory(p, 'algorithm_agent').strip() == 'Persistent fixture invariant'
assert s.growth_recovery_required and s.partial_side_effects_possible
workflow.record_growth_recovery_reread(s, 'one.py')
workflow.set_growth_recovery_plan(s, completed=['first'], residual=['second'],
    delegate_files=['two.py'], delegate_objectives=['second'], final_slice=True)
workflow.mark_algorithm_completed(s)
workflow.mark_growth_recovery_algorithm_success(s)
assert not workflow.can_finish_turn(s)[0]
workflow.mark_final_test_started(s)
workflow.mark_verification_pass(s)
assert workflow.can_finish_turn(s)[0]
print(json.dumps({'project_id': p.project_id}))
""")
        self.assertEqual(json.loads(second.stdout)["project_id"], created["project_id"])
        self.assertTrue(Path(created["root"]).is_relative_to(self.clone / ".localai"))
        self.assert_external_unchanged()

    def test_coding_lease_wraps_preflight_cli_and_idle_cleanup(self) -> None:
        self.copy_sources()
        state = self.clone / ".localai" / "qwen"
        config = self.clone / ".localai" / "config" / "local.ps1"
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / "config" / "local.example.ps1", config)
        fake_cli = self.base / "fake_cli.ps1"
        fake_cli.write_text(
            "[IO.File]::WriteAllText($env:FIXTURE_CLI_RESULT, "
            "((Get-Location).Path + '|' + ($args -join '|')))\nexit 7\n",
            encoding="utf-8",
        )
        cli = self.clone / "runtime" / "qwen-code" / "bin" / "qwen.cmd"
        cli.parent.mkdir(parents=True)
        cli.write_text(f'@echo off\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "{fake_cli}" %*\nexit /b %ERRORLEVEL%\n', encoding="utf-8")
        result_path = self.base / "cli result.txt"
        self.env["FIXTURE_CLI_RESULT"] = str(result_path)
        result = self.powershell(f"""
function python {{ if ($args -contains 'check-workspace') {{ $env:USERPROFILE }}; $global:LASTEXITCODE = 0 }}
function powershell.exe {{
    $leaseRoot = {ps_quote(state / 'runtime_clients' / 'cli')}
    $leases = @(Get-ChildItem -LiteralPath $leaseRoot -Filter '*.lock' -File)
    if ($args -contains 'Stop') {{
        if ($leases.Count -ne 0) {{ throw 'CLI lease remained during idle cleanup' }}
    }} else {{
        if ($leases.Count -ne 1) {{ throw 'CLI preflight has no exclusive lease' }}
        try {{
            $stream = [IO.File]::Open($leases[0].FullName, 'Open', 'ReadWrite', 'None')
            $stream.Dispose()
            throw 'CLI lease was not held exclusively'
        }} catch [IO.IOException] {{}}
    }}
    $global:LASTEXITCODE = 0
}}
& {ps_quote(self.clone / 'scripts' / 'qwen.ps1')} 'argument with spaces' '--fixture'
exit $LASTEXITCODE
""", check=False)
        self.assertEqual(result.returncode, 7, result.stdout + result.stderr)
        self.assertEqual(result_path.read_text(), f"{self.project}|argument with spaces|--fixture")
        self.assertEqual(list((state / "runtime_clients" / "cli").iterdir()), [])
        self.assert_external_unchanged()

    def test_role_budgets_and_hooks_are_protected(self) -> None:
        settings = json.loads((REPO / "config" / "settings.example.json").read_text())
        providers = settings["modelProviders"]["openai"]
        self.assertEqual([p["generationConfig"]["contextWindowSize"] for p in providers], [40960] * 3)
        self.assertEqual([p["generationConfig"]["extra_body"]["thinking_budget_tokens"] for p in providers], [4608, 6144, 6144])
        self.assertEqual(settings["model"]["maxContextGrowthTokensPerTurn"], 24576)
        self.assertEqual(settings["model"]["maxSubagentDepth"], 1)
        self.assertEqual(settings["agents"]["maxParallelAgents"], 1)
        self.assertTrue(all(value is False for value in settings["memory"].values()))
        self.assertIn("-IfIdle", settings["hooks"]["SessionEnd"][0]["hooks"][1]["command"])


class MigrationAcceptance(FixtureTest):
    def prepare_config(self) -> None:
        self.copy_sources()
        config = self.clone / ".localai" / "config" / "local.ps1"
        config.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(self.clone / "config" / "local.example.ps1", config)

    def import_functions(self, relative: str) -> str:
        return f"""
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile({ps_quote(self.clone / relative)}, [ref]$tokens, [ref]$errors)
foreach ($statement in $ast.FindAll({{ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }}, $true)) {{
    $parent = $statement.Parent; $nested = $false
    while ($null -ne $parent) {{
        if ($parent -is [System.Management.Automation.Language.FunctionDefinitionAst]) {{ $nested = $true; break }}
        $parent = $parent.Parent
    }}
    if (-not $nested) {{
        Invoke-Expression ($statement.Extent.Text.Replace('$PSScriptRoot', {ps_quote(ps_quote((self.clone / relative).parent))}).Replace('$PSCommandPath', {ps_quote(ps_quote(self.clone / relative))}))
    }}
}}
"""

    def test_environment_is_local_and_restored_for_direct_invocation(self) -> None:
        self.prepare_config()
        self.powershell(f"""
$original = $env:USERPROFILE; $automaticHome = $HOME
$env:QWEN_HOME = {ps_quote(self.old)}
$env:QWEN_ROOT = {ps_quote(self.old)}
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
if ($env:USERPROFILE -ne {ps_quote(self.clone / '.localai' / 'home')}) {{ throw 'Profile not scoped' }}
if ($env:QWEN_HOME -ne {ps_quote(self.clone / '.localai' / 'qwen')}) {{ throw 'Qwen state not scoped' }}
if ($HOME -ne $automaticHome) {{ throw 'PowerShell automatic HOME changed' }}
Restore-LocalEnvironment
if ($env:USERPROFILE -ne $original -or $env:QWEN_HOME -ne {ps_quote(self.old)}) {{ throw 'Caller environment not restored' }}
""")
        self.assert_external_unchanged()

    def test_strict_environment_snapshot_lifecycle_in_script_and_function(self) -> None:
        self.prepare_config()
        lifecycle = f"""
Set-StrictMode -Version 2.0
if ($null -ne (Get-Variable -Name LocalAiOriginalEnvironment -Scope Script -ErrorAction SilentlyContinue)) {{ throw 'Fixture snapshot already exists' }}
$names=@('LOCALAI_INSTALL_ROOT','USERPROFILE','HOME','APPDATA','LOCALAPPDATA','TEMP','TMP','TMPDIR',
 'QWEN_HOME','QWEN_RUNTIME_DIR','QWEN_CODE_MCP_APPROVALS_PATH','QWEN_CODE_TRUSTED_FOLDERS_PATH',
 'QWEN_CODE_SYSTEM_SETTINGS_PATH','QWEN_CODE_SYSTEM_DEFAULTS_PATH','PYTHONDONTWRITEBYTECODE',
 'NODE_COMPILE_CACHE','CUDA_CACHE_PATH','NPM_CONFIG_CACHE','LOCALAI_ORIGINAL_USERPROFILE','NODE_OPTIONS')
$before=@{{}}
for ($i=0;$i -lt $names.Count;$i++) {{
 $name=$names[$i]
 if ($name -notin @('USERPROFILE','LOCALAI_ORIGINAL_USERPROFILE')) {{
  $value=if ($i % 2) {{ 'fixture-'+$i }} else {{ $null }}
  [Environment]::SetEnvironmentVariable($name,$value,'Process')
 }}
 $before[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
}}
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
$first=$script:LocalAiOriginalEnvironment
if ($first.Count -ne $LocalAiEnvironment.Count -or $env:USERPROFILE -ne {ps_quote(self.clone / '.localai' / 'home')}) {{ throw 'First snapshot/scoping failed' }}
foreach ($name in $LocalAiEnvironment.Keys) {{ if ($first[$name] -cne $before[$name]) {{ throw ('Original value not captured: '+$name) }} }}
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
if (-not [object]::ReferenceEquals($first,$script:LocalAiOriginalEnvironment)) {{ throw 'Repeated load replaced active snapshot' }}
Restore-LocalEnvironment
Restore-LocalEnvironment
foreach ($name in $names) {{ if ([Environment]::GetEnvironmentVariable($name,'Process') -cne $before[$name]) {{ throw ('Value not restored: '+$name) }} }}
if ($null -ne $script:LocalAiOriginalEnvironment) {{ throw 'Restore did not clear snapshot' }}
[Environment]::SetEnvironmentVariable('QWEN_HOME','fixture-new-cycle','Process')
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
if ([object]::ReferenceEquals($first,$script:LocalAiOriginalEnvironment) -or $script:LocalAiOriginalEnvironment['QWEN_HOME'] -ne 'fixture-new-cycle') {{ throw 'Fresh cycle reused old snapshot' }}
Restore-LocalEnvironment
if ($env:QWEN_HOME -ne 'fixture-new-cycle') {{ throw 'Fresh cycle did not restore its caller' }}
"""
        for scope in ("script", "function"):
            with self.subTest(scope=scope):
                source = lifecycle if scope == "script" else "function Test-FunctionCaller {\n" + lifecycle + "\n}\nTest-FunctionCaller"
                self.powershell(source)
        self.assert_external_unchanged()

    def test_strict_environment_failures_preserve_caller_and_original_error(self) -> None:
        self.prepare_config()
        config = self.clone / ".localai" / "config" / "local.ps1"
        original_config = config.read_text()
        cases = (("config", "throw 'fixture config failure'", "fixture config failure", ""),
                 ("path", f"$QwenUserRoot={ps_quote(self.old)}", "Installation paths must remain", ""),
                 ("workspace", "", "working directory cannot safely", ""),
                 ("initialize", "", "initialization failed", "-Initialize"),
                 ("missing", "", "Local installation is missing", ""))
        for name, config_tail, error, arguments in cases:
            with self.subTest(failure=name):
                config.write_text(original_config + "\n" + config_tail, encoding="utf-8")
                if name == "missing":
                    config.unlink()
                self.powershell(f"""
Set-StrictMode -Version 2.0
$original=$env:USERPROFILE; $originalQwen=$env:QWEN_HOME
function python {{
 if ($args -contains 'check-workspace') {{
  $global:LASTEXITCODE={1 if name == 'workspace' else 0}
  {ps_quote(self.user)}
 }} else {{ $global:LASTEXITCODE=7 }}
}}
$failed=$false
try {{ . {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')} {arguments} }}
catch {{ if ($_.Exception.Message -notlike '*{error}*') {{ throw }}; $failed=$true }}
if (-not $failed -or $env:USERPROFILE -ne $original -or $env:QWEN_HOME -ne $originalQwen) {{ throw 'Failure changed caller environment' }}
if ($null -ne (Get-Command Restore-LocalEnvironment -ErrorAction SilentlyContinue)) {{ Restore-LocalEnvironment; Restore-LocalEnvironment }}
if ($null -ne $script:LocalAiOriginalEnvironment) {{ throw 'Failed load retained an active snapshot' }}
""")
        self.assert_external_unchanged()

    def test_strict_nested_script_owns_snapshot_without_changing_parent(self) -> None:
        self.prepare_config()
        child = self.base / "child owner.ps1"
        child.write_text(f"""
param($ParentSnapshot)
Set-StrictMode -Version 2.0
if ($null -ne (Get-Variable -Name LocalAiOriginalEnvironment -Scope Script -ErrorAction SilentlyContinue)) {{ throw 'Child inherited snapshot ownership' }}
$original=$env:USERPROFILE
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
if ([object]::ReferenceEquals($ParentSnapshot,$script:LocalAiOriginalEnvironment) -or $script:LocalAiOriginalEnvironment['USERPROFILE'] -ne $original) {{ throw 'Child snapshot does not own current caller values' }}
Restore-LocalEnvironment
Restore-LocalEnvironment
if ($env:USERPROFILE -ne $original) {{ throw 'Child restored parent original profile instead of scoped profile' }}
""", encoding="utf-8")
        self.powershell(f"""
Set-StrictMode -Version 2.0
$original=$env:USERPROFILE
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
$parentSnapshot=$script:LocalAiOriginalEnvironment
& {ps_quote(child)} -ParentSnapshot $parentSnapshot
if (-not [object]::ReferenceEquals($parentSnapshot,$script:LocalAiOriginalEnvironment) -or $env:USERPROFILE -ne {ps_quote(self.clone / '.localai' / 'home')}) {{ throw 'Child changed parent snapshot/environment' }}
Restore-LocalEnvironment
if ($env:USERPROFILE -ne $original) {{ throw 'Parent snapshot was lost' }}
""")
        self.assert_external_unchanged()

    def test_strict_benchmark_caller_reaches_isolated_missing_file_preflight(self) -> None:
        self.prepare_config()
        result = self.powershell(f"""
$original=$env:USERPROFILE
function python {{ {ps_quote(self.user)}; $global:LASTEXITCODE=0 }}
& {ps_quote(self.clone / 'benchmark' / 'benchmark_qwen.ps1')} -PreflightOnly
if ($env:USERPROFILE -ne $original) {{ throw 'Benchmark caller environment was not restored' }}
exit $LASTEXITCODE
""", check=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(" PREFLIGHT", result.stdout)
        self.assertIn("SERVER_EXE=MISSING", result.stdout)
        self.assertIn("MODEL=MISSING", result.stdout)
        self.assertIn("BENCHMARK_PREFLIGHT=FAIL", result.stdout)
        self.assertNotIn("LocalAiOriginalEnvironment", result.stderr)
        self.assert_external_unchanged()

    def test_nested_environment_loader_requires_original_locator(self) -> None:
        self.prepare_config()
        self.env["USERPROFILE"] = str(self.clone / ".localai" / "home")
        self.env.pop("LOCALAI_ORIGINAL_USERPROFILE", None)
        result = self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("LOCALAI_ORIGINAL_USERPROFILE is missing", result.stderr)

    def test_coding_precheck_failure_restores_direct_caller_environment(self) -> None:
        self.prepare_config()
        self.powershell(f"""
$original = $env:USERPROFILE
function python {{ if ($args -contains 'check-workspace') {{ $env:USERPROFILE }}; $global:LASTEXITCODE = 0 }}
$failed = $false
try {{ & {ps_quote(self.clone / 'scripts' / 'qwen.ps1')} }} catch {{ $failed = $true }}
if (-not $failed -or $env:USERPROFILE -ne $original) {{ throw 'Coding precheck leaked its scoped environment' }}
""")
        self.assert_external_unchanged()

    def test_patch_verify_failure_restores_direct_caller_environment(self) -> None:
        self.prepare_config()
        self.powershell(f"""
$original = $env:USERPROFILE
$failed = $false
try {{ & {ps_quote(self.clone / 'patches' / 'qwen_runtime_patches.ps1')} -VerifyOnly }} catch {{ $failed = $true }}
if (-not $failed -or $env:USERPROFILE -ne $original) {{ throw 'Patch verification leaked its scoped environment' }}
""")
        self.assert_external_unchanged()

    def test_standalone_registry_ignores_external_path_overrides(self) -> None:
        self.copy_sources()
        self.env["QWEN_HOME"] = str(self.old)
        self.env["ORCHESTRATION_ROOT"] = str(self.old)
        result = self.python("import project_identity as p; p.identify_project(); print(p.ORCHESTRATION_ROOT)")
        self.assertEqual(Path(result.stdout.strip()), self.clone / ".localai" / "orchestration")
        self.assert_external_unchanged()

    def test_original_profile_global_settings_do_not_own_external_project(self) -> None:
        self.copy_sources()
        global_settings = self.user / ".qwen" / "settings.json"
        global_settings.write_text('{"fixture":"historical"}', encoding="utf-8")
        result = self.python("import project_identity as p; print(p.identify_project().project_root)")
        self.assertEqual(Path(result.stdout.strip()), self.project)
        self.assertEqual(global_settings.read_text(), '{"fixture":"historical"}')
        self.assertEqual(list(self.project.iterdir()), [])

    def test_direct_environment_loader_rejects_junction_before_config_execution(self) -> None:
        self.copy_sources()
        state = self.clone / ".localai"
        state.mkdir()
        marker = self.base / "imported.txt"
        (self.old / "local.ps1").write_text(f"[IO.File]::WriteAllText({ps_quote(marker)}, 'imported')", encoding="utf-8")
        junction = state / "config"
        self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(self.old)} | Out-Null")
        self.addCleanup(lambda: os.rmdir(junction) if junction.exists() else None)
        result = self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Reparse points", result.stderr)
        self.assertFalse(marker.exists())

    def test_models_runtime_and_local_state_are_ignored(self) -> None:
        result = subprocess.run(
            ["git", "check-ignore", "--no-index", "models/fixture.gguf", "runtime/qwen-code/package.json", ".localai/install.json", "qwen.cmd"], cwd=REPO,
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.splitlines(), ["models/fixture.gguf", "runtime/qwen-code/package.json", ".localai/install.json"])

    def test_root_cmd_routes_coding_and_chat_with_cwd_arguments_and_exitcode(self) -> None:
        self.copy_sources()
        result_path = self.base / "route.txt"
        self.env["FIXTURE_ROUTE"] = str(result_path)
        for relative, mode in (("qwen.ps1", "coding"), ("qwen_chat.ps1", "chat")):
            (self.clone / "scripts" / relative).write_text(
                f"[IO.File]::WriteAllText($env:FIXTURE_ROUTE, ('{mode}|' + (Get-Location).Path + '|' + ($args -join '|')))\nexit 9\n",
                encoding="utf-8",
            )
        for arguments, expected in ((['argument with spaces', '--fixture'], "coding"), (["chat"], "chat")):
            command = '"' + str(self.clone / "qwen.cmd") + '" ' + subprocess.list2cmdline(arguments)
            result = subprocess.run(f'cmd.exe /d /s /c "{command}"', cwd=self.project, env=self.env,
                                    capture_output=True, text=True, timeout=15, check=False)
            self.assertEqual(result.returncode, 9, result.stdout + result.stderr)
            output = result_path.read_text()
            self.assertTrue(output.startswith(f"{expected}|{self.project}|"), output)
            if expected == "coding":
                self.assertTrue(output.endswith("argument with spaces|--fixture"), output)
        self.assert_external_unchanged()

    def test_foreign_ready_server_is_rejected_before_http(self) -> None:
        self.prepare_config()
        source = self.import_functions("scripts/qwen_server.ps1")
        self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
function Get-NetTCPConnection {{ [pscustomobject]@{{OwningProcess = 321}} }}
function Get-CimInstance {{ [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(self.old / 'llama-server.exe')};CommandLine='fixture'}} }}
$script:requests = 0
function Invoke-RestMethod {{ $script:requests++; throw 'Foreign HTTP request' }}
$rejected = $false
try {{ Invoke-QwenServerEnsure }} catch {{ $rejected = $_.Exception.Message -like '*another installation*' }}
if (-not $rejected -or $script:requests -ne 0) {{ throw 'Foreign listener was contacted/reused' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def server_fixture(self) -> tuple[Path, Path, str]:
        self.prepare_config()
        executable = self.clone / "runtime" / "llama.cpp" / "llama-server.exe"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(b"fixture")
        model = self.clone / "models" / "Qwen3.8-27B-UD-Q3_K_XL.gguf"
        model.parent.mkdir()
        model.write_bytes(b"fixture")
        preset = self.clone / ".localai" / "config" / "qwen_models.ini"
        preset.write_text("version = 1\n\n[qwen3.8-27b-chat]\nmodel = " + model.as_posix() +
                          "\nalias = qwen3.8-27b-local,qwen3.8-27b-algorithm,qwen3.8-27b-test\nload-on-startup = true\n", encoding="utf-8")
        command = subprocess.list2cmdline([str(executable), "--models-preset", str(preset),
            "--models-max", "1", "--host", "127.0.0.1", "--port", "8080", "--ctx-size", "40960",
            "--parallel", "1", "--n-gpu-layers", "99", "--fit", "off", "--spec-type", "draft-mtp,ngram-mod",
            "--spec-draft-n-max", "2", "--spec-draft-p-min", "0.025", "--spec-ngram-mod-n-min", "48",
            "--spec-ngram-mod-n-max", "64", "--spec-ngram-mod-n-match", "16", "--threads", "20",
            "--threads-batch", "20", "--spec-draft-threads", "20", "--spec-draft-threads-batch", "20",
            "--flash-attn", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0",
            "--batch-size", "1024", "--ubatch-size", "512", "--jinja", "--reasoning", "on",
            "--reasoning-effort", "xhigh", "--reasoning-budget", "-1", "--reasoning-preserve"])
        return executable, preset, command

    def test_same_executable_requires_exact_config_before_reuse_or_stop(self) -> None:
        executable, preset, command = self.server_fixture()
        source = self.import_functions("scripts/qwen_server.ps1")
        cases = [command.replace(str(preset), str(self.old / "qwen_models.ini")),
                 command.replace("--ctx-size 40960", "--ctx-size 8192"),
                 command.replace("--host 127.0.0.1", '--host"127.0.0.1"'),
                 command.replace("--host 127.0.0.1", "--HOST 127.0.0.1"),
                 command + ' --model "' + str(self.old / "wrong.gguf") + '"',
                 command + " --port 8080", command + " --alias wrong", ""]
        for action in ("Ensure", "Stop"):
            for candidate in cases:
                with self.subTest(action=action, command=candidate):
                    self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
function Get-NetTCPConnection {{ if ($script:stops -eq 0) {{ [pscustomobject]@{{OwningProcess=321}} }} }}
function Get-CimInstance {{ param($ClassName,$Filter); if ($Filter -like 'ParentProcessId*') {{ return }}; [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine={ps_quote(candidate)}}} }}
$script:requests=0; $script:stops=0; $rejected=$false
function Invoke-RestMethod {{ $script:requests++; [pscustomobject]@{{data=@([pscustomobject]@{{id='qwen3.8-27b-chat';aliases=@('qwen3.8-27b-local','qwen3.8-27b-algorithm','qwen3.8-27b-test')}})}} }}
function Stop-Process {{ $script:stops++ }}
try {{ Invoke-QwenServer{action} }} catch {{ $rejected=$true }}
if (-not $rejected -or $script:requests -ne 0 -or $script:stops -ne 0) {{ throw 'Unverified launch configuration was accepted' }}
Restore-LocalEnvironment
""")
        original = preset.read_text()
        preset.write_text(original.replace("Qwen3.8-27B-UD-Q3_K_XL.gguf", "wrong.gguf"), encoding="utf-8")
        self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
function Get-NetTCPConnection {{ [pscustomobject]@{{OwningProcess=321}} }}
function Get-CimInstance {{ [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine={ps_quote(command)}}} }}
$rejected=$false
try {{ Test-QwenLocalListener -HostAddress $ServerHost -Port $ServerPort -ExpectedExe $LlamaServerExe -ExpectedPreset {ps_quote(preset)} }} catch {{ $rejected=$true }}
if (-not $rejected) {{ throw 'Wrong model inside canonical preset was accepted' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_nested_native_state_redirects_fail_before_writer_launch(self) -> None:
        self.prepare_config()
        for relative in ("logs", "qwen/projects/session", "qwen/chat_ui/profile", "cache/node/deep", "tmp/deep", "benchmark/output/deep"):
            with self.subTest(relative=relative):
                junction = self.clone / ".localai" / relative
                junction.parent.mkdir(parents=True, exist_ok=True)
                self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(self.old)} | Out-Null")
                try:
                    result = self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}", check=False)
                    self.assertNotEqual(result.returncode, 0, "Nested state redirect passed preflight")
                    self.assertIn("Reparse", result.stderr)
                finally:
                    os.rmdir(junction)
        self.assert_external_unchanged()

    def test_verified_router_reuse_and_cli_chat_idle_shutdown(self) -> None:
        executable, preset, command = self.server_fixture()
        source = self.import_functions("scripts/qwen_server.ps1")
        self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$script:stops=0; $script:requests=0; $script:unloaded=$false
function Get-NetTCPConnection {{ if ($script:stops -eq 0) {{ [pscustomobject]@{{OwningProcess=321}} }} }}
function Get-CimInstance {{
 param($ClassName,$Filter)
 if ($Filter -like 'ParentProcessId*') {{ if (-not $script:unloaded) {{ [pscustomobject]@{{Name='llama-server.exe';ProcessId=322}} }}; return }}
 [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine={ps_quote(command)}}}
}}
function Invoke-RestMethod {{
 param($Uri,$Method,$Body)
 $script:requests++
 if ($Method -eq 'Post') {{
  if ($script:stops -ne 0 -or ($Body | ConvertFrom-Json).model -ne 'qwen3.8-27b-chat') {{ throw 'Wrong unload order/model' }}
  $script:unloaded=$true; return [pscustomobject]@{{success=$true}}
 }}
 [pscustomobject]@{{data=@([pscustomobject]@{{id='qwen3.8-27b-chat';aliases=@('qwen3.8-27b-local','qwen3.8-27b-algorithm','qwen3.8-27b-test')}})}}
}}
function Stop-Process {{ if (-not $script:unloaded) {{ throw 'Stop preceded unload' }}; $script:stops++ }}
Invoke-QwenServerEnsure
if ($script:requests -ne 1 -or $script:stops -ne 0) {{ throw 'Owned router reuse failed' }}
foreach ($kind in @('cli','chat','idle')) {{
 $script:requests=0; $stream=$null
 if ($kind -ne 'idle') {{
  $lease = if ($kind -eq 'cli') {{ Join-Path $QwenUserRoot 'runtime_clients\\cli\\fixture.lock' }} else {{ Join-Path $QwenUserRoot 'runtime_clients\\chat.lock' }}
  New-Item -ItemType Directory -Path (Split-Path $lease -Parent) -Force | Out-Null
  $stream=[IO.File]::Open($lease,'OpenOrCreate','ReadWrite','None')
 }}
 try {{ Invoke-QwenServerStop -IfIdle }} finally {{ if ($null -ne $stream) {{ $stream.Dispose(); Remove-Item -LiteralPath $lease }} }}
 if ($kind -ne 'idle' -and ($script:requests -ne 0 -or $script:stops -ne 0)) {{ throw 'Active client was unloaded/stopped' }}
}}
if ($script:requests -ne 1 -or $script:stops -ne 1) {{ throw 'Idle router did not unload then stop' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_verified_direct_model_legacy_mode_and_wrong_model_rejection(self) -> None:
        executable, preset, command = self.server_fixture()
        model = self.clone / "models" / "Qwen3.8-27B-UD-Q3_K_XL.gguf"
        direct = command.replace('--models-preset "' + str(preset) + '" --models-max 1',
                                 '--model "' + str(model) + '" --alias qwen3.8-27b-local')
        source = self.import_functions("scripts/qwen_server.ps1")
        for candidate, accepted in ((direct, True), (direct.replace(str(model), str(self.old / model.name)), False),
                                    (direct + ' -m "' + str(model) + '"', False)):
            self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$script:stopped=$false; $rejected=$false
function Get-NetTCPConnection {{ if (-not $script:stopped) {{ [pscustomobject]@{{OwningProcess=321}} }} }}
function Get-CimInstance {{ [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine={ps_quote(candidate)}}} }}
function Invoke-RestMethod {{ throw 'Legacy mode must not request router metadata/unload' }}
function Stop-Process {{ $script:stopped=$true }}
try {{ Invoke-QwenServerStop }} catch {{ $rejected=$true }}
if ($script:stopped -ne ${str(accepted).lower()} -or $rejected -eq ${str(accepted).lower()}) {{ throw 'Legacy identity validation failed' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_missing_cim_image_requires_independent_process_path(self) -> None:
        executable, preset, command = self.server_fixture()
        source = self.import_functions("scripts/qwen_server.ps1")
        for image, accepted in ((str(executable), True), (str(self.old / executable.name), False), ("", False)):
            self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
function Get-NetTCPConnection {{ [pscustomobject]@{{OwningProcess=321}} }}
function Get-CimInstance {{ [pscustomobject]@{{Name='llama-server.exe';ExecutablePath='';CommandLine={ps_quote(command)}}} }}
function Get-Process {{ [pscustomobject]@{{Path={ps_quote(image)}}} }}
$accepted=$false
try {{ $accepted=Test-QwenLocalListener -HostAddress $ServerHost -Port $ServerPort -ExpectedExe $LlamaServerExe -ExpectedPreset {ps_quote(preset)} }} catch {{ }}
if ($accepted -ne ${str(accepted).lower()}) {{ throw 'Command line spoof bypassed independent image identity' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_status_requires_owned_listener_before_http(self) -> None:
        executable, preset, command = self.server_fixture()
        source = self.import_functions("scripts/qwen_server.ps1")
        for owner, candidate, ready in ((False, command, False),
                                         (True, command.replace('--ctx-size 40960', '--ctx-size 8192'), False),
                                         (True, command, True)):
            self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
function Get-NetTCPConnection {{ if (${str(owner).lower()}) {{ [pscustomobject]@{{OwningProcess=321}} }} }}
function Get-CimInstance {{ [pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine={ps_quote(candidate)}}} }}
$script:requests=0
function Invoke-RestMethod {{ $script:requests++; [pscustomobject]@{{data=@([pscustomobject]@{{id='qwen3.8-27b-chat';aliases=@('qwen3.8-27b-local','qwen3.8-27b-algorithm','qwen3.8-27b-test')}})}} }}
$ready=Invoke-QwenServerStatus
if ($ready -ne ${str(ready).lower()} -or $script:requests -ne {int(ready)}) {{ throw 'Status contacted an unverified listener' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_server_paths_must_be_fully_qualified(self) -> None:
        executable, preset, command = self.server_fixture()
        model = self.clone / "models" / "Qwen3.8-27B-UD-Q3_K_XL.gguf"
        direct = command.replace('--models-preset "' + str(preset) + '" --models-max 1',
                                 '--model "' + str(model) + '" --alias qwen3.8-27b-local')
        candidates = [(command, True), (direct, True)]
        for original, path in ((command, executable), (command, preset), (direct, model)):
            for ambiguous in (str(path)[2:], path.drive + str(path)[3:]):
                candidates.append((original.replace(str(path), ambiguous), False))
        source = self.import_functions("scripts/qwen_server.ps1")
        cases = ',\n'.join(f"[pscustomobject]@{{Command={ps_quote(candidate)};Accept=${str(accepted).lower()}}}"
                            for candidate, accepted in candidates)
        self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
foreach ($case in @({cases})) {{
 $process=[pscustomobject]@{{Name='llama-server.exe';ExecutablePath={ps_quote(executable)};CommandLine=$case.Command}}
 $accepted=$false
 try {{ $mode=Get-QwenServerProcessMode -Process $process -ProcessId 321 -ExpectedExe $LlamaServerExe -ExpectedPreset {ps_quote(preset)}; $accepted=$mode -in @('Router','Legacy') }} catch {{ }}
 if ($accepted -ne $case.Accept) {{ throw ('Ambiguous drive-dependent server path accepted: '+$case.Command) }}
}}
if (-not (Test-QwenFullyQualifiedPath '\\\\fixture-server\\share\\path') -or
    (Test-QwenFullyQualifiedPath '\\path') -or (Test-QwenFullyQualifiedPath 'D:path')) {{ throw 'Fully qualified path grammar changed' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_patch_candidates_do_not_allocate_unchecked_temp_files(self) -> None:
        self.prepare_config()
        self.powershell(f"""
. {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile({ps_quote(self.clone / 'patches' / 'qwen_runtime_patches.ps1')},[ref]$tokens,[ref]$errors)
$env:TEMP={ps_quote(self.old)}; $env:TMP={ps_quote(self.old)}
function node {{ $global:LASTEXITCODE=1 }}
foreach ($name in @('localAiV4Tmp','localAiV42Tmp','localAiV43Tmp')) {{
 $assignment=@($ast.FindAll({{param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq ('$'+$name)}},$true))
 if ($assignment.Count -ne 1) {{ throw 'Temp allocation anchor is ambiguous' }}
 $statements=@($assignment[0].Parent.Statements)
 $index=[array]::IndexOf($statements,$assignment[0])
 if ($statements[$index+1] -isnot [Management.Automation.Language.TryStatementAst]) {{ throw 'Candidate cleanup anchor changed' }}
 $before=@(Get-ChildItem -LiteralPath {ps_quote(self.old)} -Force | Select-Object -ExpandProperty Name)
 foreach ($textName in @('localAiV4Text','localAiV42Text','localAiV43Text')) {{ Set-Variable -Name $textName -Value '// fixture' }}
 $failed=$false
 try {{ Invoke-Expression ($assignment[0].Extent.Text + "`n" + $statements[$index+1].Extent.Text) }} catch {{ $failed=$true }}
 if (-not $failed) {{ throw 'Candidate node failure did not propagate' }}
 $after=@(Get-ChildItem -LiteralPath {ps_quote(self.old)} -Force | Select-Object -ExpandProperty Name)
 if (($before -join '|') -cne ($after -join '|')) {{ throw 'Temporary file was created outside the clone before validation' }}
 $candidate=Get-Variable -Name $name -ValueOnly
 if (Test-Path -LiteralPath $candidate) {{ throw 'Failed candidate was not cleaned' }}
 if (-not $candidate.StartsWith({ps_quote(str(self.clone / '.localai' / 'tmp') + os.sep)})) {{ throw 'Candidate temp path was not clone-local' }}
}}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_dangling_state_junction_is_rejected_without_following_it(self) -> None:
        self.prepare_config()
        target = self.base / "disposable vanished target"
        target.mkdir()
        junction = self.clone / ".localai" / "dangling"
        self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(target)} | Out-Null")
        target.rmdir()
        try:
            result = self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Reparse", result.stderr)
            self.python(f"from local_paths import assert_local_tree; from pathlib import Path\n"
                        f"try: assert_local_tree(Path({str(junction)!r}))\n"
                        "except RuntimeError as error: assert 'Reparse' in str(error)\n"
                        "else: raise AssertionError('Dangling junction accepted')")
        finally:
            os.rmdir(junction)

    def test_direct_python_state_writers_refuse_nested_redirects(self) -> None:
        self.copy_sources()
        targets = {
            "memory/projects/fixture/algorithm_agent": "import memory_store as m; m._atomic_write(target / 'memory.md', 'blocked')",
            "state/fixture-session": "import workflow_state as w; w._atomic_write_json(target / 'fixture.json', {'fixture':True})",
            "logs": "import hook_dispatcher as h; h._log_error('fixture', RuntimeError('fixture'))",
        }
        for relative, action in targets.items():
            with self.subTest(relative=relative):
                junction = self.clone / ".localai" / "orchestration" / relative
                junction.parent.mkdir(parents=True, exist_ok=True)
                self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(self.old)} | Out-Null")
                try:
                    self.python(f"""
from pathlib import Path
target = Path({str(junction)!r})
try:
    {action}
except RuntimeError as error:
    assert 'Reparse' in str(error) or 'escapes' in str(error), error
else:
    raise AssertionError('Direct state writer accepted nested redirect')
""")
                    self.assertEqual([path.name for path in self.old.iterdir()], ['keep.txt'])
                finally:
                    os.rmdir(junction)

    def test_real_hook_entrypoint_refuses_redirected_memory_state_and_logs(self) -> None:
        self.copy_sources()
        # These fixtures live under the harness Git tree but emulate marker-free projects.
        identity_source = self.clone / "orchestration" / "project_identity.py"
        identity_source.write_text(identity_source.read_text() + "\n_find_git_root = lambda cwd: None\n", encoding="utf-8")
        project_id = self.python("import project_identity as p; print(p.identify_project().project_id)").stdout.strip()
        for relative, event in ((f"memory/projects/{project_id}/algorithm_agent", "SessionStart"),
                                ("state/fixture-session", "UserPromptSubmit"), ("logs", "PreToolUse")):
            junction = self.clone / ".localai" / "orchestration" / relative
            junction.parent.mkdir(parents=True, exist_ok=True)
            if junction.exists():
                shutil.rmtree(junction)
            self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(self.old)} | Out-Null")
            try:
                result = subprocess.run([sys.executable, "-B", str(self.clone / "orchestration" / "hook_dispatcher.py")],
                    input=json.dumps({"hook_event_name":event,"session_id":"fixture-session","cwd":str(self.project),
                                      "tool_name":"read_file","source":"startup","prompt":"fixture"}),
                    cwd=self.project, env=self.env, capture_output=True, text=True, timeout=15, check=False)
                self.assertEqual([path.name for path in self.old.iterdir()], ['keep.txt'], result.stdout + result.stderr)
            finally:
                os.rmdir(junction)
        self.assert_external_unchanged()

    def test_benchmark_checkpoint_guard_preserves_json_pipeline(self) -> None:
        self.prepare_config()
        checkpoint = self.clone / ".localai" / "benchmark" / "output" / "fixture-checkpoint.json"
        source = self.import_functions("benchmark/benchmark_qwen.ps1")
        self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$ScriptVersion='fixture'
$script:AgenticCheckpointPath={ps_quote(checkpoint)}
$script:AgenticCheckpointRunFingerprint='fixture-fingerprint'
$script:AdaptiveStressEvidence=@([pscustomobject]@{{Label='fixture';Count=1}})
Save-AgenticAutotuneCheckpoint -Completed $true
$saved=Get-Content -LiteralPath $script:AgenticCheckpointPath -Raw | ConvertFrom-Json
if ($saved.Schema -ne 1 -or $saved.RunFingerprint -ne 'fixture-fingerprint' -or
    -not $saved.Completed -or $saved.Evidence[0].Label -ne 'fixture') {{ throw 'Checkpoint JSON pipeline changed' }}
if (Test-Path -LiteralPath ($script:AgenticCheckpointPath + '.tmp')) {{ throw 'Checkpoint temporary file remained' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_proxy_snapshot_and_temporary_leaf_redirects_are_rejected(self) -> None:
        self.copy_sources()
        state = self.clone / ".localai" / "qwen" / "chat_ui" / "context-proxy"
        state.mkdir(parents=True)
        for name in ("snapshots.json", "snapshots.tmp"):
            junction = state / name
            self.powershell(f"New-Item -ItemType Junction -Path {ps_quote(junction)} -Target {ps_quote(self.old)} | Out-Null")
            try:
                source = f"""
import importlib.util
from pathlib import Path
spec=importlib.util.spec_from_file_location('proxy_fixture', {str(self.clone / 'scripts' / 'qwen_chat_context_proxy.py')!r})
proxy=importlib.util.module_from_spec(spec); spec.loader.exec_module(proxy)
try:
    store=proxy.SnapshotStore(Path({str(state / 'snapshots.json')!r}))
    store._save()
except RuntimeError as error:
    assert 'Reparse' in str(error), error
else:
    raise AssertionError('Proxy state redirect accepted')
"""
                self.python(source)
                self.assertEqual([path.name for path in self.old.iterdir()], ['keep.txt'])
            finally:
                os.rmdir(junction)

    def test_stop_fallback_requires_full_canonical_paths(self) -> None:
        executable, current_preset, command = self.server_fixture()
        source = self.import_functions("scripts/qwen_server.ps1")
        for preset, reject in ((self.old / "qwen_models.ini", True), (self.clone / ".localai" / "config" / "qwen_models.ini", False)):
            candidate = command.replace(str(current_preset), str(preset))
            self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$script:stopped = $false; $script:rejected = $false
function Get-NetTCPConnection {{ if (-not $script:stopped) {{ [pscustomobject]@{{OwningProcess = 321}} }} }}
function Get-CimInstance {{
    param($ClassName, $Filter)
    if ($Filter -like 'ParentProcessId*') {{ return }}
    [pscustomobject]@{{Name='llama-server.exe';ExecutablePath='';CommandLine={ps_quote(candidate)}}}
}}
function Get-Process {{ [pscustomobject]@{{Path={ps_quote(executable)}}} }}
function Stop-Process {{ $script:stopped = $true }}
function Invoke-RestMethod {{ throw 'No HTTP expected' }}
try {{ Invoke-QwenServerStop -IfIdle }} catch {{ $script:rejected = $true }}
if ($script:rejected -ne ${str(reject).lower()} -or $script:stopped -eq ${str(reject).lower()}) {{ throw 'Listener path identity failed' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_chat_foreign_or_missing_instance_is_rejected_before_http(self) -> None:
        self.prepare_config()
        state = self.clone / ".localai" / "qwen" / "chat_ui" / "context-proxy"
        state.mkdir(parents=True)
        instance = state / "instance.json"
        source = self.import_functions("scripts/qwen_chat.ps1")
        for present, foreign in ((False, False), (True, True), (True, False)):
            if present:
                instance.write_text('{"pid":701,"shutdown_token":"fixture-token"}', encoding="utf-8")
            else:
                instance.unlink(missing_ok=True)
            command = self.old / "proxy.py" if foreign else self.clone / "scripts" / "qwen_chat_context_proxy.py"
            self.powershell(f". {ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$ProxyInstancePath = {ps_quote(instance)}; $ProxyStateRoot = {ps_quote(state)}
$ContextProxy = {ps_quote(self.clone / 'scripts' / 'qwen_chat_context_proxy.py')}
$ProxyHealthUrl = 'http://fixture.invalid'; $script:requests = 0
function Get-NetTCPConnection {{ [pscustomobject]@{{OwningProcess = 701}} }}
function Get-CimInstance {{ [pscustomobject]@{{CommandLine='python "{command}" --state-root "{state}"'}} }}
function Invoke-RestMethod {{
    $script:requests++
    [pscustomobject]@{{status='ok';pid=701;listen_port=8081;backend_port=8080;model='qwen3.8-27b-chat';context_window=40960;soft_threshold=24888}}
}}
$health = Get-QwenChatProxyHealth
if ($script:requests -ne {int(present and not foreign)} -or ($null -ne $health) -ne ${str(present and not foreign).lower()}) {{ throw 'Chat ownership/HTTP ordering failed' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def test_updater_rejects_other_version_and_routes_check_to_local_helper(self) -> None:
        self.copy_sources()
        rejected = self.powershell(f"& {ps_quote(self.clone / 'scripts' / 'qwen_update.ps1')} -Version 0.22.4", check=False)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("pinned", rejected.stderr)
        result_path = self.base / "update-route.txt"
        result = self.powershell(f"""
function python {{
    [IO.File]::WriteAllText({ps_quote(result_path)}, ($args -join '|'))
    $global:LASTEXITCODE = 3
}}
& {ps_quote(self.clone / 'scripts' / 'qwen_update.ps1')} -CheckOnly
exit $LASTEXITCODE
""", check=False)
        self.assertEqual(result.returncode, 3)
        self.assertEqual(result_path.read_text(), f"-B|{self.clone / 'scripts' / 'install_local.py'}|check")
        self.assert_external_unchanged()

    def test_default_paths_are_bound_to_arbitrary_clone(self) -> None:
        self.copy_sources()
        result = self.powershell(f"""
. {ps_quote(self.clone / 'config' / 'local.example.ps1')}
@{{
    root = $QwenRoot; code = $QwenCodeRoot; llama = $LlamaCppRoot;
    model = $ModelPath; user = $QwenUserRoot; orchestration = $OrchestrationRoot
}} | ConvertTo-Json -Compress
""")
        paths = json.loads(result.stdout)
        self.assertEqual(Path(paths["root"]), self.clone)
        self.assertEqual(Path(paths["code"]), self.clone / "runtime" / "qwen-code")
        self.assertEqual(Path(paths["llama"]), self.clone / "runtime" / "llama.cpp")
        self.assertTrue(Path(paths["model"]).is_relative_to(self.clone / "models"))
        self.assertTrue(Path(paths["user"]).is_relative_to(self.clone / ".localai"))
        self.assertTrue(Path(paths["orchestration"]).is_relative_to(self.clone / ".localai"))
        self.assert_external_unchanged()


if __name__ == "__main__":
    unittest.main()
