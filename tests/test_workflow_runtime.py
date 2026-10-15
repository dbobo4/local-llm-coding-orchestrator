"""Bounded pinned SDK workflow compatibility checks; no inference or child execution."""
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

import test_local_installation as fixtures
import test_tool_grammar as grammar


class WorkflowRuntimeTests(fixtures.FixtureTest):
    manager_run = grammar.ToolGrammarTests.manager_run
    assert_no_backups = grammar.ToolGrammarTests.assert_no_backups

    def setUp(self):
        super().setUp()
        archive = os.environ.get('LOCALAI_TEST_QWEN_ARCHIVE')
        if not archive: self.skipTest('Set LOCALAI_TEST_QWEN_ARCHIVE to the pinned public ZIP')
        digest = hashlib.sha256()
        with Path(archive).open('rb') as stream:
            for block in iter(lambda:stream.read(1024*1024),b''): digest.update(block)
        self.assertEqual(digest.hexdigest(),'d331418c8779e5e709e0f772e0b69a4233c4d2ee2f43edd4a7466debdfc840ff')
        self.copy_sources()
        with zipfile.ZipFile(archive) as bundle: bundle.extractall(self.clone / 'runtime')
        config = self.clone / '.localai/config/local.ps1'
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / 'config/local.example.ps1',config)
        spec = importlib.util.spec_from_file_location('workflow_bootstrap',self.clone / 'scripts/install_local.py')
        bootstrap = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = bootstrap
        self.addCleanup(sys.modules.pop,spec.name,None)
        spec.loader.exec_module(bootstrap)
        self.env.update(bootstrap.local_environment(self.clone))
        self.runtime = self.clone / 'runtime/qwen-code'
        self.chunk = self.runtime / 'lib/chunks/chunk-PZ66FRIC.js'
        self.manager = self.clone / 'patches/qwen_runtime_patches.ps1'

    def node(self, script, *, timeout=30):
        path = self.base / 'workflow-sdk.mjs'
        path.write_text(script)
        env = dict(self.env,FIXTURE_CORE=str(self.chunk),FIXTURE_PROJECT=str(self.project),
                   FIXTURE_CLONE=str(self.clone),
                   FIXTURE_SETTINGS=str(self.clone / ".localai/qwen/settings.json"))
        try:
            result = subprocess.run([str(self.runtime / 'node/node.exe'),str(path)],env=env,cwd=self.project,
                                    capture_output=True,text=True,timeout=timeout)
        except subprocess.TimeoutExpired as error:
            self.fail(f'Node SDK exceeded {timeout}s; stdout={error.stdout[-5000:] if error.stdout else None!r}; '
                      f'stderr={error.stderr[-2000:] if error.stderr else None!r}')
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        return result.stdout

    def test_real_agent_schema_and_nonblocking_continuation(self):
        patched = self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { appendStopHookBlockingCapWarning };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
globalThis.fetch=()=>{throw Error('Network forbidden');};
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const config=new core.Config({sessionId:'workflow-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:false});
config.getSubagentManager=()=>({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
const agent=new core.AgentTool(config);
assert.equal(agent.schema.parametersJsonSchema.properties.todo_id.minLength,1);
const good={description:'Bounded synthetic task',prompt:'Read synthetic state'};
for(const invalid of ['', ' ',22,'x'.repeat(501)]) assert.throws(()=>agent.build({...good,todo_id:invalid}));
for(const valid of [undefined,'item-1']) assert.ok(agent.build({...good,...valid!==undefined?{todo_id:valid}:{}}));
let hooks=0,executes=0;
config.getHookSystem=()=>({fireSubagentStopEvent:async()=>{hooks++;return {
 isBlockingDecision:()=>false,shouldStopExecution:()=>false,systemMessage:'LOCALAI_ROOT_CONTINUATION: bounded next slice'};}});
const invocation=agent.build(good);
const result=await invocation.runSubagentStopHookLoop({getFinalText:()=>'',getTerminateMode:()=>undefined,
 execute:async()=>{executes++;}}, {agentId:'fake-child',agentType:'algorithm-agent',resolvedMode:'default',signal:new AbortController().signal});
assert.equal(result,'LOCALAI_ROOT_CONTINUATION: bounded next slice');
const receipt=core.appendStopHookBlockingCapWarning('Slice PASS',result);
assert.ok(receipt.includes('Slice PASS'));assert.ok(receipt.includes(result));
assert.equal(hooks,1); assert.equal(executes,0);
config.getHookSystem=()=>({fireSubagentStopEvent:async()=>({isBlockingDecision:()=>false,shouldStopExecution:()=>false,systemMessage:'unrelated hook'})});
assert.equal(await invocation.runSubagentStopHookLoop({getFinalText:()=>'',getTerminateMode:()=>undefined},{agentId:'fake',agentType:'algorithm-agent'}),undefined);
''')
        self.assert_no_backups()

    def test_actual_scheduler_normalizes_before_validation_and_pre_hook(self):
        self.powershell(f"function powershell.exe {{ $global:LASTEXITCODE=0 }}; & {fixtures.ps_quote(self.clone / 'scripts/install_orchestrator.ps1')}")
        patched = self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { HookRegistry, HookPlanner };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
globalThis.fetch=()=>{throw Error('Network forbidden');};
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const config=new core.Config({sessionId:'workflow-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true,approvalMode:'yolo'});
const settings=JSON.parse(fs.readFileSync(process.env.FIXTURE_SETTINGS,'utf8'));
config.getUserHooks=()=>settings.hooks;
config.getProjectHooks=()=>undefined;
const registry=new core.HookRegistry(config);await registry.initialize();
const planner=new core.HookPlanner(registry);
for(const toolName of ['agent','read_file']) {
 const plan=planner.createExecutionPlan('PostToolUseFailure',{toolName});
 assert.equal(plan.hookConfigs.length,1);
 assert.ok(plan.hookConfigs[0].command.includes('hook_dispatcher.py'));
}
for(const toolName of ['list_agents','not_agent','run_shell_command']) {
 assert.equal(planner.createExecutionPlan('PostToolUseFailure',{toolName}).hookConfigs.length,1);
}
assert.equal(planner.createExecutionPlan('SessionDelete',{}).hookConfigs.length,1);
for(const toolName of ['read_file','write_file','edit','run_shell_command']) {
 const hooks=planner.createExecutionPlan('PreToolUse',{toolName}).hookConfigs.filter(h=>h.name==='qwen-orchestration-dispatcher');
 assert.equal(hooks.length,1);
 assert.ok(hooks[0].command.includes(process.env.FIXTURE_CLONE));
 assert.ok(hooks[0].command.includes('hook_dispatcher.py'));
 assert.equal(hooks[0].command.includes('<CLONE_ROOT>'),false);
}
config.getSubagentManager=()=>({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
const agent=new core.AgentTool(config);
config.getToolRegistry=()=>({ensureTool:async()=>agent});
config.getPermissionManager=()=>undefined;
config.getDisableAllHooks=()=>false;
config.hasHooksForEvent=()=>true;
let events=[];
config.getMessageBus=()=>({request:async request=>{
 events.push(request);
 return {success:true,output:{hookSpecificOutput:{hookEventName:request.eventName,
  ...request.eventName==='PostToolUseFailure'?{additionalContext:'LOCALAI_WORKFLOW_INCOMPLETE: synthetic repair pause'}:
  {permissionDecision:'deny',permissionDecisionReason:'LOCALAI_WORKFLOW_INCOMPLETE: fixture prevents actual child execution'}}}};
}});
for(const value of [undefined,'','item-1',' ',22,'x'.repeat(501)]) {
 events=[];
 const scheduler=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{}});
 scheduler.checkAndNotifyCompletion=async()=>{};
 scheduler.drainRequestQueueIfIdle=()=>{};
 const args={description:'Bounded synthetic task',prompt:'Inspect synthetic state',...value!==undefined?{todo_id:value}:{}};
 const original=structuredClone(args);
 await scheduler._schedule({name:'agent',args,callId:'case-'+String(value),prompt_id:'fixture-prompt'},new AbortController().signal);
 assert.deepEqual(args,original,'caller request must remain immutable');
 const result=scheduler.toolCalls[0];
 assert.equal(result.status,'error'); // Valid inputs are denied by the synthetic PreTool hook.
 const valid=value===undefined||value===''||value==='item-1';
 const event=events.find(e=>e.eventName===(valid?'PreToolUse':'PostToolUseFailure'));
 assert.ok(event,JSON.stringify(events));
 if(valid) {
  assert.equal(event.input.tool_input.todo_id,value===''?undefined:value);
  assert.equal(result.response.errorType,'execution_denied',JSON.stringify(result.response));
  assert.ok(result.response.responseParts[0].functionResponse.response.error.startsWith('LOCALAI_WORKFLOW_INCOMPLETE:'));
 } else {
  assert.ok(event.input.error.startsWith('LOCALAI_AGENT_PARAMETER_ERROR:'));
  assert.equal(event.input.tool_input.todo_id,value);
  assert.equal(result.response.errorType,'invalid_tool_params');
  assert.equal(result.response.executionStatus,'not_started');
  assert.ok(result.response.responseParts[0].functionResponse.response.error.startsWith('LOCALAI_WORKFLOW_INCOMPLETE:'));
 }
}
''')

    def test_actual_client_pauses_current_agent_response_and_errors_at_localai_stop(self):
        patched = self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        # Expose the private class only in this disposable SDK copy; its implementation is unchanged.
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { LlmClient };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
globalThis.fetch=()=>{throw Error('Network forbidden');};
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const config=new core.Config({sessionId:'client-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true});
config.assertCanStartTurn=async()=>{};
config.getChatRecordingService=()=>undefined;
config.getFileHistoryService=()=>({makeSnapshot:async()=>{},getSnapshots:()=>[]});
config.getDisableAllHooks=()=>false;
config.hasHooksForEvent=()=>true;
let requests=0,hookEvents=[],stopOutput={};
config.getMessageBus=()=>({request:async request=>{hookEvents.push(request);return {success:true,
 output:request.eventName==='Stop'?stopOutput:{}};}});
const client=new core.LlmClient(config);
client.beginManagedAutoMemoryRecall=()=>{};
client.microcompactHistoryBeforeSend=async()=>false;
client.drainSkillAndCommandReminders=async()=>{};
client.drainAgentReminders=async()=>{};
client.getLastModelMessageText=()=> 'Synthetic response';
client.chat={getHistory:()=>[],getHistoryPushCount:()=>0,getLastPromptTokenCount:()=>0,getLastOutputTokenCount:()=>0,addHistory:()=>{},
 sendMessageStream:async function*(){requests++;yield {type:'chunk',value:{candidates:[{
 content:{role:'model',parts:[{text:'Synthetic response'}]},finishReason:'STOP'}]}};}};
const collect=async(request,options={type:'userQuery'})=>{
 const events=[];for await(const event of client.sendMessageStream(request,new AbortController().signal,
 'fixture-prompt',options)) events.push(event);return events;
};
const paused={functionResponse:{name:'agent',response:{error:'LOCALAI_WORKFLOW_INCOMPLETE: synthetic pause'}}};
await assert.rejects(()=>collect([paused]),/LOCALAI_WORKFLOW_INCOMPLETE:/);
assert.equal(requests,0);assert.equal(hookEvents.length,0);
for(const input of [
 [{functionResponse:{name:'agent',response:{error:'ordinary parameter repair'}}}],
 [{text:'LOCALAI_WORKFLOW_INCOMPLETE: plaintext is not a hook result'}],
 [{functionResponse:{name:'read_file',response:{error:'LOCALAI_WORKFLOW_INCOMPLETE: unrelated tool'}}}],
 [{text:'Genuine new user request'}],
]) { await collect(input); }
assert.equal(requests,4);
assert.ok(hookEvents.some(e=>e.eventName==='UserPromptSubmit'&&e.input.submitted_prompt==='Genuine new user request'));
hookEvents=[];
await collect([{text:'Internal continuation'}],{type:'hook'});
assert.ok(hookEvents.every(e=>e.eventName!=='UserPromptSubmit'||!('submitted_prompt' in e.input)));
for(const [message,iteration] of [['LOCALAI_WORKFLOW_INCOMPLETE: exhausted repair',0],['LOCALAI_ROOT_CONTINUATION: residual work',7]]) {
 const prior=requests;
 stopOutput={decision:'block',systemMessage:message,reason:'Synthetic pending work'};
 await assert.rejects(()=>collect([{text:'Bounded continuation'}],{type:'hook',stopHookState:{iterationCount:iteration}}),/LOCALAI_WORKFLOW_INCOMPLETE:/);
 assert.equal(requests,prior+1,'Stop must not start another continuation request');
}
stopOutput={decision:'block',systemMessage:'Unrelated hook',reason:'Unrelated condition'};
await collect([{text:'Unrelated capped hook'}],{type:'hook',stopHookState:{iterationCount:7}});
stopOutput={systemMessage:'LOCALAI_WORKFLOW_INCOMPLETE: nonblocking message'};
await collect([{text:'Nonblocking marker'}]);
let progressStops=0;
const beforeProgress=requests;
config.getMessageBus=()=>({request:async request=>{
 if(request.eventName!=='Stop') return {success:true,output:{}};
 progressStops++;
 const stagnant=progressStops>4?progressStops-4:1;
 return {success:true,output:{decision:'block',reason:'Synthetic bounded phase progress',
  systemMessage:stagnant>=3?'LOCALAI_WORKFLOW_INCOMPLETE: stagnant':'LOCALAI_ROOT_CONTINUATION: pending',
  hookSpecificOutput:{hookEventName:'Stop',localai_workflow:{version:1,session_id:'client-fixture',
   turn_id:'progress-turn',progress_epoch:Math.min(progressStops,4),stagnation_count:stagnant}}}};
}});
await assert.rejects(()=>collect([{text:'Several legitimate phases'}],{type:'hook',stopHookState:{iterationCount:77,reasons:Array(50).fill('old reason')}}),/LOCALAI_WORKFLOW_INCOMPLETE:/);
assert.equal(progressStops,7);assert.equal(requests,beforeProgress+7);
''')

    def test_compatibility_states_restart_integrity_and_exact_rollback(self):
        applied = self.manager_run()
        self.assertEqual(applied.returncode,0,applied.stdout+applied.stderr)
        self.powershell(f'''
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile({fixtures.ps_quote(self.manager)},[ref]$tokens,[ref]$errors)
$assignment=@($ast.FindAll({{param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$WorkflowCompatibilityAnchors'}},$true))
if ($assignment.Count -ne 1) {{ throw 'Unique compatibility manifest required' }}
Invoke-Expression $assignment[0].Extent.Text
foreach ($name in @('Get-WorkflowCompatibilityState','Apply-WorkflowCompatibility')) {{
 $definition=@($ast.FindAll({{param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name}},$true))
 Invoke-Expression $definition[0].Extent.Text
}}
$original=[IO.File]::ReadAllText({fixtures.ps_quote(self.chunk)}).Replace("`r`n","`n")
foreach ($anchor in $WorkflowCompatibilityAnchors) {{
 $original=$original.Replace($anchor.New.Replace("`r`n","`n"),$anchor.Old.Replace("`r`n","`n"))
}}
if ((Get-WorkflowCompatibilityState $original) -ne 'unpatched') {{ throw 'Original state' }}
foreach ($text in @($original,$original.Replace("`r`n","`n").Replace("`n","`r`n"))) {{
 $fixed=Apply-WorkflowCompatibility $text
 if ((Get-WorkflowCompatibilityState $fixed) -ne 'patched') {{ throw 'Fixed state' }}
 if ((Apply-WorkflowCompatibility $fixed) -cne $fixed) {{ throw 'Idempotence' }}
 $restored=$fixed.Replace("`r`n","`n")
 foreach ($anchor in $WorkflowCompatibilityAnchors) {{
  $restored=$restored.Replace($anchor.New.Replace("`r`n","`n"),$anchor.Old.Replace("`r`n","`n"))
 }}
 if ($text.Contains("`r`n")) {{ $restored=$restored.Replace("`n","`r`n") }}
 if ($restored -cne $text) {{ throw 'Exact workflow inverse changed the protected foundation' }}
 $wrong=$fixed.Replace('minLength: 1,','minLength: 0,')
 if ((Get-WorkflowCompatibilityState $wrong) -ne 'incompatible') {{ throw 'Tamper accepted' }}
}}
$legacy=$original
foreach ($anchor in $WorkflowCompatibilityAnchors[0..5]) {{
 $legacy=$legacy.Replace($anchor.Old.Replace("`r`n","`n"),$anchor.New.Replace("`r`n","`n"))
}}
$root=$WorkflowCompatibilityAnchors | Where-Object Id -eq 'root-paused-or-capped-stop'
$legacyRoot=$root.New.Replace("`r`n","`n")
$legacyRoot=[regex]::Replace($legacyRoot,'(?m)^        const localAi(?:RawMetadata|WorkflowMetadata) = .*\\n','')
$legacyRoot=$legacyRoot.Replace('(localAiWorkflowMetadata ? localAiWorkflowMetadata.stagnation_count : (options2?.stopHookState?.iterationCount ?? 0) + 1)','(options2?.stopHookState?.iterationCount ?? 0) + 1')
$legacy=$legacy.Replace($root.Old.Replace("`r`n","`n"),$legacyRoot)
if ((Get-WorkflowCompatibilityState $legacy) -ne 'previous') {{
 $matrix=@(foreach ($anchor in $WorkflowCompatibilityAnchors) {{
  $o=[regex]::Matches($legacy,[regex]::Escape($anchor.Old.Replace("`r`n","`n"))).Count
  $n=[regex]::Matches($legacy,[regex]::Escape($anchor.New.Replace("`r`n","`n"))).Count
  "$($anchor.Id):$o/$n"
 }}) -join ','
 throw "Approved V1 migration state: $matrix"
}}
foreach ($text in @($legacy,$legacy.Replace("`n","`r`n"))) {{
 if ((Get-WorkflowCompatibilityState $text) -ne 'previous') {{ throw 'Approved V1 state rejected' }}
 if ((Apply-WorkflowCompatibility $text).Replace("`r`n","`n") -cne (Apply-WorkflowCompatibility $original)) {{ throw 'V1 migration changes unrelated bytes' }}
}}
if ((Get-WorkflowCompatibilityState $legacy.Replace('minLength: 1,','minLength: 0,')) -ne 'incompatible') {{ throw 'V1 tamper accepted' }}
[IO.File]::WriteAllText({fixtures.ps_quote(self.base/'approved-v1.js')},$legacy,[Text.UTF8Encoding]::new($false))
$v2=$original
foreach ($anchor in $WorkflowCompatibilityAnchors[0..17]) {{
 $v2=$v2.Replace($anchor.Old.Replace("`r`n","`n"),$anchor.New.Replace("`r`n","`n"))
}}
foreach ($text in @($v2,$v2.Replace("`n","`r`n"))) {{
 if ((Get-WorkflowCompatibilityState $text) -ne 'previous_v2') {{ throw 'Approved V2 state rejected' }}
 if ((Apply-WorkflowCompatibility $text).Replace("`r`n","`n") -cne (Apply-WorkflowCompatibility $original)) {{ throw 'V2 migration changed unrelated bytes' }}
}}
if ((Get-WorkflowCompatibilityState $v2.Replace('minLength: 1,','minLength: 0,')) -ne 'incompatible') {{ throw 'V2 tamper accepted' }}
$phase=$WorkflowCompatibilityAnchors | Where-Object Id -eq 'agent-terminal-phase'
$partialPhase=$v2.Replace($phase.Old.Replace("`r`n","`n"),$phase.New.Replace("`r`n","`n"))
if ((Get-WorkflowCompatibilityState $partialPhase) -ne 'incompatible') {{ throw 'Partial V3 over V2 accepted' }}
[IO.File]::WriteAllText({fixtures.ps_quote(self.base/'approved-v2.js')},$v2,[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText({fixtures.ps_quote(self.chunk)},$legacy,[Text.UTF8Encoding]::new($false))
$partial=$original.Replace("`r`n","`n").Replace($WorkflowCompatibilityAnchors[0].Old.Replace("`r`n","`n"),$WorkflowCompatibilityAnchors[0].New.Replace("`r`n","`n"))
$v3=$original
foreach ($anchor in $WorkflowCompatibilityAnchors[0..29]) {{
 $v3=$v3.Replace($anchor.Old.Replace("`r`n","`n"),$anchor.New.Replace("`r`n","`n"))
}}
foreach ($text in @($v3,$v3.Replace("`n","`r`n"))) {{
 if ((Get-WorkflowCompatibilityState $text) -ne 'previous_v3') {{ throw 'Approved V3 state rejected' }}
 if ((Apply-WorkflowCompatibility $text).Replace("`r`n","`n") -cne (Apply-WorkflowCompatibility $original)) {{ throw 'V3 migration changed unrelated bytes' }}
}}
if ((Get-WorkflowCompatibilityState $v3.Replace('minLength: 1,','minLength: 0,')) -ne 'incompatible') {{ throw 'V3 tamper accepted' }}
$start=$WorkflowCompatibilityAnchors | Where-Object Id -eq 'managed-start-response'
$partialStart=$v3.Replace($start.Old.Replace("`r`n","`n"),$start.New.Replace("`r`n","`n"))
if ((Get-WorkflowCompatibilityState $partialStart) -ne 'incompatible') {{ throw 'Partial V4 over V3 accepted' }}
[IO.File]::WriteAllText({fixtures.ps_quote(self.base/'approved-v3.js')},$v3,[Text.UTF8Encoding]::new($false))
if ((Get-WorkflowCompatibilityState $partial) -ne 'incompatible') {{ throw 'Partial deployment accepted' }}
''')
        failing=self.clone/'patches/fixture_workflow_failure.ps1'
        source=self.manager.read_text()
        source=source.replace('"workflow-continuation-compatibility" { Invoke-WorkflowCompatibilityPatch }',
                              '"workflow-continuation-compatibility" { Invoke-WorkflowCompatibilityPatch; throw "Injected post-migration failure" }')
        failing.write_text(source)
        manager=self.manager
        try:
            self.manager=failing
            for version in ('v1','v2','v3'):
                legacy=(self.base/f'approved-{version}.js').read_bytes()
                self.chunk.write_bytes(legacy)
                failed=self.manager_run()
                self.assertNotEqual(failed.returncode,0)
                self.assertEqual(self.chunk.read_bytes(),legacy)
                self.assert_no_backups()
        finally:
            self.manager=manager
        applied = self.manager_run()
        self.assertEqual(applied.returncode,0,applied.stdout+applied.stderr)
        first = self.chunk.read_bytes()
        for args in ((),('-VerifyOnly',)):
            result = self.manager_run(*args)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(self.chunk.read_bytes(),first)
        self.chunk.write_bytes(first.replace(b'minLength: 1,\n          maxLength: 500,',b'minLength: 0,\n          maxLength: 500,'))
        before = {path.relative_to(self.runtime):path.read_bytes() for path in self.runtime.rglob('*') if path.is_file()}
        verification = self.manager_run('-VerifyOnly')
        self.assertNotEqual(verification.returncode,0)
        self.assertNotIn('QWEN_RUNTIME_PATCH_VERIFY=PASS',verification.stdout)
        rejected = self.manager_run()
        self.assertNotEqual(rejected.returncode,0)
        self.assertNotIn('QWEN_RUNTIME_PATCH_STATUS=PASS',rejected.stdout)
        self.assertEqual(before,{path.relative_to(self.runtime):path.read_bytes() for path in self.runtime.rglob('*') if path.is_file()})
        self.assert_no_backups()

    def test_actual_owner_and_parent_call_start_stop_boundaries(self):
        patched=self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        with self.chunk.open('a',encoding='utf-8') as stream:
            stream.write('\nexport { HookEventHandler, HookSystem };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import {pathToFileURL} from 'node:url';
import path from 'node:path';
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const shared=await import(pathToFileURL(path.join(path.dirname(process.env.FIXTURE_CORE),'chunk-QYMAKPY5.js')));
const config=new core.Config({sessionId:'owner-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true});
config.getSessionSourceType=()=> 'main';config.getSessionSourceId=()=> 'root-config-owner';
const handler=new core.HookEventHandler(config);
const root=handler.createBaseInput('PreToolUse');assert.equal(root.source_type,'main');assert.equal(root.agent_id,undefined);
shared.subagentIdentityContext.run({type:'algorithm-agent',id:'bound-child'},()=>{
 const child=handler.createBaseInput('PreToolUse');
 assert.equal(child.agent_id,'bound-child');assert.equal(child.agent_type,'algorithm-agent');
 assert.equal(child.source_type,'subagent');assert.equal(child.source_id,'bound-child');
});
const system=new core.HookSystem(config);
let inputs=[];system.hookEventHandler.executeHooks=async(event,input)=>{inputs.push(input);return {finalOutput:{continue:true}};};
await system.fireSubagentStartEvent('child','algorithm-agent','default',undefined,'api-parent');
await system.fireSubagentStopEvent('child','algorithm-agent',undefined,'PASS\nChecked.\nMEMORY: NONE',false,'default',undefined,'GOAL','api-parent');
assert.equal(inputs[0].parent_tool_call_id,'api-parent');assert.equal(inputs[1].parent_tool_call_id,'api-parent');
assert.equal(inputs[1].terminate_reason,'GOAL');
config.getSubagentManager=()=>({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
let calls=[],executes=0;
config.getHookSystem=()=>({fireSubagentStartEvent:async(...args)=>{calls.push(args);return {
 isBlockingDecision:()=>true,shouldStopExecution:()=>true,getAdditionalContext:()=>''};}});
const invocation=new core.AgentTool(config).build({description:'Bounded owner fixture',prompt:'Synthetic scope'});
invocation.setCallId('api-parent-different-from-synthetic-use');
await assert.rejects(()=>invocation.runSubagentWithHooks({execute:async()=>{executes++;}},
 {set:()=>{}},{agentId:'child',agentType:'algorithm-agent',resolvedMode:'default',signal:new AbortController().signal}),/LOCALAI_WORKFLOW_INCOMPLETE:/);
assert.equal(executes,0);assert.equal(calls[0][4],'api-parent-different-from-synthetic-use');
''')

    def test_actual_hook_system_preserves_typed_stop_progress(self):
        self.powershell(f"function powershell.exe {{ $global:LASTEXITCODE=0 }}; & {fixtures.ps_quote(self.clone / 'scripts/install_orchestrator.ps1')}")
        patched=self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        identity=self.clone/'orchestration/project_identity.py'
        identity.write_text(identity.read_text()+'\n_find_git_root = lambda cwd: None\n')
        self.python("""import workflow_state as w,project_identity as p
s=w.create_state('typed-fixture','typed-turn',p.identify_project().project_id)
w.set_active_root_turn(s.session_id,s.turn_id)
w.select_implementation_workflow(s,require_test=True)
""")
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { HookSystem };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const config=new core.Config({sessionId:'typed-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true});
const settings=JSON.parse(fs.readFileSync(process.env.FIXTURE_SETTINGS,'utf8'));
config.getUserHooks=()=>settings.hooks;config.getProjectHooks=()=>undefined;
const system=new core.HookSystem(config);await system.initialize();
const scope={files:['synthetic.py'],objectives:['bounded_fixture']};
const admitted=await system.firePreToolUseEvent('agent',{
 subagent_type:'algorithm-agent',run_in_background:false,
 prompt:'<ALGORITHM_SCOPE>'+JSON.stringify(scope)+'</ALGORITHM_SCOPE>Inspect the bounded synthetic scope.'
},'synthetic-use-id','default',undefined,'api-parent-id');
assert.equal(admitted.hookSpecificOutput.permissionDecision,'allow');
const started=await system.fireSubagentStartEvent('typed-child','algorithm-agent','default',undefined,'api-parent-id');
assert.equal(started.shouldStopExecution(),false);
const {subagentIdentityContext}=await import(new URL('./chunk-QYMAKPY5.js',pathToFileURL(process.env.FIXTURE_CORE)));
const read=await subagentIdentityContext.run({type:'algorithm-agent',id:'typed-child'},()=>
 system.firePreToolUseEvent('read_file',{file_path:process.env.FIXTURE_PROJECT+'\\synthetic.py'},
 'another-synthetic-use','default',undefined,'api-read-id'));
assert.equal(read.hookSpecificOutput.permissionDecision,'allow');
for(let count=1;count<=3;count++) {
 const aggregate=await system.fireStopEvent(false,'Synthetic pending workflow');
 const {createHookOutput}=await import(new URL('./chunk-TTX2JUE6.js',pathToFileURL(process.env.FIXTURE_CORE)));
 const output=createHookOutput('Stop',aggregate.finalOutput);
 assert.equal(output.isBlockingDecision(),true);
 const metadata=output.hookSpecificOutput.localai_workflow;
 assert.equal(metadata.session_id,'typed-fixture');assert.equal(metadata.turn_id,'typed-turn');
 assert.equal(metadata.version,1);assert.equal(metadata.progress_epoch,0);assert.equal(metadata.stagnation_count,count);
 if(count===3) assert.ok(output.systemMessage.startsWith('LOCALAI_WORKFLOW_INCOMPLETE:'));
}
''')
        observed=json.loads(self.python("import workflow_state as w,json; s=w.get_active_state('typed-fixture'); print(json.dumps(s.active_agents['typed-child']['tools']))").stdout)
        self.assertEqual(set(observed),{'api-read-id'})

    def test_actual_guard_failure_after_admission_retires_only_not_started(self):
        self.powershell(f"function powershell.exe {{ $global:LASTEXITCODE=0 }}; & {fixtures.ps_quote(self.clone / 'scripts/install_orchestrator.ps1')}")
        patched=self.manager_run()
        self.assertEqual(patched.returncode,0,patched.stdout+patched.stderr)
        identity=self.clone/'orchestration/project_identity.py'
        identity.write_text(identity.read_text()+'\n_find_git_root = lambda cwd: None\n')
        self.python("""import workflow_state as w,project_identity as p
s=w.create_state('prestart-fixture','prestart-turn',p.identify_project().project_id)
w.set_active_root_turn(s.session_id,s.turn_id)
w.select_implementation_workflow(s,require_test=True)
s=w.create_state('entered-fixture','entered-turn',p.identify_project().project_id)
w.set_active_root_turn(s.session_id,s.turn_id)
w.select_implementation_workflow(s,require_test=True)
for case in ('pre-denied','guard-throw','guard-cancel','delayed-guard-cancel','early-cancel','transport','non-agent'):
 s=w.create_state(case+'-fixture',case+'-turn',p.identify_project().project_id)
 w.set_active_root_turn(s.session_id,s.turn_id)
 w.select_implementation_workflow(s,require_test=True)
""")
        (self.project/'synthetic.py').write_text('synthetic read fixture\n')
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { HookSystem };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';
import {getEventListeners} from 'node:events';
import {pathToFileURL} from 'node:url';
globalThis.fetch=()=>{throw Error('Network forbidden');};
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const config=new core.Config({sessionId:'prestart-fixture',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true,approvalMode:'yolo'});
const settings=JSON.parse(fs.readFileSync(process.env.FIXTURE_SETTINGS,'utf8'));
config.getUserHooks=()=>settings.hooks;config.getProjectHooks=()=>undefined;
config.getSubagentManager=()=>({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
config.getPermissionManager=()=>undefined;config.getDisableAllHooks=()=>false;config.hasHooksForEvent=()=>true;
const system=new core.HookSystem(config);await system.initialize();
let executes=0,events=[],failuresFinished=0,failTransport=false,delayedGuardFinished=true;
const agent=new core.AgentTool(config);const build=agent.build.bind(agent);
agent.build=params=>{const invocation=build(params);invocation.execute=async()=>{executes++;throw Error('Must not execute');};return invocation;};
config.getToolRegistry=()=>({ensureTool:async()=>agent});
config.getToolInvocationGuard=()=>async()=>({allowed:false,reason:'Synthetic pre-execution policy denial'});
config.getMessageBus=()=>({request:async request=>{
 events.push({...request,guardFinishedAtDispatch:delayedGuardFinished});
 if(request.eventName==='PostToolUseFailure'&&failTransport) throw Error('Synthetic failure-hook transport rejection');
 const i=request.input;
 const output=request.eventName==='PreToolUse'?await system.firePreToolUseEvent(i.tool_name,i.tool_input,i.tool_use_id,i.permission_mode,undefined,i.tool_call_id):
  request.eventName==='PostToolUseFailure'?await system.firePostToolUseFailureEvent(i.tool_use_id,i.tool_name,i.tool_input,i.error,i.is_interrupt,i.permission_mode,undefined,i.tool_call_id,i.execution_status):undefined;
 if(request.eventName==='PostToolUseFailure') failuresFinished++;
 return {success:true,output:output??{}};
}});
let completed=[],completionState,resolveCompletion,phaseAtCompletion;
const completion=new Promise(resolve=>{resolveCompletion=resolve;});
const statePath=path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state/prestart-fixture/prestart-turn.json');
const scheduler=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async calls=>{
 completionState=JSON.parse(fs.readFileSync(statePath,'utf8'));
 phaseAtCompletion=scheduler.localAiPendingFailureCommits?.size??0;
 assert.equal(failuresFinished,1,'Failure callback must finish before native completion');
 completed.push(...calls);
 resolveCompletion();
}});
const args={description:'Bounded prestart case',subagent_type:'algorithm-agent',run_in_background:false,
 prompt:'<ALGORITHM_SCOPE>'+JSON.stringify({files:['synthetic.py'],objectives:['bounded']})+'</ALGORITHM_SCOPE>Inspect synthetic state.'};
await scheduler._schedule({name:'agent',args,callId:'original-api-failure',prompt_id:'fixture-prompt'},new AbortController().signal);
await completion;
const result=completed[0];assert.ok(result);assert.equal(executes,0);assert.equal(result.response.executionStatus,'not_started');
assert.equal(completionState.pending_admission,null,'Retirement must precede native completion');
assert.equal(completionState.processed_stops[result.request.callId],'NOT_STARTED');
assert.equal(phaseAtCompletion,0);
assert.equal(scheduler.toolCalls.length,0,'Actual finalization must clear terminal calls');
assert.equal(scheduler.localAiPendingFailureCommits.size,0,'Phase protection must not leak');
const pre=events.find(e=>e.eventName==='PreToolUse');assert.ok(pre);assert.notEqual(pre.input.tool_use_id,pre.input.tool_call_id);
const failure=events.find(e=>e.eventName==='PostToolUseFailure');
assert.ok(failure,'An accepted not-started admission must receive a terminal failure hook');
assert.equal(events.filter(e=>e.eventName==='PostToolUseFailure').length,1);
assert.equal(failure.input.tool_call_id,'original-api-failure');assert.equal(failure.input.execution_status,'not_started');
const state=JSON.parse(fs.readFileSync(path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state/prestart-fixture/prestart-turn.json'),'utf8'));
assert.equal(state.pending_admission,null);assert.equal(state.processed_stops['original-api-failure'],'NOT_STARTED');
assert.equal(state.algorithm_completed,false);assert.equal(state.delegation_failure_total,1);
const late=await system.fireSubagentStartEvent('late-child','algorithm-agent','default',undefined,'original-api-failure');
assert.equal(late.shouldStopExecution(),true);
// Select each other native not_started branch without executing an invocation.
for(const mode of ['pre-denied','guard-throw','guard-cancel','delayed-guard-cancel','early-cancel']) {
 const controller=new AbortController();let guardReads=0,guardCalls=0;
 config.getSessionId=()=>mode+'-fixture';events=[];failuresFinished=0;
 delayedGuardFinished=mode!=='delayed-guard-cancel';
 config.getToolInvocationGuard=()=>{
  guardReads++;
  if(mode==='early-cancel') {controller.abort();return undefined;}
  return async()=>{
   guardCalls++;
   if(mode==='guard-throw') throw Error('Synthetic guard failure before execution');
   controller.abort();
   if(mode==='delayed-guard-cancel') {
    await new Promise(resolve=>setTimeout(resolve,20));delayedGuardFinished=true;
   }
   return {allowed:true};
  };
 };
 let resolveCase,caseCalls,caseState,finishedAtCompletion,phaseAtCompletion;
 const done=new Promise(resolve=>{resolveCase=resolve;});
 const casePath=path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state',mode+'-fixture',mode+'-turn.json');
 const current=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async calls=>{
  caseCalls=calls;caseState=JSON.parse(fs.readFileSync(casePath,'utf8'));
  finishedAtCompletion=failuresFinished;resolveCase();
  phaseAtCompletion=current.localAiPendingFailureCommits?.size??0;
 }});
 const caseArgs=mode==='pre-denied'?{...args,prompt:'No machine scope carrier: expected PreToolUse denial'}:args;
 const callId=mode+'-api';
 await current._schedule({name:'agent',args:caseArgs,callId,prompt_id:'fixture-prompt'},controller.signal);
 await done;
 assert.equal(executes,0,mode);assert.equal(current.toolCalls.length,0,mode);
 assert.equal(current.localAiPendingFailureCommits.size,0,mode);
 assert.equal(getEventListeners(controller.signal,'abort').length,0,mode);
 assert.equal(phaseAtCompletion,0,mode);
 assert.equal(caseCalls.length,1,mode);assert.equal(caseCalls[0].response.executionStatus,'not_started',mode);
 assert.equal(caseCalls[0].status,mode.endsWith('cancel')?'cancelled':'error',mode);
 const failed=events.filter(event=>event.eventName==='PostToolUseFailure');
 assert.equal(failed.length,1,mode);assert.equal(finishedAtCompletion,1,mode);
 assert.equal(failed[0].input.tool_call_id,callId);assert.equal(failed[0].input.execution_status,'not_started');
 if(mode==='delayed-guard-cancel') assert.equal(failed[0].guardFinishedAtDispatch,false,'Cancellation must not wait for the guard');
 const admitted=events.find(event=>event.eventName==='PreToolUse');
 assert.notEqual(admitted.input.tool_call_id,admitted.input.tool_use_id);
 assert.equal(guardReads,mode==='pre-denied'?0:1,mode);
 assert.equal(guardCalls,['guard-throw','guard-cancel','delayed-guard-cancel'].includes(mode)?1:0,mode);
 assert.equal(caseState.pending_admission,null);assert.equal(caseState.algorithm_completed,false);
 assert.equal(caseState.processed_stops[callId],mode==='pre-denied'?undefined:'NOT_STARTED');
 const stale=await system.fireSubagentStartEvent(mode+'-late-child','algorithm-agent','default',undefined,callId);
 assert.equal(stale.shouldStopExecution(),true,mode);
}
// A failed phase callback leaves resumable pending state, and never leaves abort protection active.
config.getSessionId=()=> 'transport-fixture';failTransport=true;events=[];
config.getToolInvocationGuard=()=>async()=>({allowed:false,reason:'Synthetic transport case'});
let resolveTransport,transportCalls,transportState,transportPhaseAtCompletion;
const transportDone=new Promise(resolve=>{resolveTransport=resolve;});
const transport=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async calls=>{
 transportCalls=calls;transportPhaseAtCompletion=transport.localAiPendingFailureCommits?.size??0;
 transportState=JSON.parse(fs.readFileSync(path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state/transport-fixture/transport-turn.json'),'utf8'));
 resolveTransport();
}});
await transport._schedule({name:'agent',args,callId:'transport-api',prompt_id:'fixture-prompt'},new AbortController().signal);
await transportDone;
assert.equal(executes,0);assert.equal(transportCalls[0].response.executionStatus,'not_started');
assert.equal(transport.localAiPendingFailureCommits.size,0);assert.equal(transportPhaseAtCompletion,0);
assert.equal(events.filter(event=>event.eventName==='PostToolUseFailure').length,1);
assert.equal(transportState.pending_admission.call_id,'transport-api');
assert.equal(transportState.processed_stops['transport-api'],undefined);assert.equal(transportState.algorithm_completed,false);
failTransport=false;
// Entered execution errors are ambiguous, and must keep exactly one native Failure callback.
config.getSessionId=()=> 'entered-fixture';config.getToolInvocationGuard=()=>undefined;
let resolveEntered,enteredCalls;
const enteredCompletion=new Promise(resolve=>{resolveEntered=resolve;});
const entered=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async calls=>{
 enteredCalls=calls;resolveEntered();
}});
events=[];
await entered._schedule({name:'agent',args:{...args,todo_id:''},callId:'entered-api',prompt_id:'fixture-prompt'},new AbortController().signal);
await enteredCompletion;
assert.equal(executes,1);assert.equal(enteredCalls[0].response.executionStatus,'error');
const failures=events.filter(event=>event.eventName==='PostToolUseFailure');
assert.equal(failures.length,1,'Existing error hooks must not be duplicated');
assert.equal(failures[0].input.execution_status,undefined,'No not-started phase may be inferred from a thrown execution');
const uncertain=JSON.parse(fs.readFileSync(path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state/entered-fixture/entered-turn.json'),'utf8'));
assert.equal(uncertain.pending_admission.interruption,'START_PHASE_UNPROVEN');
assert.equal(uncertain.algorithm_completed,false);assert.equal(uncertain.partial_side_effects_possible,true);
assert.deepEqual(failures[0].input.tool_input,uncertain.pending_admission.tool_input,'Failure evidence must use accepted updated args');
const delayed=await system.fireSubagentStartEvent('delayed-child','algorithm-agent','default',undefined,'entered-api');
assert.equal(delayed.shouldStopExecution(),true);
// Unrelated tools retain the native abort behavior and emit no added phase callback.
config.getSessionId=()=> 'non-agent-fixture';events=[];
config.getSkillManager=()=>({addChangeListener:()=>()=>{},getAllSkills:()=>[]});
const registry=await config.createToolRegistry(undefined,{skipDiscovery:true});
const read=await registry.ensureTool('read_file');let reads=0;
const readBuild=read.build.bind(read);
read.build=params=>{const invocation=readBuild(params);invocation.execute=async()=>{reads++;throw Error('Read must not execute');};return invocation;};
config.getToolRegistry=()=>registry;
const controller=new AbortController();let guardReturned=false;
config.getToolInvocationGuard=()=>async()=>{
 controller.abort();await new Promise(resolve=>setTimeout(resolve,20));guardReturned=true;return {allowed:true};
};
let resolveRead,readCalls,returnedAtCompletion;
const readDone=new Promise(resolve=>{resolveRead=resolve;});
const reader=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async calls=>{
 readCalls=calls;returnedAtCompletion=guardReturned;resolveRead();
}});
await reader._schedule({name:'read_file',args:{file_path:path.join(process.env.FIXTURE_PROJECT,'synthetic.py')},
 callId:'read-api',prompt_id:'fixture-prompt'},controller.signal);
await readDone;
assert.equal(reads,0);assert.equal(returnedAtCompletion,false,'Unrelated native abort drain remains unchanged');
assert.equal(readCalls[0].response.executionStatus,'not_started');assert.equal(readCalls[0].status,'cancelled');
assert.equal(reader.localAiPendingFailureCommits,undefined);
assert.equal(events.filter(event=>event.eventName==='PostToolUseFailure').length,0);
''')

    def test_managed_start_requires_verified_response_before_child_execution(self):
        self.powershell(f"function powershell.exe {{ $global:LASTEXITCODE=0 }}; & {fixtures.ps_quote(self.clone / 'scripts/install_orchestrator.ps1')}")
        applied=self.manager_run()
        self.assertEqual(applied.returncode,0,applied.stdout+applied.stderr)
        identity=self.clone/'orchestration/project_identity.py'
        identity.write_text(identity.read_text()+'\n_find_git_root = lambda cwd: None\n')
        cases=['allow','deny','throw','reject','missing','malformed','invalid-continue','invalid-decision','typed-missing-continue','bad-context','no-system',
               'aggregate-missing','aggregate-mixed','after-commit-missing','recovery-reject']
        self.python(f"""import workflow_state as w,project_identity as p
for case in {cases!r}:
 s=w.create_state(case+'-start',case+'-turn',p.identify_project().project_id)
 w.set_active_root_turn(s.session_id,s.turn_id)
 w.select_implementation_workflow(s,require_test=True)
 if case=='recovery-reject':
  w.set_algorithm_scope(s,files=['synthetic.py','remaining.py'],objectives=['done','remaining'])
  w.mark_growth_recovery_required(s)
""")
        for name in ('synthetic.py','remaining.py'): (self.project/name).write_text('synthetic bounded state\n')
        with self.chunk.open('a',encoding='utf-8') as stream: stream.write('\nexport { HookSystem };\n')
        self.node(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';import path from 'node:path';
import {pathToFileURL} from 'node:url';
globalThis.fetch=()=>{throw Error('Network forbidden');};
const core=await import(pathToFileURL(process.env.FIXTURE_CORE));
const {createHookOutput}=await import(new URL('./chunk-TTX2JUE6.js',pathToFileURL(process.env.FIXTURE_CORE)));
const matrixStarted=performance.now();
const config=new core.Config({sessionId:'allow-start',targetDir:process.env.FIXTURE_PROJECT,
 model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:true,approvalMode:'yolo'});
const settings=JSON.parse(fs.readFileSync(process.env.FIXTURE_SETTINGS,'utf8'));
config.getUserHooks=()=>settings.hooks;config.getProjectHooks=()=>undefined;
config.getSubagentManager=()=>({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
config.getDisableAllHooks=()=>false;config.hasHooksForEvent=()=>true;config.getPermissionManager=()=>undefined;
const system=new core.HookSystem(config);await system.initialize();
const executeHooks=system.hookEventHandler.executeHooks.bind(system.hookEventHandler);
let mode='allow',children=0,events=[];
system.hookEventHandler.executeHooks=async(event,...args)=>{
 if(event==='SubagentStart'&&mode==='aggregate-missing') return {success:true,allOutputs:[],errors:[],finalOutput:undefined};
 if(event==='SubagentStart'&&mode==='aggregate-mixed') return {success:false,allOutputs:[],errors:['Synthetic managed transport failure'],finalOutput:{continue:true}};
 if(event==='SubagentStart'&&mode==='bad-context') return {success:true,allOutputs:[],errors:[],finalOutput:{continue:true,hookSpecificOutput:'invalid'}};
 return executeHooks(event,...args);
};
const normalStart=system.fireSubagentStartEvent.bind(system);
config.getHookSystem=()=>mode==='no-system'?undefined:({
 fireSubagentStartEvent:(...args)=>{
  if(mode==='deny') return createHookOutput('SubagentStart',{continue:false,decision:'block'});
  if(mode==='throw') throw Error('Synthetic Start transport throw');
  if(mode==='reject'||mode==='recovery-reject') return Promise.reject(Error('Synthetic Start transport rejection'));
  if(mode==='missing') return undefined;
  if(mode==='malformed') return {};
  if(mode==='invalid-continue') return createHookOutput('SubagentStart',{continue:'true'});
  if(mode==='invalid-decision') return createHookOutput('SubagentStart',{continue:true,decision:['deny']});
  if(mode==='typed-missing-continue') return createHookOutput('SubagentStart',{decision:'allow'});
  if(mode==='after-commit-missing') return normalStart(...args).then(()=>undefined);
  return normalStart(...args);
 },
 fireSubagentStopEvent:system.fireSubagentStopEvent.bind(system)
});
config.getMessageBus=()=>({request:async request=>{
 events.push(request);const i=request.input;
 const output=request.eventName==='PreToolUse'?await system.firePreToolUseEvent(i.tool_name,i.tool_input,i.tool_use_id,i.permission_mode,undefined,i.tool_call_id):
  request.eventName==='PostToolUseFailure'?await system.firePostToolUseFailureEvent(i.tool_use_id,i.tool_name,i.tool_input,i.error,i.is_interrupt,i.permission_mode,undefined,i.tool_call_id,i.execution_status):undefined;
 return {success:true,output:output??{}};
}});
const agent=new core.AgentTool(config),build=agent.build.bind(agent);
agent.build=params=>{
 const invocation=build(params);
 invocation.execute=async signal=>{
  let ran=false;
  const child={execute:async()=>{children++;ran=true;},getFinalText:()=>ran?'PASS\nSynthetic bounded slice verified.\nMEMORY: NONE':'',
   getTerminateMode:()=>ran?'GOAL':'ERROR',getExecutionSummary:()=>({})};
  const warning=await invocation.runSubagentWithHooks(child,new Map([['task_prompt',params.prompt]]),
   {agentId:mode+'-child',agentType:'algorithm-agent',resolvedMode:'default',signal});
  return {llmContent:[{text:child.getFinalText()+(warning??'')}]};
 };
 return invocation;
};
config.getToolRegistry=()=>({ensureTool:async()=>agent});
const observed=[];
for(mode of ['allow','deny','throw','reject','missing','malformed','invalid-continue','invalid-decision','typed-missing-continue','bad-context','no-system',
             'aggregate-missing','aggregate-mixed','after-commit-missing','recovery-reject']) {
 const caseStarted=performance.now();
 console.log('MANAGED_START_CASE='+mode+' phase=BEGIN elapsed_ms='+Math.round(caseStarted-matrixStarted));
 config.getSessionId=()=>mode+'-start';children=0;events=[];
 let resolveDone,calls;
 const done=new Promise(resolve=>{resolveDone=resolve;});
 const scheduler=new core.CoreToolScheduler({config,onToolCallsUpdate:()=>{},onAllToolCallsComplete:async completed=>{calls=completed;resolveDone();}});
 const args={description:'Bounded Start regression',subagent_type:'algorithm-agent',run_in_background:false,
  prompt:'<ALGORITHM_SCOPE>'+JSON.stringify({files:['synthetic.py'],objectives:['bounded']})+'</ALGORITHM_SCOPE>Inspect synthetic state.'};
 if(mode==='recovery-reject') {
  for(const name of ['synthetic.py','remaining.py']) {
   await system.firePostToolUseEvent('read_file',{file_path:path.join(process.env.FIXTURE_PROJECT,name)},
    {llmContent:'synthetic bounded state\n',returnDisplay:''},'read-'+name,'default',undefined,'read-api-'+name);
  }
  args.prompt='<ALGORITHM_SCOPE>'+JSON.stringify({files:['remaining.py'],objectives:['remaining::verify']})+'</ALGORITHM_SCOPE>'+
   '<GROWTH_RECOVERY>'+JSON.stringify({completed:['done'],residual:['remaining'],final_slice:true})+'</GROWTH_RECOVERY>Verify the remaining synthetic state.';
 }
 await scheduler._schedule({name:'agent',args,callId:mode+'-api',prompt_id:'fixture-prompt'},new AbortController().signal);
 await done;
 const state=JSON.parse(fs.readFileSync(path.join(process.env.FIXTURE_CLONE,'.localai/orchestration/state',mode+'-start',mode+'-turn.json'),'utf8'));
 const failures=events.filter(event=>event.eventName==='PostToolUseFailure');
 observed.push({mode,children,status:calls[0].status,phase:calls[0].response.executionStatus,
  failureCount:failures.length,completed:state.algorithm_completed,pending:!!state.pending_admission,active:Object.keys(state.active_agents).length});
 if(mode==='allow') {
  assert.equal(children,1);assert.equal(calls[0].status,'success');assert.equal(failures.length,0);
  assert.equal(state.algorithm_completed,true);assert.equal(state.pending_admission,null);
 } else if(children===0) {
  assert.equal(calls[0].status,'error');assert.equal(calls[0].response.executionStatus,'error','An entered Agent is not certified not_started');
  assert.ok(calls[0].response.responseParts[0].functionResponse.response.error.startsWith('LOCALAI_WORKFLOW_INCOMPLETE:'));
  assert.equal(failures.length,1);assert.equal(failures[0].input.tool_call_id,mode+'-api');
  assert.equal(failures[0].input.execution_status,undefined);assert.equal(state.algorithm_completed,false);
  if(mode==='after-commit-missing') assert.equal(state.active_agents[mode+'-child'].call_id,mode+'-api');
  else assert.equal(state.pending_admission.interruption,'START_PHASE_UNPROVEN');
  if(mode==='recovery-reject') {
   assert.deepEqual(state.algorithm_scope_files,['remaining.py']);assert.deepEqual(state.algorithm_scope_objectives,['remaining::verify']);
   assert.deepEqual(state.growth_recovery_completed_objectives,['done']);assert.deepEqual(state.growth_recovery_residual_objectives,['remaining']);
   assert.equal(state.growth_recovery_guard_active,true);assert.equal(state.growth_recovery_generation,1);
  }
  const test=await system.firePreToolUseEvent('agent',{subagent_type:'test-agent',run_in_background:false,prompt:'Verify too early'},
   'different-test-use','default',undefined,'different-test-api');
  assert.equal(test.hookSpecificOutput.permissionDecision,'deny');
 }
 console.log('MANAGED_START_CASE='+mode+' phase=END duration_ms='+Math.round(performance.now()-caseStarted));
}
assert.deepEqual(observed.filter(item=>item.mode!=='allow'&&item.children!==0),[],JSON.stringify(observed));
// The same library helper outside configured LocalAI management keeps native error handling.
config.getUserHooks=()=>undefined;
config.getHookSystem=()=>({fireSubagentStartEvent:()=>{throw Error('Unmanaged native hook failure');},
 fireSubagentStopEvent:async()=>createHookOutput('SubagentStop',{continue:true})});
const unmanaged=build({description:'Unmanaged SDK case',prompt:'Synthetic library use'});let nativeChildren=0;
await unmanaged.runSubagentWithHooks({execute:async()=>{nativeChildren++;},getFinalText:()=> 'PASS\nNative case.\nMEMORY: NONE',
 getTerminateMode:()=> 'GOAL',getExecutionSummary:()=>({})},new Map(),
 {agentId:'unmanaged',agentType:'algorithm-agent',resolvedMode:'default',signal:new AbortController().signal});
assert.equal(nativeChildren,1);
console.log('MANAGED_START_MATRIX=PASS cases=15 elapsed_ms='+Math.round(performance.now()-matrixStarted));
''', timeout=60)
