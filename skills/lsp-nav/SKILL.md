---
name: lsp-nav
description: Navigate TypeScript code via LSP (definitions, references, callers, callees, document outlines) instead of reading full source files. Use for "where is X defined", "what calls Y", "what does Z call", "what's the structure of this file", "find all implementations of this interface" — anything structural, not content. Cuts token cost ~3× on a 400-line file.
allowed-tools: LSP Bash Read
---

# LSP-Nav: token-cheap code navigation

The `LSP` tool is a **deferred** tool — its schema is not loaded by default. Before first use in a session, run:

```
ToolSearch(query="select:LSP", max_results=1)
```

That costs a one-time ~400 tokens for the schema. Amortize it across multiple LSP calls or skip LSP for tiny lookups.

## When LSP wins vs Read/grep

| Question | Use | Why |
|---|---|---|
| "What's the shape of `foo.ts`?" | `documentSymbol` | ~1.5K tokens for a 400-line file vs ~3.7K for Read. Returns every function/interface/property with line numbers — lets you targeted-Read only the slice you need next. |
| "What is `X`'s signature / type?" | `hover` | ~20–100 tokens for the inferred signature. Read of a 30-line block is ~200. |
| "Where is `X` defined?" | `goToDefinition` | One line out (`file.ts:L:C`). Beats `grep -rn 'export.*X'`. |
| "Who calls `X`?" | `findReferences` or `incomingCalls` | LSP returns `file:line:col` only — no matched text. ~50 tokens for 4 callsites. `grep -rn` costs ~150 tokens for the same 4 but **includes the matched line**, which often saves a follow-up Read. Pick LSP only when you don't need argument context. |
| "What does `X` call?" | `outgoingCalls` | The unique LSP win — no grep equivalent without reading the function body. Returns every called symbol with the callsite line:col. |
| "What implements this interface?" | `goToImplementation` | Returns every implementing type/class. Grep can't do this without reading the schema. |

## When Read/grep wins

- **Reading source code.** LSP returns structure, never content. To know what code *does*, you still Read.
- **Need matched line text.** `grep -rn 'X'` gives line content; `findReferences` gives only line:col.
- **One-off lookup on a small file.** If you'd Read <100 lines anyway, the LSP tool-load overhead isn't worth it.
- **Non-TS files.** LSP server here is TypeScript-only. For Prisma schemas, JSON, markdown — grep/Read.
- **Prefix / fuzzy name search.** LSP can't search by partial name in this harness (`workspaceSymbol` is broken — see Traps). Use ripgrep directly: `rg -n '\bfunction classify\w+' src/`. Benchmarked at parity with any LSP alternative.

## Edge cases worth knowing

- **`findReferences` + arg context is a tight contest.** Raw LSP `findReferences` is ~3× cheaper than `grep -rn` for "where is X used?", but if you pipe through `lsp-enrich-refs` to recover the matched-line content, the savings collapse to ~1.2× because every ref triggers a `sed` line-read. Use unenriched LSP for navigation-only queries; only enrich when the caller actually needs to see args.

## The coordinate-first workflow

LSP requires `line:character`. Use the bundled helpers in `.claude/skills/lsp-nav/`:

| Helper | Purpose |
|---|---|
| `lsp-find <symbol> [path]` | Symbol name → `<file> line=N character=N` (declaration site, skips imports). |
| `lsp-context <file>:<line> [n]` | Coords → ±n lines of source with line numbers and a `>` marker on the target. |
| `lsp-body <file>:<line>` | Coords → entire function/block body via brace balancing. Use instead of Read when you want "what does this function do." ~60% smaller than Read on typical files. |
| `lsp-enrich-refs` (stdin) | LSP `findReferences` / `incomingCalls` / `outgoingCalls` output → enriched with the matched line content. Closes the gap vs `grep -rn`. |
| `tsc-errors` (stdin or interactive) | `tsc` raw output → one line per error (`file:line:col  error TSxxxx: msg`). Drops banners, source excerpts, arrow-underlines, ANSI codes. ~10× smaller. |

Standard flow:

```
$ .claude/skills/lsp-nav/lsp-find extractProfileCheap
src/server/url-digestion/extract-profile.ts line=58 character=23

→ LSP(operation="hover", filePath=..., line=58, character=23)
→ LSP(operation="findReferences", ...same coords...) → pipe to lsp-enrich-refs
```

LSP is **additive**, not a grep replacement. The savings come on the *second through Nth* query on the same symbol.

## Recipes

### Full call graph for a function

```
1. lsp-find <name>                            → coords
2. LSP prepareCallHierarchy at coords         → confirms analyzability
3. LSP incomingCalls at coords                → who calls it
4. LSP outgoingCalls at coords | grep -v node_modules
                                              → what it calls (no stdlib noise)
```

### "Where is X used, with arg context?"

```
1. lsp-find <name>                            → coords
2. LSP findReferences at coords
3. Pipe LSP output through lsp-enrich-refs    → file:line: content
```

This beats `grep -rn` on accuracy (no false matches in comments/strings) and ties it on readability.

### Survey an unfamiliar file before editing

```
1. LSP documentSymbol on the file             → full outline + line numbers
2. lsp-context <file>:<line> 10               → targeted slice for any symbol of interest
3. Read only the slice you actually need to modify
```

### Pre-resolve LSP context before delegating to a subagent

**Subagents launched via the `Agent` tool cannot access the LSP plugin or MCP tools.** If you delegate without pre-resolving, the subagent falls back to `Grep + Read` inside *its own context* — invisible to you, can burn 20–50K tokens per delegation.

Before any `Agent` call that needs to navigate code, do the LSP work in the parent and inject the result as text:

```
1. lsp-find <symbol>                          → coords for every relevant symbol
2. lsp-body <file>:<line>                     → key function bodies (optional, when behavior matters)
3. LSP findReferences at coords               → callsite list
```

Then bake the result into the prompt as a fenced context block:

```
Agent({
  prompt: `Fix handleSubmit error handling.

  ## LSP CONTEXT (pre-resolved)
  - handleSubmit: form-actions.ts:42
  - Callers: page.tsx:15, form.tsx:88
  - FormData type: { name: string; email: string }`,
  subagent_type: "implementation"
})
```

**Cost math:** ~500 tokens for the parent to resolve via LSP + helpers. Skip cost: ~30K tokens of `Grep + Read` inside the subagent, with no enforcement layer to stop it (the subagent's tool calls aren't gated by the parent's hooks).

The pattern especially matters for `Agent` tasks that ask the subagent to "find X and modify Y" — exactly the cases where Grep+Read inside the subagent would balloon.

## Operation reference (all 9 ops)

All ops take `operation`, `filePath`, `line` (1-based), `character` (1-based).

| Operation | Returns | Typical tokens | Use when |
|---|---|---|---|
| `documentSymbol` | Full outline of one file: every function, interface, property, with line numbers | 500–2000 | Surveying an unfamiliar file before deciding what to Read |
| `hover` | Inferred signature + JSDoc for the symbol under cursor | 20–200 | Checking a function's signature or a type's shape |
| `goToDefinition` | One line: `path:line:col` of the declaration | ~10 | Jumping from a usage to its source |
| `goToImplementation` | All implementations of an interface / abstract method | 10–500 | "What types implement `Foo`?" |
| `findReferences` | All references workspace-wide as `file:line:col` (no line content) | 30–2000 | "Where is `X` used?" — when arg context isn't needed |
| `prepareCallHierarchy` | Confirms the symbol can be analyzed for calls. Cheap prep step. | ~30 | Sanity check before `incomingCalls` / `outgoingCalls` |
| `incomingCalls` | Every function/method that calls the target, grouped by file | 50–1000 | "Who calls `X`?" with caller names (richer than `findReferences`) |
| `outgoingCalls` | Every symbol the target calls, grouped by file (includes node_modules) | 100–2000 | "What does `X` call?" — the **unique LSP win** |
| `workspaceSymbol` | ⚠️ **TRAP** — see below | 150K+ | **Don't use in this harness.** |

## Traps and gotchas

### 1. `workspaceSymbol` dumps the whole workspace

The tool schema exposes only `filePath` / `line` / `character` — no `query` string parameter. A call dumps **every symbol in every file** (observed: 504KB / ~150K tokens, auto-persisted to a file). It's effectively unusable here. To find a symbol by name, use `grep -rn` instead.

### 2. `findReferences` strips line content

LSP returns bare `file:line:col`. `grep -rn` returns `file:line: <matched line>`. For navigation, LSP wins on tokens. For "called with what arguments?", grep is cheaper because it avoids a follow-up Read.

### 3. `outgoingCalls` pulls in node_modules

Calls into stdlib (`Promise.all`, `Date.now`, etc.) appear in `node_modules/.pnpm/typescript@.../lib/...`. Filter mentally — these are usually noise.

### 4. Coordinates are 1-based, column too

`grep -n` gives line; character is the column where the **identifier starts**, not where the line starts. For `export async function extractProfileCheap(`, the identifier starts at column 23 — but pointing at any column inside the identifier (e.g. 17) also works.

### 5. LSP needs the dev server / tsserver running

If the project's TypeScript server isn't initialized, LSP returns errors. Restart logic isn't in your hands — if you get `no server available`, fall back to grep+Read.

### 6. Stale diagnostics from other working dirs

The harness sometimes surfaces `<new-diagnostics>` from files that don't exist in the current repo. If LSP says a file doesn't exist, trust LSP, not the diagnostic.

## Worked example: "Who calls `extractProfileCheap` and what does it call?"

**LSP path** (after one grep to find line 58):

```
LSP findReferences  → 4 callsites    (~60 tokens)
LSP incomingCalls   → 2 caller funcs (~80 tokens)
LSP outgoingCalls   → 16 calls       (~400 tokens)
Total: ~540 tokens
```

**Read/grep path**:

```
grep -rn extractProfileCheap src/  → 16 hits w/ context (~700 tokens)
Read extract-profile.ts (400 lines, to see what it calls) (~3700 tokens)
Total: ~4400 tokens
```

**~8× cheaper** for this specific question.

## Decision flow (1-minute version)

1. **Is the question about code structure, not content?** If yes, consider LSP.
2. **Is LSP loaded?** If not, weigh the ~400-token schema load against ≥2 expected uses.
3. **Do I know the symbol's coordinates?** If not, one `grep -n` first.
4. **Pick the narrowest op**: `hover` < `goToDefinition` < `findReferences` < `documentSymbol` < `outgoingCalls`.
5. **Need to read code afterward?** Use the line numbers from LSP to Read a targeted slice (50 lines, not the whole file).
