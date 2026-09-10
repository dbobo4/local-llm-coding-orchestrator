# Compression tuning

## Current production decision

```text
Qwen Code: 0.22.3
context window: 40960
COMPACT_MAX_OUTPUT_TOKENS = 3072
auto-compaction threshold = 24888
compaction reasoning = xhigh
cache sharing = enabled / preserved
```

The Qwen Code provider `generationConfig.contextWindowSize` is synchronized with the `40960` llama.cpp server context because compression thresholds are computed from the provider context window.

The `3072` output cap was selected by the earlier controlled A/B/C tuning performed at a 49152-token context. The cap remains unchanged; the current automatic-compaction threshold is lower because the production context is now 40960.

The compact state handoff contains `goal`, `durable_constraints`, `current_state`, `open_issues`, and `next_step`, targeting roughly 800-1500 tokens.

## Historical 49152-context tuning basis

The stock Qwen Code reserve was equivalent to `COMPACT_MAX_OUTPUT_TOKENS = 2e4`. At a 49152-token context window that produced an effective auto-compaction threshold of roughly 16152 tokens. The first local optimization reduced the cap to 4096, moving the threshold to 32056 and eliminating the observed rapid re-compaction behavior.

A second tuning pass compared 4096, 3072, and 2048.

## Exact mechanical A/B/C

| Cap | Auto threshold | Avg trigger | Avg summary output | Avg post-compact prompt | Cache | Avg compaction wall |
|---:|---:|---:|---:|---:|---:|---:|
| 4096 | 32056 | ~32404 | 957.5 | 17149 | ~96.3% | 25.59 s |
| 3072 | 33080 | ~33504.5 | 1233.5 | 17128.5 | ~96.44% | 28.96 s |
| 2048 | 34104 | ~34600 | 1536.5 | 17305 | ~96.50% | 33.08 s |

Wall time is noisy and was not used as a single-variable decision criterion.

### 4096 events

```text
event 1: ORIGINAL=32567 COMP_INPUT=32479 COMP_OUTPUT=807  COMP_CACHED=31353 POST=16994 WALL_MS=24830
event 2: ORIGINAL=32241 COMP_INPUT=32099 COMP_OUTPUT=1108 COMP_CACHED=30834 POST=17304 WALL_MS=26345
```

### 3072 events

```text
event 1: ORIGINAL=33403 COMP_INPUT=33315 COMP_OUTPUT=816  COMP_CACHED=32187 POST=16950 WALL_MS=22814
event 2: ORIGINAL=33606 COMP_INPUT=33464 COMP_OUTPUT=1651 COMP_CACHED=32212 POST=17307 WALL_MS=35107
```

### 2048 events

```text
event 1: ORIGINAL=34730 COMP_INPUT=34642 COMP_OUTPUT=1516 COMP_CACHED=33466 POST=17107 WALL_MS=32665
event 2: ORIGINAL=34470 COMP_INPUT=34328 COMP_OUTPUT=1557 COMP_CACHED=33093 POST=17503 WALL_MS=33491
```

## Semantic-retention validation

The strict semantic benchmark verifies current versus obsolete values, accepted and rejected strategies with reasons, unresolved blockers, the immediate next step, and supersession of earlier state.

| Cap | Compactions | Marker retention | Semantic retention |
|---:|---:|---|---|
| 4096 | 2 | PASS | PASS |
| 3072 | 2 | PASS | PASS |
| 2048 | 2 | PASS | PASS |

Observed strict semantic summary outputs:

```text
4096: 1014, 1669
3072: 846, 1765
2048: 1448, 1255
```

## Why 3072 instead of 2048

2048 passed correctness tests, but the largest mechanical-run summary was 1557 tokens, leaving only 491 tokens of cap headroom. The 3072 configuration preserves materially more reserve while still delaying compaction relative to 4096. Therefore 3072 is the production robustness/frequency compromise; 2048 was not rejected for semantic correctness.

## Compaction reasoning effort

A same-model request-level `medium` override reached the wire, but cache sharing degraded from roughly 96.3% on the xhigh baseline to roughly 24.5% in the medium probe. Average wall time in that probe also increased from roughly 25.59 s to roughly 42.62 s. Medium was therefore rejected for production compaction and `xhigh` was retained.

`thinkingConfig.includeThoughts = false` should not be interpreted as proof that the model performs no internal reasoning.

## Runtime patcher states

```text
unpatched: stock prompt/directive + cap 2e4
legacy:    optimized prompt/directive + cap 4096
patched:   optimized prompt/directive + cap 3072
incompatible: unknown/mixed state -> fail closed
```

The validated production runtime SHA256 is:

```text
8854D92C278AD63603C1E2695A2BE74B198A7D3AB3358074E0FAEAA9CF36AA8D
```

The 4096 optimized state is intentionally supported as a migration state.
