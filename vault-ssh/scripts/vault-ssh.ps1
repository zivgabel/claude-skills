#Requires -Version 5.1
<#
  vault-ssh.ps1 — sign a local SSH public key with HashiCorp Vault's SSH CA
  to produce a short-lived (1 day) SSH certificate.

  Credentials come from ~/.vaultrc (shell format: `export VAULT_ADDR=...` /
  `export VAULT_TOKEN=...`). Signing engine mount defaults to `ssh-client-signer2`.

  Commands:
    status              - check Vault reachability + token validity
    list                - list local .ssh public keys and available signer roles
    sign [keyPubPath]   - sign a key. If keyPubPath omitted: use the only key,
                          or emit MULTIPLE_KEYS for the caller to disambiguate.

  Machine-readable output contract (first token of a line):
    NO_VAULTRC          (exit 2)  ~/.vaultrc missing or lacks VAULT_ADDR/VAULT_TOKEN
    VAULT_UNREACHABLE   (exit 6)  network/TLS error talking to Vault
    TOKEN_INVALID       (exit 7)  token expired / denied
    NO_KEYS             (exit 4)  no *.pub under ~/.ssh
    MULTIPLE_KEYS       (exit 3)  more than one key and none specified (list follows)
    NO_ROLE             (exit 5)  no signer role found and none specified
    MULTIPLE_ROLES      (exit 5)  more than one role and none specified (list follows)
    SIGN_FAILED <msg>   (exit 8)  Vault rejected the signing request
    SIGNED <certPath>   (exit 0)  success; certificate written next to the key
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'list', 'sign')]
    [string]$Command = 'sign',

    [Parameter(Position = 1)]
    [string]$KeyPath,

    [string]$Role = $env:VAULT_SSH_ROLE,
    [string]$Mount = $(if ($env:VAULT_SSH_MOUNT) { $env:VAULT_SSH_MOUNT } else { 'ssh-client-signer2' }),
    [string]$Ttl = $(if ($env:VAULT_SSH_TTL) { $env:VAULT_SSH_TTL } else { '24h' })
)

$ErrorActionPreference = 'Stop'
$SshDir = Join-Path $HOME '.ssh'
$VaultRc = Join-Path $HOME '.vaultrc'

function Read-VaultRc {
    if (-not (Test-Path $VaultRc)) {
        Write-Output "NO_VAULTRC (~/.vaultrc not found)"
        exit 2
    }
    $addr = $null; $token = $null
    foreach ($line in Get-Content $VaultRc) {
        if ($line -match '^\s*(?:export\s+)?VAULT_ADDR\s*=\s*(.+?)\s*$') {
            $addr = $Matches[1].Trim('"').Trim("'")
        }
        elseif ($line -match '^\s*(?:export\s+)?VAULT_TOKEN\s*=\s*(.+?)\s*$') {
            $token = $Matches[1].Trim('"').Trim("'")
        }
    }
    if (-not $addr -or -not $token) {
        Write-Output "NO_VAULTRC (VAULT_ADDR or VAULT_TOKEN missing in ~/.vaultrc)"
        exit 2
    }
    return @{ Addr = $addr.TrimEnd('/'); Token = $token }
}

function Invoke-Vault {
    param([string]$Method, [string]$Path, [hashtable]$Body)
    $uri = "$($script:V.Addr)/v1/$Path"
    $headers = @{ 'X-Vault-Token' = $script:V.Token }
    try {
        if ($Body) {
            return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers `
                -Body ($Body | ConvertTo-Json -Compress) -ContentType 'application/json'
        }
        return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers
    }
    catch {
        $resp = $_.Exception.Response
        if ($resp -and ($resp.StatusCode.value__ -in 401, 403)) {
            Write-Output "TOKEN_INVALID ($($resp.StatusCode.value__): token expired or lacks permission)"
            exit 7
        }
        # Re-throw so callers can decide (e.g. role listing may 403 legitimately)
        throw
    }
}

function Get-PublicKeys {
    if (-not (Test-Path $SshDir)) { return @() }
    # Leading comma prevents PowerShell from unrolling a single-element result.
    return ,@(Get-ChildItem -Path $SshDir -Filter '*.pub' -File |
        Where-Object { $_.Name -notlike '*-cert.pub' } |
        Sort-Object Name)
}

function Get-Roles {
    try {
        $r = Invoke-Vault -Method 'Get' -Path "$Mount/roles?list=true"
        # Leading comma keeps this an array even for a single role (else PS
        # unrolls it to a bare string and $roles[0] indexes a char).
        return ,@($r.data.keys)
    }
    catch {
        # Listing may be denied even when signing is allowed; $null signals that.
        return $null
    }
}

# --- Load credentials for every command ---
$script:V = Read-VaultRc

switch ($Command) {

    'status' {
        try {
            $r = Invoke-Vault -Method 'Get' -Path 'auth/token/lookup-self'
            $ttlLeft = $r.data.ttl
            Write-Output "OK (Vault $($script:V.Addr) reachable; token valid, ttl ${ttlLeft}s)"
            exit 0
        }
        catch {
            Write-Output "VAULT_UNREACHABLE ($($_.Exception.Message))"
            exit 6
        }
    }

    'list' {
        $keys = Get-PublicKeys
        Write-Output "KEYS ($($keys.Count)):"
        foreach ($k in $keys) { Write-Output "  $($k.FullName)" }
        $roles = Get-Roles
        if ($null -eq $roles) {
            Write-Output "ROLES: (cannot list - insufficient permission; specify -Role)"
        }
        else {
            Write-Output "ROLES ($($roles.Count)):"
            foreach ($ro in $roles) { Write-Output "  $ro" }
        }
        exit 0
    }

    'sign' {
        # 1. Resolve which public key to sign.
        $keys = Get-PublicKeys
        if ($keys.Count -eq 0) {
            Write-Output "NO_KEYS (no *.pub found under ~/.ssh)"
            exit 4
        }
        if ($KeyPath) {
            $resolved = if (Test-Path $KeyPath) { (Resolve-Path $KeyPath).Path }
                        elseif (Test-Path (Join-Path $SshDir $KeyPath)) { (Resolve-Path (Join-Path $SshDir $KeyPath)).Path }
                        else { $null }
            if (-not $resolved) {
                Write-Output "NO_KEYS (specified key '$KeyPath' not found)"
                exit 4
            }
            $pubFile = $resolved
        }
        elseif ($keys.Count -eq 1) {
            $pubFile = $keys[0].FullName
        }
        else {
            # Prefer the conventional default identity (id_ed25519 / id_rsa /
            # id_ecdsa) so the caller can suggest it; mark it in the list.
            $defaultNames = @('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub')
            $default = $keys | Where-Object { $defaultNames -contains $_.Name } |
                Sort-Object { $defaultNames.IndexOf($_.Name) } | Select-Object -First 1
            Write-Output "MULTIPLE_KEYS ($($keys.Count) keys - caller must pick one; DEFAULT marked):"
            foreach ($k in $keys) {
                $tag = if ($default -and $k.FullName -eq $default.FullName) { '  <-- DEFAULT (suggest this)' } else { '' }
                Write-Output "  $($k.FullName)$tag"
            }
            exit 3
        }

        # 2. Resolve the signing role.
        if (-not $Role) {
            $roles = Get-Roles
            if ($null -eq $roles) {
                Write-Output "NO_ROLE (cannot list roles under '$Mount'; rerun with -Role <name>)"
                exit 5
            }
            elseif ($roles.Count -eq 0) {
                Write-Output "NO_ROLE (no roles configured under '$Mount')"
                exit 5
            }
            elseif ($roles.Count -eq 1) {
                $Role = $roles[0]
            }
            else {
                Write-Output "MULTIPLE_ROLES ($($roles.Count) roles - caller must pick one, pass -Role):"
                foreach ($ro in $roles) { Write-Output "  $ro" }
                exit 5
            }
        }

        # 3. Sign.
        $pubKey = (Get-Content -Raw $pubFile).Trim()
        try {
            $r = Invoke-Vault -Method 'Post' -Path "$Mount/sign/$Role" -Body @{
                public_key = $pubKey
                ttl        = $Ttl
            }
        }
        catch {
            $msg = $_.Exception.Message
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                if ($body) { $msg = $body }
            } catch {}
            Write-Output "SIGN_FAILED ($Mount/sign/$Role): $msg"
            exit 8
        }

        $signed = $r.data.signed_key
        if (-not $signed) {
            Write-Output "SIGN_FAILED (Vault returned no signed_key)"
            exit 8
        }

        # 4. Write the cert next to the key so OpenSSH auto-loads it.
        $certPath = ($pubFile -replace '\.pub$', '') + '-cert.pub'
        # Write exactly one LF-terminated line (no CRLF, no trailing blank line)
        # so ssh-keygen/OpenSSH parse it without "invalid format" noise.
        [System.IO.File]::WriteAllText($certPath, $signed.Trim() + "`n", `
            (New-Object System.Text.ASCIIEncoding))

        # 5. Report the certificate contents (validity window / principals).
        try {
            $info = & ssh-keygen -L -f $certPath 2>$null
            Write-Output "SIGNED $certPath (role=$Role, ttl=$Ttl)"
            if ($info) { $info | ForEach-Object { Write-Output "  $_" } }
        }
        catch {
            Write-Output "SIGNED $certPath (role=$Role, ttl=$Ttl)"
        }
        exit 0
    }
}
