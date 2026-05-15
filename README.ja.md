# macos-auth

`macos-auth` は、Mac から Linux の認証要求を承認するための実験的な PAM モジュール、Linux ヘルパー、macOS ユーザーセッション agent です。

この public repository には、Linux build / packaging subset、release packaging documentation、ユーザー向け setup notes が含まれています。macOS agent package は署名・notarize 済みの release asset および Homebrew cask として配布されます。macOS agent の source は、現時点ではこの public source subset には含まれていません。

public な Linux 側の内容は以下です。

- Rust protocol / Linux helper crates
- C PAM shim
- Linux package build scripts と package metadata
- Linux testing / packaging documentation

> **Status:** development-only。まだ production authentication mechanism として使わないでください。

## 前提条件

2 台の machine または VM が必要です。

1. macOS user-session agent を実行する **Mac**
2. Mac から PAM 認証要求を承認したい **Linux host**

macOS 側:

- 現在の検証対象は Apple Silicon Mac
- Touch ID または Apple Watch unlock が LocalAuthentication approval に使える状態
- OpenSSH client
- cask で install する場合は Homebrew

Linux 側:

- OpenSSH server
- sudo 権限を持つ user account
- 対応 package target:
  - Ubuntu 24.04 / 25.10, `amd64` または `arm64`
  - RHEL 9 / 10 family, `x86_64` または `aarch64`
- `sudo` PAM configuration を触る前に `pamtester` での検証を強く推奨

安全性と recovery の前提:

- まず VM または disposable host で試す
- Linux machine への console access を確保する
- PAM file を編集する前に root shell を開いたままにする
- まだ production authentication mechanism として使わない

## 環境

典型的な構成では、Linux host が SSH `RemoteForward` を通して Mac 上の Unix-domain socket に接続します。

Linux package が提供するもの:

- `/usr/bin/macos-auth-helper`
- `pam_macos_auth.so`
- documentation と PAM examples

macOS package / cask は Apple Silicon Homebrew prefix に従い、以下を提供します。

- `/opt/homebrew/bin/macos-auth-agent`
- `/opt/homebrew/share/macos-auth/scripts/` 以下の LaunchAgent helper scripts
- LaunchAgent plist template
- `/opt/homebrew/share/macos-auth/examples/` 以下の sample config files

runtime state は意図的に user-controlled です。

- macOS agent config: `$HOME/Library/Application Support/macos-auth/agent-config.json`
- macOS agent socket: 通常 `$HOME/Library/Application Support/macos-auth/agent.sock`
- Linux helper config: `/etc/macos-auth/config.toml`
- Linux host private key: `/etc/macos-auth/host_ed25519.key`
- pinned macOS agent public key: `/etc/macos-auth/agents.d/*.pub`
- macOS samples: `/opt/homebrew/share/macos-auth/examples/agent-config.json.example` と `/opt/homebrew/share/macos-auth/examples/ssh-config.sample`
- Linux samples: `/usr/share/macos-auth/examples/config.toml.sample` と `/usr/share/macos-auth/examples/ssh-config.sample`

## 動作の流れ

```text
+----------------------+                         +----------------------+
| Linux host           |                         | macOS user session   |
|                      |                         |                      |
|  user runs sudo      |                         |  macos-auth-agent    |
|        |             |                         |  LocalAuthentication |
|        v             |                         |  Touch ID / Watch    |
|  Linux PAM           |                         |          ^           |
|        |             |                         |          |           |
|        v             | signed request          |          |           |
|  pam_macos_auth.so   |-------------------------+----------+           |
|        |             | via SSH RemoteForward Unix socket                |
|        v             |                         |                      |
|  macos-auth-helper   | signed response         |                      |
|        |             |<-----------------------------------------------|
|        v             |                         |                      |
|  PAM result          |                         |                      |
|   - approved: success|                         |                      |
|   - unavailable:    |                         |                      |
|     password fallback                         |                      |
|   - tamper/unsafe:  |                         |                      |
|     hard fail       |                         |                      |
+----------------------+                         +----------------------+
```

trust model の概要:

- SSH forwarding は transport のみであり、trust boundary ではありません。
- Linux request は root-owned Linux host key で署名されます。
- macOS response は pinned agent key で署名されます。
- macOS agent は UI を表示する前に Linux host signature を検証します。
- nonce、timestamp、request hash により replay / substitution risk を制限します。
- authenticator unavailable / cancel / failure は通常の Linux password authentication に fallback できます。
- invalid signature、unsafe config、tampering、protocol error は fail closed します。

## インストール方法

### 1. macOS agent をインストールする `[macOS]`

これは **macOS** で実行します。Homebrew cask が利用可能な場合:

```text
brew install --cask rioriost/cask/macos-auth
```

cask は `/opt/homebrew` 以下に files をインストールします。keys、host allowlists、LaunchAgent は自動作成しません。

agent key と config を準備し、per-user LaunchAgent は明示的に install します。host allowlist の設定は、次の手順で生成する Linux host key に依存します。

便利な installed commands:

```text
/opt/homebrew/bin/macos-auth-agent --help
/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh --help
/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh
/opt/homebrew/share/macos-auth/scripts/uninstall-launchagent.sh --help
```

### 2. Linux package をインストールする `[Linux]`

これは **Linux** で実行します。release assets から Linux distribution family と architecture に合う package を download してください。

Ubuntu / Debian example:

```text
sudo dpkg -i macos-auth_0.1.0_ubuntu24.04_arm64.deb
```

RHEL-family example:

```text
sudo rpm -Uvh macos-auth-0.1.0-1.rhel9.aarch64.rpm
```

packages は helper と PAM module を install しますが、`/etc/pam.d/sudo` は変更しません。

### 3. Mac と Linux host を pair する `[macOS + Linux]`

**Linux** で Linux host key を生成します。

```text
sudo mkdir -p /etc/macos-auth/agents.d
sudo /usr/bin/macos-auth-helper gen-key \
  --private-key-file /etc/macos-auth/host_ed25519.key \
  --public-key-file /etc/macos-auth/host_ed25519.pub
```

**macOS** で macOS agent key を初期化します。

```text
/opt/homebrew/bin/macos-auth-agent keychain-init \
  --service com.macos-auth.agent \
  --account default

/opt/homebrew/bin/macos-auth-agent keychain-public-key \
  --service com.macos-auth.agent \
  --account default > agent.pub
```

public keys を反対側へ copy します。

- Linux host public key `/etc/macos-auth/host_ed25519.pub` を Mac の host allowlist へ copy
- macOS agent public key `agent.pub` を Linux の `/etc/macos-auth/agents.d/agent.pub` として copy

**macOS** では、必要なら installed sample から始められます。

```text
cp /opt/homebrew/share/macos-auth/examples/agent-config.json.example \
  "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

macOS agent config example:

```text
{
  "socket_path": "/Users/alice/Library/Application Support/macos-auth/agent.sock",
  "hosts": [
    {
      "host_id": "linux-host-id",
      "public_key_file": "/Users/alice/Library/Application Support/macos-auth/hosts/linux-host-id.pub"
    }
  ],
  "agent_keychain_service": "com.macos-auth.agent",
  "agent_keychain_account": "default",
  "agent_key_id": "agent-key-1",
  "allowed_future_skew_ms": 30000,
  "require_confirmation": false,
  "rate_limit_window_seconds": 60,
  "rate_limit_max_requests": 5
}
```

`$HOME/Library/Application Support/macos-auth/agent-config.json` として保存し、`hosts` entry が copy 済みの Linux host public key を指すようにしてください。sample では `require_confirmation=false` にしているため、通常の flow では LocalAuthentication prompt 1 回だけが表示されます。Touch ID / Apple Watch の前に追加の事前確認 dialog を出したい場合のみ `true` にしてください。

### 4. Linux helper を設定する `[Linux]`

これは **Linux** で実行します。必要なら installed sample から始められます。

```text
sudo cp /usr/share/macos-auth/examples/config.toml.sample /etc/macos-auth/config.toml
```

`/etc/macos-auth/config.toml` を作成します。

```text
socket_path = "/run/user/1000/macos-auth-agent.sock"
host_key_file = "/etc/macos-auth/host_ed25519.key"
agent_pubkey_file = "/etc/macos-auth/agents.d/agent.pub"
key_id = "host-key-1"
host_id = "linux-host-id"
hostname = "linux.example.com"
service = "sudo"
timeout_ms = 15000
allowed_future_skew_ms = 30000
```

重要な permissions:

```text
sudo chown -R root:root /etc/macos-auth
sudo chmod 0755 /etc/macos-auth /etc/macos-auth/agents.d
sudo chmod 0600 /etc/macos-auth/host_ed25519.key
sudo chmod 0644 /etc/macos-auth/config.toml /etc/macos-auth/agents.d/agent.pub
```

### 5. SSH RemoteForward を設定する `[macOS]`

この手順は **macOS** で行います。

必要なら installed sample を作業用ファイルにコピーし、`HostName`、`User`、Linux 側 UID、macOS 側 socket path を編集してから `~/.ssh/config` に反映します。

```text
cp /opt/homebrew/share/macos-auth/examples/ssh-config.sample /tmp/macos-auth-ssh-config
$EDITOR /tmp/macos-auth-ssh-config
mkdir -p "$HOME/.ssh"
cat /tmp/macos-auth-ssh-config >> "$HOME/.ssh/config"
chmod 0600 "$HOME/.ssh/config"
```

macOS の SSH config example:

```text
Host linux-with-macos-auth
    HostName linux.example.com
    User alice
    RemoteForward /run/user/1000/macos-auth-agent.sock /Users/alice/Library/Application Support/macos-auth/agent.sock
    StreamLocalBindUnlink yes
    ExitOnForwardFailure yes
```

`/run/user/1000` は Linux user の UID に、macOS socket path は agent config の path に合わせてください。

## 使い方

### 1. macOS agent を起動する `[macOS]`

LaunchAgent helper を使う場合、これは **macOS** で実行します。

```text
/opt/homebrew/share/macos-auth/scripts/install-launchagent.sh \
  --agent-bin /opt/homebrew/bin/macos-auth-agent \
  --config "$HOME/Library/Application Support/macos-auth/agent-config.json"
```

status を確認します。

```text
/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh
```

### 2. RemoteForward 付きで SSH する `[macOS]`

`RemoteForward` を含む host entry を使って、**macOS** から SSH します。

```text
ssh linux-with-macos-auth
```

その結果入った **Linux** session の中で、forwarded socket が存在することを確認します。

```text
ls -l /run/user/$(id -u)/macos-auth-agent.sock
```

### 3. helper を直接テストする `[Linux]`

PAM を使う前に、**Linux** で helper をテストします。

```text
/usr/bin/macos-auth-helper request \
  --config /etc/macos-auth/config.toml \
  --user "$USER" \
  --ruser "$USER" \
  --tty "$(tty | sed 's|^/dev/||')"
```

期待される exit codes:

| Exit | Meaning | Intended PAM behavior |
|---:|---|---|
| `0` | approved | success |
| `10` | agent unavailable | password fallback |
| `11` | user cancelled | password fallback |
| `12` | authentication failed | password fallback |
| `30` | signature/binding/freshness failure | hard fail |
| `31` | unsafe config | hard fail |
| `32` | protocol error | hard fail |

### 4. sudo を触る前に PAM をテストする `[Linux]`

まず `/etc/pam.d/sudo` は編集しないでください。これは **Linux** で実行します。

テスト用 service を作り、`pamtester` を使ってください。distro-specific details は `docs/pam-testing.md` を参照してください。

推奨 control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper timeout_ms=25000 debug
```

### 5. pamtester 成功後にのみ sudo を有効化する `[Linux]`

テスト用 service が動作した後でのみ、**Linux** の `/etc/pam.d/sudo` を編集し、通常の password authentication より上の方に `pam_macos_auth.so` 行を追加します。

PAM を編集している間は、必ず別の root shell を開いたままにしてください。

## トラブルシュート

### `agent unavailable: failed to connect to /run/user/.../macos-auth-agent.sock`

これは、Linux helper が Linux 側の SSH-forwarded Unix socket を見つけられなかったという意味です。

macOS agent 自体は正常に動作している場合があります。最も多い原因は、SSH `RemoteForward` の connection が切れていて、Linux 側の socket が存在しなくなっていることです。

```text
/run/user/1000/macos-auth-agent.sock
```

よくある理由:

- `RemoteForward` を作成した SSH session が終了した
- Mac が sleep した
- network が切り替わった、または切断された
- background の `ssh -fN ...` process が終了した
- Linux 側の `/run/user/<uid>` runtime directory が cleanup された
- Linux SSH server が remote forwarding を拒否した

**macOS** で agent が動いているか確認します。

```text
/opt/homebrew/share/macos-auth/scripts/status-launchagent.sh
ls -l "$HOME/Library/Application Support/macos-auth/agent.sock"
```

**Linux** で forwarded socket が存在するか確認します。

```text
ls -l /run/user/$(id -u)/macos-auth-agent.sock
```

forwarding connection を作り直すには、**macOS** から interactive SSH session を開きます。

```text
ssh linux-with-macos-auth
```

または background tunnel を張ります。

```text
ssh -fN linux-with-macos-auth
```

その後、**Linux** 側でもう一度確認します。

```text
ls -l /run/user/$(id -u)/macos-auth-agent.sock
```

forwarding が拒否される場合は、Linux SSH server configuration を確認してください。対象 user に対して remote forwarding と stream-local forwarding が許可されている必要があります。例:

```text
Match User alice
    AllowTcpForwarding remote
    AllowStreamLocalForwarding yes
    StreamLocalBindUnlink yes
```

server configuration を変更したら `sshd` を reload してください。

### `sudo -n` が `a password is required` で失敗する

これは想定内です。`sudo -n` は non-interactive mode なので、sudo が PAM approval flow に入らず即失敗することがあります。通常の TTY 付き command でテストしてください。

```text
sudo -k
sudo true
```

## この repository に含まれる components

| Component | Path | Purpose |
|---|---|---|
| Protocol crate | `crates/protocol` | signed request / response types、canonical bytes、signature verification |
| Linux helper | `crates/helper` | signed PAM requests を生成し、agent socket と通信し、responses を検証 |
| PAM shim | `pam/pam_macos_auth.c` | PAM context を抽出し、helper を呼び出し、helper exit codes を PAM results に map |
| Debian packaging | `packaging/linux/build-deb.sh`, `packaging/linux/deb/` | native `.deb` package build |
| RPM packaging | `packaging/linux/build-rpm.sh`, `packaging/linux/rpm/` | native `.rpm` package build |
| Linux setup helpers | `scripts/linux-*.sh` | VM testing 用 development config / install helpers |

## build prerequisites

Debian / Ubuntu builders:

```text
sudo apt-get update
sudo apt-get install -y build-essential cargo dpkg-dev libpam0g-dev make rustc
```

Fedora / RHEL-family builders:

```text
sudo dnf install -y cargo gcc make pam-devel rpm-build rust
```

local builders では、`rustup` による current Rust toolchain を使っても構いません。

## quality gate

package 作成前または commit 前に実行します。

```text
make check
```

実行内容:

- Rust formatting check
- Rust tests
- PAM C syntax check
- shell script syntax checks

同等の script:

```text
scripts/check.sh
```

## Linux packages を build する

### Debian / Ubuntu `.deb`

native Debian / Ubuntu builder で実行します。

```text
make package-deb
```

同等:

```text
packaging/linux/build-deb.sh
```

artifact は `target/package/deb/` に出力されます。

### Fedora / RHEL `.rpm`

native Fedora / RHEL-family builder で実行します。

```text
make package-rpm
```

同等:

```text
packaging/linux/build-rpm.sh
```

artifact は `target/package/rpm/` に出力されます。

Rust を distro RPM packages ではなく `rustup` 経由で入れている場合、`rpmbuild` dependency checks が Rust を認識しないことがあります。その場合は distro の `rust` / `cargo` packages を install するか、明示的な local-builder options を使ってください。

```text
RPMBUILD_OPTS=--nodeps packaging/linux/build-rpm.sh
```

## package contents

Linux packages が install するもの:

- `/usr/bin/macos-auth-helper`
- distro の PAM module directory 内の `pam_macos_auth.so`
- `/usr/share/doc/macos-auth/` 以下の package documentation
- `/usr/share/macos-auth/examples/` 以下の PAM examples
- sample Linux config: `/usr/share/macos-auth/examples/config.toml.sample`
- sample SSH config: `/usr/share/macos-auth/examples/ssh-config.sample`

packages は `/etc/pam.d/sudo` を自動変更してはいけません。

## PAM testing

最初に `/etc/pam.d/sudo` を編集しないでください。

テスト用 service と `pamtester` の流れを使います。

- `docs/pam-testing.md`
- `pam/examples/macos-auth-test`

推奨 PAM control syntax:

```text
auth [success=done authinfo_unavail=ignore default=die] pam_macos_auth.so conf=/etc/macos-auth/config.toml helper=/usr/bin/macos-auth-helper
```

意味:

- macOS approval が成功したら即成功
- authenticator unavailable / cancel / failure は password fallback
- tampering / unsafe config / protocol errors は hard fail

## documentation index

| Document | Purpose |
|---|---|
| `docs/release-packaging.md` | Linux / macOS artifacts の release packaging plan |
| `docs/release-runbook.md` | 再現可能な release targets と release checklist |
| `docs/build-farm.md` | local/native build farm policy と builder roles |
| `docs/linux-vm-test-plan.md` | Ubuntu/Debian と Fedora/RHEL の manual Parallels VM test plan |
| `docs/pam-testing.md` | PAM testing guide |
| `docs/helper.md` | Linux helper usage |
| `pam/README.md` | PAM shim usage |
| `packaging/linux/README.md` | Linux package build notes |

## License

MIT。`LICENSE` を参照してください。
