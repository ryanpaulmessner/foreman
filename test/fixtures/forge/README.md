# GitHub read fixtures

Captured with read-only `gh api graphql` calls to `rpmessner/form-engine` on 2026-10-18.

- `form-engine.json` contains the two open PRs, #5 and #6, with the default branch, head/base, draft, mergeability, and check rollup.
- `form-engine-tracked.json` contains the same open query and the `pr3: pullRequest(number:3)` alias. PR #3 was already merged before this session.

The query fields match `Foreman.Forge.GitHub`. Responses contain no authentication headers or tokens. Negative tests modify these responses in memory to exercise pagination, missing identities, and API errors. No GitHub mutation was used to produce a fixture.

## human-merge/

Derived, not captured: built from the recorded `form-engine-tracked.json` node shape (same fields
and nesting as the `Foreman.Forge.GitHub` query) for a scratch repo `owner/report-scratch` whose PR
base is `staging` while the default branch is `main`. No GitHub call was made for these (the build
brief forbade writes to any real repo, scratch included).

- `open.json`: four open PRs, two stacks: #11 (staging ← work/aaa) with #12 on it and #14 on #12; #13 (staging ← work/ccc).
- `merged-commit.json`: a person merged #11 with a merge commit. The open list no longer has #11; the tracked alias reports `MERGED`. The head branches are kept, so #12 still targets `work/aaa` (not retargeted).
- `merged-squash.json`: a person squashed #13. `staging` moves to a squash sha that differs from #13's head; the response names no merge commit.
