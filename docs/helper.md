# `macos-auth-helper`

`macos-auth-helper` is the Linux-side protocol verifier used by the PAM shim. It also supports development fixtures and Unix-domain-socket integration tests.

## Commands

### Generate a keypair

```text
cargo run -p macos-auth-helper -- gen-key
```

You can also write key files directly:

```text
cargo run -p macos-auth-helper -- gen-key \
  --private-key-file ./host_ed25519.key \
  --public-key-file ./host_ed25519.pub
```

The private key file is created with mode `0600`. The public key file is created with mode `0644`.

Output:

```text
private_key_hex=...
public_key_hex=...
```

### Derive a public key from a private key

```text
cargo run -p macos-auth-helper -- pubkey --key-hex <private-key-hex>
```

or:

```text
cargo run -p macos-auth-helper -- pubkey --key-file ./host_ed25519.key
```

### Emit a signed sample request

```text
cargo run -p macos-auth-helper -- sample-request --user alice --ruser alice --tty pts/3
```

### Run a fake agent

```text
cargo run -p macos-auth-helper -- fake-agent \
  --socket "$PWD/agent.sock" \
  --host-pubkey-hex <linux-host-public-key-hex> \
  --agent-key-hex <agent-private-key-hex> \
  --once
```

### Send a request to an agent

```text
cargo run -p macos-auth-helper -- request \
  --socket "$PWD/agent.sock" \
  --key-file ./host_ed25519.key \
  --agent-pubkey-file ./agent_ed25519.pub \
  --host-id host-abc \
  --hostname linux.example.com \
  --user alice \
  --ruser alice \
  --tty pts/3
```

### Send a request using a config file

```text
cargo run -p macos-auth-helper -- request \
  --config ./macos-auth-helper.toml \
  --user alice \
  --ruser alice \
  --tty pts/3
```

Example config:

```toml
socket_path = "/run/macos-auth/alice/agent.sock"
host_key_file = "/etc/macos-auth/host_ed25519.key"
agent_pubkey_file = "/etc/macos-auth/agents.d/alice.pub"
key_id = "host-key-1"
host_id = "host-abc"
hostname = "linux.example.com"
service = "sudo"
timeout_ms = 15000
allowed_future_skew_ms = 30000
```

The config file must be a regular file and must not be group/world writable. CLI arguments override config values.

### Production trust mode

PAM always runs `/usr/bin/macos-auth-helper request --require-root-owned`.
For a production-equivalent direct test, explicitly add `--require-root-owned`.
There is no automatic downgrade when ownership validation fails.

In this mode, config, private key, pinned public key, and optional replay-cache
directory must have absolute, root-owned paths. Every ancestor must also be
root-owned and not group/world writable. Symlinks and `..` components are
rejected. Private keys and replay directories allow no group/world permissions;
config and public keys may be readable but not writable by others.
Files are read through the descriptors that were validated, and replay markers
are created/cleaned relative to the validated directory descriptor.
Inline key hex is rejected in production mode.

Direct development commands omit `--require-root-owned` and may read user-owned
files with relative paths. File modes, non-writable ancestors, and no-symlink
checks still apply. This mode is not suitable for PAM. The socket path is always
required to be absolute; socket ownership does not establish trust in responses.

### Configuration generation and relocation

`prepare-config` serializes TOML safely, including quotes in host names/IDs:

```text
macos-auth-helper prepare-config \
  --socket /run/macos-auth/agent.sock \
  --host-key-file /etc/macos-auth/host_ed25519.key \
  --agent-pubkey-file /etc/macos-auth/agents.d/agent.pub \
  --host-id host-abc --hostname linux.example.com
```

With `--source CONFIG`, it preserves other TOML options while replacing the
three supplied paths. An existing replay-cache option additionally requires
`--replay-cache-dir DESTINATION`. Comments/formatting are not preserved.
`config-key-path --config CONFIG --key host|agent` validates the actual source
fields and key material before printing an absolute key path for the installer.
Neither command creates system files or enables production trust by itself.

### Deadlines

`timeout_ms` defaults to 15000, must be positive, and must not overflow the
request expiry or monotonic deadline. One absolute deadline covers signing,
nonblocking connect, writes, reads, and the final approval check; receiving
partial bytes cannot restart the budget. Request expiry uses this same budget.
The helper rechecks request freshness before returning a verified decision.
PAM has an independent 20000 ms process timeout, which should be longer.

## Exit codes

| exit code | meaning | PAM behavior |
|---:|---|---|
| 0 | approved | success |
| 10 | unavailable / operation timeout / request budget exhausted | password fallback |
| 11 | cancelled | password fallback by default |
| 12 | failed | password fallback |
| 20 | denied | hard fail |
| 30 | tamper/signature/binding/freshness failure | hard fail |
| 31 | unsafe config, including permissive private key file permissions | hard fail |
| 32 | malformed/truncated frames or non-timeout I/O failure after connecting | hard fail |

## Security note

`--key-hex` remains available for early development and tests, but real use should pass private keys through `--key-file`. Private key files must be regular files and must not grant any group/world permissions. Public key files must be regular files and must not be group/world writable.
