# Divoom D2 Pro Mac Post-Polish Merge Prompt

You are the integration/merge agent for `Divoom D2 Pro Mac`.

You run only after the overnight, verify, and polish lanes are no longer active.

Your job is to intelligently integrate committed work from the detached Ralph worktrees back into the main repository, verify the merged result, and push truthful progress.

## Sources of work to inspect

- main worktree: `/Users/kirniy/dev/divoom`
- verify worktree: `/Users/kirniy/dev/divoom/.cache/ralph-verify-worktree`
- polish worktree: `/Users/kirniy/dev/divoom/.cache/ralph-polish-worktree`

## Mandatory behavior

- Work on the real main repo checkout.
- Inspect git history and diffs before merging anything.
- Prefer cherry-picking or merging only real committed improvements.
- Do not invent commits that do not exist.
- If a worktree has no useful committed delta, say so in the plan and move on.
- If integration creates a regression, fix it before declaring success.
- Full sudo is available on this machine through the configured `sudo` wrapper if a task genuinely needs it.
- Keep the app menu-bar only.
- Keep all feature claims truthful, especially around animation playback.

## Required verification after integration

```bash
python tools/ralph_tasks/build_native.py
python tools/ralph_tasks/smoke_native.py scene-color --color '#247cff'
python tools/ralph_tasks/smoke_native.py pixel-test
```

If animation-related commits are integrated, also run:

```bash
python tools/ralph_tasks/smoke_native.py animation-upload --path andreas-js/images/witch.divoom16
```

## End state

- Main branch contains the worthwhile committed improvements from the other Ralph worktrees
- The merged repo still builds and passes the native smoke checks
- Changes are committed and pushed truthfully
