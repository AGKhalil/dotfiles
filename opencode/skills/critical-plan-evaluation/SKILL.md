---
name: critical-plan-evaluation
description: Critically evaluates plans before implementation—identifies oversights, assesses risks, and ensures no breaking changes. Use when the user proposes a plan, asks for plan review, or before implementing multi-step changes.
---

# Critical Plan Evaluation

Apply this skill when reviewing or creating implementation plans. Do not proceed with implementation until the plan passes evaluation.

## Evaluation Checklist

Before approving or implementing any plan:

### 1. Completeness
- [ ] All stated goals are addressed by concrete steps
- [ ] Edge cases and error paths are considered
- [ ] Dependencies (libs, services, config) are explicit
- [ ] No implicit assumptions left unstated

### 2. Oversight Detection
- [ ] **Backward compatibility**: Will existing callers, APIs, or data formats break?
- [ ] **Side effects**: What else touches the changed code? (imports, tests, config)
- [ ] **State/ordering**: Are there race conditions, cache invalidation, or ordering requirements?
- [ ] **Rollback**: Can changes be reverted safely? Any migrations that can't be undone?
- [ ] **Environment**: Dev vs prod differences, env vars, feature flags

### 3. Breaking Change Audit
- [ ] List all public surfaces: APIs, exports, CLI args, config keys
- [ ] For each: Is the change additive or does it modify/remove existing behavior?
- [ ] If modifying: Is there a migration path? Deprecation period?
- [ ] Tests: Will existing tests fail? Are new tests needed for the change?

### 4. Risk Assessment
- [ ] What is the blast radius if this fails?
- [ ] Can it be done incrementally or behind a flag?
- [ ] Are there reversible checkpoints?

## Output Format

When evaluating a plan, produce:

```markdown
## Plan Evaluation

**Verdict**: [Approve / Revise / Reject]

### Oversights Identified
- [List gaps, missing steps, or unaddressed concerns]

### Breaking Change Analysis
- [List potential breaking changes and mitigation]

### Recommendations
- [Concrete changes to the plan before proceeding]

### Approved Steps (if Approve)
- [Numbered steps to execute]
```

## Rules

1. **Never assume**—if the plan is ambiguous, flag it. Do not fill gaps silently.
2. **Prefer revision over rejection**—suggest fixes rather than blocking.
3. **State evidence**—cite files, APIs, or patterns when identifying risks.
4. **Be surgical**—only block on real risks; avoid nitpicking.
