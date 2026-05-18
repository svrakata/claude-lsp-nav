#!/bin/bash
# warn-large-read — soft warning when Claude is about to Read a large file.
# Does NOT block (returns permissionDecision: "allow"). Surfaces the hint to
# Claude via hookSpecificOutput.additionalContext — the only PreToolUse
# output field that reliably surfaces to the assistant on a non-blocking
# allow. permissionDecisionReason is silent on "allow"; stderr is silent on
# exit 0.
#
# Branches by extension:
#   .ts/.tsx/.js/.jsx/.mts/.cts > 300 lines → suggest LSP / lsp-context / lsp-body
#   .md                          > 500 lines → suggest `grep -n '^#'` + offset/limit
#
# Skipped:
#   - non-Read tool calls
#   - calls with offset or limit set (already a targeted slice)
#   - files under node_modules / .next / generated / dist

INPUT=$(cat)

# Parse the payload via node (jq not assumed). Emit three tab-separated fields.
read TOOL_NAME FILE_PATH HAS_SLICE < <(
  node -e '
    const data = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const t = data.tool_name || "";
    const f = (data.tool_input && data.tool_input.file_path) || "";
    const off = data.tool_input && data.tool_input.offset;
    const lim = data.tool_input && data.tool_input.limit;
    const slice = (off || lim) ? 1 : 0;
    process.stdout.write(`${t}\t${f}\t${slice}\n`);
  ' <<< "$INPUT" 2>/dev/null | tr '\t' ' '
)

# Silent exit paths.
if [ "$TOOL_NAME" != "Read" ]; then exit 0; fi
if [ "$HAS_SLICE" = "1" ]; then exit 0; fi
if [ ! -f "$FILE_PATH" ]; then exit 0; fi
if echo "$FILE_PATH" | grep -qE 'node_modules|\.next|generated/|dist/'; then exit 0; fi

LINES=$(wc -l < "$FILE_PATH" 2>/dev/null || echo 0)

# Build the hint message per extension.
MESSAGE=""
case "$FILE_PATH" in
  *.ts|*.tsx|*.js|*.jsx|*.mts|*.cts)
    if [ "$LINES" -gt 300 ]; then
      MESSAGE="hint: $FILE_PATH is $LINES lines. For navigation/structure questions, LSP is ~3× cheaper: LSP documentSymbol → outline + line numbers; lsp-context <file>:<line> N → targeted slice; lsp-body <file>:<line> → one function body. See .claude/skills/lsp-nav/SKILL.md. Proceeding with Read."
    fi
    ;;
  *.md)
    if [ "$LINES" -gt 500 ]; then
      MESSAGE="hint: $FILE_PATH is $LINES lines. For 'what does this doc say about X' questions, survey headers first: \`grep -n '^#' $FILE_PATH\` lists section headers + line numbers; then Read with offset/limit for just the section you need. Proceeding with Read."
    fi
    ;;
esac

if [ -z "$MESSAGE" ]; then
  exit 0
fi

# Emit JSON. hookSpecificOutput.additionalContext is the channel that
# surfaces to Claude on a non-blocking allow.
node -e '
  const msg = process.argv[1];
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: msg,
    },
  }));
' "$MESSAGE"

exit 0
