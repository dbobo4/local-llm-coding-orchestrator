"""Pinned installation transactions using tiny archives and mocked network/processes."""

from __future__ import annotations

import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import zipfile

from test_local_installation import FixtureTest, REPO


def archive(files: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as output:
        for name, content in files.items():
            output.writestr(name, content)
    return buffer.getvalue()


class NvidiaCudaBannerTests(unittest.TestCase):
    """Accept both published NVIDIA-SMI CUDA labels, without weakening the minimum."""

    def setUp(self) -> None:
        spec = importlib.util.spec_from_file_location("cuda_banner_installer", REPO / "scripts" / "install_local.py")
        self.installer = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.installer
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(self.installer)

    def check_banner(self, output: str, returncode: int = 0) -> None:
        def find_program(name: str) -> str | None:
            return name if name in {"powershell.exe", "nvidia-smi.exe"} else None

        result = SimpleNamespace(stdout=output, returncode=returncode)
        with patch.object(self.installer.shutil, "which", side_effect=find_program), \
             patch.object(self.installer.platform, "machine", return_value="AMD64"), \
             patch.object(self.installer.subprocess, "run", return_value=result):
            self.installer.check_prerequisites()

    def test_standard_cuda_banner(self) -> None:
        self.check_banner("NVIDIA-SMI 610.88  Driver Version: 610.88  CUDA Version: 13.3")

    def test_windows_cuda_umd_banner(self) -> None:
        self.check_banner("NVIDIA-SMI 610.88  KMD Version: 610.88  CUDA UMD Version: 13.3")

    def test_cuda_umd_below_required_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "CUDA 13.3"):
            self.check_banner("CUDA UMD Version: 13.2")

    def test_missing_cuda_version_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "CUDA 13.3"):
            self.check_banner("NVIDIA-SMI unknown version")

    def test_failed_nvidia_smi_is_rejected(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "CUDA 13.3"):
            self.check_banner("CUDA UMD Version: 13.3", returncode=1)

    def test_malformed_cuda_versions_are_rejected(self) -> None:
        for banner in (
            "CUDA Version: 13.3.4",
            "CUDA UMD Version: 13.3.",
            "CUDA Version:",
            "CUDA UMD Version: 13",
            "CUDA Version: 13.x",
            "CUDA UMD Version: 13.3beta",
        ):
            with self.subTest(banner=banner):
                with self.assertRaisesRegex(RuntimeError, "CUDA 13.3"):
                    self.check_banner(banner)


class BootstrapTests(FixtureTest):
    def setUp(self) -> None:
        super().setUp()
        self.copy_sources()
        spec = importlib.util.spec_from_file_location("fixture_bootstrap", REPO / "scripts" / "install_local.py")
        self.bootstrap = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.bootstrap
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(self.bootstrap)
        qwen_files = {
            "qwen-code/package.json": b'{"version":"0.22.3"}',
            "qwen-code/lib/cli.js": b"// fixture",
            "qwen-code/bin/qwen.cmd": b"@echo off",
            "qwen-code/node/node.exe": b"fixture node",
            "qwen-code/lib/chunks/chunk-PZ66FRIC.js": b"fixture chunk",
            "qwen-code/lib/chunks/chunk-ZEYFMJQA.js": b"fixture schema",
            "qwen-code/lib/chunks/chunk-DJPASAUV.js": b"fixture loader",
            "qwen-code/lib/bundled/qc-helper/docs/configuration/settings.md": b"fixture docs",
        }
        self.payloads = {
            "qwen": archive(qwen_files),
            "llama": archive({"llama-server.exe": b"fixture server", "ggml-cuda.dll": b"fixture cuda"}),
            "cuda": archive({"cudart64_13.dll": b"fixture cudart", "cublas64_13.dll": b"fixture cublas", "cublasLt64_13.dll": b"fixture cublasLt"}),
            "model": b"tiny deterministic model fixture",
        }
        self.artifacts = {
            key: self.bootstrap.Artifact(
                f"{key}.zip" if key != "model" else self.bootstrap.MODEL_NAME,
                f"https://fixture.invalid/{key}", hashlib.sha256(data).hexdigest(), len(data),
            ) for key, data in self.payloads.items()
        }
        self.requests: list[str] = []

        def open_url(request, **kwargs):
            url = request.full_url if hasattr(request, "full_url") else request
            self.requests.append(url)
            return io.BytesIO(self.payloads[url.rsplit("/", 1)[1]])

        for name, value in (
            ("ARTIFACTS", self.artifacts),
            ("check_prerequisites", lambda: None),
            ("verify_llama", lambda path: None),
            ("verify_settings", lambda root: None),
        ):
            context = patch.object(self.bootstrap, name, value)
            context.start()
            self.addCleanup(context.stop)
        context = patch.object(self.bootstrap.urllib.request, "urlopen", open_url)
        context.start()
        self.addCleanup(context.stop)

        def deploy(root, environment):
            self.assertEqual(Path(environment["QWEN_HOME"]), root / ".localai" / "qwen")
            state = root / ".localai" / "qwen"
            state.mkdir(parents=True, exist_ok=True)
            (state / "settings.json").write_text('{"fixture":true}', encoding="utf-8")
            for relative in ("QWEN.md", "agents/algorithm-agent.md", "agents/test-agent.md"):
                path = state / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture", encoding="utf-8")

        context = patch.object(self.bootstrap, "deploy_orchestrator", deploy)
        context.start()
        self.addCleanup(context.stop)

    def test_initial_install_and_reuse_preserve_state_without_downloads(self) -> None:
        self.bootstrap.install(self.clone)
        state = self.clone / ".localai" / "qwen"
        memory = state / "memory.txt"
        memory.write_text("keep local memory", encoding="utf-8")
        first_requests = list(self.requests)
        self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, first_requests)
        self.assertEqual(len(first_requests), 4)
        self.assertEqual(memory.read_text(), "keep local memory")
        self.assertEqual(json.loads((self.clone / "runtime" / "qwen-code" / "package.json").read_text())["version"], "0.22.3")
        self.assertTrue((self.clone / "runtime" / "llama.cpp" / "cudart64_13.dll").is_file())
        self.assert_external_unchanged()

    def test_hash_failure_never_promotes_download(self) -> None:
        self.payloads["qwen"] = b"wrong archive"
        with self.assertRaisesRegex(RuntimeError, "SHA-256|size"):
            self.bootstrap.install(self.clone)
        self.assertFalse((self.clone / "runtime" / "qwen-code").exists())
        self.assertFalse((self.clone / ".localai" / "install.json").exists())
        self.assert_external_unchanged()

    def test_partial_download_and_interrupted_staging_are_recoverable(self) -> None:
        downloads = self.clone / ".localai" / "downloads"
        downloads.mkdir(parents=True)
        (downloads / "qwen.zip.part").write_bytes(b"interrupted")
        staging = self.clone / ".localai" / "staging"
        staging.mkdir()
        (staging / "partial.txt").write_text("interrupted", encoding="utf-8")
        self.bootstrap.install(self.clone)
        self.assertTrue((self.clone / ".localai" / "install.json").is_file())
        self.assertFalse((downloads / "qwen.zip.part").exists())
        self.assert_external_unchanged()

    def test_wrong_archive_version_is_rejected(self) -> None:
        self.payloads["qwen"] = archive({
            "qwen-code/package.json": b'{"version":"0.22.2"}',
            "qwen-code/lib/cli.js": b"fixture", "qwen-code/bin/qwen.cmd": b"fixture",
            "qwen-code/node/node.exe": b"fixture",
        })
        data = self.payloads["qwen"]
        self.artifacts["qwen"] = self.bootstrap.Artifact("qwen.zip", "https://fixture.invalid/qwen", hashlib.sha256(data).hexdigest(), len(data))
        with self.assertRaisesRegex(RuntimeError, "version|0.22.3"):
            self.bootstrap.install(self.clone)
        self.assertFalse((self.clone / ".localai" / "install.json").exists())

    def test_failed_deployment_restores_previous_runtime_and_settings(self) -> None:
        self.bootstrap.install(self.clone)
        runtime = self.clone / "runtime" / "qwen-code"
        package = runtime / "package.json"
        package.write_text('{"version":"0.22.2"}', encoding="utf-8")
        original = package.read_bytes()
        settings = self.clone / ".localai" / "qwen" / "settings.json"
        original_settings = settings.read_bytes()

        def fail_deployment(root, environment):
            settings.write_text("partially written", encoding="utf-8")
            raise RuntimeError("fixture patch failure")

        with patch.object(self.bootstrap, "deploy_orchestrator", fail_deployment):
            with self.assertRaisesRegex(RuntimeError, "fixture patch failure"):
                self.bootstrap.install(self.clone)
        self.assertEqual(package.read_bytes(), original)
        self.assertEqual(settings.read_bytes(), original_settings)
        self.assert_external_unchanged()

    def test_archive_traversal_and_symlinks_are_rejected(self) -> None:
        for entry in ("../outside.txt", "C:/outside.txt", "/outside.txt", "file:stream"):
            path = self.base / "unsafe.zip"
            path.write_bytes(archive({entry: b"unsafe"}))
            with self.assertRaisesRegex(RuntimeError, "Unsafe"):
                self.bootstrap.checked_extract(path, self.clone / ".localai" / "extract")
        path = self.base / "symlink.zip"
        with zipfile.ZipFile(path, "w") as output:
            entry = zipfile.ZipInfo("link")
            entry.create_system = 3
            entry.external_attr = 0o120777 << 16
            output.writestr(entry, "../outside")
        with self.assertRaisesRegex(RuntimeError, "Unsafe"):
            self.bootstrap.checked_extract(path, self.clone / ".localai" / "extract")

    def test_scoped_environment_overrides_poisoned_inherited_paths(self) -> None:
        poisoned = {name: str(self.old) for name in self.bootstrap.LOCAL_ENV_KEYS}
        with patch.dict(os.environ, poisoned):
            environment = self.bootstrap.local_environment(self.clone)
        for name in self.bootstrap.LOCAL_ENV_KEYS:
            if name == "LOCALAI_ORIGINAL_USERPROFILE":
                self.assertEqual(Path(environment[name]), self.old)
            else:
                self.assertTrue(Path(environment[name]).is_relative_to(self.clone if name == "LOCALAI_INSTALL_ROOT" else self.clone / ".localai"), name)
        self.assert_external_unchanged()

    def test_source_and_config_refresh_reuses_all_components(self) -> None:
        self.bootstrap.install(self.clone)
        before = list(self.requests)
        config = self.clone / ".localai" / "config" / "local.ps1"
        config.write_text(config.read_text() + "\n# fixture local edit\n", encoding="utf-8")
        self.bootstrap.install(self.clone)
        source = self.clone / "orchestration" / "QWEN.md"
        source.write_text(source.read_text() + "\nfixture source change\n", encoding="utf-8")
        self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, before)

    def test_changed_model_is_rejected_before_download_or_deployment(self) -> None:
        self.bootstrap.install(self.clone)
        model = self.clone / "models" / self.bootstrap.MODEL_NAME
        model.write_bytes(b"tampered")
        before = list(self.requests)
        with self.assertRaisesRegex(RuntimeError, "Model SHA-256"):
            self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, before)
        self.assertFalse(self.bootstrap.readiness(self.clone))

    def test_model_byte_change_with_preserved_size_and_timestamp_is_rejected(self) -> None:
        self.bootstrap.install(self.clone)
        model = self.clone / "models" / self.bootstrap.MODEL_NAME
        previous = model.stat()
        contents = bytearray(model.read_bytes())
        contents[0] ^= 1
        model.write_bytes(contents)
        os.utime(model, ns=(previous.st_atime_ns, previous.st_mtime_ns))
        before = list(self.requests)
        self.assertFalse(self.bootstrap.readiness(self.clone))
        with self.assertRaisesRegex(RuntimeError, "Model SHA-256"):
            self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, before)

    def test_failed_rollback_keeps_journal_for_next_attempt(self) -> None:
        self.bootstrap.install(self.clone)
        package = self.clone / "runtime" / "qwen-code" / "package.json"
        package.write_text('{"version":"0.22.2"}', encoding="utf-8")
        with patch.object(self.bootstrap, "deploy_orchestrator", side_effect=RuntimeError("patch failure")), \
                patch.object(self.bootstrap, "recover_transaction", side_effect=[None, OSError("locked rollback")]):
            with self.assertRaisesRegex(RuntimeError, "Recovery files retained"):
                self.bootstrap.install(self.clone)
        staging = self.clone / ".localai" / "staging"
        self.assertTrue((staging / "transaction.json").exists())
        self.assertTrue((staging / "old-qwen" / "package.json").exists())
        self.bootstrap.install(self.clone)
        self.assertFalse(staging.exists())
        self.assertTrue(self.bootstrap.readiness(self.clone))

    def test_setup_lock_rejects_overlap_and_reuses_unlocked_file(self) -> None:
        state = self.clone / ".localai"
        state.mkdir()
        with self.bootstrap.setup_lock(state):
            with self.assertRaisesRegex(RuntimeError, "Another setup"):
                self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, [])
        self.bootstrap.install(self.clone)
        self.assertTrue(self.bootstrap.readiness(self.clone))

    def test_retained_transaction_refuses_recovery_while_client_lease_is_active(self) -> None:
        self.bootstrap.install(self.clone)
        with patch.object(self.bootstrap, "check_idle", side_effect=AssertionError("Warm reuse checked clients")):
            self.bootstrap.install(self.clone)
        staging = self.clone / ".localai" / "staging"
        staging.mkdir()
        journal = staging / "transaction.json"
        self.bootstrap.write_json(journal, {
            "replace": {"qwen": False, "llama": False},
            "existing_files": [path.relative_to(self.clone).as_posix() for path in self.bootstrap.transaction_files(self.clone) if path.is_file()],
        })
        backup = staging / "retained-backup.txt"
        backup.write_text("Retained rollback data", encoding="utf-8")
        lease = self.clone / ".localai" / "qwen" / "runtime_clients" / "cli" / "fixture.lock"
        lease.parent.mkdir(parents=True)
        lease.write_text("Active client", encoding="utf-8")
        paths = [journal, backup, *self.bootstrap.transaction_files(self.clone)]
        before = {path: path.read_bytes() for path in paths if path.is_file()}
        requests = list(self.requests)
        original_open = Path.open

        def lease_open(path, *args, **kwargs):
            if path == lease:
                raise PermissionError("Client holds an exclusive lease")
            return original_open(path, *args, **kwargs)

        with patch.object(Path, "open", lease_open), \
                patch.object(self.bootstrap, "recover_transaction", side_effect=AssertionError("Recovery preceded lease check")):
            with self.assertRaisesRegex(RuntimeError, "Close this clone"):
                self.bootstrap.install(self.clone)
        self.assertEqual({path: path.read_bytes() for path in before}, before)
        self.assertEqual(self.requests, requests)
        lease.unlink()
        self.bootstrap.install(self.clone)
        self.assertFalse(staging.exists())
        self.assertTrue(self.bootstrap.readiness(self.clone))

    def test_disk_preflight_blocks_before_any_download(self) -> None:
        with patch.object(self.bootstrap.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            with self.assertRaisesRegex(RuntimeError, "free disk"):
                self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, [])

    def test_missing_cublas_is_rejected(self) -> None:
        self.payloads["cuda"] = archive({"cudart64_13.dll": b"fixture"})
        data = self.payloads["cuda"]
        self.artifacts["cuda"] = self.bootstrap.Artifact("cuda.zip", "https://fixture.invalid/cuda", hashlib.sha256(data).hexdigest(), len(data))
        with self.assertRaisesRegex(RuntimeError, "cuBLAS"):
            self.bootstrap.install(self.clone)
        self.assertFalse((self.clone / ".localai" / "install.json").exists())

    def test_corrupt_settings_require_refresh_without_runtime_downloads(self) -> None:
        self.bootstrap.install(self.clone)
        before = list(self.requests)
        settings = self.clone / ".localai" / "qwen" / "settings.json"
        settings.write_text("corrupt", encoding="utf-8")
        self.assertFalse(self.bootstrap.readiness(self.clone))
        self.bootstrap.install(self.clone)
        self.assertEqual(self.requests, before)
        self.assertTrue(self.bootstrap.readiness(self.clone))

    def test_original_profile_and_git_root_at_profile_fail_closed(self) -> None:
        with patch.dict(os.environ, {"USERPROFILE": str(self.user)}), \
                patch.object(self.bootstrap.Path, "cwd", return_value=self.user):
            with self.assertRaisesRegex(RuntimeError, "private Qwen"):
                self.bootstrap.check_workspace(self.clone)

    def test_nested_case_variant_profile_and_npm_alias_preserve_isolation(self) -> None:
        with patch.dict(os.environ, {
            "USERPROFILE": str(self.clone / ".localai" / "home").upper(),
            "LOCALAI_ORIGINAL_USERPROFILE": str(self.user), "npm_config_cache": str(self.old),
        }):
            environment = self.bootstrap.local_environment(self.clone)
        self.assertEqual(environment["LOCALAI_ORIGINAL_USERPROFILE"], str(self.user))
        self.assertEqual(environment["NPM_CONFIG_CACHE"], str(self.clone / ".localai" / "cache" / "npm"))
        self.assertEqual(len([key for key in environment if key.upper() == "NPM_CONFIG_CACHE"]), 1)
        with patch.dict(os.environ, clear=True):
            with self.assertRaisesRegex(RuntimeError, "USERPROFILE is missing"):
                self.bootstrap.local_environment(self.clone)
        with patch.dict(os.environ, {"USERPROFILE": str(self.user)}), \
                patch.object(self.bootstrap.Path, "cwd", return_value=self.project), \
                patch.object(self.bootstrap.shutil, "which", return_value="fixture-git"), \
                patch.object(self.bootstrap.subprocess, "run", return_value=SimpleNamespace(returncode=0, stdout=str(self.user))):
            with self.assertRaisesRegex(RuntimeError, "Git root"):
                self.bootstrap.check_workspace(self.clone)

    def test_nested_profile_requires_original_locator(self) -> None:
        for value in (None, "", " "):
            with patch.dict(os.environ, {"USERPROFILE": str(self.clone / ".localai" / "home")}):
                if value is None:
                    os.environ.pop("LOCALAI_ORIGINAL_USERPROFILE", None)
                else:
                    os.environ["LOCALAI_ORIGINAL_USERPROFILE"] = value
                with self.assertRaisesRegex(RuntimeError, "LOCALAI_ORIGINAL_USERPROFILE is missing"):
                    self.bootstrap.local_environment(self.clone)

    def test_managed_paths_reject_junction_before_hash_or_settings_read(self) -> None:
        state = self.clone / ".localai"
        state.mkdir()
        junction = state / "qwen"
        self.powershell(f"New-Item -ItemType Junction -Path '{junction}' -Target '{self.old}' | Out-Null")
        self.addCleanup(lambda: os.rmdir(junction) if junction.exists() else None)
        with patch.object(self.bootstrap, "sha256", side_effect=AssertionError("Hashing preceded path validation")), \
                patch.object(Path, "read_text", side_effect=AssertionError("Reading preceded path validation")):
            with self.assertRaisesRegex(RuntimeError, "escapes|Reparse"):
                self.bootstrap.managed_files(self.clone)
            # Bootstrap tests normally stub this verifier; call its real source implementation.
            spec = importlib.util.spec_from_file_location("guard_fixture_bootstrap", REPO / "scripts" / "install_local.py")
            verifier = importlib.util.module_from_spec(spec)
            sys.modules[spec.name] = verifier
            self.addCleanup(sys.modules.pop, spec.name, None)
            spec.loader.exec_module(verifier)
            with self.assertRaisesRegex(RuntimeError, "escapes|Reparse"):
                verifier.verify_settings(self.clone)

    def test_recovery_journal_rejects_junction_before_json_read(self) -> None:
        state = self.clone / ".localai"
        state.mkdir()
        staging = state / "staging"
        self.powershell(f"New-Item -ItemType Junction -Path '{staging}' -Target '{self.old}' | Out-Null")
        self.addCleanup(lambda: os.rmdir(staging) if staging.exists() else None)
        with patch.object(Path, "read_text", side_effect=AssertionError("Journal read preceded path validation")):
            with self.assertRaisesRegex(RuntimeError, "escapes|Reparse"):
                self.bootstrap.recover_transaction(self.clone, staging)

    def test_original_profile_junction_is_canonicalized(self) -> None:
        alias = self.base / "profile alias"
        self.powershell(f"New-Item -ItemType Junction -Path '{alias}' -Target '{self.user}' | Out-Null")
        self.addCleanup(lambda: os.rmdir(alias) if alias.exists() else None)
        with patch.dict(os.environ, {"USERPROFILE": str(alias)}):
            environment = self.bootstrap.local_environment(self.clone)
        self.assertEqual(Path(environment["LOCALAI_ORIGINAL_USERPROFILE"]), self.user.resolve())


if __name__ == "__main__":
    unittest.main()
