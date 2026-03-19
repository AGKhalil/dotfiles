# Git Worktree Policy

Before making code changes to a git repository, verify you are working in a
git worktree (not the main/default branch checkout).

## Check

Run: `git branch --show-current`

If the current branch is `main`, `master`, or the repo's default branch, **stop
and tell the user** to create a worktree first:

> You're on the default branch. Create a worktree before I make changes:
> `wt switch --create <branch-name>`

## Exceptions — skip the worktree check when:

- The change is trivial (single file, < 5 lines)
- The user explicitly says to work on the current branch
- You're already on a feature branch / in a worktree
- The task is read-only (exploration, questions, planning)

## Context

This project uses Worktrunk (`wt`) for git worktree management. Useful commands:
- `wt switch --create <branch>` — create worktree + branch, cd into it
- `wt switch <branch>` — switch to existing worktree
- `wt list` — show all worktrees and their status
- `wt remove` — clean up current worktree
- `wt merge <target>` — squash merge into target branch
