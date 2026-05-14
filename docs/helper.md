# `macos-auth-helper`

`macos-auth-helper` is the early Linux-side integration binary. It currently supports protocol fixtures and Unix-domain-socket integration tests before the PAM shim exists.

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
  --socket /tmp/macos-auth-test.sock \
  --host-pubkey-hex <linux-host-public-key-hex> \
  --agent-key-hex <agent-private-key-hex> \
  --once
```

### Send a request to an agent

```text
cargo run -p macos-auth-helper -- request \
  --socket /tmp/macos-auth-test.sock \
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

## Exit codes

| exit code | meaning | PAM behavior |
|---:|---|---|
| 0 | approved | success |
| 10 | unavailable | password fallback |
| 11 | cancelled | password fallback by default |
| 12 | failed | password fallback |
| 20 | denied | policy-dependent |
| 30 | tamper/signature/binding/freshness failure | hard fail |
| 31 | unsafe config, including permissive private key file permissions | hard fail |
| 32 | protocol error after connecting | hard fail |

## Security note

`--key-hex` remains available for early development and tests, but real use should pass private keys through `--key-file`. Private key files must be regular files and must not grant any group/world permissions. Public key files must be regular files and must not be group/world writable.
