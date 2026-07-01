---
name: vault-ssh
description: Sign a local SSH key with HashiCorp Vault's SSH CA to mint a short-lived (1 day) SSH certificate. Invoke with /vault-ssh, or use proactively whenever an SSH connection fails because of an expired/missing certificate or a rejected public key.
allowed-tools: PowerShell, Read, AskUserQuestion, Bash(ssh:*), Bash(ssh-keygen:*)
---

# Vault SSH certificate signing

Some hosts only accept SSH **certificates** signed by the office Vault CA, not raw public keys. When a local key's certificate is missing or expired, `ssh` fails with things like `Permission denied (publickey)`, `no matching host key`, or the server simply rejects the key. This skill signs a local key with Vault's `ssh-client-signer2` engine and drops a **1-day certificate** next to the key so OpenSSH auto-loads it.

**Use this skill proactively**: whenever an SSH/scp/rsync/git-over-SSH operation fails with a publickey rejection and the target is an office host, run the `sign` flow below, then retry the original operation. Don't ask the user first unless a key/role choice is genuinely ambiguous — signing is safe and idempotent (it just refreshes the cert).

Credentials are read from **`~/.vaultrc`**, which must exist and contain `VAULT_ADDR` and `VAULT_TOKEN` (shell `export VAR=value` format). Nothing is prompted; secrets never pass through the conversation.

All commands go through one script: `"${SKILL_DIR}/scripts/vault-ssh.ps1"` (PowerShell).

## Standard flow: `sign`

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>/scripts/vault-ssh.ps1" sign
```

The script auto-detects the key and role:
- **Keys**: scans `~/.ssh/*.pub` (ignoring existing `*-cert.pub`). If exactly one, it uses it. If more than one, it emits `MULTIPLE_KEYS` and a list with the conventional **default identity marked `<-- DEFAULT`** (`id_ed25519`, else `id_ecdsa`/`id_rsa`). **Ask the user which key** (AskUserQuestion): present the default as the recommended first option, and make clear they can pick any other listed key instead. Then re-run with the chosen path: `sign <path-to.pub>`. To sign a non-default key, just pass its `.pub` path explicitly (e.g. `sign "C:/Users/ziv/.ssh/id_ed25519_work.pub"`).
- **Role**: lists roles under `ssh-client-signer2`. If exactly one, it uses it. If more than one, it emits `MULTIPLE_ROLES` — ask the user, then pass `-Role <name>`.

Interpret the output (first token of a line):

| Output | Meaning | What you do |
|---|---|---|
| `SIGNED <certPath> ...` | Certificate written next to the key (with validity/principals) | Retry the original SSH operation |
| `MULTIPLE_KEYS` (exit 3) | Several keys, none specified | Ask the user which key, re-run `sign <path.pub>` |
| `NO_KEYS` (exit 4) | No `*.pub` under `~/.ssh` | Tell the user; nothing to sign |
| `NO_ROLE` / `MULTIPLE_ROLES` (exit 5) | Role ambiguous or unlistable | Ask the user, re-run with `-Role <name>` |
| `NO_VAULTRC` (exit 2) | `~/.vaultrc` missing or lacks `VAULT_ADDR`/`VAULT_TOKEN` | Tell the user to create/fix `~/.vaultrc` |
| `TOKEN_INVALID` (exit 7) | Vault token expired or denied | Tell the user to refresh `VAULT_TOKEN` in `~/.vaultrc` |
| `VAULT_UNREACHABLE` (exit 6) | Network/TLS error reaching Vault | May need the office VPN — consider the `/vpn` skill, then retry |
| `SIGN_FAILED <msg>` (exit 8) | Vault rejected signing | Show the user the message; role/policy may be wrong |

Selecting a specific key and role explicitly:

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<SKILL_DIR>/scripts/vault-ssh.ps1" sign "C:/Users/ziv/.ssh/id_ed25519.pub" -Role myrole
```

## Other commands

- `status` — check Vault reachability and token validity (`auth/token/lookup-self`).
- `list` — list local public keys and available signer roles (useful before asking the user to choose).

## Configuration / overrides

- Signing engine mount defaults to `ssh-client-signer2` — override with env `VAULT_SSH_MOUNT`.
- Certificate TTL defaults to `24h` (1 day) — override with env `VAULT_SSH_TTL` (the role's `max_ttl` still caps it).
- Role can be forced with `-Role` or env `VAULT_SSH_ROLE`.
- The signed certificate is written as `<key>-cert.pub` in the same directory, so OpenSSH picks it up automatically for the matching `IdentityFile`.

## Notes (tell the user if asked)

- `VAULT_TOKEN` is read from `~/.vaultrc` in plaintext — that file's protection is the trust boundary; the skill never writes or logs it.
- Certificates are short-lived by design (1 day). Re-run `sign` whenever a cert has expired; it simply overwrites the old `*-cert.pub`.
