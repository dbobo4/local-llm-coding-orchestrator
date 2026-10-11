"""Optional bounded verification against the SHA-verified official Qwen ZIP."""

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

from test_local_installation import FixtureTest, POWERSHELL, REPO


class PinnedRuntimeTests(FixtureTest):
    def test_compression_templates_preserve_lf_and_crlf_runtime_anchors(self) -> None:
        archive = os.environ.get("LOCALAI_TEST_QWEN_ARCHIVE")
        if not archive:
            self.skipTest("Set LOCALAI_TEST_QWEN_ARCHIVE for the pinned newline regression")
        self.copy_sources()
        raw = self.base / "raw-runtime.js"
        with zipfile.ZipFile(archive) as source:
            raw.write_bytes(source.read("qwen-code/lib/chunks/chunk-PZ66FRIC.js"))
        from test_local_installation import ps_quote
        self.powershell(f"""
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile({ps_quote(self.clone / 'patches' / 'qwen_runtime_patches.ps1')}, [ref]$tokens, [ref]$errors)
$names = @('Get-NewLine','Test-UniqueOrdinalMarker','Replace-UniqueOrdinalMarker','Get-CompressionPromptBlocks','Get-CompressionOptimizationState','Apply-CompressionOptimization','Get-RuntimeHardeningState','Get-OrchestrationLatencyHardeningState')
foreach ($name in $names) {{
    $function = @($ast.FindAll({{ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }}, $true))[0]
    Invoke-Expression $function.Extent.Text
}}
$original = [IO.File]::ReadAllText({ps_quote(raw)})
$results = @()
foreach ($newline in @("`n", "`r`n")) {{
    $text = $original.Replace("`r`n", "`n").Replace("`n", $newline)
    if ((Get-CompressionOptimizationState $text) -ne 'unpatched') {{ throw 'Pristine encoding rejected' }}
    $patched = Apply-CompressionOptimization $text
    if ((Get-CompressionOptimizationState $patched) -ne 'patched') {{ throw 'Compression policy not applied' }}
    if ((Get-RuntimeHardeningState $patched) -ne 'unpatched' -or (Get-OrchestrationLatencyHardeningState $patched) -ne 'unpatched') {{ throw 'Unchanged runtime anchors became incompatible' }}
    if ($newline -eq "`n" -and $patched.Contains("`r`n")) {{ throw 'CRLF template injected into LF runtime' }}
    if ($newline -eq "`r`n" -and $patched.Replace("`r`n", '').Contains("`n")) {{ throw 'LF template injected into CRLF runtime' }}
    $results += $patched.Replace("`r`n", "`n")
}}
if ($results[0] -cne $results[1]) {{ throw 'Newline correction changed template semantics' }}
""")

    def test_official_bundle_patches_and_keeps_paths_local_during_reload(self) -> None:
        archive = os.environ.get("LOCALAI_TEST_QWEN_ARCHIVE")
        if not archive:
            self.skipTest("Set LOCALAI_TEST_QWEN_ARCHIVE to the official pinned ZIP for this bounded check")
        archive_path = Path(archive)
        digest = hashlib.sha256()
        with archive_path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        self.assertEqual(digest.hexdigest(), "d331418c8779e5e709e0f772e0b69a4233c4d2ee2f43edd4a7466debdfc840ff")
        self.clone = self.base / "clone with spaces $dollar & apostrophe's"
        self.clone.mkdir()
        self.copy_sources()
        config = self.clone / ".localai" / "config" / "local.ps1"
        config.parent.mkdir(parents=True)
        shutil.copy2(self.clone / "config" / "local.example.ps1", config)
        with zipfile.ZipFile(archive_path) as source:
            source.extractall(self.clone / "runtime")
        spec = importlib.util.spec_from_file_location("pinned_fixture_bootstrap", REPO / "scripts" / "install_local.py")
        bootstrap = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = bootstrap
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(bootstrap)
        environment = bootstrap.local_environment(self.clone)
        environment.update(self.env)
        environment.update(bootstrap.local_environment(self.clone))
        environment["LOCALAI_ORIGINAL_USERPROFILE"] = str(self.user)
        bootstrap.write_json(self.clone / ".localai" / "system-settings.json", {"general": {"enableAutoUpdate": False}})
        bootstrap.write_json(self.clone / ".localai" / "system-defaults.json", {})
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
             str(self.clone / "scripts" / "install_orchestrator.ps1")],
            cwd=self.project, env=environment, capture_output=True, text=True,
            timeout=60, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("ORCHESTRATOR_INSTALL=PASS", result.stdout)
        bootstrap.verify_settings(self.clone)
        # A second patch gate checks idempotency and all managed JavaScript syntax.
        result = subprocess.run(
            [POWERSHELL, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
             str(self.clone / "patches" / "qwen_runtime_patches.ps1")],
            cwd=self.project, env=environment, capture_output=True, text=True,
            timeout=60, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        keys = bootstrap.LOCAL_ENV_KEYS
        (self.project / ".env").write_text(
            "\n".join(f"{key}={self.old}" for key in keys) + "\nFIXTURE_ALLOWED=first\n",
            encoding="utf-8",
        )
        # These historical home files must never be consulted by the runtime.
        (self.user / ".env").write_text("FIXTURE_HISTORY=historical", encoding="utf-8")
        (self.user / ".qwen" / ".env").write_text("FIXTURE_HISTORY=historical", encoding="utf-8")
        (self.user / "QWEN.md").write_text("HISTORICAL_HOME_MEMORY", encoding="utf-8")
        (self.project / "QWEN.md").write_text("CURRENT_PROJECT_MEMORY", encoding="utf-8")
        module = self.clone / "runtime" / "qwen-code" / "lib" / "chunks" / "chunk-XHF7WQ6B.js"
        environment.update({
            "FIXTURE_ENV_MODULE": module.as_uri(), "FIXTURE_PROJECT": str(self.project),
            "FIXTURE_KEYS": json.dumps(keys), "FIXTURE_OLD": str(self.old),
            "FIXTURE_ORIGINAL_PROFILE": str(self.user),
        })
        script = self.base / "reload.mjs"
        script.write_text(r"""
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {syncBuiltinESMExports} from 'node:module';
const originalExists = fs.existsSync;
const originalRead = fs.readFileSync;
function assertLocalLookup(value) {
  const text = path.resolve(String(value)).toLowerCase();
  const original = path.resolve(process.env.FIXTURE_ORIGINAL_PROFILE).toLowerCase();
  assert.ok(text !== path.join(original, '.env') && text !== path.join(original, 'qwen.md') &&
    !text.startsWith(path.join(original, '.qwen')) && !text.startsWith(path.join(original, '.agents')), text);
}
fs.existsSync = value => { assertLocalLookup(value); return originalExists(value); };
fs.readFileSync = (value, ...args) => { assertLocalLookup(value); return originalRead(value, ...args); };
syncBuiltinESMExports();
const {loadEnvironment, reloadEnvironment, buildRuntimeEnvironment} = await import(process.env.FIXTURE_ENV_MODULE);
const keys = JSON.parse(process.env.FIXTURE_KEYS);
const before = Object.fromEntries(keys.map(key => [key, process.env[key]]));
assert.equal(os.homedir(), before.USERPROFILE);
const settings = {security: {folderTrust: {enabled: false}}, env: {}};
const envPath = path.join(process.env.FIXTURE_PROJECT, '.env');
const projectEnv = fs.readFileSync(envPath, 'utf8');
fs.unlinkSync(envPath);
loadEnvironment(settings, process.env.FIXTURE_PROJECT);
assert.equal(process.env.FIXTURE_ALLOWED, undefined);
assert.equal(process.env.FIXTURE_HISTORY, undefined);
fs.writeFileSync(envPath, projectEnv);
loadEnvironment(settings, process.env.FIXTURE_PROJECT);
assert.equal(process.env.FIXTURE_ALLOWED, 'first');
fs.writeFileSync(envPath, keys.map(key => `${key}=${process.env.FIXTURE_OLD}`).join('\n') + '\nFIXTURE_ALLOWED=second\n');
settings.env = Object.fromEntries(keys.map(key => [key, process.env.FIXTURE_OLD]));
reloadEnvironment(settings, process.env.FIXTURE_PROJECT, true);
assert.equal(process.env.FIXTURE_ALLOWED, 'second');
const built = buildRuntimeEnvironment(settings, process.env.FIXTURE_PROJECT, process.env, true);
for (const key of keys) {
  assert.equal(process.env[key], before[key], key);
  assert.equal(built.effectiveEnv[key], before[key], key);
}
assert.equal(process.env.FIXTURE_HISTORY, undefined);
const core = await import(new URL('./chunk-PZ66FRIC.js', process.env.FIXTURE_ENV_MODULE));
const memory = await core.loadServerHierarchicalMemory(process.env.FIXTURE_PROJECT, [], undefined, [], true);
assert.ok(JSON.stringify(memory).includes('CURRENT_PROJECT_MEMORY'));
assert.ok(!JSON.stringify(memory).includes('HISTORICAL_HOME_MEMORY'));
console.log('PINNED_ENVIRONMENT_RELOAD=PASS');
""", encoding="utf-8")
        result = subprocess.run(
            [str(self.clone / "runtime" / "qwen-code" / "node" / "node.exe"), str(script)],
            cwd=self.project, env=environment, capture_output=True, text=True,
            timeout=20, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("PINNED_ENVIRONMENT_RELOAD=PASS", result.stdout)
        settings = json.loads((self.clone / ".localai" / "qwen" / "settings.json").read_text())
        self.assertFalse(settings["general"]["enableAutoUpdate"])
        for root in (self.old, self.user / ".qwen"):
            self.assertEqual((root / "keep.txt").read_text(), "untouched")
        self.assertFalse((self.project / ".qwen").exists())
