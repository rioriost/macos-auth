#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  linux-install-dev.sh --dev-dir PATH [options]

Installs the development Linux helper config and PAM module artifacts into system paths.
This script does not modify /etc/pam.d/sudo. It can optionally install a separate
/etc/pam.d/macos-auth-test service for pamtester.

Options:
  --dev-dir PATH               Directory produced by scripts/linux-dev-setup.sh
  --helper-bin PATH            Default: target/debug/macos-auth-helper
  --pam-module PATH            Default: pam/pam_macos_auth.so
  --pam-dir PATH               Default: auto-detect /lib/*/security or /lib/security
  --install-pamtester-service  Install /etc/pam.d/macos-auth-test
  --force                      Overwrite existing installed files
  -h, --help                   Show this help
USAGE
}

dev_dir=""
helper_bin="target/debug/macos-auth-helper"
pam_module="pam/pam_macos_auth.so"
pam_dir=""
install_pamtester_service=0
force=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dev-dir)
      dev_dir="$2"
      shift 2
      ;;
    --helper-bin)
      helper_bin="$2"
      shift 2
      ;;
    --pam-module)
      pam_module="$2"
      shift 2
      ;;
    --pam-dir)
      pam_dir="$2"
      shift 2
      ;;
    --install-pamtester-service)
      install_pamtester_service=1
      shift
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

if [ -z "$dev_dir" ]; then
  usage >&2
  exit 2
fi

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer must be run as root." >&2
  exit 1
fi

if [ ! -d "$dev_dir" ]; then
  echo "dev dir does not exist: $dev_dir" >&2
  exit 1
fi

if [ ! -x "$helper_bin" ]; then
  echo "helper binary is not executable: $helper_bin" >&2
  exit 1
fi

if [ ! -f "$pam_module" ]; then
  echo "PAM module does not exist: $pam_module" >&2
  echo "Run: make -C pam" >&2
  exit 1
fi

if [ -z "$pam_dir" ]; then
  if [ -d /lib/aarch64-linux-gnu/security ]; then
    pam_dir=/lib/aarch64-linux-gnu/security
  elif [ -d /lib/x86_64-linux-gnu/security ]; then
    pam_dir=/lib/x86_64-linux-gnu/security
  elif [ -d /lib64/security ]; then
    pam_dir=/lib64/security
  elif [ -d /lib/security ]; then
    pam_dir=/lib/security
  else
    echo "Could not auto-detect PAM module directory. Pass --pam-dir." >&2
    exit 1
  fi
fi

install_file() {
  src="$1"
  dst="$2"
  mode="$3"
  owner="$4"

  if [ -e "$dst" ] && [ "$force" -ne 1 ]; then
    echo "Refusing to overwrite existing file: $dst" >&2
    echo "Use --force to overwrite." >&2
    exit 1
  fi
  mkdir -p "$(dirname -- "$dst")"
  cp "$src" "$dst"
  chown "$owner" "$dst"
  chmod "$mode" "$dst"
}

install_file "$helper_bin" /usr/local/bin/macos-auth-helper 0755 root:root
install_file "$pam_module" "$pam_dir/pam_macos_auth.so" 0644 root:root
install_file "$dev_dir/host_ed25519.key" /etc/macos-auth/host_ed25519.key 0600 root:root
install_file "$dev_dir/config.toml" /etc/macos-auth/config.toml 0644 root:root
install_file "$dev_dir/agents.d/agent.pub" /etc/macos-auth/agents.d/agent.pub 0644 root:root

if [ "$install_pamtester_service" -eq 1 ]; then
  service_src="pam/examples/macos-auth-test"
  if [ ! -f "$service_src" ]; then
    echo "PAM service template missing: $service_src" >&2
    exit 1
  fi
  install_file "$service_src" /etc/pam.d/macos-auth-test 0644 root:root
fi

cat <<EOF
macos-auth development Linux system install complete.

Installed helper: /usr/local/bin/macos-auth-helper
Installed PAM module: $pam_dir/pam_macos_auth.so
Installed config: /etc/macos-auth/config.toml

This script did not modify /etc/pam.d/sudo.

Recommended test before touching sudo:
  pamtester macos-auth-test "$SUDO_USER" authenticate

If pamtester is not installed, install it with your distro package manager.
EOF
