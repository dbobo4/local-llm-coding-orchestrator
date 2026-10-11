"""Bounded benchmark preflight and runner checks with disposable Windows fixtures."""

from __future__ import annotations

import os
from pathlib import Path
import shutil

import test_local_installation as fixtures


MODES = {
    "PreflightOnly": "BENCHMARK_PREFLIGHT=PASS",
    "AgenticHarnessSelfTest": "AGENTIC_HARNESS_SELFTEST=PASS",
    "ReasoningGrowthSelfTest": "REASONING_GROWTH_SELFTEST=PASS",
    "OrchestrationEnduranceSelfTest": "ORCHESTRATION_ENDURANCE_SELFTEST=PASS",
}


class BenchmarkE2ETests(fixtures.FixtureTest):
    def setUp(self) -> None:
        super().setUp()
        fixtures.MigrationAcceptance.prepare_config(self)
        self.benchmark = self.clone / "benchmark" / "benchmark_qwen.ps1"
        self.launcher = self.clone / "scripts" / "qwen_server.ps1"
        self.original_launcher = self.launcher.read_text()
        settings = self.clone / ".localai" / "qwen" / "settings.json"
        settings.parent.mkdir(parents=True)
        shutil.copy2(self.clone / "config" / "settings.example.json", settings)
        (self.clone / ".localai" / "tmp").mkdir()
        for relative in ("runtime/llama.cpp/llama-server.exe", "runtime/qwen-code/bin/qwen.cmd",
                         "models/Qwen3.8-27B-UD-Q3_K_XL.gguf"):
            path = self.clone / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"inert fixture")
        help_stub = self.base / "llama help stub.ps1"
        help_calls = self.clone / ".localai" / "help-calls.txt"
        help_stub.write_text(f"""
if ($args.Count -ne 1 -or $args[0] -ne '--help') {{ throw 'Native execution is forbidden' }}
Add-Content -LiteralPath {fixtures.ps_quote(help_calls)} -Value '--help'
'--model --alias --models-preset --models-max --ctx-size --spec-type --spec-draft-n-max --spec-draft-p-min --spec-ngram-mod-n-min --spec-ngram-mod-n-max --spec-ngram-mod-n-match --cache-type-k --cache-type-v --batch-size --ubatch-size --reasoning-effort'
""", encoding="utf-8")
        # Only the disposable benchmark copy substitutes external dependencies.
        source = self.benchmark.read_text().replace(
            "$ServerExe = $LlamaServerExe",
            f"$ServerExe = {fixtures.ps_quote(help_stub)}\nfunction Get-NetTCPConnection {{ }}",
        )
        self.benchmark.write_text(source, encoding="utf-8")
        self.runner = self.clone / "scripts" / "test_local_e2e.ps1"
        if (fixtures.REPO / "scripts" / "test_local_e2e.ps1").is_file():
            shutil.copy2(fixtures.REPO / "scripts" / "test_local_e2e.ps1", self.runner)

    def test_current_shared_array_preflight_and_real_selftest_bodies(self) -> None:
        result = self.powershell(f"& {fixtures.ps_quote(self.runner)}\nexit $LASTEXITCODE", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines().count('AUTOMATED_E2E_SELFTESTS=PASS'), 1)
        for mode, marker in MODES.items():
            with self.subTest(mode=mode):
                log = next((self.clone / '.localai' / 'logs').rglob(mode + '.stdout.log'))
                self.assertEqual(log.read_text().splitlines().count(marker), 1)
        prefixes = ('qwen-agentic-harness-selftest-', 'qwen-settings-selftest-', 'qwen-orchestration-endurance-selftest-')
        self.assertEqual([path.name for path in (self.clone / '.localai' / 'tmp').iterdir()
                          if path.name.startswith(prefixes)], [])
        self.assert_external_unchanged()

    def test_source_flags_and_invocation_linkage_fail_closed(self) -> None:
        mutations = (
            ("missing", "'--parallel', '1', ", ""),
            ("duplicate", "'--parallel', '1'", "'--parallel', '1', '--parallel', '1'"),
            ("fixed value", "'--threads', '20'", "'--threads', '19'"),
            ("config value", "[string]$ContextWindowSize, '--parallel'", "'8192', '--parallel'"),
            ("cache value", "'--cache-type-k', $CacheTypeK", "'--cache-type-k', 'q4_0'"),
            ("missing switch", "'--jinja', ", ""),
            ("wrong array", "& $ServerExe @ServerArguments", "& $ServerExe @OtherArguments"),
            ("array mutation", "& $ServerExe @ServerArguments", "$ServerArguments += '--jinja'\n    & $ServerExe @ServerArguments"),
            ("wrong builder branch", "@(Get-QwenServerArguments)", "@(Get-QwenServerArguments -Legacy)"),
            ("config mutation", "$ServerArguments = @(Get-QwenServerArguments)", "$ServerHost = '0.0.0.0'\n    $ServerArguments = @(Get-QwenServerArguments)"),
            ("scoped executable mutation", "$ServerArguments = @(Get-QwenServerArguments)", "$local:ServerExe = 'other.exe'\n    $ServerArguments = @(Get-QwenServerArguments)"),
            ("scoped config mutation", "$ServerArguments = @(Get-QwenServerArguments)", "$local:ServerHost = '0.0.0.0'\n    $ServerArguments = @(Get-QwenServerArguments)"),
            ("scoped root mutation", "$ServerArguments = @(Get-QwenServerArguments)", "$local:RepoRoot = 'other-root'\n    $ServerArguments = @(Get-QwenServerArguments)"),
            ("defaults guard reversed", "$null -eq (Get-Variable -Name $Entry.Key", "$null -ne (Get-Variable -Name $Entry.Key"),
            ("fallback default changed", "ContextWindowSize = 40960", "ContextWindowSize = 8192"),
            ("fallback literal whitespace", 'CacheTypeK = "q8_0"', 'CacheTypeK = "q8_ 0"'),
            ("fallback probability whitespace", 'SpecDraftPMin = "0.025"', 'SpecDraftPMin = "0. 025"'),
            ("preset literal whitespace", "'.localai\\config\\qwen_models.ini'", "'.localai\\ config\\qwen_models.ini'"),
            ("loader literal whitespace", '"scripts\\local_environment.ps1"', '"scripts\\ local_environment.ps1"'),
            ("root compound assignment", "$RepoRoot = Split-Path $PSScriptRoot -Parent", "$RepoRoot += Split-Path $PSScriptRoot -Parent"),
            ("builder compound assignment", "$modelArguments = if ($Legacy)", "$modelArguments += if ($Legacy)"),
            ("defaults compound assignment", "$BenchmarkDefaults = [ordered]", "$BenchmarkDefaults += [ordered]"),
            ("different configuration", '. (Join-Path $RepoRoot "scripts\\local_environment.ps1")', '. (Join-Path $RepoRoot "scripts\\other_config.ps1")'),
            ("unknown builder", "return $modelArguments + @(", "return $(Write-Output '--bad') + @("),
        )
        source = f"""
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile({fixtures.ps_quote(self.benchmark)},[ref]$tokens,[ref]$errors)
foreach ($function in $ast.FindAll({{param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $n.Name -in @('Test-BenchmarkJoinPathAst','Resolve-BenchmarkArgumentAst','Get-BenchmarkServerOptions')}},$true)) {{
    Invoke-Expression $function.Extent.Text
}}
"""
        for label, old, new in mutations:
            with self.subTest(label=label):
                self.assertIn(old, self.original_launcher)
                self.launcher.write_text(self.original_launcher.replace(old, new), encoding="utf-8")
                self.powershell(f". {fixtures.ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}\n" + source + f"""
$rejected=$false
try {{ Get-BenchmarkServerOptions -Text ([IO.File]::ReadAllText({fixtures.ps_quote(self.launcher)})) | Out-Null }} catch {{ $rejected=$true }}
if (-not $rejected) {{ throw 'Unverified server source was accepted' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()

    def write_child_stub(self, output: str, exitcode: int = 0) -> Path:
        trace = self.clone / ".localai" / "children.txt"
        cases = "\n".join(f"'{mode}' {{ {fixtures.ps_quote(marker)} }}" for mode, marker in MODES.items())
        self.benchmark.write_text(f"""
param([switch]$PreflightOnly,[switch]$AgenticHarnessSelfTest,[switch]$ReasoningGrowthSelfTest,[switch]$OrchestrationEnduranceSelfTest)
$modes=@('PreflightOnly','AgenticHarnessSelfTest','ReasoningGrowthSelfTest','OrchestrationEnduranceSelfTest')
$selected=@($modes | Where-Object {{ (Get-Variable -Name $_ -ValueOnly).IsPresent }})
if ($selected.Count -ne 1) {{ throw 'Exactly one safe mode is required' }}
$mode=$selected[0]
Add-Content -LiteralPath {fixtures.ps_quote(trace)} -Value ($mode+'|'+$PID)
$marker=switch ($mode) {{ {cases} }}
if ($mode -eq 'PreflightOnly') {{
 {output}
 exit {exitcode}
}}
'normal diagnostic'
$marker
exit 0
""", encoding="utf-8")
        return trace

    def test_runner_uses_four_separate_children_and_saved_logs(self) -> None:
        trace = self.write_child_stub("'normal diagnostic'; [Console]::Error.WriteLine('stderr diagnostic'); $marker")
        result = self.powershell(f"& {fixtures.ps_quote(self.runner)}\nexit $LASTEXITCODE", check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout.splitlines().count("AUTOMATED_E2E_SELFTESTS=PASS"), 1)
        calls = [line.split('|') for line in trace.read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], list(MODES))
        self.assertEqual(len({call[1] for call in calls}), 4)
        logs = self.clone / ".localai" / "logs"
        self.assertEqual(len(list(logs.rglob("*.stdout.log"))), 4)
        self.assertEqual(len(list(logs.rglob("*.stderr.log"))), 4)
        stderr = next(logs.rglob('PreflightOnly.stderr.log')).read_text()
        self.assertIn('stderr diagnostic', stderr)
        self.assert_external_unchanged()

    def test_runner_rejects_redirected_logs_before_starting_children(self) -> None:
        trace = self.write_child_stub('$marker')
        logs = self.clone / '.localai' / 'logs'
        self.powershell(f"New-Item -ItemType Junction -Path {fixtures.ps_quote(logs)} -Target {fixtures.ps_quote(self.old)} | Out-Null")
        try:
            result = self.powershell(f"& {fixtures.ps_quote(self.runner)}\nexit $LASTEXITCODE", check=False)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('Reparse', result.stderr)
            self.assertFalse(trace.exists())
            self.assert_external_unchanged()
        finally:
            os.rmdir(logs)

    def test_runner_stops_on_failed_or_ambiguous_result(self) -> None:
        for output, exitcode in (("$marker", 7), ("'diagnostic only'", 0),
                                 ("'prefix '+$marker", 0), ("$marker+' suffix'", 0),
                                 ("$marker; $marker", 0), ("$marker; 'BENCHMARK_PREFLIGHT=FAIL'", 0)):
            with self.subTest(output=output, exitcode=exitcode):
                trace = self.write_child_stub(output, exitcode)
                trace.unlink(missing_ok=True)
                result = self.powershell(f"& {fixtures.ps_quote(self.runner)}\nexit $LASTEXITCODE", check=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("AUTOMATED_E2E_SELFTESTS=PASS", result.stdout.splitlines())
                self.assertEqual(len(trace.read_text().splitlines()), 1)
        self.assert_external_unchanged()

    def test_runner_missing_exit_code_stays_failed(self) -> None:
        result = self.powershell(f"""
$script:starts=0
function Start-Process {{
 param($FilePath,$ArgumentList,$WorkingDirectory,$WindowStyle,[switch]$Wait,[switch]$PassThru,$RedirectStandardOutput,$RedirectStandardError)
 $script:starts++
 [IO.File]::WriteAllText($RedirectStandardOutput,'BENCHMARK_PREFLIGHT=PASS')
 [IO.File]::WriteAllText($RedirectStandardError,'')
 $process=[pscustomobject]@{{ExitCode=$null}}
 $process | Add-Member -MemberType ScriptMethod -Name Refresh -Value {{ }}
 return $process
}}
& {fixtures.ps_quote(self.runner)}
if ($script:starts -ne 1 -or $LASTEXITCODE -ne 1) {{ throw 'Unavailable exit code was accepted' }}
exit $LASTEXITCODE
""", check=False)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertNotIn('AUTOMATED_E2E_SELFTESTS=PASS', result.stdout.splitlines())
        self.assert_external_unchanged()

    def test_runner_argument_failure_preserves_parent_snapshot(self) -> None:
        self.powershell(f"""
. {fixtures.ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
$parent=$script:LocalAiOriginalEnvironment; $profile=$env:USERPROFILE
& {fixtures.ps_quote(self.runner)} -Unexpected
if ($LASTEXITCODE -ne 1 -or -not [object]::ReferenceEquals($parent,$script:LocalAiOriginalEnvironment) -or $env:USERPROFILE -ne $profile) {{ throw 'Runner argument failure restored the parent snapshot' }}
Restore-LocalEnvironment
""")
        self.assert_external_unchanged()
