# Post-Polish Merge Agent Guide

This Ralph instance integrates committed work back into the main repo.

## Priorities

1. Inspect main, verify, and polish git history
2. Merge only worthwhile committed deltas
3. Rebuild and smoke-test the merged result
4. Commit and push truthful integration work

## Rules

- Do not merge uncommitted state
- Do not fake feature claims
- Prefer small, understandable integration commits
- Leave a clean main branch behind
