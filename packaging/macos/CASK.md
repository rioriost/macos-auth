# Homebrew cask notes

The cask repository is maintained separately from this source tree.

Repository/path:

- `../homebrew-cask/`
- `github.com/rioriost/homebrew/cask/`

## Cask skeleton

```text
cask "macos-auth" do
  version "0.1.2"
  sha256 "SHA256_OF_NOTARIZED_PKG"

  url "https://github.com/rioriost/macos-auth/releases/download/v#{version}/macos-auth-#{version}-darwin-arm64.pkg"
  name "macos-auth"
  desc "Agent for approving Linux PAM authentication requests"
  homepage "https://github.com/rioriost/macos-auth"

  depends_on arch: :arm64
  depends_on macos: :ventura

  pkg "macos-auth-#{version}-darwin-arm64.pkg"

  uninstall launchctl: "com.macos-auth.agent",
            pkgutil: "com.macos-auth.pkg",
            delete: [
              "/opt/homebrew/bin/macos-auth-agent",
              "/opt/homebrew/share/macos-auth",
              "/opt/homebrew/share/doc/macos-auth",
            ]

  caveats <<~EOS
    macos-auth installs the agent binary and helper scripts only.
    It does not create agent keys, host allowlists, or a per-user LaunchAgent automatically.

    After preparing an agent config, install the LaunchAgent with:
      /opt/homebrew/share/macos-auth/scripts/install-launchagent.sh \\
        --agent-bin /opt/homebrew/bin/macos-auth-agent \\
        --config "$HOME/Library/Application Support/macos-auth/agent-config.json"

    Check status with:
      /opt/homebrew/share/macos-auth/scripts/status-launchagent.sh

    Unload with:
      /opt/homebrew/share/macos-auth/scripts/uninstall-launchagent.sh --keep-plist
  EOS
end
```

## Release asset expectations

The cask should point to a signed and notarized package named:

```text
macos-auth-0.1.2-darwin-arm64.pkg
```

The package should pass:

```text
xcrun stapler validate macos-auth-0.1.2-darwin-arm64.pkg
pkgutil --check-signature macos-auth-0.1.2-darwin-arm64.pkg
spctl --assess --type install -vv macos-auth-0.1.2-darwin-arm64.pkg
```

Use the final-byte hash from the provenance-aware `notarize-pkg.sh` wrapper's
`SHA256SUMS.cask`, not the hash of the unstapled signed intermediate. Publish a new
versioned asset; never replace an asset in the already-published 0.1.1 release.
