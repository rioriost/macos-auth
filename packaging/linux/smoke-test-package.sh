#!/bin/sh
set -eu

usage() {
  cat <<'USAGE'
Usage:
  smoke-test-package.sh PATH_TO_DEB_OR_RPM

Installs a built macos-auth Linux package, verifies the installed helper and file
list, then uninstalls the package.

Run this script as root in a disposable VM or test container. It does not modify
/etc/pam.d/sudo and does not run pamtester.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -ne 1 ]; then
  usage >&2
  exit 2
fi

package_path=$1
package_name=macos-auth

if [ "$(id -u)" -ne 0 ]; then
  echo "This smoke test must be run as root because package install/uninstall is required." >&2
  exit 1
fi

if [ ! -f "$package_path" ]; then
  echo "package file not found: $package_path" >&2
  exit 1
fi

case "$package_path" in
  *.deb)
    if ! command -v dpkg >/dev/null 2>&1; then
      echo "dpkg is required for .deb smoke tests" >&2
      exit 1
    fi
    echo "Installing $package_path"
    dpkg -i "$package_path"

    echo "Checking helper"
    /usr/bin/macos-auth-helper --help >/tmp/macos-auth-helper-help.txt

    echo "Installed files"
    dpkg -L "$package_name"

    echo "Removing $package_name"
    dpkg -r "$package_name"

    if dpkg -s "$package_name" >/dev/null 2>&1; then
      echo "package still appears installed after removal: $package_name" >&2
      exit 1
    fi
    ;;
  *.rpm)
    if ! command -v rpm >/dev/null 2>&1; then
      echo "rpm is required for .rpm smoke tests" >&2
      exit 1
    fi
    echo "Installing $package_path"
    rpm -Uvh --replacepkgs "$package_path"

    echo "Checking helper"
    /usr/bin/macos-auth-helper --help >/tmp/macos-auth-helper-help.txt

    echo "Installed files"
    rpm -ql "$package_name"

    echo "Removing $package_name"
    rpm -e "$package_name"

    if rpm -q "$package_name" >/dev/null 2>&1; then
      echo "package still appears installed after removal: $package_name" >&2
      exit 1
    fi
    ;;
  *)
    echo "unsupported package type: $package_path" >&2
    echo "expected .deb or .rpm" >&2
    exit 2
    ;;
esac

echo "smoke test passed: $package_path"
