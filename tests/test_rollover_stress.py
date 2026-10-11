"""Finite rollover scheduling and evidence checks; no inference/model execution."""

from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

import test_local_installation as fixtures


class RolloverStressTests(fixtures.FixtureTest):
    def setUp(self) -> None:
        super().setUp()
        fixtures.MigrationAcceptance.prepare_config(self)
        settings = self.clone / '.localai' / 'qwen' / 'settings.json'
        settings.parent.mkdir(parents=True)
        shutil.copy2(self.clone / 'config' / 'settings.example.json', settings)
        (self.clone / '.localai' / 'tmp').mkdir()

    def run_stress(self, **scenario):
        values = dict(compaction=5, rollover=8, required=True, completed=True,
                      failed_turn=0, retention=True, usage='logs', safety='',
                      repeat_turn=0, recall_rollover=False, recall_safety='', safety_turn=0,
                      same_turn_repeat=False, historical=False, silent_turn=0,
                      reply='valid', reply_turn=0, silent_retention=False, retention_reply='valid')
        values.update(scenario)
        trace = self.base / 'stress trace.json'
        benchmark = self.clone / 'benchmark' / 'benchmark_qwen.ps1'
        source = rf"""
Set-StrictMode -Version 2.0
. {fixtures.ps_quote(self.clone / 'scripts' / 'local_environment.ps1')}
$SettingsPath=Join-Path $QwenUserRoot 'settings.json'
$scenario=ConvertFrom-Json {fixtures.ps_quote(json.dumps(values))}
$script:turn=0; $script:recalls=0; $script:stops=0; $script:cleanups=0; $script:apiResponses=0
$script:trace=New-Object 'Collections.Generic.List[object]'
$script:sentinels=New-Object 'Collections.Generic.List[string]'
$script:stateFile=Join-Path $env:TEMP ('fake-rollover-'+[Guid]::NewGuid().ToString('N')+'.jsonl')
$ConfirmPromptReasoningBudget=0; $ConfirmAlgorithmReasoningBudget=0
$ConfirmTestReasoningBudget=0; $ConfirmGrowthBudget=0
$Port=18080; $ServerExe=Join-Path $RepoRoot 'inert server.exe'
$QwenCodeCli='Invoke-FixtureQwen'; $ModelAlias='fixture-model'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile({fixtures.ps_quote(benchmark)},[ref]$tokens,[ref]$errors)
$names=@('Get-ContextLifecycleDigest','New-ContextLifecyclePacket','New-ContextLifecyclePendingPressurePacket',
 'New-ContextLifecycleRecallPrompt','Get-ContextLifecycleRolloverMechanismContext',
 'Get-ContextLifecycleRolloverEvidence','Get-ContextLifecycleCumulativeMetrics','Get-ContextLifecycleOpenAiAudit','Get-ContextLifecycleTurnUsage',
 'Get-ContextLifecycleOpenAiCompactionEvents','Convert-ContextLifecycleAuditValue','Get-ObjectPropertyValue',
 'Get-ContextLifecycleCliProof','Invoke-ContextLifecycleRolloverStress')
foreach ($f in $ast.FindAll({{param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -in $names}},$true)) {{ Invoke-Expression $f.Extent.Text }}
function Assert-BenchmarkIdle {{ }}
function Test-PortListener {{ return $false }}
function New-AgenticConfirmationConfig {{ param($Parameters,$PromptBudget,$AlgorithmBudget,$TestBudget,$GrowthBudget); return $Parameters.Clone() }}
function Get-QwenJsonlSnapshot {{ return @{{}} }}
function Get-QwenProjectDirectorySnapshot {{ return @{{}} }}
function Get-ChangedQwenJsonlFiles {{ param($Before); if (Test-Path -LiteralPath $script:stateFile) {{ return Get-Item -LiteralPath $script:stateFile }}; return @() }}
function Remove-NewQwenProjectDirectories {{ param($Before); $script:cleanups++; [IO.File]::Delete($script:stateFile) }}
function Write-ContextLifecycleBenchmarkWorkspace {{ param($Path,$Parameters); Assert-LocalPath $Path; New-Item -ItemType Directory -Path $Path | Out-Null }}
function Get-BenchmarkRouterArgumentLine {{ param($Parameters); return '--fixture-only' }}
function Start-Process {{ param($FilePath,$ArgumentList,$WorkingDirectory,$RedirectStandardOutput,$RedirectStandardError,$WindowStyle,[switch]$PassThru)
 if ($FilePath -ne $ServerExe -or $ArgumentList -ne '--fixture-only') {{ throw 'Unexpected native invocation' }}
 return [pscustomobject]@{{Id=-1}}
}}
function Wait-BenchmarkRouterReady {{ param($Process) }}
function Stop-BenchmarkRouterProcess {{ param($Process); $script:stops++ }}
function Start-Sleep {{ param($Milliseconds) }}
function Get-RoleAwareTelemetrySummary {{ param($Files)
 $safetyActive=($scenario.safety_turn -eq 0 -or $script:turn -ge $scenario.safety_turn)
 return [pscustomobject]@{{
  ApiResponses=$script:apiResponses
  ContextRolloverRequiredCount=([int]($scenario.required -and $scenario.rollover -gt 0 -and $script:turn -ge $scenario.rollover)+[int]($scenario.repeat_turn -gt 0 -and $script:turn -ge $scenario.repeat_turn)+[int]($scenario.recall_rollover -and $script:recalls -gt 0))
  ContextRolloverCompletedCount=([int]($scenario.completed -and $scenario.rollover -gt 0 -and $script:turn -ge $scenario.rollover)+[int]($scenario.repeat_turn -gt 0 -and $script:turn -ge $scenario.repeat_turn)+[int]($scenario.recall_rollover -and $script:recalls -gt 0))
  MaxTokensCount=[int](($scenario.safety -eq 'max_tokens' -and $safetyActive) -or ($scenario.recall_safety -eq 'max_tokens' -and $script:recalls -gt 0))
  NoVisibleProgressCount=[int](($scenario.safety -eq 'no_progress' -and $safetyActive) -or ($scenario.recall_safety -eq 'no_progress' -and $script:recalls -gt 0))
  ToolCalls=[int](($scenario.safety -eq 'tools' -and $safetyActive) -or ($scenario.recall_safety -eq 'tools' -and $script:recalls -gt 0))
 }}
}}
function Write-FixtureReply {{ param($text,$mode,$session,$prompt)
 $assistant=@{{type='assistant';session_id=$session;parent_tool_use_id=$null;message=@{{role='assistant';model=$ModelAlias;content=@(@{{type='text';text=$text}})}}}}
 $result=@{{type='result';session_id=$session;subtype='success';is_error=$false;num_turns=1;result=$text}}
 if ($scenario.usage -ne 'none') {{ $result.usage=@{{input_tokens=99000;output_tokens=700}} }}
 switch ($mode) {{
  'empty' {{ $assistant.message.content[0].text=''; $result.result='' }}
  'wrong_ack' {{ $assistant.message.content[0].text='ACK WRONG'; $result.result='ACK WRONG' }}
  'stream_error' {{ $assistant.message.content[0].text='maximum context length exceeded'; $result.result='maximum context length exceeded' }}
  'error' {{ $result.subtype='error_during_execution'; $result.is_error=$true; $result.error=@{{message='maximum context length exceeded'}} }}
  'malformed' {{ $result.is_error='false' }}
  'zero_turns' {{ $result.num_turns=0 }}
  'result_mismatch' {{ $result.result='old transcript' }}
  'assistant_session_array' {{ $assistant.session_id=@($session) }}
  'assistant_role_array' {{ $assistant.message.role=@('assistant') }}
  'assistant_model_array' {{ $assistant.message.model=@($ModelAlias) }}
  'result_session_array' {{ $result.session_id=@($session) }}
  'result_type_array' {{ $result.type=@('result') }}
  'result_error_array' {{ $result.is_error=@($false) }}
  'result_num_array' {{ $result.num_turns=@(1) }}
  'result_text_array' {{ $result.result=@($text) }}
  'wrong_session' {{ $assistant.session_id='other-session' }}
  'subagent' {{ $assistant.parent_tool_use_id='agent-tool' }}
 }}
 if ($mode -eq 'assistant_after_result') {{ $result | ConvertTo-Json -Depth 6 -Compress; $assistant | ConvertTo-Json -Depth 6 -Compress; return }}
 if ($mode -eq 'user_echo') {{ @{{type='user';session_id=$session;message=@{{role='user';content=@(@{{type='text';text=$prompt}})}}}} | ConvertTo-Json -Depth 6 -Compress }}
 else {{ $assistant | ConvertTo-Json -Depth 6 -Compress }}
 if ($mode -eq 'broken_json') {{ '{{"type":"result"' }}
 elseif ($mode -ne 'missing_result') {{ $result | ConvertTo-Json -Depth 6 -Compress }}
 if ($mode -eq 'multiple_results') {{ $result | ConvertTo-Json -Depth 6 -Compress }}
}}
function Invoke-FixtureQwen {{
 $prompt=$input -join "`n"
 $logDir=[string]$args[([Array]::IndexOf($args,'--openai-logging-dir')+1)]
 if ($args[([Array]::IndexOf($args,'--max-tool-calls')+1)] -ne '0') {{ throw 'Tools were allowed' }}
 $sessionFlag=if ($args -contains '--session-id') {{ '--session-id' }} else {{ '--resume' }}
 $session=[string]$args[([Array]::IndexOf($args,$sessionFlag)+1)]
 if ($logDir.EndsWith('openai-rollover-recall')) {{
  $script:recalls++; $global:LASTEXITCODE=0
  if (-not $scenario.silent_retention) {{ $script:apiResponses++; [IO.File]::WriteAllText((Join-Path $logDir 'request.json'),'{{"messages":[]}}') }}
  $reply=if ($scenario.retention) {{ $script:sentinels.ToArray() -join "`n" }} else {{ 'missing retention' }}
  Write-FixtureReply $reply $scenario.retention_reply $session $prompt
  if ($scenario.recall_rollover) {{ '[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=8; history_entries=7' }}
  return
 }}
 $script:turn++
 $requestMade=$script:turn -ne $scenario.silent_turn
 if ($requestMade) {{ $script:apiResponses++ }}
 $sentinel=[regex]::Match($prompt,'KEEP_T\d+=INV-[A-F0-9]+').Value
 if ([string]::IsNullOrEmpty($sentinel)) {{ throw 'Actual packet was not supplied' }}
 [void]$script:sentinels.Add($sentinel)
 $pressure=$prompt.Contains('OPAQUE_PENDING_PAYLOAD_BEGIN')
 [void]$script:trace.Add([pscustomobject]@{{turn=$script:turn; pressure=$pressure; chars=$prompt.Length; logDir=$logDir}})
 if ($requestMade -and $script:turn -eq $scenario.compaction) {{
  [IO.File]::WriteAllText((Join-Path $logDir 'compaction.json'),'{{"messages":[{{"content":"Produce the compact <state_snapshot> XML directly"}}],"usage":{{"prompt_tokens":21000,"completion_tokens":500}}}}')
 }}
 if ($requestMade -and $scenario.usage -eq 'logs') {{
  [IO.File]::WriteAllText((Join-Path $logDir 'normal.json'),'{{"messages":[],"usage":{{"prompt_tokens":12345,"completion_tokens":17}}}}')
 }}
 if ($requestMade -and $scenario.usage -eq 'partial') {{ [IO.File]::WriteAllText((Join-Path $logDir 'normal.json'),'{{"usage":{{"prompt_tokens":12345}}}}') }}
 $mode=if ($scenario.reply_turn -eq 0 -or $scenario.reply_turn -eq $script:turn) {{ $scenario.reply }} else {{ 'valid' }}
 Write-FixtureReply ('ACK T'+$script:turn.ToString('D2')+' '+$sentinel) $mode $session $prompt
 if ($script:turn -eq $scenario.rollover -or $script:turn -eq $scenario.repeat_turn) {{
  if ($scenario.historical) {{ [IO.File]::WriteAllText($script:stateFile,"LOCALAI_CONTEXT_ROLLOVER_REQUIRED: reason=max_compaction_passes; prompt_id=fixture; before=24000; after=23000; safe_target=22000; passes=8`n[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=8; history_entries=7") }}
  if ($scenario.required) {{ 'LOCALAI_CONTEXT_ROLLOVER_REQUIRED: reason=max_compaction_passes; prompt_id=fixture; before=24000; after=23000; safe_target=22000; passes=8' }}
  if ($scenario.completed) {{ '[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=8; history_entries=7' }}
  if ($scenario.same_turn_repeat) {{
   'LOCALAI_CONTEXT_ROLLOVER_REQUIRED: reason=max_compaction_passes; prompt_id=fixture-2; before=24000; after=23000; safe_target=22000; passes=8'
   '[LOCALAI_CONTEXT_ROLLOVER_V4] same-session fresh-chat rollover completed; passes=8; history_entries=9'
  }}
 }}
 $global:LASTEXITCODE=if ($script:turn -eq $scenario.failed_turn) {{ 7 }} else {{ 0 }}
}}
$failure=$null
try {{ Invoke-ContextLifecycleRolloverStress -Parameters @{{'ctx-size'='40960';'prompt-reasoning-budget'='4608';'algorithm-reasoning-budget'='6144';'test-reasoning-budget'='6144';'max-context-growth-tokens-per-turn'='24576'}} }}
catch {{ $failure=$_.Exception.Message }}
[IO.File]::WriteAllText({fixtures.ps_quote(trace)},(ConvertTo-Json -Depth 5 -InputObject @{{turns=$script:trace.ToArray();recalls=$script:recalls;stops=$script:stops;cleanups=$script:cleanups;failure=$failure}}))
Restore-LocalEnvironment
"""
        result = self.powershell(source)
        data = json.loads(trace.read_text())
        self.assertEqual(data['stops'], 1)
        self.assertEqual(data['cleanups'], 1)
        self.assertLessEqual(len(data['turns']), 12)
        self.assertLessEqual(data['recalls'], 1)
        self.assertEqual(list((self.clone / '.localai' / 'tmp').glob('qwen-context-rollover-*')), [])
        self.assert_external_unchanged()
        return result.stdout, data

    def test_late_compaction_reserves_three_pressure_and_two_continuation_turns(self):
        for compaction in (5, 7):
            with self.subTest(compaction=compaction):
                output, data = self.run_stress(compaction=compaction, rollover=compaction + 3)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)
                self.assertIsNone(data['failure'])
                self.assertEqual(len(data['turns']), compaction + 5)
                pressure = [turn for turn in data['turns'] if turn['pressure']]
                self.assertEqual([turn['turn'] for turn in pressure], list(range(compaction + 1, compaction + 4)))
                self.assertTrue(29000 < pressure[0]['chars'] < 30000)
                self.assertTrue(36000 < pressure[1]['chars'] < 38000)
                self.assertTrue(44000 < pressure[2]['chars'] < 45000)
                self.assertEqual(data['recalls'], 1)
                self.assertIn('POST_ROLLOVER_TURNS=2', output)

    def test_early_rollover_stops_pressure_and_runs_two_subsequent_turns(self):
        for historical in (False, True):
            with self.subTest(historical=historical):
                output, data = self.run_stress(compaction=5, rollover=6, historical=historical)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)
                self.assertEqual([t['turn'] for t in data['turns'] if t['pressure']], [6])
                self.assertEqual(len(data['turns']), 8)
                self.assertTrue(all(t['chars'] < 2000 for t in data['turns'][-2:]))

    def test_exhausted_discovery_or_pressure_reports_not_exercised(self):
        for compaction, count, reason in ((0, 7, 'FIRST_COMPACTION_NOT_OBSERVED'),
                                          (5, 8, 'PENDING_PRESSURE_LIMIT_REACHED'),
                                          (7, 10, 'PENDING_PRESSURE_LIMIT_REACHED')):
            with self.subTest(compaction=compaction):
                output, data = self.run_stress(compaction=compaction, rollover=0)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=NOT_EXERCISED', output)
                self.assertIn('NOT_EXERCISED_REASON=' + reason, output)
                self.assertEqual(len(data['turns']), count)
                self.assertEqual(data['recalls'], 0)
                self.assertNotIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)

    def test_missing_evidence_continuation_or_retention_never_passes(self):
        cases = (({'required': False}, 'ROLLOVER_REQUIRED_EVIDENCE_MISSING'),
                 ({'completed': False}, 'ROLLOVER_REQUIRED_WITHOUT_COMPLETION'),
                 ({'failed_turn': 9}, 'QWEN_EXIT_CODE_7_TURN_9'),
                 ({'failed_turn': 10}, 'QWEN_EXIT_CODE_7_TURN_10'),
                 ({'retention': False}, 'RETENTION_SENTINELS_MISSING'))
        for scenario, reason in cases:
            with self.subTest(scenario=scenario):
                output, data = self.run_stress(**scenario)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=' + reason, output)
                self.assertNotIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)
                self.assertIsNotNone(data['failure'])
                if 'failed_turn' in scenario:
                    self.assertIn('request_evidence=FRESH_OPENAI_REQUEST_LOG api_response_delta=UNKNOWN', output)
                    self.assertNotIn('QWEN OUTPUT TAIL', output)

    def test_usage_diagnostics_distinguish_logged_cumulative_and_missing_tokens(self):
        for usage, source in (('logs', 'OPENAI_LOG_MAX_PER_REQUEST'),
                              ('partial', 'OPENAI_LOG_MAX_PER_REQUEST'),
                              ('stream', 'QWEN_STREAM_MAX_CUMULATIVE_ONLY'), ('none', 'MISSING')):
            with self.subTest(usage=usage):
                output, data = self.run_stress(compaction=1, rollover=2, usage=usage)
                lines = [line for line in output.splitlines() if line.startswith('ROLLOVER_TURN index=2 ')]
                self.assertEqual(len(lines), 1)
                self.assertIn('phase=PENDING_PRESSURE', lines[0])
                self.assertIn('usage_source=' + source, lines[0])
                expected = '12345' if usage in ('logs', 'partial') else 'NA'
                self.assertIn('prompt_tokens=' + expected, lines[0])
                if usage == 'partial':
                    self.assertIn('usage_status=PARTIAL', lines[0])
                    self.assertIn(' completion_tokens=NA ', lines[0])
                if usage in ('stream', 'none'):
                    self.assertIn('usage_status=MISSING', lines[0])
                if usage != 'none':
                    self.assertIn('cli_cumulative_prompt_tokens=99000', lines[0])
                self.assertIn('EXECUTED_STRESS_TURNS=4', output)
                self.assertIn('ROLLOVER_REQUIRED_TOKEN_SOURCE=RUNTIME_EFFECTIVE_CONTEXT_ESTIMATE', output)
                self.assertIn('EXECUTED_RETENTION_CALLS=1', output)
                self.assertIn('ROLLOVER_RETENTION phase=RETENTION', output)
                retention = next(line for line in output.splitlines() if line.startswith('ROLLOVER_RETENTION '))
                self.assertIn('openai_request_files=1', retention)
                self.assertIn('cumulative_usage_change=' + ('MISSING' if usage == 'none' else 'UNCHANGED'), retention)
                self.assertEqual(len(data['turns']), 4)

    def test_existing_telemetry_safety_guards_stop_immediately(self):
        for safety in ('max_tokens', 'no_progress', 'tools'):
            with self.subTest(safety=safety):
                output, data = self.run_stress(safety=safety)
                self.assertEqual(len(data['turns']), 1)
                self.assertEqual(data['recalls'], 0)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL', output)

    def test_new_rollover_during_continuation_or_retention_fails(self):
        for scenario, reason in (({'repeat_turn': 9}, 'ROLLOVER_REPEATED_DURING_CONTINUATION'),
                                 ({'recall_rollover': True}, 'ROLLOVER_DURING_RETENTION'),
                                 ({'same_turn_repeat': True}, 'MULTIPLE_ROLLOVERS_ON_FIRST_COMPLETED_TURN'),
                                 ({'repeat_turn': 8}, 'MULTIPLE_ROLLOVERS_ON_FIRST_COMPLETED_TURN')):
            with self.subTest(scenario=scenario):
                output, data = self.run_stress(**scenario)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=' + reason, output)
                self.assertNotIn('ROLLOVER_SPIRAL=NOT_OBSERVED', output)
                self.assertIsNotNone(data['failure'])

    def test_retention_telemetry_errors_cannot_pass(self):
        for safety in ('max_tokens', 'no_progress', 'tools'):
            with self.subTest(safety=safety):
                output, data = self.run_stress(recall_safety=safety)
                self.assertEqual(data['recalls'], 1)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL', output)
                self.assertNotIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)

    def test_continuation_telemetry_errors_stop_before_retention(self):
        for safety in ('max_tokens', 'no_progress', 'tools'):
            with self.subTest(safety=safety):
                output, data = self.run_stress(safety=safety, safety_turn=9)
                self.assertEqual(len(data['turns']), 9)
                self.assertEqual(data['recalls'], 0)
                self.assertIn('POST_ROLLOVER_TURNS=0', output)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL', output)

    def test_zero_api_exit_zero_and_unchanged_cumulative_are_not_processed(self):
        output, data = self.run_stress(compaction=3, rollover=0, silent_turn=5)
        self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=CLI_NO_NEW_MODEL_REQUEST', output)
        self.assertIn('PENDING_PRESSURE_ATTEMPTS=2', output)
        self.assertIn('PROCESSED_PRESSURE_ATTEMPTS=1', output)
        self.assertEqual(len(data['turns']), 5)
        self.assertEqual(data['recalls'], 0)
        failed = next(line for line in output.splitlines() if line.startswith('ROLLOVER_TURN index=5 '))
        self.assertIn('openai_usage_files=0', failed)
        self.assertIn('cumulative_usage_change=UNCHANGED', failed)
        self.assertIn('exit_code=0', failed)
        self.assertIn('cli_cumulative_prompt_tokens=99000', failed)

    def test_terminal_result_and_current_root_assistant_are_required(self):
        for reply, reason in (('missing_result', 'CLI_RESULT_MISSING'), ('malformed', 'CLI_RESULT_MALFORMED'),
                              ('broken_json', 'CLI_RESULT_MALFORMED'), ('error', 'CLI_RESULT_ERROR'),
                              ('zero_turns', 'CLI_RESULT_NO_MODEL_TURN'), ('multiple_results', 'CLI_RESULT_AMBIGUOUS'),
                              ('assistant_after_result', 'CLI_RESULT_MALFORMED'), ('result_mismatch', 'CLI_RESULT_MALFORMED'),
                              *[(name, 'CLI_RESULT_MALFORMED') for name in ('assistant_session_array', 'assistant_role_array',
                                'assistant_model_array', 'result_session_array', 'result_type_array', 'result_error_array',
                                'result_num_array', 'result_text_array')],
                              ('empty', 'CLI_ASSISTANT_TEXT_MISSING'), ('wrong_ack', 'CLI_ACK_MISMATCH'),
                              ('stream_error', 'CLI_ASSISTANT_ERROR'), ('user_echo', 'CLI_ASSISTANT_TEXT_MISSING'),
                              ('wrong_session', 'CLI_ASSISTANT_TEXT_MISSING'), ('subagent', 'CLI_ASSISTANT_TEXT_MISSING')):
            with self.subTest(reply=reply):
                output, data = self.run_stress(reply=reply, reply_turn=1)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=' + reason, output)
                self.assertEqual(len(data['turns']), 1)
                self.assertEqual(data['recalls'], 0)

    def test_silent_continuation_and_retention_cannot_pass(self):
        for scenario in ({'silent_turn': 9}, {'silent_retention': True}, {'retention_reply': 'user_echo'}):
            with self.subTest(scenario=scenario):
                output, data = self.run_stress(**scenario)
                self.assertIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=FAIL reason=CLI_', output)
                self.assertNotIn('CONTEXT_LIFECYCLE_ROLLOVER_STRESS=PASS', output)

    def test_pinned_public_stdin_reader_accepts_complete_pressure_packet(self):
        archive = os.environ.get('LOCALAI_TEST_QWEN_ARCHIVE')
        if not archive:
            self.skipTest('Set LOCALAI_TEST_QWEN_ARCHIVE for the bounded pinned stdin check')
        digest = hashlib.sha256()
        with Path(archive).open('rb') as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(chunk)
        self.assertEqual(digest.hexdigest(), 'd331418c8779e5e709e0f772e0b69a4233c4d2ee2f43edd4a7466debdfc840ff')
        executable = self.base / 'public node.exe'
        with zipfile.ZipFile(archive) as bundle:
            executable.write_bytes(bundle.read('qwen-code/node/node.exe'))
            source = bundle.read('qwen-code/lib/chunks/llm-NSAVK5V3.js').decode()
        start = source.index('function takeUtf8Prefix(')
        end = source.index('\n__name(readStdin, "readStdin");', start)
        script = self.base / 'pinned stdin.cjs'
        script.write_text('const __name=(fn)=>fn; const writeStderrLine=(s)=>console.error(s);\n' +
                          source[start:end] + '\nreadStdin().then(text=>process.stdout.write(text));\n', encoding='utf-8')
        environment = {**self.env, 'NODE_OPTIONS': '',
                       'NODE_COMPILE_CACHE': str(self.clone / '.localai' / 'cache' / 'stdin'),
                       'TEMP': str(self.clone / '.localai' / 'tmp'), 'TMP': str(self.clone / '.localai' / 'tmp'),
                       'APPDATA': str(self.clone / '.localai' / 'home'), 'LOCALAPPDATA': str(self.clone / '.localai' / 'home')}
        prompt = ('LOCALAI PENDING PRESSURE\n' + '0123456789ABCDEF' * 2755 + '\nACK T01 KEEP_T01=INV-0123456789ABCDEF').encode()
        result = subprocess.run([str(executable), str(script)], input=prompt, capture_output=True,
                                cwd=self.project, env=environment, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout, prompt)
        self.assertEqual(result.stderr, b'')
        self.assert_external_unchanged()
