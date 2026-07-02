# Known-bad configurations

This document lists configurations that are unsafe, misleading, or likely to hide security failures.

Use this as a pre-flight checklist before testing `macos-auth`.

## PAM configurations

### Bad: `sufficient` without result discrimination

```text
auth sufficient pam_macos_auth.so conf=/etc/macos-auth/config.toml
```

Problem:

- PAM behavior depends on stack details.
- Hard failures may be harder to reason about.

Use instead:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

### Bad: ignore all failures

```text
auth [success=done default=ignore] pam_macos_auth.so conf=/etc/macos-auth/config.toml
```

Problem:

- Tampering can silently fall through to password authentication.
- Unsafe config can be hidden.

Use instead:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/local/bin/macos-auth-helper
```

### Bad: editing `sudo` before testing with pamtester

Problem:

- PAM mistakes can break `sudo`.
- Recovery may require console/root access.

Use instead:

1. Install `/etc/pam.d/macos-auth-test`.
2. Test with `pamtester`.
3. Keep a root shell open.
4. Only then edit `/etc/pam.d/sudo`.

## SSH configurations

### Bad: SSH agent forwarding as transport

```text
ForwardAgent yes
```

Problem:

- Exposes a generic signing interface to the remote host.
- Does not bind approval to `sudo` request context.

Use instead:

```text
RemoteForward /run/user/1000/macos-auth-agent.sock /Users/YOUR_MAC_USER/Library/Application Support/macos-auth/agent.sock
```

### Bad: no `ExitOnForwardFailure`

```text
RemoteForward /run/user/1000/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
```

Problem:

- SSH can succeed even when forwarding failed.
- The helper will fall back to password and hide deployment problems.

Use instead:

```text
ExitOnForwardFailure yes
```

### Bad: shared `/tmp` socket on multi-user hosts

```text
RemoteForward /tmp/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
```

Problem:

- Collisions across users.
- Confusing access boundaries.
- Stale socket issues.

Use instead:

```text
RemoteForward /run/user/1000/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
```

or a root-managed per-user runtime directory.

## Linux key and config permissions

### Bad: host private key readable by group/world

```text
-rw-r--r-- /etc/macos-auth/host_ed25519.key
```

Problem:

- Any local user may copy the Linux host signing key.
- macOS agent may trust forged requests from that host id.

Use instead:

```text
-rw------- root root /etc/macos-auth/host_ed25519.key
```

### Bad: config file group/world writable

```text
-rw-rw-rw- /etc/macos-auth/config.toml
```

Problem:

- Attackers can redirect socket paths or key files.

Use instead:

```text
-rw-r--r-- root root /etc/macos-auth/config.toml
```

### Bad: agent public key file writable by group/world

Problem:

- Attackers can replace the pinned macOS agent public key.

Use instead:

```text
-rw-r--r-- root root /etc/macos-auth/agents.d/alice.pub
```

## macOS agent configurations

### Bad: inline agent private key in config

```json
{
  "agent_key_hex": "..."
}
```

Problem:

- Private key material is stored directly in config.
- Config may be copied or logged during troubleshooting.

Use instead for development:

```json
{
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default"
}
```

### Bad: wildcard host key in long-lived config

```json
{
  "host_public_key_hex": "..."
}
```

Problem:

- This acts as a single wildcard verifier.
- It is less explicit than a host allowlist.

Use instead:

```json
{
  "hosts": [
    {
      "host_id": "linux-host-id",
      "public_key_file": "/Users/alice/Library/Application Support/macos-auth/hosts/linux-host-id.pub"
    }
  ]
}
```

### Bad: disabling confirmation without compensating controls

```json
{
  "require_confirmation": false
}
```

Problem:

- User may see only the LocalAuthentication prompt with reduced context.
- Prompt bombing is easier to miss.

Use instead:

```json
{
  "require_confirmation": true
}
```

## Helper / script configurations

### Bad: world-writable helper binary

Problem:

- PAM shim executes the helper as part of authentication.
- Writable helper path is equivalent to code execution in the PAM flow.

Use instead:

```text
-rwxr-xr-x root root /usr/local/bin/macos-auth-helper
```

### Bad: installing without rollback path

Problem:

- PAM mistakes can lock out privilege escalation.

Use instead:

- keep a root shell open
- test `macos-auth-test` with `pamtester`
- backup PAM files
- document recovery steps

## Development shortcuts that must not become production defaults

These are acceptable for local development but not production:

- `/tmp` socket paths
- inline `agent_key_hex`
- `unsafe_allow_helper_permissions`
- direct edits to `/etc/pam.d/sudo` without `pamtester`
- generic-password Keychain storage as a final non-exportable key solution

## Quick pre-flight checklist

- [ ] PAM uses `authinfo_unavail=ignore default=die`
- [ ] `sudo` was not edited before `pamtester` succeeded
- [ ] Linux host private key is `0600 root:root`
- [ ] Linux config and agent public key are not group/world writable
- [ ] SSH uses `RemoteForward`, not `ForwardAgent`
- [ ] SSH uses `ExitOnForwardFailure yes`
- [ ] macOS agent uses `hosts` allowlist
- [ ] macOS agent config does not contain inline private key material
- [ ] confirmation UI is enabled
