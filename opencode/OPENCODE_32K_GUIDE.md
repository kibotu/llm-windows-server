# OpenCode Configuration Guide for 32k Context Window

## Overview
Your Qwen 3.5-9B model with a 32,000 token context window is a reasonable constraint for local development work. This guide explains the optimizations needed to work effectively within these limits.

---

## Key Configuration Changes

### 1. **Model Definition (CRITICAL)**
```json
"models": {
  "Qwen3.5-9B": {
    "name": "Qwen3.5-9B",
    "contextWindow": 32000
  }
}
```
**Why**: Explicitly declaring the context window ensures OpenCode's compaction system knows the hard limit. Without this, OpenCode may make overly optimistic assumptions about available tokens.

### 2. **Compaction Settings (CRITICAL)**
```json
"compaction": {
  "auto": true,
  "prune": true,
  "reserved": 4000
}
```

**Explanation**:
- **`auto: true`** - Automatically compacts the session when hitting context limits. This prevents crashes when you exceed tokens.
- **`prune: true`** - Removes older tool outputs (like file reads, bash results) when compacting. Saves ~20-30% of token overhead.
- **`reserved: 4000`** - Leaves a 4,000 token buffer before compaction triggers. With 32k context, this is ~12.5% of your budget:
  - Allows the model time to complete thoughts
  - Prevents mid-response token overflow
  - Ensures you can always get a meaningful completion

**Why 4000?** For a 32k window:
- ~8k tokens for system prompts + agent context
- ~12k tokens for code/files in conversation
- ~8k tokens for model response generation
- 4k reserved = safe threshold before automatic compaction

### 3. **Timeout Configuration**
```json
"options": {
  "timeout": 180000,
  "chunkTimeout": 30000
}
```

**Explanation**:
- **`timeout: 180000`** (3 minutes) - Total time allowed per request. Local models can be slower than cloud APIs.
- **`chunkTimeout: 30000`** (30 seconds) - Time between streamed chunks. If your RTX4080 stalls >30s without output, abort. Prevents hanging indefinitely.

### 4. **Watcher Configuration (Prevents Context Bloat)**
```json
"watcher": {
  "ignore": [
    "node_modules/**",
    "dist/**",
    "build/**",
    ".git/**",
    ".next/**",
    "venv/**",
    "env/**"
  ]
}
```

**Why**: File watching on large directories (node_modules, venv, .git) triggers frequent reads and updates, consuming tokens. Ignoring them keeps context lean.

### 5. **Tool Configuration (Optional Optimization)**
```json
"tools": {
  "browser": false
}
```

**Why**: Disable browser tool on a local model. It's inefficient with constrained context and rarely needed for local development.

---

## Best Practices for 32k Context

### A. Project Structure
```
my-project/
├── src/                    # Keep most code here
├── tests/
├── docs/
├── .opencode/              # Create custom agents/tools
├── opencode.json           # Use your optimized config
├── .gitignore
└── CONTRIBUTING.md         # Include guidelines for the model
```

### B. Instructions File Strategy
Minimize context usage from instructions:
- Keep `CONTRIBUTING.md` under 500 tokens (basic guidelines)
- Use glob patterns to load only relevant docs: `"docs/architecture/*.md"` instead of `"docs/**/*"`
- Avoid massive changelogs or dependency lists

### C. Commands to Minimize Context Usage

**Bad**: Ask OpenCode to analyze entire codebase
```bash
opencode run "Review the entire codebase for bugs"
```

**Good**: Be specific and focused
```bash
opencode run "Fix the bug in src/auth.js where JWT validation fails"
```

### D. Managing Snapshots
```json
"snapshot": false
```
Keep this enabled—it's essential for rollback on a resource-constrained setup, not absolutely necessary for our setup.

---

## Context Usage Breakdown (Typical 32k Session)

| Component | Tokens | Notes |
|-----------|--------|-------|
| System prompt + agent context | 2,500-3,500 | OpenCode overhead |
| Conversation history | 2,000-4,000 | Grows with chat length |
| Files in context (avg 3 files @ 500 tokens) | 1,500 | Compaction will prune old reads |
| Model response buffer | 4,000-6,000 | Reserved space |
| **Usable for new work** | ~16,000-20,000 | Actual working space |
| **Compaction buffer** | 4,000 | Reserved threshold |

---

## Monitoring & Debugging

### Check Config Load
```bash
opencode debug config
```
Verify your 32k limit is recognized.

### Enable Token Logging (if available)
Look for debug output showing:
- Current token count in session
- When compaction triggers
- Whether pruning removed old outputs

### Signs of Context Pressure
1. **Model responses become shorter** - Likely hitting reserved buffer
2. **Compaction triggers frequently** - Session is token-heavy
3. **File reads don't persist in memory** - Pruning is aggressive

**Solutions**:
- Reduce conversation length (archive old chats)
- Ask narrower questions
- Increase `reserved` if you see frequent compaction (at the cost of less work space)

---

## Advanced: Tuning `reserved` Parameter

The 4,000 token reservation balances safety with usable space:

| `reserved` Value | Impact |
|------------------|--------|
| 2,000 | **Risky** - Very little buffer, more frequent compaction, responses may be cut off |
| 3,000 | **Aggressive** - Squeezes more work tokens but compaction happens more often |
| **4,000** | **Recommended** - Sweet spot for 32k, balanced safety and usability |
| 5,000 | **Conservative** - Safer, fewer surprise truncations, but less working space |
| 6,000+ | **Very Safe** - Leaves lots of room, but wastes ~20% of context on overhead |

**Recommendation**: Start with 4,000. If you see truncated responses, increase to 5,000.

---

## Common Issues & Fixes

### Issue: "Context window exceeded" errors
**Fix**: Increase compaction sensitivity
```json
"compaction": {
  "reserved": 3500
}
```
Make it trigger earlier, even if it means more frequent compaction.

### Issue: Model consistently runs out of tokens mid-response
**Fix**: Either increase `reserved` or work on smaller scopes
```bash
# Instead of:
opencode run "Refactor this entire auth module"

# Do:
opencode run "Refactor the login function in src/auth/login.js"
```

### Issue: File watcher causing constant context refreshes
**Fix**: Expand ignore patterns to match your project structure
```json
"watcher": {
  "ignore": ["**/.env*", "**/*.log", "coverage/**"]
}
```

### Issue: Hanging requests or no response
**Possible causes**:
- Model is slow to start (`timeout: 180000` is set, so wait ~3 min)
- Network issue with `baseURL` (check 12.13.13.13:8899 is reachable)
- Model crashed or is out of memory

**Debug**:
```bash
# Test connection directly
curl -X POST http://12.13.13.13:8899/v1/completions \
  -H "Content-Type: application/json" \
  -d '{"prompt": "test", "max_tokens": 10}'
```

---

## Performance Tips

1. **Use `small_model` strategically**: Currently set to same model, but if you have a faster quantization, point it there for title generation
2. **Batch file operations**: Instead of reading files one-by-one, ask OpenCode to examine specific files together
3. **Archive old conversations**: Long chat histories consume tokens; start fresh sessions regularly
4. **Monitor GPU/VRAM**: RTX4080 has 12GB VRAM. If model thrashes to disk, increase timeouts further or reduce context
5. **Offload to filesystem**: For very large codebases, store design docs, architecture, and guidelines **outside** context—reference by filename only

---

## Testing Your Config

Run this command to validate:
```bash
opencode debug config
```

Look for:
```
provider: llama-at-home ✓
model: Qwen3.5-9B ✓
contextWindow: 32000 ✓
compaction: enabled ✓
```

Then try a simple task:
```bash
opencode run "Create a hello world function in JavaScript"
```

Monitor the output for:
- ✅ Response completes without truncation
- ✅ No timeout errors
- ✅ No "context exceeded" warnings

---

## Summary Checklist

- ✅ Define `contextWindow: 32000` in model config
- ✅ Set `compaction.reserved: 4000` (or adjust based on testing)
- ✅ Enable `compaction.auto: true` and `compaction.prune: true`
- ✅ Set `timeout` and `chunkTimeout` for local model latency
- ✅ Configure `watcher.ignore` to exclude large directories
- ✅ Keep instructions lean and focused
- ✅ Ask focused, scoped questions
- ✅ Monitor token usage and adjust `reserved` if needed

---

## References

- [OpenCode Config Docs](https://opencode.ai/docs/config/)
- [OpenCode Models Docs](https://opencode.ai/docs/models/)
- [Qwen3.5 Model Info](https://github.com/QwenLM/Qwen)
