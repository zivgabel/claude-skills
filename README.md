# claude-skills

Personal Claude Code skills, packaged as a plugin marketplace.

## Skills

| Skill | Description |
| --- | --- |
| [pr-review](pr-review/SKILL.md) | Find open GitHub PRs awaiting my review, show them as a table, review with full local context, and submit approve / request changes / comment after explicit confirmation. |

## Install

### Option A — plugin install (any machine)

```
/plugin marketplace add zivgabel/claude-skills
/plugin install pr-review@claude-skills
```

### Option B — clone as the personal skills folder

Clone the repo directly as the profile's `skills` directory (each top-level skill folder is discovered as a personal skill):

```powershell
# default profile
git clone https://github.com/zivgabel/claude-skills "$env:USERPROFILE\.claude\skills"

# work profile (CLAUDE_CONFIG_DIR=~/.claude-work)
git clone https://github.com/zivgabel/claude-skills "$env:USERPROFILE\.claude-work\skills"
```

Update with `git pull` in that folder.

## Machine prerequisites for pr-review

- `gh` CLI authenticated with the work account (`ziv-gabel`).
- SSH config alias (`githubup`) pointing at github.com with the work SSH key.
- Work repos base folder per the CONFIG table in `pr-review/SKILL.md` (edit it per machine).
