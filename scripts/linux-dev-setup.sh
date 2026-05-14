#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  linux-dev-setup.sh --host-id ID --hostname NAME --agent-pubkey-file PATH [options]

Creates a development Linux helper setup in a local output directory by default.
It does not edit /etc/pam.d or require root unless you choose paths that require it.

Options:
  --host-id ID                 Stable Linux host id
  --hostname NAME              Hostname to place in signed requests
  --agent-pubkey-file PATH     macOS agent public key file
  --out-dir PATH               Default: ./macos-auth-linux-dev
  --socket-path PATH           Default: OUT_DIR/agent.sock
  --helper-bin PATH            Default: target/debug/macos-auth-helper
  --force                      Overwrite generated output files
  -h, --help                   Show this help
USAGE
}

host_id=""
hostname=""
agent_pubkey_file=""
out_dir="./macos-auth-linux-dev"
socket_path=""
helper_bin="target/debug/macos-auth-helper"
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-id)
      host_id="$2"
      shift 2
      ;;
    --hostname)
      hostname="$2"
      shift 2
      ;;
    --agent-pubkey-file)
      agent_pubkey_file="$2"
      shift 2
      ;;
    --out-dir)
      out_dir="$2"
      shift 2
      ;;
    --socket-path)
      socket_path="$2"
      shift 2
      ;;
    --helper-bin)
      helper_bin="$2"
      shift 2
      ;;
    --force)
      force=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "$host_id" ] || [ -z "$hostname" ] || [ -z "$agent_pubkey_file" ]; then
  usage >&2
  exit 2
fi

if [ ! -x "$helper_bin" ]; then
  echo "helper binary is not executable: $helper_bin" >&2
  echo "Run cargo build first or pass --helper-bin." >&2
  exit 1
fi

if [ ! -f "$agent_pubkey_file" ]; then
  echo "agent public key file does not exist: $agent_pubkey_file" >&2
  exit 1
fi

if [ -z "$socket_path" ]; then
  socket_path="$out_dir/agent.sock"
fi

if [ -e "$out_dir" ] && [ "$force" -ne 1 ]; then
  echo "output directory already exists: $out_dir" >&2
  echo "Use --force to overwrite generated files." >&2
  exit 1
fi

mkdir -p "$out_dir/agents.d"

host_key_file="$out_dir/host_ed25519.key"
host_pubkey_file="$out_dir/host_ed25519.pub"
config_file="$out_dir/config.toml"
agent_pubkey_dest="$out_dir/agents.d/agent.pub"

if [ "$force" -eq 1 ]; then
  rm -f "$host_key_file" "$host_pubkey_file" "$config_file" "$agent_pubkey_dest"
fi

"$helper_bin" gen-key \
  --private-key-file "$host_key_file" \
  --public-key-file "$host_pubkey_file" >/dev/null

cp "$agent_pubkey_file" "$agent_pubkey_dest"
chmod 0644 "$agent_pubkey_dest"

cat > "$config_file" <<EOF
socket_path = "$socket_path"
host_key_file = "$host_key_file"
agent_pubkey_file = "$agent_pubkey_dest"
key_id = "host-key-1"
host_id = "$host_id"
hostname = "$hostname"
service = "sudo"
timeout_ms = 15000
allowed_future_skew_ms = 30000
EOF
chmod 0644 "$config_file"

cat <<EOF
macos-auth Linux development helper setup complete.

Output directory: $out_dir
Host private key: $host_key_file
Host public key: $host_pubkey_file
Helper config: $config_file
Agent public key: $agent_pubkey_dest
Socket path: $socket_path

Give this host public key to the macOS agent allowlist:
  $host_pubkey_file

Test with:
  "$helper_bin" request --config "$config_file" --user "$USER"
EOF
