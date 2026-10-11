"""Pinned tool schemas and source-based b10636 boundary checks; no inference."""

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


CHUNK = 'lib/chunks/chunk-WNPDGUJO.js'


def pinned_repetition_accepts(minimum, maximum):
    # 4d19b287 src/llama-grammar.cpp:655 makes max > 2000 unbounded;
    # handle_repetitions:495 rejects n_prev_rules(1) * total_rules >= 2000.
    if minimum > 2000:
        return False
    maximum = None if maximum is not None and maximum > 2000 else maximum
    total_rules = maximum if maximum is not None and maximum > 0 else minimum or 1
    return total_rules < 2000


class ToolGrammarTests(fixtures.FixtureTest):
    def setUp(self):
        super().setUp()
        archive = os.environ.get('LOCALAI_TEST_QWEN_ARCHIVE')
        if not archive:
            self.skipTest('Set LOCALAI_TEST_QWEN_ARCHIVE to the official pinned ZIP')
        digest = hashlib.sha256()
        with Path(archive).open('rb') as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b''):
                digest.update(block)
        self.assertEqual(digest.hexdigest(), 'd331418c8779e5e709e0f772e0b69a4233c4d2ee2f43edd4a7466debdfc840ff')
        self.copy_sources()
        with zipfile.ZipFile(archive) as bundle:
            bundle.extractall(self.clone / 'runtime')
        config = self.clone / '.localai' / 'config' / 'local.ps1'
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / 'config' / 'local.example.ps1', config)
        spec = importlib.util.spec_from_file_location('grammar_fixture_bootstrap', self.clone / 'scripts' / 'install_local.py')
        bootstrap = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = bootstrap
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(bootstrap)
        self.env.update(bootstrap.local_environment(self.clone))
        self.runtime = self.clone / 'runtime' / 'qwen-code'
        self.chunk = self.runtime / CHUNK
        self.manager = self.clone / 'patches' / 'qwen_runtime_patches.ps1'

    def import_patch(self):
        return f'''
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile({fixtures.ps_quote(self.manager)},[ref]$tokens,[ref]$errors)
foreach ($name in @('Get-ReportFindingsGrammarState','Apply-ReportFindingsGrammarCompatibility','Invoke-ReportFindingsGrammarPatch')) {{
    $function=@($ast.FindAll({{param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name}},$true))
    if ($function.Count -ne 1) {{ throw "Missing unique grammar function: $name" }}
    Invoke-Expression $function[0].Extent.Text
}}
$RuntimeRoot={fixtures.ps_quote(self.runtime)}
function Assert-LocalPath {{ param($Path) }}
'''

    def manager_run(self, *arguments):
        return subprocess.run([fixtures.POWERSHELL, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                               '-File', str(self.manager), *arguments], cwd=self.project, env=self.env,
                              capture_output=True, text=True, timeout=60)

    def assert_no_backups(self):
        temporary = self.clone / '.localai' / 'tmp'
        self.assertFalse(list(temporary.glob('localai-qwen-runtime-patch-*')))
        for path in temporary.rglob('*'):
            if path.is_file():
                self.assertNotIn('.bak',path.name)
                self.assertFalse(any(parent.name in ('rollback','qwen-code-patches') for parent in path.parents),path)

    def catalog(self):
        script = self.base / 'catalog.mjs'
        script.write_text(r'''
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {pathToFileURL} from 'node:url';
globalThis.fetch = () => { throw Error('Network forbidden in catalog fixture'); };
const core = await import(pathToFileURL(process.env.FIXTURE_CORE));
const config = new core.Config({sessionId:'grammar-fixture',targetDir:process.env.FIXTURE_PROJECT,
  model:'qwen3.8-27b-coder',interactive:false,useRipgrep:false,enableHooks:false});
// Catalog construction needs metadata, never subagent/model execution.
config.getSubagentManager = () => ({addChangeListener:()=>()=>{},listSubagents:async()=>[],getAvailableModelGrades:()=>new Map()});
config.getSkillManager = () => ({addChangeListener:()=>()=>{},getAllSkills:()=>[]});
const registry = await config.createToolRegistry(undefined,{skipDiscovery:true});
await registry.warmAll({strict:true});
config.getToolRegistry = () => registry;
let setTools = 0;
config.getLlmClient = () => ({setTools:async () => { setTools++; }});
const before = registry.getFunctionDeclarations();
assert.ok(!before.some(tool => tool.name === 'report_findings'));
const roles = {};
for (const role of ['algorithm-agent','test-agent']) {
  const source = fs.readFileSync(`${process.env.FIXTURE_AGENTS}/${role}.md`,'utf8');
  const frontmatter = source.split('---')[1];
  const names = [...frontmatter.matchAll(/^\s*-\s+(\S+)\s*$/gm)].map(match => match[1]);
  assert.equal(names.length,role==='algorithm-agent'?9:6);
  assert.deepEqual(names.filter(name=>name.startsWith('mcp__')).sort(),
    ['mcp__context7__query-docs','mcp__context7__resolve-library-id']);
  const declarations = registry.getFunctionDeclarationsFiltered(names);
  assert.deepEqual(declarations.map(tool=>tool.name).sort(),names.filter(name=>!name.startsWith('mcp__')).sort());
  assert.ok(!declarations.some(tool=>tool.name==='report_findings'));
  roles[role] = declarations;
}
const search = registry.getTool('tool_search');
const found = await search.build({query:'select:report_findings'}).execute(new AbortController().signal);
assert.ok(!found.error,JSON.stringify(found));
assert.equal(setTools,1);
assert.ok(registry.getFunctionDeclarations().some(tool=>tool.name==='report_findings'));
const report = registry.getTool('report_findings');
const maximum = report.schema.parametersJsonSchema.properties.findings.items.properties.summary.maxLength;
const finding = {severity:'Suggestion',file:'fixture.py',summary:'x'.repeat(maximum),failureScenario:'Synthetic trigger.'};
assert.doesNotThrow(()=>report.build({findings:[finding]}));
assert.throws(()=>report.build({findings:[{...finding,summary:'x'.repeat(maximum+1)}]}));
const invocation = report.build({findings:[{severity:'Suggestion',file:'fixture.py',
  summary:'Synthetic finding.',failureScenario:'Synthetic trigger.'}]});
const result = await invocation.execute(new AbortController().signal);
assert.ok(!result.error);
console.log(JSON.stringify({roles,report:report.schema,catalog:registry.getFunctionDeclarations({includeDeferred:true})}));
''', encoding='utf-8')
        environment = {**self.env, 'FIXTURE_CORE': str(self.runtime / 'lib' / 'chunks' / 'chunk-PZ66FRIC.js'),
                       'FIXTURE_PROJECT': str(self.project), 'FIXTURE_AGENTS': str(self.clone / 'orchestration' / 'agents')}
        result = subprocess.run([str(self.runtime / 'node' / 'node.exe'), str(script)], cwd=self.project,
                                env=environment, capture_output=True, text=True, encoding='utf-8', timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout.splitlines()[-1])

    def test_approved_states_unique_anchor_and_newline_idempotency(self):
        self.powershell(self.import_patch() + f'''
$original=[IO.File]::ReadAllText({fixtures.ps_quote(self.chunk)})
foreach ($newline in @("`n","`r`n")) {{
    $text=$original.Replace("`r`n","`n").Replace("`n",$newline)
    if ((Get-ReportFindingsGrammarState $text) -ne 'unpatched') {{ throw 'Pristine state rejected' }}
    $patched=Apply-ReportFindingsGrammarCompatibility $text
    if ((Get-ReportFindingsGrammarState $patched) -ne 'patched') {{ throw 'Fixed state rejected' }}
    if ((Apply-ReportFindingsGrammarCompatibility $patched) -cne $patched) {{ throw 'Not idempotent' }}
    [IO.File]::WriteAllText({fixtures.ps_quote(self.chunk)},$text,[Text.UTF8Encoding]::new($true))
    Invoke-ReportFindingsGrammarPatch
    $bytes=[IO.File]::ReadAllBytes({fixtures.ps_quote(self.chunk)})
    if ($bytes[0] -ne 239 -or $bytes[1] -ne 187 -or $bytes[2] -ne 191) {{ throw 'BOM removed' }}
    if ([IO.File]::ReadAllText({fixtures.ps_quote(self.chunk)}) -cne $patched) {{ throw 'File newline changed' }}
    foreach ($bad in @($text + $text,$patched.Replace('maxLength: 1999','maxLength: 1998'),$patched.Replace('maxItems: REPORT_FINDINGS_MAX','maxItems: 49'))) {{
        if ((Get-ReportFindingsGrammarState $bad) -ne 'incompatible') {{ throw 'Unapproved chunk accepted' }}
        $failed=$false; try {{ Apply-ReportFindingsGrammarCompatibility $bad }} catch {{ $failed=$true }}
        if (-not $failed) {{ throw 'Unapproved chunk modified' }}
    }}
}}
''')

    def test_actual_catalog_roles_toolsearch_and_pinned_source_boundary(self):
        original = self.catalog()
        self.powershell(self.import_patch() + '\nInvoke-ReportFindingsGrammarPatch\n')
        patched = self.catalog()
        schema = original['report']['parametersJsonSchema']['properties']['findings']['items']['properties']
        fixed = patched['report']['parametersJsonSchema']['properties']['findings']['items']['properties']
        self.assertEqual(schema['summary']['maxLength'], 2000)
        self.assertEqual(fixed['summary']['maxLength'], 1999)
        self.assertFalse(pinned_repetition_accepts(0, schema['summary']['maxLength']))
        self.assertTrue(pinned_repetition_accepts(0, fixed['summary']['maxLength']))
        self.assertEqual((fixed['failureScenario']['maxLength'],fixed['file']['maxLength']), (4000,4096))
        self.assertTrue(pinned_repetition_accepts(0,4000))
        self.assertTrue(pinned_repetition_accepts(0,4096))
        schema['summary']['maxLength'] = 1999
        for tool in original['catalog']:
            if tool['name'] == 'report_findings':
                tool['parametersJsonSchema']['properties']['findings']['items']['properties']['summary']['maxLength'] = 1999
        self.assertEqual(original, patched)
        def check_bounds(value):
            if isinstance(value,dict):
                if value.get('type') == 'string':
                    self.assertTrue(pinned_repetition_accepts(value.get('minLength',0),value.get('maxLength')),value)
                for child in value.values(): check_bounds(child)
            elif isinstance(value,list):
                for child in value: check_bounds(child)
        check_bounds(patched)

    def test_full_manager_verify_restart_integrity_and_no_backups(self):
        applied = self.manager_run()
        self.assertEqual(applied.returncode,0,applied.stdout+applied.stderr)
        first = self.chunk.read_bytes()
        for args in ((),('-VerifyOnly',)):
            result = self.manager_run(*args)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            self.assertEqual(self.chunk.read_bytes(),first)
        self.chunk.write_bytes(first.replace(b'maxLength: 1999',b'maxLength: 1998'))
        rejected = self.manager_run('-VerifyOnly')
        self.assertNotEqual(rejected.returncode,0)
        self.assertNotIn('QWEN_RUNTIME_PATCH_VERIFY=PASS',rejected.stdout)
        self.assert_no_backups()

    def test_unknown_schema_rolls_back_every_managed_file(self):
        self.chunk.write_bytes(self.chunk.read_bytes().replace(b'maxLength: 2e3',b'maxLength: 1998'))
        before = {path.relative_to(self.runtime):path.read_bytes() for path in self.runtime.rglob('*') if path.is_file()}
        rejected = self.manager_run()
        self.assertNotEqual(rejected.returncode,0)
        self.assertIn('QWEN_RUNTIME_PATCH_STATUS=FAIL',rejected.stdout)
        self.assertNotIn('QWEN_RUNTIME_PATCH_STATUS=PASS',rejected.stdout)
        after = {path.relative_to(self.runtime):path.read_bytes() for path in self.runtime.rglob('*') if path.is_file()}
        self.assertEqual(before,after)
        self.assert_no_backups()
