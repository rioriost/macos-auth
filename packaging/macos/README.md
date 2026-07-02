# macOS packaging

macOS release packaging targets Apple Silicon only.

Intended distribution:

- Homebrew cask
- signed and notarized `darwin-arm64` package artifact

The macOS package contains:

- `macos-auth-agent`
- LaunchAgent template
- setup/uninstall/status helper scripts
- documentation
- sample agent and SSH configuration files

The macOS package does not include Linux PAM components.

See `docs/release-packaging.md` for the full plan.

## Layout

The package follows Homebrew's Apple Silicon prefix and installs under `/opt/homebrew`:

- `/opt/homebrew/bin/macos-auth-agent`
- `/opt/homebrew/share/macos-auth/launchd/com.macos-auth.agent.plist`
- `/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh`
- `/opt/homebrew/share/macos-auth/scripts/uninstall-launchagent.sh`
- `/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh`
- `/opt/homebrew/share/macos-auth/examples/agent-config.json.example`
- `/opt/homebrew/share/macos-auth/examples/ssh-config.sample`
- `/opt/homebrew/share/doc/macos-auth/`

The package does not automatically create user Keychain material, host allowlists, or per-user LaunchAgent files. Those remain explicit user setup steps.

## Build unsigned local package

```text
packaging/macos/build-pkg.sh
```

Output:

```text
target/package/macos/macos-auth-0.1.0-darwin-arm64.pkg
```

## Build signed package

Use a Developer ID Application certificate for the agent binary and a Developer ID Installer certificate for the pkg:

```text
packaging/macos/build-pkg.sh \
  --sign-identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --pkg-sign-identity "Developer ID Installer: YOUR NAME (TEAMID)"
```

The signed output is:

```text
target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
```

## Notarization

After building a signed package, submit and staple it:

```text
xcrun notarytool submit target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg \
  --keychain-profile macos-auth-notary \
  --wait

xcrun stapler staple target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
spctl --assess --type install -vv target/package/macos/macos-auth-0.1.0-darwin-arm64-signed.pkg
```

Create the notary profile once with:

```text
xcrun notarytool store-credentials macos-auth-notary \
  --apple-id APPLE_ID \
  --team-id TEAM_ID \
  --password APP_SPECIFIC_PASSWORD
```

## Local install test

```text
sudo installer -pkg target/package/macos/macos-auth-0.1.0-darwin-arm64.pkg -target /
/opt/homebrew/bin/macos-auth-agent --help
pkgutil --files com.macos-auth.pkg
sudo pkgutil --forget com.macos-auth.pkg
sudo rm -f /opt/homebrew/bin/macos-auth-agent
sudo rm -rf /opt/homebrew/share/macos-auth /opt/homebrew/share/doc/macos-auth
```

## User setup after install

Create or update an agent config and install the per-user LaunchAgent explicitly. Example:

```text
/opt/homebrew/bin/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default

/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh \
  --agent-bin /opt/homebrew/bin/macos-auth-agent \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

The Homebrew cask should present these as caveats rather than silently modifying per-user state during package installation.
