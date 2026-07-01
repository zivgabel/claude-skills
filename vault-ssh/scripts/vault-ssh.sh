#!/usr/bin/env bash
# vault-ssh.sh — sign a local SSH public key with HashiCorp Vault's SSH CA
# to produce a short-lived (1 day) SSH certificate. POSIX/bash port of
# vault-ssh.ps1; same output contract and exit codes.
#
# Credentials come from ~/.vaultrc (shell format: `export VAULT_ADDR=...` /
# `export VAULT_TOKEN=...`). Signing engine mount defaults to ssh-client-signer2.
#
# Usage:
#   vault-ssh.sh status
#   vault-ssh.sh list
#   vault-ssh.sh sign [key.pub] [--role NAME] [--mount NAME] [--ttl DUR]
#
# Output contract (first token of a line):
#   NO_VAULTRC        (exit 2)  ~/.vaultrc missing or lacks VAULT_ADDR/VAULT_TOKEN
#   VAULT_UNREACHABLE (exit 6)  network/TLS error talking to Vault
#   TOKEN_INVALID     (exit 7)  token expired / denied
#   NO_KEYS           (exit 4)  no *.pub under ~/.ssh
#   MULTIPLE_KEYS     (exit 3)  more than one key and none specified (list follows)
#   NO_ROLE           (exit 5)  no signer role found and none specified
#   MULTIPLE_ROLES    (exit 5)  more than one role and none specified (list follows)
#   SIGN_FAILED <msg> (exit 8)  Vault rejected the signing request
#   SIGNED <certPath> (exit 0)  success; certificate written next to the key

set -u

SSH_DIR="${HOME}/.ssh"
VAULTRC="${HOME}/.vaultrc"

MOUNT="${VAULT_SSH_MOUNT:-ssh-client-signer2}"
TTL="${VAULT_SSH_TTL:-24h}"
ROLE="${VAULT_SSH_ROLE:-}"
KEYARG=""

# --- parse args ---
CMD="${1:-sign}"; shift || true
while [ "$#" -gt 0 ]; do
  case "$1" in
    --role)  ROLE="$2"; shift 2 ;;
    --mount) MOUNT="$2"; shift 2 ;;
    --ttl)   TTL="$2"; shift 2 ;;
    -*)      echo "Unknown option: $1" >&2; exit 64 ;;
    *)       KEYARG="$1"; shift ;;
  esac
done

# --- pick a JSON engine once, functionally testing each candidate so we never
#     select a broken one (e.g. Windows' Store python3 stub prints nothing) ---
JSON_ENGINE=sed; PY=""
if command -v jq >/dev/null 2>&1 && [ "$(printf '{"a":1}' | jq -r .a 2>/dev/null)" = "1" ]; then
  JSON_ENGINE=jq
else
  for cand in python3 python; do
    if command -v "$cand" >/dev/null 2>&1 &&
       [ "$(printf '{"a":1}' | "$cand" -c 'import sys,json;print(json.load(sys.stdin)["a"])' 2>/dev/null)" = "1" ]; then
      JSON_ENGINE=py; PY="$cand"; break
    fi
  done
fi

# json_str <json> <dotted.path>  -> prints value or empty
json_str() {
  case "$JSON_ENGINE" in
    jq)  printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null ;;
    py)  printf '%s' "$1" | "$PY" -c 'import sys,json
d=json.load(sys.stdin)
for k in sys.argv[1].strip(".").split("."):
    d=d.get(k) if isinstance(d,dict) else None
    if d is None: break
print(d if d is not None else "")' "$2" 2>/dev/null ;;
    sed) # only used for .data.signed_key style single string values
         local leaf="${2##*.}"
         printf '%s' "$1" | sed -n "s/.*\"$leaf\":\"\\([^\"]*\\)\".*/\\1/p" ;;
  esac
}

# json_list_keys <json>  -> prints .data.keys[] one per line
json_list_keys() {
  case "$JSON_ENGINE" in
    jq)  printf '%s' "$1" | jq -r '.data.keys[]?' 2>/dev/null ;;
    py)  printf '%s' "$1" | "$PY" -c 'import sys,json
d=json.load(sys.stdin)
for k in (d.get("data") or {}).get("keys") or []: print(k)' 2>/dev/null ;;
    sed) printf '%s' "$1" | sed -n 's/.*"keys":\[\([^]]*\)\].*/\1/p' \
           | tr ',' '\n' | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//' ;;
  esac
}

# --- read credentials ---
read_vaultrc() {
  [ -f "$VAULTRC" ] || { echo "NO_VAULTRC (~/.vaultrc not found)"; exit 2; }
  VAULT_ADDR=""; VAULT_TOKEN=""
  # shellcheck disable=SC1090
  . "$VAULTRC" 2>/dev/null || true
  VAULT_ADDR="${VAULT_ADDR%/}"
  if [ -z "${VAULT_ADDR:-}" ] || [ -z "${VAULT_TOKEN:-}" ]; then
    echo "NO_VAULTRC (VAULT_ADDR or VAULT_TOKEN missing in ~/.vaultrc)"; exit 2
  fi
}

# vault <METHOD> <path> [json-body]  -> sets HTTP_CODE, RESP
vault_call() {
  local method="$1" path="$2" body="${3:-}"
  local out
  if [ -n "$body" ]; then
    out=$(curl -sS -m 30 -w $'\n%{http_code}' -X "$method" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" -H 'Content-Type: application/json' \
      --data "$body" "${VAULT_ADDR}/v1/${path}" 2>/dev/null) || {
        echo "VAULT_UNREACHABLE (curl failed contacting ${VAULT_ADDR})"; exit 6; }
  else
    out=$(curl -sS -m 30 -w $'\n%{http_code}' -X "$method" \
      -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${path}" 2>/dev/null) || {
        echo "VAULT_UNREACHABLE (curl failed contacting ${VAULT_ADDR})"; exit 6; }
  fi
  HTTP_CODE="${out##*$'\n'}"
  RESP="${out%$'\n'*}"
}

# list public keys (excluding *-cert.pub), default-first preference marker
list_pubkeys() {
  [ -d "$SSH_DIR" ] || return 0
  ls -1 "$SSH_DIR"/*.pub 2>/dev/null | grep -v -- '-cert\.pub$' | sort
}

default_key() {
  local keys="$1" name
  for name in id_ed25519.pub id_ecdsa.pub id_rsa.pub; do
    printf '%s\n' "$keys" | grep -q "/$name$" && { printf '%s\n' "$keys" | grep "/$name$" | head -1; return; }
  done
}

# get roles: sets globals ROLES_STATE (ok|deny|none) and ROLES_LIST (newlines).
# Sets globals directly (NOT via $(...)/subshell) so state survives to the caller.
ROLES_STATE=""; ROLES_LIST=""
get_roles() {
  vault_call GET "${MOUNT}/roles?list=true"
  case "$HTTP_CODE" in
    200) ROLES_STATE=ok;   ROLES_LIST="$(json_list_keys "$RESP")" ;;
    403) ROLES_STATE=deny; ROLES_LIST="" ;;
    404) ROLES_STATE=none; ROLES_LIST="" ;;
    401) echo "TOKEN_INVALID (401: token expired or lacks permission)"; exit 7 ;;
    *)   ROLES_STATE=deny; ROLES_LIST="" ;;
  esac
}

read_vaultrc

case "$CMD" in
  status)
    vault_call GET auth/token/lookup-self
    if [ "$HTTP_CODE" = "200" ]; then
      ttl="$(json_str "$RESP" .data.ttl)"
      echo "OK (Vault ${VAULT_ADDR} reachable; token valid, ttl ${ttl}s)"; exit 0
    elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
      echo "TOKEN_INVALID (${HTTP_CODE}: token expired or denied)"; exit 7
    else
      echo "VAULT_UNREACHABLE (HTTP ${HTTP_CODE} from ${VAULT_ADDR})"; exit 6
    fi
    ;;

  list)
    keys="$(list_pubkeys)"; n=$(printf '%s' "$keys" | grep -c . || true)
    echo "KEYS (${n}):"
    [ -n "$keys" ] && printf '%s\n' "$keys" | sed 's/^/  /'
    get_roles
    case "$ROLES_STATE" in
      ok)   rn=$(printf '%s' "$ROLES_LIST" | grep -c . || true)
            echo "ROLES (${rn}):"; [ -n "$ROLES_LIST" ] && printf '%s\n' "$ROLES_LIST" | sed 's/^/  /' ;;
      none) echo "ROLES (0):" ;;
      deny) echo "ROLES: (cannot list - insufficient permission; specify --role)" ;;
    esac
    exit 0
    ;;

  sign)
    # 1. resolve key
    keys="$(list_pubkeys)"
    [ -n "$keys" ] || { echo "NO_KEYS (no *.pub found under ~/.ssh)"; exit 4; }
    if [ -n "$KEYARG" ]; then
      if [ -f "$KEYARG" ]; then PUB="$KEYARG"
      elif [ -f "${SSH_DIR}/${KEYARG}" ]; then PUB="${SSH_DIR}/${KEYARG}"
      else echo "NO_KEYS (specified key '${KEYARG}' not found)"; exit 4; fi
    else
      n=$(printf '%s' "$keys" | grep -c . || true)
      if [ "$n" -eq 1 ]; then
        PUB="$keys"
      else
        def="$(default_key "$keys")"
        echo "MULTIPLE_KEYS (${n} keys - caller must pick one; DEFAULT marked):"
        while IFS= read -r k; do
          if [ -n "$def" ] && [ "$k" = "$def" ]; then
            echo "  ${k}  <-- DEFAULT (suggest this)"
          else echo "  ${k}"; fi
        done <<EOF
$keys
EOF
        exit 3
      fi
    fi

    # 2. resolve role
    if [ -z "$ROLE" ]; then
      get_roles
      case "$ROLES_STATE" in
        deny) echo "NO_ROLE (cannot list roles under '${MOUNT}'; rerun with --role NAME)"; exit 5 ;;
        none) echo "NO_ROLE (no roles configured under '${MOUNT}')"; exit 5 ;;
        ok)
          rn=$(printf '%s' "$ROLES_LIST" | grep -c . || true)
          if [ "$rn" -eq 1 ]; then ROLE="$ROLES_LIST"
          elif [ "$rn" -eq 0 ]; then echo "NO_ROLE (no roles configured under '${MOUNT}')"; exit 5
          else
            echo "MULTIPLE_ROLES (${rn} roles - caller must pick one, pass --role):"
            printf '%s\n' "$ROLES_LIST" | sed 's/^/  /'
            exit 5
          fi ;;
      esac
    fi

    # 3. sign
    pubkey="$(tr -d '\r\n' < "$PUB")"
    body=$(printf '{"public_key":"%s","ttl":"%s"}' "$pubkey" "$TTL")
    vault_call POST "${MOUNT}/sign/${ROLE}" "$body"
    if [ "$HTTP_CODE" != "200" ]; then
      echo "SIGN_FAILED (${MOUNT}/sign/${ROLE}): HTTP ${HTTP_CODE} ${RESP}"; exit 8
    fi
    signed="$(json_str "$RESP" .data.signed_key)"
    [ -n "$signed" ] || { echo "SIGN_FAILED (Vault returned no signed_key)"; exit 8; }

    # 4. write cert next to the key (single LF-terminated line)
    CERT="${PUB%.pub}-cert.pub"
    printf '%s\n' "$signed" > "$CERT"

    # 5. report
    echo "SIGNED ${CERT} (role=${ROLE}, ttl=${TTL})"
    if command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -L -f "$CERT" 2>/dev/null | sed 's/^/  /'
    fi
    exit 0
    ;;

  *)
    echo "Unknown command: ${CMD} (use status|list|sign)" >&2; exit 64 ;;
esac
