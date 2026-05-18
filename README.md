# claude-lsp-nav

> Ergonomic LSP-first code navigation for Claude Code. Five shell helpers, one decision-table skill, and a soft hint hook. **~3.5× fewer tokens** on navigation tasks across 40 measured cases.

A Claude Code plugin that makes LSP-style code navigation cheap and obvious to reach for — without forcing it.

## What's inside

| Component | Purpose |
|---|---|
| `lsp-find <symbol>` | Symbol name → `file line=N character=N`. Skips imports/re-exports. Works with ripgrep, no MCP required. |
| `lsp-context <file>:<line> [n]` | Coord → ±n lines of source with line numbers and a `>` marker on the target. |
| `lsp-body <file>:<line>` | Coord → entire function or class body via brace balancing. Closes the "show me what this function does" gap that Read of a full file would otherwise cost ~10× more tokens for. |
| `lsp-enrich-refs` | LSP `findReferences` output → enriched with the matched line content. Bridges LSP precision and grep readability. |
| `tsc-errors` | Raw `tsc` output → one line per error (`file:line:col  error TSxxxx: msg`). Strips banners, source excerpts, arrow-underlines, ANSI codes. ~10× compression. |
| `warn-large-read.sh` | Soft PreToolUse hook on `Read`. Hints at LSP/survey alternatives when reading large `.ts` (>300 lines) or `.md` (>500 lines) files. Never blocks. |
| `SKILL.md` | Decision tables, op cheat-sheet, traps, recipes — auto-triggers on structural-navigation tasks. |

## Install

```
/plugin install lsp-nav@svrakata/claude-lsp-nav
```

Restart Claude Code. The skill auto-loads on navigation tasks; the hook fires on every `Read`; the helpers are available at `${CLAUDE_PLUGIN_ROOT}/skills/lsp-nav/`.

## What it does, concretely

When Claude is about to read a 400-line source file just to find one function, the hook surfaces a hint:

```
hint: src/server/site/tools.ts is 330 lines. For navigation/structure
questions, LSP is ~3× cheaper: LSP documentSymbol → outline + line
numbers; lsp-context <file>:<line> N → targeted slice; lsp-body
<file>:<line> → one function body.
```

When Claude needs to extract a function body to understand behavior:

```
$ lsp-body src/server/url-digestion/extract-profile.ts:58
>   58  export async function extractProfileCheap(
    59    rawInput: string,
    60  ): Promise<CheapProfileResult> {
    ...
   174  }
```

289 bytes vs Reading the whole 12,610-byte file. **35× cheaper** for "show me one function."

When Claude needs callsites with arg context:

```
$ LSP findReferences | lsp-enrich-refs
src/server/site/repo.ts:83: export async function patchSite(args: {
src/server/site/generate-orchestrator.ts:85: await patchSite({ chatId: args.chatId, ...
src/server/site/generate-orchestrator.ts:134: await patchSite({
```

Same accuracy as LSP, same readability as `grep -rn`.

## Benchmarks

Three rounds, 40 tasks total. Token cost on real navigation queries:

| Round | Tasks | Path A (skill) | Path B (Read/grep) | Ratio |
|---|---|---|---|---|
| 1 | 10 | ~3,610 tok | ~14,050 tok | **3.9×** |
| 2 | 10 | ~3,718 tok | ~13,840 tok | **3.7×** |
| 3 | 20 | ~21,200 tok | ~83,400 tok | **3.9×** |
| **Total** | **40** | **~28,500 tok** | **~111,300 tok** | **3.9×** |

Notable per-task wins:

| Task | Win |
|---|---|
| `lsp-body` on small function in large file | **35×** |
| Full call graph for a function | **27×** |
| Type chase | **21×** |
| Find references | **8×** |
| File structure survey | **3–4×** |
| Whole-file survey on 6000-line file | **3.8×** |

Where the kit **doesn't** help: prefix / fuzzy name search (use `rg` directly). The skill calls this out explicitly.

## Recipes the skill teaches

- **Full call graph for a function** — `lsp-find` → `prepareCallHierarchy` → `incomingCalls` → `outgoingCalls` (with `node_modules` filter)
- **Refs with arg context** — LSP `findReferences` piped through `lsp-enrich-refs`
- **Survey an unfamiliar file before editing** — LSP `documentSymbol` → `lsp-context` → targeted Read
- **Pre-resolve LSP context before delegating to a subagent** — the highest-value pattern. Subagents can't access MCP/LSP, so without pre-resolution they fall back to Grep+Read inside their own context, burning 20–50K tokens invisibly. Resolve in the parent, inject as a `## LSP CONTEXT` block in the Agent prompt.

## How this compares to the [LSP Enforcement Kit](https://github.com/nesaminua/claude-code-lsp-enforcement-kit)

This kit is the **ergonomic layer**. The Enforcement Kit is the **policing layer**. They're complementary, not competing.

|  | LSP Enforcement Kit | claude-lsp-nav |
|---|---|---|
| Philosophy | Force LSP-first by blocking alternatives | Make LSP-first cheap by providing tooling |
| Hooks | 7 (Grep, Glob, Bash-grep, Read gate, Agent, session reset, tracker) | 1 (Read warn) |
| Behavior | Hard block (exit 2) with copy-paste fix | Soft hint (`additionalContext`) |
| Shell tools | None — relies on MCP | 5 (`lsp-find` works without MCP) |
| State | Per-cwd state file with session reset | Stateless |
| MCP requirement | Required (cclsp or Serena) | Optional |
| `.md` coverage | Allow-listed | Hint with header-survey suggestion |
| Pre-delegation | Hook-enforced | Documented as a recipe |

**Pick the Enforcement Kit if** you want hard guarantees that no one on your team can bypass LSP. **Pick this kit if** you want the ergonomic helpers (especially `lsp-body`, `lsp-enrich-refs`, `tsc-errors`) and prefer soft nudges over hard blocks. **Run both** for maximum coverage — they don't conflict.

## Design notes

- **`workspaceSymbol` is a trap** in the in-harness LSP tool. The schema doesn't expose a query parameter, so calling it dumps every symbol in every file — observed: 504KB / ~150K tokens auto-persisted. The skill documents this.
- **PreToolUse hook output channels matter.** `stderr` + `exit 0` is silently discarded. JSON `hookSpecificOutput.additionalContext` is the only channel that surfaces a non-blocking message to Claude. The hook uses that.
- **`lsp-find` skips imports.** First version returned imports first because they're earlier in the file walk order; the filter (`from ['"]`) reliably finds the actual declaration.
- **`lsp-body` brace-balances with string literals stripped.** Template literals (backticks) are a known limitation — fall back to Read if the function body has them with unbalanced inner braces.

## Tuning

The hook thresholds (300 lines for `.ts`, 500 for `.md`) are conservative defaults. To adjust, edit `hooks/warn-large-read.sh`:

```bash
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts)
    if [ "$LINES" -gt 300 ]; then  # ← here
      ...
```

## License

MIT — see [LICENSE](LICENSE).
