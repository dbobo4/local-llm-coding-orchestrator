from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

QWEN_ROOT_VALUE = os.environ.get("LOCALAI_QWEN_ROOT")
if not QWEN_ROOT_VALUE:
    raise RuntimeError("LOCALAI_QWEN_ROOT is required")

QWEN_ROOT = Path(QWEN_ROOT_VALUE)
RUNTIME = (
    QWEN_ROOT
    / "runtime"
    / "qwen-code"
    / "standalone"
    / "qwen-code"
    / "lib"
    / "chunks"
    / "chunk-PZ66FRIC.js"
)
MARKER = "LOCALAI_SPECIALIST_GROWTH_TERMINATION_V5_5"


def read_preserve(path: Path):
    raw = path.read_bytes()
    bom = raw.startswith(b"\xef\xbb\xbf")
    payload = raw[3:] if bom else raw
    nl = "\r\n" if b"\r\n" in payload else "\n"
    text = payload.decode("utf-8").replace("\r\n", "\n")
    return raw, text, nl, bom


def encode_preserve(text: str, nl: str, bom: bool) -> bytes:
    if nl == "\r\n":
        text = text.replace("\n", "\r\n")
    raw = text.encode("utf-8")
    return (b"\xef\xbb\xbf" + raw) if bom else raw


def replace_exact(text: str, old: str, new: str, count: int, label: str) -> str:
    found = text.count(old)
    if found != count:
        raise RuntimeError(f"{label}: expected {count}, found {found}")
    return text.replace(old, new, count)


def node_check(path: Path):
    p = subprocess.run(
        ["node", "--check", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if p.returncode:
        raise RuntimeError((p.stderr or p.stdout).strip())


def patch_runtime(rt: str) -> str:
    if MARKER in rt:
        return rt

    old = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal) {
    const input = {
      ...this.createBaseInput("SubagentStop" /* SubagentStop */),
      permission_mode: permissionMode,
      stop_hook_active: stopHookActive,
      agent_id: agentId,
      agent_type: agentType,
      agent_transcript_path: agentTranscriptPath,
      last_assistant_message: lastAssistantMessage,
      background_tasks: this.getBackgroundTaskSnapshot(),
      crons: this.getCronJobSnapshot()
    };'''
    new = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal, terminateReason) {
    // LOCALAI_SPECIALIST_GROWTH_TERMINATION_V5_5
    const input = {
      ...this.createBaseInput("SubagentStop" /* SubagentStop */),
      permission_mode: permissionMode,
      stop_hook_active: stopHookActive,
      agent_id: agentId,
      agent_type: agentType,
      agent_transcript_path: agentTranscriptPath,
      last_assistant_message: lastAssistantMessage,
      ...(terminateReason !== void 0 ? { terminate_reason: terminateReason } : {}),
      background_tasks: this.getBackgroundTaskSnapshot(),
      crons: this.getCronJobSnapshot()
    };'''
    rt = replace_exact(rt, old, new, 1, "payload builder")

    old = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal) {
    const result = await this.hookEventHandler.fireSubagentStopEvent(
      agentId,
      agentType,
      agentTranscriptPath,
      lastAssistantMessage,
      stopHookActive,
      permissionMode,
      signal
    );'''
    new = '''  async fireSubagentStopEvent(agentId, agentType, agentTranscriptPath, lastAssistantMessage, stopHookActive, permissionMode, signal, terminateReason) {
    const result = await this.hookEventHandler.fireSubagentStopEvent(
      agentId,
      agentType,
      agentTranscriptPath,
      lastAssistantMessage,
      stopHookActive,
      permissionMode,
      signal,
      terminateReason
    );'''
    rt = replace_exact(rt, old, new, 1, "forwarding wrapper")

    old = '''          subagent.getFinalText(),
          stopHookActive,
          resolvedMode,
          signal
        );'''
    new = '''          subagent.getFinalText(),
          stopHookActive,
          resolvedMode,
          signal,
          subagent.getTerminateMode()
        );'''
    rt = replace_exact(rt, old, new, 2, "normal stop callsites")

    old = '''                  input["last_assistant_message"] || "",
                  input["stop_hook_active"] || false,
                  input["permission_mode"] || "default" /* Default */,
                  signal
                );'''
    new = '''                  input["last_assistant_message"] || "",
                  input["stop_hook_active"] || false,
                  input["permission_mode"] || "default" /* Default */,
                  signal,
                  input["terminate_reason"] || void 0
                );'''
    rt = replace_exact(rt, old, new, 1, "replay forwarding")

    old = '''        const visibleFinalText = finalText || "(subagent produced no model-visible output)";
        return {
          llmContent: [{ text: visibleFinalText + wtSuffix }],
          returnDisplay: this.currentDisplay
        };'''
    new = '''        if (terminateMode === "GROWTH_LIMIT") {
          return {
            llmContent: [{ text: (finalText || "Agent stopped: per-turn context growth limit reached.") + wtSuffix }],
            returnDisplay: this.currentDisplay
          };
        }
        const visibleFinalText = finalText || "(subagent produced no model-visible output)";
        return {
          llmContent: [{ text: visibleFinalText + wtSuffix }],
          returnDisplay: this.currentDisplay
        };'''
    rt = replace_exact(rt, old, new, 1, "parent-visible receipt")

    for needle in (
        MARKER,
        "terminate_reason: terminateReason",
        "subagent.getTerminateMode()",
        'input["terminate_reason"] || void 0',
        'terminateMode === "GROWTH_LIMIT"',
    ):
        if needle not in rt:
            raise RuntimeError(f"verification missing: {needle}")

    return rt


def main() -> int:
    if not RUNTIME.is_file():
        raise FileNotFoundError(RUNTIME)

    raw, text, nl, bom = read_preserve(RUNTIME)
    patched = patch_runtime(text)

    if patched == text:
        print(f"{MARKER}=ALREADY_APPLIED")
        return 0

    candidate = encode_preserve(patched, nl, bom)

    fd, tmp_name = tempfile.mkstemp(suffix=".js")
    os.close(fd)
    tmp = Path(tmp_name)
    try:
        tmp.write_bytes(candidate)
        node_check(tmp)
        RUNTIME.write_bytes(candidate)
        try:
            node_check(RUNTIME)
        except Exception:
            RUNTIME.write_bytes(raw)
            raise
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass

    print(f"{MARKER}=APPLIED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
