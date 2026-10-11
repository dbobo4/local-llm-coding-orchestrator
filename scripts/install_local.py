"""Install the pinned Windows runtimes and model inside this clone."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import asdict, dataclass
import hashlib
import json
import msvcrt
import os
from pathlib import Path, PureWindowsPath
import platform
import re
import shutil
import stat
import subprocess
import sys
import time
import urllib.request
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "orchestration"))
from local_paths import assert_local_path, assert_local_tree


# CONFIG: pinned releases; change only as part of a validated runtime migration.
QWEN_VERSION = "0.22.3"
LLAMA_BUILD = "b10636"
LLAMA_COMMIT = "4d19b287691e8f47fc303be420f630c40ec45684"
MODEL_NAME = "Qwen3.8-27B-UD-Q3_K_XL.gguf"
INSTALL_ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Artifact:
    name: str
    url: str
    sha256: str
    size: int


# SHA-256/size: official GitHub release asset digests and publisher HF LFS metadata.
ARTIFACTS = {
    "qwen": Artifact(
        "qwen-code-win-x64.zip",
        "https://github.com/QwenLM/qwen-code/releases/download/v0.22.3/qwen-code-win-x64.zip",
        "d331418c8779e5e709e0f772e0b69a4233c4d2ee2f43edd4a7466debdfc840ff", 65194084,
    ),
    "llama": Artifact(
        "llama-b10636-bin-win-cuda-13.3-x64.zip",
        "https://github.com/ggml-org/llama.cpp/releases/download/b10636/llama-b10636-bin-win-cuda-13.3-x64.zip",
        "8a60cadf69ae2e850fdf06412a8d1205cfa54d75130086c8e14108c75e7625c1", 146449775,
    ),
    "cuda": Artifact(
        "cudart-llama-bin-win-cuda-13.3-x64.zip",
        "https://github.com/ggml-org/llama.cpp/releases/download/b10636/cudart-llama-bin-win-cuda-13.3-x64.zip",
        "1462a050eb4c684921ba51dcc4cc488a036674c3e73e9945ee705b854808d03e", 390970417,
    ),
    "model": Artifact(
        MODEL_NAME,
        "https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/4ca720788d1e01f1bff70c033e0d0028fd02e502/" + MODEL_NAME,
        "8c2a45ff85e7674ca185ec8eb6cdeab0e617ed9d8018caed0b64380eb2a67a5e", 13146393504,
    ),
}

LOCAL_ENV_KEYS = (
    "USERPROFILE", "HOME", "APPDATA", "LOCALAPPDATA", "TEMP", "TMP", "TMPDIR",
    "QWEN_HOME", "QWEN_RUNTIME_DIR", "QWEN_CODE_MCP_APPROVALS_PATH",
    "QWEN_CODE_TRUSTED_FOLDERS_PATH", "QWEN_CODE_SYSTEM_SETTINGS_PATH",
    "QWEN_CODE_SYSTEM_DEFAULTS_PATH", "LOCALAI_INSTALL_ROOT",
    "NODE_COMPILE_CACHE", "CUDA_CACHE_PATH", "NPM_CONFIG_CACHE",
    "LOCALAI_ORIGINAL_USERPROFILE",
)
ISOLATION_MARKER = "LOCALAI_INSTALLATION_PATH_ISOLATION_V1"
ISOLATION_CHUNK = "lib/chunks/chunk-MZCJWS5Y.js"
PATCH_FILES = (
    "lib/chunks/chunk-PZ66FRIC.js", "lib/chunks/chunk-ZEYFMJQA.js",
    "lib/chunks/chunk-DJPASAUV.js", ISOLATION_CHUNK,
    "lib/bundled/qc-helper/docs/configuration/settings.md",
    "lib/chunks/chunk-XHF7WQ6B.js",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def assert_local(root: Path, path: Path) -> None:
    assert_local_path(path, root)


def remove_local(root: Path, path: Path) -> None:
    assert_local_tree(path, root)
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def local_environment(root: Path) -> dict[str, str]:
    state = root / ".localai"
    profile = state / "home"
    environment = os.environ.copy()
    original_profile = environment.get("USERPROFILE", "")
    if not original_profile:
        raise RuntimeError("USERPROFILE is missing; the original profile boundary cannot be established safely.")
    if os.path.normcase(os.path.normpath(original_profile)) == os.path.normcase(os.path.normpath(str(profile))):
        original_profile = environment.get("LOCALAI_ORIGINAL_USERPROFILE", "")
        if not original_profile.strip():
            raise RuntimeError("LOCALAI_ORIGINAL_USERPROFILE is missing for an already scoped profile; the original profile boundary cannot be established safely.")
    try:
        original_path = Path(original_profile).resolve(strict=True)
        if not original_path.is_dir():
            raise OSError("not a directory")
    except OSError as error:
        raise RuntimeError("The original user profile must identify an existing directory.") from error
    original_profile = str(original_path)
    environment.update({
        "USERPROFILE": str(profile), "HOME": str(profile),
        "APPDATA": str(profile / "AppData" / "Roaming"),
        "LOCALAPPDATA": str(profile / "AppData" / "Local"),
        "TEMP": str(state / "tmp"), "TMP": str(state / "tmp"), "TMPDIR": str(state / "tmp"),
        "QWEN_HOME": str(state / "qwen"), "QWEN_RUNTIME_DIR": str(state / "qwen-runtime"),
        "QWEN_CODE_MCP_APPROVALS_PATH": str(state / "qwen" / "mcpApprovals.json"),
        "QWEN_CODE_TRUSTED_FOLDERS_PATH": str(state / "qwen" / "trustedFolders.json"),
        "QWEN_CODE_SYSTEM_SETTINGS_PATH": str(state / "system-settings.json"),
        "QWEN_CODE_SYSTEM_DEFAULTS_PATH": str(state / "system-defaults.json"),
        "LOCALAI_INSTALL_ROOT": str(root), "PYTHONDONTWRITEBYTECODE": "1",
        "NODE_COMPILE_CACHE": str(state / "cache" / "node"),
        "CUDA_CACHE_PATH": str(state / "cache" / "cuda"),
        "NPM_CONFIG_CACHE": str(state / "cache" / "npm"),
        "LOCALAI_ORIGINAL_USERPROFILE": original_profile,
    })
    return environment


def write_json(path: Path, value: object) -> None:
    assert_local(INSTALL_ROOT, path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    assert_local(INSTALL_ROOT, temporary)
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def check_prerequisites() -> None:
    if sys.version_info < (3, 10):
        raise RuntimeError("Python 3.10 or newer is required.")
    if os.name != "nt" or platform.machine().lower() not in {"amd64", "x86_64"}:
        raise RuntimeError("This installation requires 64-bit Windows and Python 3.10 or newer.")
    if not shutil.which("powershell.exe"):
        raise RuntimeError("Windows PowerShell was not found.")
    driver = shutil.which("nvidia-smi.exe") or shutil.which("nvidia-smi")
    if driver is None:
        raise RuntimeError("NVIDIA driver tools were not found. Install a driver supporting CUDA 13.3.")
    result = subprocess.run([driver], capture_output=True, text=True, timeout=20, check=False)
    match = re.search(r"\bCUDA(?:\s+UMD)?\s+Version:\s*(\d+)\.(\d+)(?=\s|\||$)", result.stdout)
    if result.returncode or not match or tuple(map(int, match.groups())) < (13, 3):
        raise RuntimeError("The NVIDIA driver must advertise CUDA 13.3 or newer; no driver is installed automatically.")


def check_workspace(root: Path = INSTALL_ROOT) -> None:
    original = local_environment(root).get("LOCALAI_ORIGINAL_USERPROFILE")
    if not original:
        return
    profile = Path(original).resolve()
    cwd = Path.cwd().resolve()
    if cwd == profile or cwd.is_relative_to(profile / ".qwen") or cwd.is_relative_to(profile / ".agents"):
        raise RuntimeError("Launch from a working project below or outside the original profile, rather than the profile or its private Qwen directories.")
    git = shutil.which("git")
    if git:
        result = subprocess.run([git, "-C", str(cwd), "rev-parse", "--show-toplevel"], capture_output=True, text=True, timeout=5, check=False)
        if result.returncode == 0 and Path(result.stdout.strip()).resolve() == profile:
            raise RuntimeError("The working project's Git root is the original user profile. Choose a separate project root to keep global Qwen files isolated.")


def download(artifact: Artifact, directory: Path) -> Path:
    assert_local(directory, directory)
    directory.mkdir(parents=True, exist_ok=True)
    target = directory / artifact.name
    partial = target.with_name(target.name + ".part")
    assert_local(directory, target)
    assert_local(directory, partial)
    if target.is_file() and target.stat().st_size == artifact.size and sha256(target) == artifact.sha256:
        return target
    # A failed or interrupted transfer is never treated as a completed artifact.
    partial.unlink(missing_ok=True)
    request = urllib.request.Request(artifact.url, headers={"User-Agent": "localai-pinned-installer"})
    digest = hashlib.sha256()
    total = 0
    started = last_feedback = time.monotonic()
    print(f"Downloading {artifact.name} ({artifact.size / 1024**3:.2f} GiB)", flush=True)
    try:
        with urllib.request.urlopen(request, timeout=60) as response, partial.open("wb") as output:
            while block := response.read(4 * 1024 * 1024):
                output.write(block)
                digest.update(block)
                total += len(block)
                if total > artifact.size:
                    raise RuntimeError(f"Downloaded size exceeds pinned size: {artifact.name}")
                now = time.monotonic()
                if now - last_feedback >= 2:
                    rate = total / max(now - started, 0.001)
                    print(f"  {100 * total / artifact.size:.1f}%  ETA {(artifact.size - total) / rate:.0f}s", flush=True)
                    last_feedback = now
        if total != artifact.size or digest.hexdigest() != artifact.sha256:
            raise RuntimeError(f"SHA-256 or size verification failed: {artifact.name}")
        os.replace(partial, target)
        return target
    except BaseException:
        partial.unlink(missing_ok=True)
        raise


def checked_extract(archive: Path, destination: Path) -> None:
    assert_local_tree(destination, destination.parent)
    with zipfile.ZipFile(archive) as source:
        expanded_size = sum(entry.file_size for entry in source.infolist())
        if shutil.disk_usage(archive.parent).free < expanded_size + 64 * 1024**2:
            raise RuntimeError(f"Not enough free disk space to extract {archive.name}.")
        for entry in source.infolist():
            name = entry.filename.replace("\\", "/")
            relative = PureWindowsPath(name)
            mode = entry.external_attr >> 16
            if relative.root or relative.drive or ".." in relative.parts or any(":" in part for part in relative.parts) or stat.S_ISLNK(mode):
                raise RuntimeError(f"Unsafe ZIP entry: {entry.filename}")
            target = destination.joinpath(*relative.parts)
            assert_local(destination, target)
            if not target.resolve().is_relative_to(destination.resolve()):
                raise RuntimeError(f"Unsafe ZIP entry: {entry.filename}")
        destination.mkdir(parents=True, exist_ok=True)
        source.extractall(destination)


def validate_qwen(runtime: Path) -> None:
    package = json.loads((runtime / "package.json").read_text(encoding="utf-8"))
    if package.get("version") != QWEN_VERSION:
        raise RuntimeError(f"Qwen Code version must be {QWEN_VERSION}.")
    for relative in ("lib/cli.js", "bin/qwen.cmd", "node/node.exe"):
        if not (runtime / relative).is_file():
            raise RuntimeError(f"Qwen release is missing {relative}")


def protect_environment(runtime: Path) -> None:
    assert_local_tree(runtime, runtime)
    validate_qwen(runtime)
    path = runtime / ISOLATION_CHUNK
    text = path.read_text(encoding="utf-8")
    anchor = "var PROJECT_ENV_HARDCODED_EXCLUSIONS = [\n"
    if text.count(anchor) != 1:
        raise RuntimeError("Pinned Qwen environment isolation anchor is missing or ambiguous.")
    start = text.index(anchor) + len(anchor)
    end = text.index("\n];", start)
    exclusions = text[start:end]
    if ISOLATION_MARKER not in exclusions:
        if sha256(path) != "09bdc60fbf1de60f18fdb7396b3f56a8a1e560fb7155873507893e3d06b3dac1":
            raise RuntimeError("Pinned Qwen environment module SHA-256 does not match the verified release.")
        added = [key for key in LOCAL_ENV_KEYS if f'"{key}"' not in exclusions]
        insertion = f"  // {ISOLATION_MARKER}\n" + "".join(f'  "{key}",\n' for key in added)
        text = text[:start] + insertion + text[start:]
        path.write_text(text, encoding="utf-8", newline="\n")
    else:
        if any(f'"{key}"' not in exclusions for key in LOCAL_ENV_KEYS):
            raise RuntimeError("Pinned Qwen environment isolation exclusions are incomplete.")
    # A project below the original profile must not import that profile as an ancestor.
    boundary_marker = "LOCALAI_ORIGINAL_PROFILE_BOUNDARY_V1"
    environment_path = runtime / "lib/chunks/chunk-XHF7WQ6B.js"
    environment_text = environment_path.read_text(encoding="utf-8")
    anchor = "  while (true) {\n    if (currentDir === homeDir) {"
    if boundary_marker not in environment_text:
        if environment_text.count(anchor) != 1 or sha256(environment_path) != "50b50ad09a7b7c85d92c9619f3ca0f8dbbf9bc8f666b6b1d7bfa1fef39a85391":
            raise RuntimeError("Pinned Qwen ancestor environment discovery does not match the verified release.")
        replacement = "  while (true) {\n    // " + boundary_marker + "\n" + '''    const originalHome = process.env["LOCALAI_ORIGINAL_USERPROFILE"];
    if (originalHome && currentDir.toLowerCase() === path.resolve(originalHome).toLowerCase()) {
      pushHomeCandidates();
      return found;
    }
    if (currentDir === homeDir) {'''
        environment_path.write_text(environment_text.replace(anchor, replacement), encoding="utf-8", newline="\n")
    memory_path = runtime / "lib/chunks/chunk-PZ66FRIC.js"
    memory_text = memory_path.read_text(encoding="utf-8")
    anchor = "      while (currentDir && currentDir !== path73.dirname(currentDir)) {\n"
    if boundary_marker not in memory_text:
        if memory_text.count(anchor) != 1:
            raise RuntimeError("Pinned Qwen ancestor memory discovery anchor is missing or ambiguous.")
        replacement = anchor + "        // " + boundary_marker + "\n" + '''        const originalHome = process.env["LOCALAI_ORIGINAL_USERPROFILE"];
        if (originalHome && currentDir.toLowerCase() === path73.resolve(originalHome).toLowerCase()) {
          break;
        }
'''
        memory_path.write_text(memory_text.replace(anchor, replacement), encoding="utf-8", newline="\n")


def verify_llama(runtime: Path) -> None:
    result = subprocess.run(
        [str(runtime / "llama-server.exe"), "--version"], capture_output=True,
        text=True, timeout=30, check=False,
    )
    output = result.stdout + result.stderr
    if result.returncode or "10636" not in output or LLAMA_COMMIT[:7] not in output:
        raise RuntimeError("llama.cpp b10636 loader/version validation failed. Check CUDA DLLs and the NVIDIA driver.\n" + output)


def deploy_orchestrator(root: Path, environment: dict[str, str]) -> None:
    result = subprocess.run(
        ["powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
         "-File", str(root / "scripts" / "install_orchestrator.ps1")],
        env=environment, check=False,
    )
    if result.returncode:
        raise RuntimeError(f"Orchestration/patch deployment failed: exit={result.returncode}")


def tree_hashes(root: Path, directory: Path) -> dict[str, str]:
    assert_local_tree(directory, root)
    files = {}
    for path in sorted(directory.rglob("*")):
        assert_local(root, path)
        if path.is_file():
            files[path.relative_to(root).as_posix()] = sha256(path)
    return files


def source_hashes(root: Path) -> dict[str, str]:
    paths = [root / "config" / "local.example.ps1", root / "config" / "settings.example.json", root / "qwen.cmd"]
    for name, suffixes in (("scripts", {".py", ".ps1", ".cmd"}), ("patches", {".ps1"}),
                           ("orchestration", {".py", ".md"}), ("benchmark", {".ps1"})):
        paths.extend(p for p in (root / name).rglob("*") if p.is_file() and p.suffix in suffixes)
    paths.append(root / ".localai" / "config" / "local.ps1")
    for path in paths:
        assert_local(root, path)
    return {p.relative_to(root).as_posix(): sha256(p) for p in paths if p.is_file()}


def managed_files(root: Path) -> list[Path]:
    state = root / ".localai"
    paths = [state / "qwen" / relative for relative in (
        "settings.json", "QWEN.md", "agents/algorithm-agent.md", "agents/test-agent.md",
    )] + [state / "system-settings.json", state / "system-defaults.json", state / "install.json"]
    for path in paths:
        assert_local(root, path)
    return paths


def transaction_files(root: Path) -> list[Path]:
    return managed_files(root) + [root / "runtime" / "qwen-code" / relative for relative in PATCH_FILES]


def verify_settings(root: Path) -> None:
    managed_files(root)
    state = root / ".localai"
    settings = json.loads((state / "qwen" / "settings.json").read_text(encoding="utf-8"))
    system = json.loads((state / "system-settings.json").read_text(encoding="utf-8"))
    if settings.get("general", {}).get("enableAutoUpdate") is not False or system.get("general", {}).get("enableAutoUpdate") is not False:
        raise RuntimeError("Qwen built-in auto-update must remain disabled.")
    if settings.get("mcpServers", {}).get("context7", {}).get("httpUrl") != "https://mcp.context7.com/mcp":
        raise RuntimeError("Context7 configuration is missing.")
    aliases = [settings["model"]["name"]]
    for name in ("algorithm-agent.md", "test-agent.md"):
        text = (state / "qwen" / "agents" / name).read_text(encoding="utf-8")
        matches = re.findall(r"(?m)^model:\s*([^\r\n]+)$", text)
        if len(matches) != 1:
            raise RuntimeError(f"Agent routing/policy verification failed: {name}")
        source_path = root / "orchestration" / "agents" / name
        assert_local(root, source_path)
        expected = re.sub(r"(?m)^model:\s*[^\r\n]+$", lambda _: "model: " + matches[0].strip(), source_path.read_text(encoding="utf-8"), count=1)
        if text != expected:
            raise RuntimeError(f"Agent policy differs from the authoritative source: {name}")
        aliases.append(matches[0].strip())
    if len(set(aliases)) != 3 or settings["model"].get("maxSubagentDepth") != 1 or settings.get("agents", {}).get("maxParallelAgents") != 1:
        raise RuntimeError("Role routing/delegation limits are invalid.")
    providers = settings["modelProviders"]["openai"]
    windows = []
    for alias in aliases:
        matches = [provider for provider in providers if provider["id"] == alias]
        if len(matches) != 1:
            raise RuntimeError(f"Expected exactly one role provider: {alias}")
        generation = matches[0]["generationConfig"]
        if int(generation["contextWindowSize"]) <= 0 or int(generation["extra_body"]["thinking_budget_tokens"]) <= 0 or generation["reasoning"]["effort"] != generation["extra_body"]["reasoning_effort"]:
            raise RuntimeError(f"Role context/reasoning verification failed: {alias}")
        windows.append(generation["contextWindowSize"])
    if len(set(windows)) != 1 or int(settings["model"]["maxContextGrowthTokensPerTurn"]) <= 0:
        raise RuntimeError("Role context/growth settings are inconsistent.")
    template = json.loads((root / "config" / "settings.example.json").read_text(encoding="utf-8"))
    if any(settings.get("memory", {}).get(key) is not False for key in template["memory"]):
        raise RuntimeError("Managed automatic memory features must remain disabled.")
    paths = {
        "qwen-orchestration-dispatcher": root / "orchestration" / "hook_dispatcher.py",
        "qwen-prompt-memory-carrier": root / "orchestration" / "hook_dispatcher.py",
        "qwen-orchestration-maintenance": root / "orchestration" / "maintenance_hook.py",
        "qwen-server-stop": root / "scripts" / "qwen_server.ps1",
    }
    for event, groups in template["hooks"].items():
        actual = [(group.get("matcher"), hook) for group in settings["hooks"].get(event, []) for hook in group.get("hooks", [])]
        for group in groups:
            for expected in group["hooks"]:
                matches = [hook for matcher, hook in actual if matcher == group["matcher"] and hook.get("name") == expected["name"]]
                quoted = "'" + str(paths[expected["name"]]).replace("'", "''") + "'"
                if len(matches) != 1 or quoted not in matches[0].get("command", ""):
                    raise RuntimeError(f"Local managed hook verification failed: {event}/{expected['name']}")
    if settings.get("disableAllHooks") is not False:
        raise RuntimeError("Managed hooks must remain enabled.")


def recover_transaction(root: Path, staging: Path) -> None:
    journal = staging / "transaction.json"
    assert_local(root, journal)
    if not journal.is_file():
        return
    transaction = json.loads(journal.read_text(encoding="utf-8"))
    for key, directory in (("qwen", root / "runtime" / "qwen-code"), ("llama", root / "runtime" / "llama.cpp")):
        if not transaction.get("replace", {}).get(key, True):
            continue
        backup = staging / ("old-" + key)
        assert_local(root, backup)
        assert_local(root, directory)
        if backup.exists():
            remove_local(root, directory)
            os.replace(backup, directory)
        elif not transaction[key]:
            remove_local(root, directory)
    for path in transaction_files(root):
        backup = staging / "files" / path.relative_to(root)
        assert_local(root, path)
        assert_local(root, backup)
        if backup.is_file():
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(backup, path)
        elif path.relative_to(root).as_posix() not in transaction["existing_files"]:
            path.unlink(missing_ok=True)
    print("LOCALAI_INSTALL_ROLLBACK=PASS", flush=True)


@contextmanager
def setup_lock(state: Path):
    assert_local(state, state / "setup.lock")
    with (state / "setup.lock").open("a+b") as stream:
        if stream.tell() == 0:
            stream.write(b"0")
            stream.flush()
        stream.seek(0)
        try:
            msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
        except OSError as error:
            raise RuntimeError("Another setup/update is active for this clone. Retry after it finishes.") from error
        try:
            yield
        finally:
            stream.seek(0)
            msvcrt.locking(stream.fileno(), msvcrt.LK_UNLCK, 1)


def install(root: Path = INSTALL_ROOT) -> None:
    root = root.absolute()
    check_workspace(root)
    for directory in (root, root / ".localai", root / "runtime", root / "models"):
        assert_local(root, directory)
    assert_local_tree(root / ".localai", root)
    state = root / ".localai"
    state.mkdir(parents=True, exist_ok=True)
    with setup_lock(state):
        _install(root)


def check_idle(root: Path) -> None:
    clients = root / ".localai" / "qwen" / "runtime_clients"
    assert_local_tree(clients, root)
    for path in clients.rglob("*.lock"):
        assert_local(root, path)
        try:
            with path.open("r+b"):
                pass
        except FileNotFoundError:
            continue
        except OSError as error:
            raise RuntimeError("Close this clone's coding/chat clients before repairing or refreshing the installation.") from error


def readiness(root: Path = INSTALL_ROOT) -> bool:
    try:
        state = root / ".localai"
        assert_local_tree(state, root)
        path = state / "install.json"
        assert_local(root, path)
        receipt = json.loads(path.read_text(encoding="utf-8"))
        model = root / "models" / MODEL_NAME
        assert_local(root, model)
        info = model.stat()
        print("Verifying model SHA-256...", flush=True)
        if info.st_size != ARTIFACTS["model"].size or sha256(model) != ARTIFACTS["model"].sha256:
            return False
        managed = {p.relative_to(root).as_posix(): sha256(p) for p in managed_files(root) if p.is_file() and p != path}
        valid = (
            receipt["pins"] == {key: asdict(value) for key, value in ARTIFACTS.items()}
            and receipt["sources"] == source_hashes(root)
            and receipt["model"] == {"sha256": ARTIFACTS["model"].sha256, "size": info.st_size, "mtime_ns": info.st_mtime_ns}
            and receipt["runtime"] == {**tree_hashes(root, root / "runtime" / "qwen-code"), **tree_hashes(root, root / "runtime" / "llama.cpp")}
            and receipt["managed"] == managed
            and all(p.is_file() for p in managed_files(root))
        )
        if valid:
            validate_qwen(root / "runtime" / "qwen-code")
            verify_settings(root)
        return valid
    except (OSError, ValueError, KeyError, TypeError, RuntimeError):
        return False


def _install(root: Path) -> None:
    state = root / ".localai"
    staging = state / "staging"
    assert_local(root, staging)
    journal = staging / "transaction.json"
    assert_local(root, journal)
    if journal.is_file():
        check_idle(root)
    recover_transaction(root, staging)
    remove_local(root, staging)
    environment = local_environment(root)
    for key in ("USERPROFILE", "APPDATA", "LOCALAPPDATA", "TEMP", "QWEN_HOME", "QWEN_RUNTIME_DIR", "NODE_COMPILE_CACHE", "CUDA_CACHE_PATH", "NPM_CONFIG_CACHE"):
        path = Path(environment[key])
        assert_local(root, path)
        path.mkdir(parents=True, exist_ok=True)
    config = state / "config" / "local.ps1"
    assert_local(root, config)
    if not config.exists():
        config.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / "config" / "local.example.ps1", config)
    receipt_path = state / "install.json"
    assert_local(root, receipt_path)
    receipt = {}
    if receipt_path.is_file():
        try:
            receipt = json.loads(receipt_path.read_text(encoding="utf-8"))
            if not isinstance(receipt, dict):
                receipt = {}
        except (ValueError, OSError):
            pass
    pins = {key: asdict(value) for key, value in ARTIFACTS.items()}
    qwen = root / "runtime" / "qwen-code"
    llama = root / "runtime" / "llama.cpp"
    model = root / "models" / MODEL_NAME
    assert_local(root, model)
    model_info = {"sha256": ARTIFACTS["model"].sha256}
    if model.exists():
        info = model.stat()
        model_info.update(size=info.st_size, mtime_ns=info.st_mtime_ns)
        print("Verifying model SHA-256...", flush=True)
        if info.st_size != ARTIFACTS["model"].size or sha256(model) != ARTIFACTS["model"].sha256:
            raise RuntimeError(f"Model SHA-256 or size verification failed: {model}")
    sources = source_hashes(root)
    current_qwen = tree_hashes(root, qwen)
    current_llama = tree_hashes(root, llama)
    previous_runtime = receipt.get("runtime", {})
    previous_pins = receipt.get("pins", {})
    if not isinstance(previous_runtime, dict):
        previous_runtime = {}
    if not isinstance(previous_pins, dict):
        previous_pins = {}
    qwen_valid = bool(current_qwen) and previous_pins.get("qwen") == pins["qwen"] and current_qwen == {key: value for key, value in previous_runtime.items() if key.startswith("runtime/qwen-code/")}
    llama_valid = bool(current_llama) and all(previous_pins.get(key) == pins[key] for key in ("llama", "cuda")) and current_llama == {key: value for key, value in previous_runtime.items() if key.startswith("runtime/llama.cpp/")}
    if receipt.get("pins") == pins and receipt.get("sources") == sources and receipt.get("model") == model_info:
        managed = {p.relative_to(root).as_posix(): sha256(p) for p in managed_files(root) if p.is_file() and p != receipt_path}
        if qwen_valid and llama_valid and receipt.get("managed") == managed and all(path.is_file() for path in managed_files(root)):
            validate_qwen(qwen)
            verify_settings(root)
            print("LOCALAI_INSTALL_STATUS=REUSED", flush=True)
            return
    check_prerequisites()
    check_idle(root)
    download_keys = ([] if qwen_valid else ["qwen"]) + ([] if llama_valid else ["llama", "cuda"])
    required_space = 3 * sum(ARTIFACTS[key].size for key in download_keys) + 64 * 1024**2
    if not model.exists():
        required_space += ARTIFACTS["model"].size
    if shutil.disk_usage(root).free < required_space:
        raise RuntimeError(f"Not enough free disk space for setup. At least {required_space / 1024**3:.2f} GiB is required.")
    print("Initializing the pinned local installation...", flush=True)
    downloads = state / "downloads"
    assert_local(root, downloads)
    archives = {key: download(ARTIFACTS[key], downloads) for key in download_keys}
    for key, archive in archives.items():
        checked_extract(archive, staging / key)
    candidates = {}
    if not qwen_valid:
        candidates["qwen"] = staging / "qwen" / "qwen-code"
        validate_qwen(candidates["qwen"])
    if not llama_valid:
        servers = list((staging / "llama").rglob("llama-server.exe"))
        if len(servers) != 1:
            raise RuntimeError("The pinned llama.cpp archive must contain exactly one llama-server.exe.")
        candidate_llama = servers[0].parent
        if not (candidate_llama / "ggml-cuda.dll").is_file():
            raise RuntimeError("The pinned llama.cpp CUDA backend is missing.")
        cuda_dlls = list((staging / "cuda").rglob("*.dll"))
        if {path.name.lower() for path in cuda_dlls} != {"cudart64_13.dll", "cublas64_13.dll", "cublaslt64_13.dll"}:
            raise RuntimeError("The pinned CUDA runtime archive must contain cudart and both cuBLAS DLLs.")
        for path in cuda_dlls:
            shutil.copy2(path, candidate_llama / path.name)
        verify_llama(candidate_llama)
        candidates["llama"] = candidate_llama
    if not model.exists():
        model_download = download(ARTIFACTS["model"], downloads)
        model.parent.mkdir(parents=True, exist_ok=True)
        os.replace(model_download, model)
    info = model.stat()
    model_info.update(size=info.st_size, mtime_ns=info.st_mtime_ns)
    existing_files = []
    for path in transaction_files(root):
        assert_local(root, path)
        if path.is_file():
            existing_files.append(path.relative_to(root).as_posix())
            backup = staging / "files" / path.relative_to(root)
            assert_local(root, backup)
            backup.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, backup)
    write_json(staging / "transaction.json", {"qwen": qwen.exists(), "llama": llama.exists(), "replace": {key: key in candidates for key in ("qwen", "llama")}, "existing_files": existing_files})
    cleanup_staging = False
    try:
        for key, candidate in candidates.items():
            target = qwen if key == "qwen" else llama
            assert_local(root, target)
            target.parent.mkdir(parents=True, exist_ok=True)
            if target.exists():
                os.replace(target, staging / ("old-" + key))
            os.replace(candidate, target)
        write_json(state / "system-settings.json", {"general": {"enableAutoUpdate": False}})
        write_json(state / "system-defaults.json", {})
        deploy_orchestrator(root, environment)
        validate_qwen(qwen)
        verify_settings(root)
        runtime_hashes = {**tree_hashes(root, qwen), **tree_hashes(root, llama)}
        managed = {p.relative_to(root).as_posix(): sha256(p) for p in managed_files(root) if p.is_file() and p != receipt_path}
        write_json(receipt_path, {"pins": pins, "sources": source_hashes(root), "runtime": runtime_hashes, "managed": managed, "model": model_info})
        cleanup_staging = True
    except BaseException as error:
        try:
            recover_transaction(root, staging)
            cleanup_staging = True
        except Exception as rollback_error:
            raise RuntimeError(f"Setup failed ({error}); rollback also failed ({rollback_error}). Recovery files retained at {staging}.") from rollback_error
        raise
    finally:
        if cleanup_staging:
            remove_local(root, staging)
    for path in archives.values():
        path.unlink(missing_ok=True)
    print("LOCALAI_INSTALL_STATUS=READY", flush=True)


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["protect-environment"]:
            protect_environment(INSTALL_ROOT / "runtime" / "qwen-code")
        elif sys.argv[1:] == ["check-workspace"]:
            check_workspace()
            print(local_environment(INSTALL_ROOT)["LOCALAI_ORIGINAL_USERPROFILE"])
        elif sys.argv[1:] == ["check"]:
            valid = readiness()
            print("QWEN_UPDATE_STATUS=" + ("UP_TO_DATE" if valid else "INITIALIZATION_REQUIRED"))
            raise SystemExit(0 if valid else 1)
        elif sys.argv[1:]:
            raise RuntimeError("Run install_local.py without arguments to initialize this clone.")
        else:
            install()
    except Exception as error:
        print(f"LOCALAI_INSTALL_STATUS=FAIL\n{error}", file=sys.stderr)
        raise SystemExit(1)
