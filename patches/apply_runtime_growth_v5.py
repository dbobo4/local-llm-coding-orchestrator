#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

QWEN_ROOT_VALUE = os.environ.get("LOCALAI_QWEN_ROOT")
if not QWEN_ROOT_VALUE:
    raise RuntimeError("LOCALAI_QWEN_ROOT is required")
QWEN_ROOT = Path(QWEN_ROOT_VALUE)
ROOT = QWEN_ROOT / "runtime" / "qwen-code" / "standalone" / "qwen-code"
CHUNKS = ROOT / "lib" / "chunks"

PZ = CHUNKS / "chunk-PZ66FRIC.js"
SCHEMA = CHUNKS / "chunk-ZEYFMJQA.js"
LOADER = CHUNKS / "chunk-DJPASAUV.js"
DOCS = ROOT / "lib" / "bundled" / "qc-helper" / "docs" / "configuration" / "settings.md"

MARKER = "LOCALAI_TURN_GROWTH_BUDGET_V5"
DEFAULT_LIMIT = 0
BACKUP_SUFFIX = ".pre-localai-repo-growth-v5.bak"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest().upper()


def read_text_preserve(path: Path):
    raw = path.read_bytes()
    newline = "\r\n" if b"\r\n" in raw else "\n"
    # Normalize internally so LF patch anchors also match CRLF runtime files.
    # write_text_preserve() restores the original newline convention on write.
    text = raw.decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return text, newline


def write_text_preserve(path: Path, text: str, newline: str):
    normalized = text.replace("\r\n", "\n").replace("\r", "\n")
    if newline == "\r\n":
        normalized = normalized.replace("\n", "\r\n")
    path.write_bytes(normalized.encode("utf-8"))


def backup_once(path: Path):
    backup = Path(str(path) + BACKUP_SUFFIX)
    if not backup.exists():
        shutil.copy2(path, backup)
    return backup


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly 1 anchor, found {count}")
    return text.replace(old, new, 1)


def insert_after_line_containing(text: str, needle: str, new_line: str, label: str) -> str:
    lines = text.splitlines()
    hits = [i for i, line in enumerate(lines) if needle in line]
    if len(hits) != 1:
        raise RuntimeError(f"{label}: expected exactly 1 line containing {needle!r}, found {len(hits)}")
    i = hits[0]
    if i + 1 < len(lines) and new_line.strip() == lines[i + 1].strip():
        return text
    lines.insert(i + 1, new_line)
    trailing = "\n" if text.endswith(("\n", "\r")) else ""
    return "\n".join(lines) + trailing


def patch_pz(text: str) -> str:
    if MARKER in text:
        return text

    old = '''function validateMaxToolCallsPerTurn(value) {
  const resolved = value ?? DEFAULT_MAX_TOOL_CALLS_PER_TURN;
  if (!Number.isInteger(resolved)) {
    throw new FatalConfigError(
      `Invalid maxToolCallsPerTurn: must be an integer, got ${String(resolved)}`
    );
  }
  return resolved;
}
__name(validateMaxToolCallsPerTurn, "validateMaxToolCallsPerTurn");
var MAX_MODEL_FALLBACKS = 3;'''
    new = f'''function validateMaxToolCallsPerTurn(value) {{
  const resolved = value ?? DEFAULT_MAX_TOOL_CALLS_PER_TURN;
  if (!Number.isInteger(resolved)) {{
    throw new FatalConfigError(
      `Invalid maxToolCallsPerTurn: must be an integer, got ${{String(resolved)}}`
    );
  }}
  return resolved;
}}
__name(validateMaxToolCallsPerTurn, "validateMaxToolCallsPerTurn");
// {MARKER}
// LOCALAI_TURN_GROWTH_BUDGET_V5_4_PLAIN_CHAT_ISOLATION
var LOCALAI_DEFAULT_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN = {DEFAULT_LIMIT};
function validateMaxContextGrowthTokensPerTurn(value) {{
  const resolved = value ?? LOCALAI_DEFAULT_MAX_CONTEXT_GROWTH_TOKENS_PER_TURN;
  if (!Number.isInteger(resolved)) {{
    throw new FatalConfigError(
      `Invalid maxContextGrowthTokensPerTurn: must be an integer, got ${{String(resolved)}}`
    );
  }}
  return resolved;
}}
__name(validateMaxContextGrowthTokensPerTurn, "validateMaxContextGrowthTokensPerTurn");
var MAX_MODEL_FALLBACKS = 3;'''
    text = replace_once(text, old, new, "config validator")

    text = replace_once(
        text,
        '''  maxToolCallsPerTurn;
  maxToolCallsPerTurnExplicit;
  skipStartupContext;''',
        '''  maxToolCallsPerTurn;
  maxToolCallsPerTurnExplicit;
  maxContextGrowthTokensPerTurn;
  skipStartupContext;''',
        "config field",
    )

    text = replace_once(
        text,
        '''    this.maxToolCallsPerTurnExplicit = params.maxToolCallsPerTurn !== void 0;
    this.skipStartupContext = params.skipStartupContext ?? false;''',
        '''    this.maxToolCallsPerTurnExplicit = params.maxToolCallsPerTurn !== void 0;
    this.maxContextGrowthTokensPerTurn = validateMaxContextGrowthTokensPerTurn(
      params.maxContextGrowthTokensPerTurn
    );
    this.skipStartupContext = params.skipStartupContext ?? false;''',
        "config constructor",
    )

    text = replace_once(
        text,
        '''  isMaxToolCallsPerTurnExplicit() {
    return this.maxToolCallsPerTurnExplicit;
  }
  getSkipStartupContext() {''',
        '''  isMaxToolCallsPerTurnExplicit() {
    return this.maxToolCallsPerTurnExplicit;
  }
  /**
   * Hard cumulative context-growth budget for one logical interaction.
   * Values <= 0 disable the guard.
   */
  getMaxContextGrowthTokensPerTurn() {
    if (this.maxContextGrowthTokensPerTurn <= 0) {
      return Number.POSITIVE_INFINITY;
    }
    return this.maxContextGrowthTokensPerTurn;
  }
  getSkipStartupContext() {''',
        "config getter",
    )

    text = replace_once(
        text,
        '''  interactionStartTypeByOwner = /* @__PURE__ */ new WeakMap();
  loopDetector;''',
        '''  interactionStartTypeByOwner = /* @__PURE__ */ new WeakMap();
  // Telemetry-independent logical-interaction ownership for the LocalAI growth guard.
  interactionGrowthByPromptId = /* @__PURE__ */ new Map();
  loopDetector;''',
        "llmclient growth field",
    )

    anchor = '''    const startsInteraction = messageType === "userQuery" /* UserQuery */ || messageType === "retry" /* Retry */ || messageType === "cron" /* Cron */ || messageType === "notification" /* Notification */ || messageType === "teammate" /* Teammate */ || messageType === "goal" /* Goal */;
    let interactionOwner = startsInteraction ? void 0 : getActiveInteractionSpan(prompt_id);'''
    replacement = '''    const startsInteraction = messageType === "userQuery" /* UserQuery */ || messageType === "retry" /* Retry */ || messageType === "cron" /* Cron */ || messageType === "notification" /* Notification */ || messageType === "teammate" /* Teammate */ || messageType === "goal" /* Goal */;
    let localAiGrowthEntry;
    if (startsInteraction) {
      localAiGrowthEntry = {
        ownerToken: {},
        state: {
          limit: this.config.getMaxContextGrowthTokensPerTurn(),
          consumedTokens: 0,
          initialized: false,
          chargedLogicalSends: /* @__PURE__ */ new Set()
        }
      };
      this.interactionGrowthByPromptId.set(prompt_id, localAiGrowthEntry);
    } else {
      localAiGrowthEntry = this.interactionGrowthByPromptId.get(prompt_id);
      if (!localAiGrowthEntry) {
        localAiGrowthEntry = {
          ownerToken: {},
          state: {
            limit: this.config.getMaxContextGrowthTokensPerTurn(),
            consumedTokens: 0,
            initialized: false,
            chargedLogicalSends: /* @__PURE__ */ new Set()
          }
        };
        this.interactionGrowthByPromptId.set(prompt_id, localAiGrowthEntry);
      }
    }
    const localAiGrowthOwnerToken = localAiGrowthEntry.ownerToken;
    const localAiGrowthState = localAiGrowthEntry.state;
    const localAiLogicalSendKey = {};
    const localAiPriorOutputTokens = startsInteraction ? 0 : Math.max(
      0,
      this.getChat().getLastOutputTokenCount()
    );
    let interactionOwner = startsInteraction ? void 0 : getActiveInteractionSpan(prompt_id);'''
    text = replace_once(text, anchor, replacement, "root interaction growth ownership")

    text = replace_once(
        text,
        '''    const endCurrentInteraction = /* @__PURE__ */ __name((status, errorMessage, errorType) => {
      if (!interactionOwner || getActiveInteractionSpan(prompt_id) !== interactionOwner) {
        return;
      }''',
        '''    const endCurrentInteraction = /* @__PURE__ */ __name((status, errorMessage, errorType) => {
      const currentGrowthEntry = this.interactionGrowthByPromptId.get(prompt_id);
      if (currentGrowthEntry?.ownerToken === localAiGrowthOwnerToken) {
        this.interactionGrowthByPromptId.delete(prompt_id);
      }
      if (!interactionOwner || getActiveInteractionSpan(prompt_id) !== interactionOwner) {
        return;
      }''',
        "root growth cleanup",
    )

    text = replace_once(
        text,
        '''  async *run(model, req, signal) {
    try {
      const responseStream = await this.chat.sendMessageStream(
        model,
        {
          message: req,
          config: {
            abortSignal: signal
          }
        },
        this.prompt_id,
        this.goalContext
      );''',
        '''  async *run(model, req, signal, localAiGrowthState, localAiLogicalSendKey, localAiPriorOutputTokens) {
    try {
      const responseStream = await this.chat.sendMessageStream(
        model,
        {
          message: req,
          config: {
            abortSignal: signal
          }
        },
        this.prompt_id,
        this.goalContext,
        {
          growthBudgetState: localAiGrowthState,
          logicalSendKey: localAiLogicalSendKey,
          priorOutputTokens: localAiPriorOutputTokens
        }
      );''',
        "Turn.run growth plumbing",
    )

    old_marker = '''      if (e instanceof Error && e.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:")) {
        throw e;
      }'''
    new_marker = '''      if (e instanceof Error && (e.message.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:") || e.message.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:"))) {
        throw e;
      }'''
    text = replace_once(text, old_marker, new_marker, "Turn.run marker rethrow")

    text = replace_once(
        text,
        '''    let promptTokensForClamp = 0;
    let currentUserContent;
    try {''',
        '''    let promptTokensForClamp = 0;
    let currentUserContent;
    let localAiGrowthRemaining = Number.POSITIVE_INFINITY;
    const localAiGrowthPriorOutputTokens = Number.isFinite(options2?.priorOutputTokens) ? Math.max(0, options2.priorOutputTokens) : Math.max(0, this.lastOutputTokenCount);
    try {''',
        "LlmChat growth locals",
    )

    text = replace_once(
        text,
        '''      }
      this.history.push(userContent);
      currentUserContent = userContent;''',
        '''      }
      const localAiGrowthState = options2?.growthBudgetState;
      const localAiGrowthLogicalSendKey = options2?.logicalSendKey;
      if (localAiGrowthState && Number.isFinite(localAiGrowthState.limit) && localAiGrowthState.limit > 0) {
        localAiGrowthState.chargedLogicalSends ??= /* @__PURE__ */ new Set();
        const alreadyCharged = localAiGrowthLogicalSendKey !== void 0 && localAiGrowthState.chargedLogicalSends.has(localAiGrowthLogicalSendKey);
        if (!alreadyCharged) {
          if (!localAiGrowthState.initialized) {
            localAiGrowthState.initialized = true;
          } else {
            const localAiGrowthInputTokens = estimateContentTokens(
              [userContent],
              imageTokenEstimate
            );
            localAiGrowthState.consumedTokens = Math.max(0, localAiGrowthState.consumedTokens ?? 0) + localAiGrowthPriorOutputTokens + localAiGrowthInputTokens;
          }
          if (localAiGrowthLogicalSendKey !== void 0) {
            localAiGrowthState.chargedLogicalSends.add(localAiGrowthLogicalSendKey);
          }
        }
        localAiGrowthRemaining = Math.max(
          0,
          localAiGrowthState.limit - Math.max(0, localAiGrowthState.consumedTokens ?? 0)
        );
        if (localAiGrowthRemaining <= 0) {
          throw new Error(
            `LOCALAI_TURN_GROWTH_LIMIT_REACHED: consumed=${Math.max(0, localAiGrowthState.consumedTokens ?? 0)}; limit=${localAiGrowthState.limit}`
          );
        }
      }
      this.history.push(userContent);
      currentUserContent = userContent;''',
        "LlmChat cumulative growth charge",
    )

    text = replace_once(
        text,
        '''      const clampedMaxOutputTokens = clampOutputTokensToWindow(
        outputCeiling,
        contextWindowForClamp,
        promptTokensForClamp
      );
      params = {
        ...params,
        config: {
          ...params.config,
          maxOutputTokens: clampedMaxOutputTokens
        }
      };''',
        '''      const clampedMaxOutputTokens = clampOutputTokensToWindow(
        outputCeiling,
        contextWindowForClamp,
        promptTokensForClamp
      );
      const localAiGrowthClampedMaxOutputTokens = Number.isFinite(localAiGrowthRemaining) ? Math.max(
        1,
        Math.min(clampedMaxOutputTokens, Math.floor(localAiGrowthRemaining))
      ) : clampedMaxOutputTokens;
      params = {
        ...params,
        config: {
          ...params.config,
          maxOutputTokens: localAiGrowthClampedMaxOutputTokens
        }
      };''',
        "growth output clamp",
    )

    text = replace_once(
        text,
        '''          const resultStream = turn.run(model, requestToSend, signal);''',
        '''          const resultStream = turn.run(
            model,
            requestToSend,
            signal,
            localAiGrowthState,
            localAiLogicalSendKey,
            localAiPriorOutputTokens
          );''',
        "root Turn.run call",
    )

    old = '''            if (!localAiRolloverAttempted && !localAiRolloverOutputSeen && !signal.aborted && this.isLocalAiContextRolloverRequired(error)) {
              localAiRolloverAttempted = true;
              await this.localAiRolloverChat(error);
              turn = new Turn(this.getChat(), prompt_id, goalPermit);
              hasToolCalls = false;
              agentOutput.restartAttempt(false);
              yield { type: "retry" /* Retry */ };
              continue;
            }
            throw error;'''
    new = '''            if (!localAiRolloverAttempted && !localAiRolloverOutputSeen && !signal.aborted && this.isLocalAiContextRolloverRequired(error)) {
              localAiRolloverAttempted = true;
              await this.localAiRolloverChat(error);
              turn = new Turn(this.getChat(), prompt_id, goalPermit);
              hasToolCalls = false;
              agentOutput.restartAttempt(false);
              yield { type: "retry" /* Retry */ };
              continue;
            }
            const localAiGrowthErrorMessage = error instanceof Error ? error.message : String(error);
            if (localAiGrowthErrorMessage.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:")) {
              const consumedTokens = Math.max(0, localAiGrowthState.consumedTokens ?? 0);
              const limit = localAiGrowthState.limit;
              for (const goalEvent of await finalizeInterruptedGoalTurn()) {
                yield goalEvent;
              }
              this.cancelPendingMemoryPrefetch("no_safe_delivery_point");
              endCurrentInteraction(
                "error",
                "per-turn context growth limit exceeded",
                "turn_growth_limit"
              );
              yield {
                type: "turn_growth_limit_exceeded",
                value: {
                  consumedTokens,
                  limit,
                  message: `Per-turn context growth limit exceeded: ${consumedTokens} tokens >= ${limit} limit.`
                }
              };
              return turn;
            }
            throw error;'''
    text = replace_once(text, old, new, "root controlled growth termination")

    text = replace_once(
        text,
        '''    let finalText = "";
    let terminateMode = null;
    let localAiRolloverRetriedPromptId;''',
        '''    let finalText = "";
    let terminateMode = null;
    const localAiGrowthState = {
      limit: this.runtimeContext.getMaxContextGrowthTokensPerTurn(),
      consumedTokens: 0,
      initialized: false,
      chargedLogicalSends: /* @__PURE__ */ new Set()
    };
    let localAiRolloverRetriedPromptId;''',
        "specialist growth state",
    )

    text = replace_once(
        text,
        '''        const responseStream = await activeChat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId
        );''',
        '''        const responseStream = await activeChat.sendMessageStream(
          this.modelConfig.model || this.runtimeContext.getModel() || DEFAULT_QWEN_MODEL,
          messageParams,
          promptId,
          void 0,
          {
            growthBudgetState: localAiGrowthState,
            logicalSendKey: promptId
          }
        );''',
        "specialist LlmChat plumbing",
    )

    text = replace_once(
        text,
        '''      } catch (error3) {
        const rolloverMessage = error3 instanceof Error ? error3.message : String(error3);
        const isRolloverRequired = rolloverMessage.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");''',
        '''      } catch (error3) {
        const rolloverMessage = error3 instanceof Error ? error3.message : String(error3);
        if (rolloverMessage.startsWith("LOCALAI_TURN_GROWTH_LIMIT_REACHED:")) {
          terminateMode = "GROWTH_LIMIT";
          this.runtimeContext.getDebugLogger()?.warn(
            `[LOCALAI_TURN_GROWTH_LIMIT] subagent=${this.subagentId} consumed=${Math.max(0, localAiGrowthState.consumedTokens ?? 0)} limit=${localAiGrowthState.limit}`
          );
          break;
        }
        const isRolloverRequired = rolloverMessage.startsWith("LOCALAI_CONTEXT_ROLLOVER_REQUIRED:");''',
        "specialist growth termination",
    )

    text = replace_once(
        text,
        '''    case "TIMEOUT" /* TIMEOUT */:
      return { text: "Agent stopped: time limit reached.", level: "warning" };''',
        '''    case "GROWTH_LIMIT":
      return {
        text: "Agent stopped: per-turn context growth limit reached.",
        level: "warning"
      };
    case "TIMEOUT" /* TIMEOUT */:
      return { text: "Agent stopped: time limit reached.", level: "warning" };''',
        "specialist terminateModeMessage",
    )

    return text


def patch_schema(text: str) -> str:
    if "maxContextGrowthTokensPerTurn:" in text:
        return text
    old = '''      maxToolCallsPerTurn: {
        type: "integer",
        label: "Max Tool Calls Per Turn",
        category: "Model",
        requiresRestart: false,
        default: DEFAULT_MAX_TOOL_CALLS_PER_TURN,
        description: "Per-turn tool-call cap (one model turn plus its tool-result continuations; blocking Stop-hook continuations such as /goal iterations start a fresh budget). When set explicitly, this value is a hard cap: the turn halts on the next tool call after it is reached (the released behavior). When left unset (default 100), the cap is adaptive: once the turn exceeds 100 it halts only when the model keeps repeating the same call (a stuck loop); a productive turn (diverse calls) continues up to a hard backstop of 1000, which always halts. The adaptive default applies to the interactive TUI, non-interactive (-p / JSON / stream-JSON) core-client runs, and daemon/ACP sessions alike. Daemon/ACP sessions evaluate the cap once per tool batch, before execution: a batch that would cross an explicit cap or the hard backstop is skipped whole, so a turn never executes past either (it can halt up to one batch short), while the adaptive soft cap is exceeded by design, up to the backstop. They also have no in-session disable. An always-on circuit breaker against runaway turns, independent of model.skipLoopDetection. Set to 0 or a negative value to disable the cap.",
        showInDialog: false
      },'''
    new = old + f'''
      maxContextGrowthTokensPerTurn: {{
        type: "integer",
        label: "Max Context Growth Tokens Per Turn",
        category: "Model",
        requiresRestart: false,
        default: {DEFAULT_LIMIT},
        description: "Hard cumulative context-growth budget for one logical interaction. The first model send establishes the baseline; later model output plus newly appended tool-result, hook, steer, reminder, and other continuation input consumes the budget. Compaction and automatic context rollover do not refund consumed growth. The remaining budget also clamps model output independently of the context-window output clamp. Disabled by default so generic Qwen Code behavior is unchanged; set a positive integer to enable.",
        showInDialog: false
      }},'''
    return replace_once(text, old, new, "settings schema")


def patch_loader(text: str) -> str:
    if "maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn" in text:
        return text
    return replace_once(
        text,
        '''    maxToolCallsPerTurn: settings.model?.maxToolCallsPerTurn,
    skipStartupContext: settings.model?.skipStartupContext ?? false,''',
        '''    maxToolCallsPerTurn: settings.model?.maxToolCallsPerTurn,
    maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn,
    skipStartupContext: settings.model?.skipStartupContext ?? false,''',
        "settings -> Config loader",
    )


def patch_docs(text: str) -> str:
    if "`model.maxContextGrowthTokensPerTurn`" in text:
        return text
    row = (
        "| `model.maxContextGrowthTokensPerTurn`                  | integer | "
        "Hard cumulative context-growth budget for one logical interaction. The first model send establishes the baseline; "
        "later model output plus newly appended continuation input consumes the budget. Compaction and automatic rollover "
        "do not refund consumed growth. Remaining budget also clamps model output. Disabled by default; set a positive integer to enable. "
        f"| `{DEFAULT_LIMIT}`      |"
    )
    return insert_after_line_containing(text, "`model.maxToolCallsPerTurn`", row, "settings docs")


def syntax_check(paths):
    node = shutil.which("node")
    if not node:
        print("NODE_SYNTAX_CHECK=SKIP (node not found)")
        return
    for path in paths:
        proc = subprocess.run(
            [node, "--check", str(path)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
        )
        if proc.returncode != 0:
            raise RuntimeError(
                f"node --check failed for {path}\nSTDOUT:\n{proc.stdout}\nSTDERR:\n{proc.stderr}"
            )
        print(f"NODE_CHECK {path.name}=PASS")


def verify():
    checks = {
        PZ: [
            MARKER,
            "maxContextGrowthTokensPerTurn",
            "interactionGrowthByPromptId",
            "LOCALAI_TURN_GROWTH_LIMIT_REACHED:",
            'type: "turn_growth_limit_exceeded"',
            'terminateMode = "GROWTH_LIMIT"',
            "growthBudgetState: localAiGrowthState",
        ],
        SCHEMA: ["maxContextGrowthTokensPerTurn:", f"default: {DEFAULT_LIMIT}"],
        LOADER: ["maxContextGrowthTokensPerTurn: settings.model?.maxContextGrowthTokensPerTurn"],
        DOCS: ["`model.maxContextGrowthTokensPerTurn`"],
    }
    for path, needles in checks.items():
        text, _ = read_text_preserve(path)
        for needle in needles:
            if needle not in text:
                raise RuntimeError(f"verification failed: {needle!r} missing from {path}")
    print("STATIC_VERIFY=PASS")


def main():
    ap = argparse.ArgumentParser(description="LocalAI V5 per-turn context-growth hardening patch")
    ap.add_argument("--check", action="store_true", help="verify an already-patched runtime without modifying files")
    args = ap.parse_args()

    for path in (PZ, SCHEMA, LOADER, DOCS):
        if not path.exists():
            raise FileNotFoundError(path)

    if args.check:
        verify()
        syntax_check([PZ, SCHEMA, LOADER])
        for p in (PZ, SCHEMA, LOADER, DOCS):
            print(f"SHA256 {p.name} {sha256(p)}")
        return 0

    originals = {}
    newtexts = {}

    for path in (PZ, SCHEMA, LOADER, DOCS):
        text, newline = read_text_preserve(path)
        originals[path] = (text, newline, sha256(path))
        backup = backup_once(path)
        print(f"BACKUP {path.name} -> {backup}")

    newtexts[PZ] = patch_pz(originals[PZ][0])
    newtexts[SCHEMA] = patch_schema(originals[SCHEMA][0])
    newtexts[LOADER] = patch_loader(originals[LOADER][0])
    newtexts[DOCS] = patch_docs(originals[DOCS][0])

    try:
        for path in (PZ, SCHEMA, LOADER, DOCS):
            write_text_preserve(path, newtexts[path], originals[path][1])

        verify()
        syntax_check([PZ, SCHEMA, LOADER])

    except Exception:
        print("PATCH_FAILED: restoring exact pre-patch bytes from backups", file=sys.stderr)
        for path in (PZ, SCHEMA, LOADER, DOCS):
            backup = Path(str(path) + BACKUP_SUFFIX)
            if backup.exists():
                shutil.copy2(backup, path)
                backup.unlink()
        raise

    print("")
    print("LOCALAI_TURN_GROWTH_BUDGET_V5=APPLIED")
    print(f"DEFAULT_LIMIT={DEFAULT_LIMIT}")
    for path in (PZ, SCHEMA, LOADER, DOCS):
        before = originals[path][2]
        after = sha256(path)
        print(f"SHA256 {path.name} BEFORE={before} AFTER={after}")
        backup = Path(str(path) + BACKUP_SUFFIX)
        if backup.exists():
            backup.unlink()

    print("BACKUP_RETENTION=TRANSIENT_ONLY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
