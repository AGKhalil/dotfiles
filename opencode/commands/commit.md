---
description: Commit with an approved message
---

Commit in this repo. Never run `git commit` before I approve the message.

!`git status --short && echo "=== staged ===" && git diff --cached --stat && echo "=== log style ===" && git log --oneline -5`

1. If something is staged, commit exactly that. Stage nothing more.
2. If nothing is staged, ask me which files to include using the question tool:
   one option per changed file, `multiple: true`, plus an "All files" option
   first. Stage exactly what I pick.
3. Read the real diff of what will be committed (`git diff --cached`).
4. Write one message in this exact format:

   `(feature/bug/fix): one line commit`

   where the parenthesis hold literally `feature`, `bug`, or `fix` — nothing else.
   One lowercase imperative line, under 72 chars, no period, no body.
5. Ask me to approve it with the question tool. Offer the message plus one
   alternative wording; I can also type my own.
6. Commit only after approval, using my approved text verbatim. Print
   `git show --stat --oneline HEAD`. Do not push.
