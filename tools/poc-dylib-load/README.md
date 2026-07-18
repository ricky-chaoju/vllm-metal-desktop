# M0 gate: loading the engine's foreign dylibs

The whole app architecture (docs/PLAN.md §3) rests on one assumption: a process
can `dlopen()` the engine's native libraries — `_paged_ops.so`, `libmlx.dylib`,
libtorch — which are **not signed by this app's developer Team ID**, while the
app ships hardened-runtime + Developer ID + notarized.

This PoC proves it, without needing the GUI app or notarization, by codesigning
three permutations of a tiny loader against a tiny ad-hoc-signed (no Team ID)
dylib that stands in for those engine libraries.

## Run

```sh
./run.sh        # exits 0 on GATE PASS
```

## What it proves

| Case | Loader signing | Models | Result |
|------|----------------|--------|--------|
| A | ad-hoc (`codesign -s -`) | the spawned venv **python** (its own process, not hardened by us) | **loads** the foreign dylib |
| B | hardened runtime **+ `disable-library-validation`** | the app hosting an in-process helper | **loads** the foreign dylib |
| C | hardened runtime, **no** `disable-library-validation` | negative control | **blocked**: `different Team IDs` |

Case A is the real architecture — the app spawns `vllm serve`; the child python
process is governed by *its own* signature, not the app's, so it loads the
engine libs regardless of the app's hardened runtime. Case B validates the
defensive entitlement we ship anyway. Case C is the proof that
`com.apple.security.cs.disable-library-validation` is *precisely* the flag that
gates this — remove it and a hardened process is blocked from loading any
non-team dylib.

## Gotcha discovered here (matters for the EngineSupervisor)

A hardened program **rejects `dlopen()` of a relative path**
(`relative path not allowed in hardened program`). Always hand the engine
**absolute** paths. The venv lives at an absolute location
(`~/.venv-vllm-metal`) so this is natural, but the supervisor must never invoke
the interpreter or pass `--model`/library paths relatively.
