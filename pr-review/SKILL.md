---
name: pr-review
description: Find all open GitHub pull requests where my review is requested, show them as a table, review the selected ones with full local code context, explain the findings, and — only after my explicit per-PR approval — submit Approve / Request changes / Comment. Use when the user asks to "review my PRs", "check PRs waiting for my review", "what PRs do I need to review", or "handle my review requests".
---

# pr-review — review the PRs waiting for me

## CONFIG (edit per machine)

| Setting     | Value                       |
| ----------- | --------------------------- |
| BASE_DIR    | `C:\Users\ziv\work\github`  |
| WORK_LOGIN  | `ziv-gabel`                 |
| CLONE_HOST  | `githubup`                  |

`BASE_DIR` holds work repos as `<org>\<repo>`. `CLONE_HOST` is an SSH config alias for github.com that selects the work SSH key; all clones must use `git@<CLONE_HOST>:<org>/<repo>.git`. `gh` resolves the alias via ssh config, so `gh pr ...` commands work inside these clones without `--repo`.

## Hard rules

- NEVER submit a review, comment, or any write to GitHub without the user explicitly choosing the action for that specific PR in this session.
- NEVER check out branches or modify working trees in `BASE_DIR` repos — review only from fetched refs.
- Always finish with `WORK_LOGIN` as the active gh account.

## Flow

### 1. Preflight

`gh auth status` — if the active github.com account is not `WORK_LOGIN`, run `gh auth switch --user <WORK_LOGIN>`.

### 2. Discover and show the table

```
gh search prs --review-requested=<WORK_LOGIN> --state=open --limit 50 \
  --json repository,number,title,author,updatedAt,isDraft,url
```

**Always render a markdown table of ALL results** before anything else:

| Repo | PR | Title | Author | Updated | Draft | Link |

Then use AskUserQuestion (multi-select) to let the user pick which PRs to review now. Default selection: all non-draft PRs. If there are no PRs, say so and stop.

### 3. Prepare each selected PR (no working-tree changes)

For PR `<N>` in `<org>/<repo>`, target dir `BASE_DIR\<org>\<repo>`:

1. If the dir is missing: `git clone -c core.longpaths=true git@<CLONE_HOST>:<org>/<repo>.git <target>`.
2. Fetch the PR head and base branch without touching the working tree:
   ```
   git fetch origin +refs/pull/<N>/head:refs/pr/<N>
   git fetch origin <baseRefName>
   ```
   (`baseRefName` from `gh pr view <N> --json baseRefName`.) This also works for fork PRs.
3. Read code at the PR head with `git show refs/pr/<N>:<path>`; diff with `gh pr diff <N>` and `git diff $(git merge-base origin/<base> refs/pr/<N>) refs/pr/<N>`.

### 4. Review

Per PR, gather: `gh pr view <N> --json title,body,author,baseRefName,commits,files,reviews,comments,statusCheckRollup`, the full diff, the complete changed files at the PR head, and enough surrounding code (callers, configs, related modules — also read via `git show refs/pr/<N>:<path>`) to judge correctness, not just style.

If more than 2 PRs are selected, fan out one subagent per PR in parallel; each works in its repo dir and returns structured findings.

Findings format per PR:
- One-paragraph summary of what the PR does.
- Findings list: **severity** (blocker / major / minor / nit), `file:line`, what is wrong, suggested fix.
- Existing CI status and prior review activity worth noting.
- Recommended verdict: approve / request changes / comment.

### 5. Explain

Present one consolidated report to the user, grouped per PR, findings ordered by severity, with the recommended action for each PR. Plain language — the user decides based on this report.

### 6. Decide and submit (only after explicit confirmation)

For each reviewed PR, AskUserQuestion: **Approve / Request changes / Comment / Skip**.

For any non-Skip choice: draft the review body in markdown (short summary + findings with `file:line` references), show it to the user, and only after they confirm the text, submit from the repo dir:

```
gh pr review <N> --approve | --request-changes | --comment --body-file <tempfile>
```

Use `--body-file` (temp file, delete after) to avoid quoting issues. If the user edits the verdict or text, apply their edits before submitting.

### 7. Wrap up

Show a final table: PR | action taken | review URL (or "skipped"). Confirm the active gh account is `WORK_LOGIN`.
