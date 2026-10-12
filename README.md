# Reality Manager

A cross-platform desktop application for deploying, configuring, operating, and recovering a **VLESS + REALITY** tunnel across a VPS and either an OpenWrt router or a Linux computer.

Reality Manager was built from a manually validated GL.iNet/OpenWrt deployment workflow and turns that process into a guided GUI: connect to the target and VPS over SSH, detect whether the system is already configured, perform first-time deployment when needed, and otherwise open directly to a simple REALITY on/off dashboard.

> **Scope:** Reality Manager configures **VLESS + REALITY only**. OpenVPN screenshots in this README are retained as development/testing evidence and performance comparison; the application does not install or manage OpenVPN.

## What it does

### First launch / first-time setup

1. Prompts for SSH connection details for the router/computer and VPS.
2. Connects to both systems inside the application using Paramiko.
3. Probes the target OS, firewall stack, network interfaces, and existing REALITY state.
4. If no installation exists, presents setup fields for environment-specific values such as:
   - VPS public IP or hostname
   - REALITY listen port
   - SNI / camouflage hostname
   - sing-box version
   - LAN interface and subnet for router deployments
   - TUN interface/address and MTU
   - policy-routing table ID
   - DNS resolver used through the tunnel
5. Deploys the VPS first.
6. Generates or retrieves the VLESS UUID, REALITY keypair, and short ID.
7. Deploys the client side to the router/computer.
8. Validates the sing-box configuration before enabling services.
9. Leaves the user in a known state and exposes activation/recovery controls from the GUI.

### Existing installation

If Reality Manager detects an already configured target, it skips setup and opens the dashboard.

The dashboard is intended to provide:

- **REALITY ON / OFF** control
- current deployment state
- router/computer SSH state
- VPS SSH state
- public IP verification
- tunnel/interface status
- routing and firewall diagnostics
- recovery logs

## Architecture

```text
+-----------------------------+
| Reality Manager             |
| Windows / macOS             |
| PySide6 GUI                 |
+--------------+--------------+
               |
               | SSH (Paramiko)
        +------+-------+
        |              |
        v              v
+---------------+  +----------------+
| Router / PC   |  | VPS            |
| sing-box TUN  |  | sing-box       |
| kill switch   |  | VLESS+REALITY  |
| routing/DNS   |  | server         |
+-------+-------+  +--------+-------+
        |                   |
        +--------- encrypted REALITY tunnel -------->
```

The application does **not** shell out to the local machine's `ssh` or `scp`. SSH transport is handled directly through Paramiko. File upload uses the SSH channel itself so embedded OpenWrt systems do not need `sftp-server`.

## Supported targets

### OpenWrt router mode

Current automated router support intentionally targets:

- OpenWrt
- **fw3 + iptables**
- BusyBox/ash-compatible shell
- LAN gateway deployments

The installer refuses likely fw4/nftables OpenWrt targets rather than applying firewall rules intended for a different stack.

The OpenWrt deployment installs the fail-closed design validated during development, including:

- VLESS + REALITY sing-box client
- TUN interface
- explicit policy-routing table
- unreachable IPv4 fallback
- IPv6 LAN forwarding block
- native LAN-to-WAN forwarding restriction while REALITY is active
- forced client DNS path through the tunnel
- firewall guards allowing LAN traffic only to the tunnel while protected mode is active
- early boot protection
- late boot restoration
- TUN hotplug route recovery after sing-box restarts
- explicit normal-mode recovery
- persistent operational shell shortcuts

### Linux computer mode

Linux client support is designed for:

- systemd
- nftables
- host-only protection
- sing-box TUN with automatic routing/redirect support

Protected mode keeps the kill switch active independently of a transient sing-box failure. Turning REALITY off is an explicit request to restore ordinary Internet access.

## Safety model

Reality Manager is intentionally conservative.

- First-time setup asks for machine-specific values instead of copying a hard-coded configuration.
- Router activation is intended to be **fail-closed** once the transition into protected mode begins.
- Ordinary WAN forwarding is restored only through explicit normal-mode recovery.
- Recreated TUN interfaces can restore the missing tunnel route through event-driven OpenWrt hotplug handling.
- Boot-time restoration and TUN-restart restoration are separate mechanisms so they do not race blindly.
- Hardware/software acceleration settings that can bypass iptables are disabled where the supported OpenWrt platform exposes them.
- The application validates configuration syntax before starting sing-box.

A successful installation is **not** a mathematical guarantee of zero leaks on every firmware, network, startup sequence, or censorship environment. New hardware should be tested before relying on it.

## Development validation

The original workflow was validated on a GL.iNet Beryl 7 / OpenWrt fw3 environment through a long series of manual tests before being automated. Tests included:

- normal-mode activation into REALITY
- public exit-IP verification
- sing-box stop/restart
- automatic restoration of a TUN route removed when the interface disappears
- complete router reboot while REALITY mode is persistent
- early boot protection followed by late protected-mode restoration
- loss and recovery of upstream Wi-Fi using a phone hotspot
- preservation of IPv4 policy rules during upstream changes
- IPv6 LAN blocking
- manual return to normal Internet
- simulated controller failures before and during activation
- configuration backup and checksum verification

The tested router design uses an independent unreachable IPv4 fallback in addition to the route through `sb-tun`, plus a second unreachable policy rule behind the main table lookup.

## Screenshots from the original validation process

### GL.iNet tunnel options

The original router testing used GL.iNet's VPN UI as an independent comparison/fallback path. These screenshots are included as historical test evidence only; Reality Manager itself is VLESS + REALITY focused.

![GL.iNet tunnel options](docs/screenshots/01-glinet-tunnel-options.png)

### GL.iNet VPN dashboard — disconnected

![GL.iNet VPN dashboard disconnected](docs/screenshots/02-glinet-vpn-dashboard-disconnected.png)

### GL.iNet OpenVPN connected

![GL.iNet OpenVPN connected](docs/screenshots/03-glinet-openvpn-connected.png)

### OpenVPN reconnecting during outage testing

![GL.iNet OpenVPN reconnecting](docs/screenshots/04-glinet-openvpn-reconnecting.png)

### OpenVPN reconnected

![GL.iNet OpenVPN reconnected](docs/screenshots/05-glinet-openvpn-reconnected.png)

## Performance example from the original test environment

These are illustrative measurements from the same Tokyo VPS exit, not a controlled scientific benchmark. Different Speedtest endpoints were used, so they should be treated as directional rather than definitive.

### VLESS + REALITY

![REALITY Speedtest](docs/screenshots/06-reality-speedtest.png)

Observed in this run:

- Download: **258.48 Mbps**
- Upload: **281.24 Mbps**
- Ping shown by Speedtest: **255 ms**
- Exit IP: Tokyo VPS

### OpenVPN comparison

![OpenVPN Speedtest](docs/screenshots/07-openvpn-speedtest.png)

Observed in this run:

- Download: **46.14 Mbps**
- Upload: Speedtest reported **0.00 Mbps** in that run
- Ping shown by Speedtest: **401 ms**
- Exit IP: same Tokyo VPS

In this particular environment, REALITY delivered substantially higher throughput and lower displayed latency than the OpenVPN fallback. Reality Manager therefore focuses on VLESS + REALITY rather than reproducing the fallback OpenVPN workflow.

## SSH and credential handling

Supported authentication methods include:

- password
- SSH agent
- private key

Passwords are not written into `settings.json`.

If **Remember passwords** is enabled, Reality Manager uses Python `keyring` so credentials are stored using the operating system's credential store:

- macOS Keychain
- Windows Credential Manager

The application can work with OpenWrt systems that do not provide SFTP by uploading file contents over the SSH execution channel.

## VPS deployment

The VPS installer is intended for a Linux server with systemd.

It can:

- install a pinned sing-box release
- generate a UUID
- generate REALITY keys
- generate a short ID
- write the VLESS + REALITY server configuration
- validate with `sing-box check`
- create/enable a systemd service
- open a local firewall rule when UFW/firewalld is detected
- return the generated client credential bundle to the desktop application

The installer cannot modify an external cloud provider security group/firewall. The selected REALITY TCP port must also be permitted by the VPS provider.

## Run from source

Python 3.12 is recommended.

```bash
python -m venv .venv
```

macOS/Linux:

```bash
. .venv/bin/activate
pip install -r requirements.txt
python run.py
```

Windows PowerShell:

```powershell
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python run.py
```

## Build for Windows

Run on Windows PowerShell:

```powershell
.\build_windows.ps1
```

Expected output:

```text
dist\Reality Manager.exe
```

## Build for macOS

Run on macOS:

```bash
./build_macos.sh
```

Expected output:

```text
dist/Reality Manager.app
```

For distribution to other Macs without Gatekeeper warnings, sign and notarize the application with an Apple Developer ID. No signing certificate is embedded in this repository.

## GitHub Actions builds

`.github/workflows/build.yml` builds on native GitHub-hosted runners:

- Windows -> `Reality Manager.exe`
- macOS -> `Reality Manager.app`, zipped for artifact upload

The workflow runs manually through `workflow_dispatch` and on tags matching `v*`.

## Project structure

```text
.
├── .github/
│   └── workflows/
│       └── build.yml
├── docs/
│   └── screenshots/
├── reality_manager/
│   ├── resources/
│   │   ├── icon.icns
│   │   ├── icon.ico
│   │   ├── icon.png
│   │   └── reality-deploy.sh
│   ├── __init__.py
│   ├── app.py
│   ├── deploy.py
│   ├── main.py
│   ├── ssh_client.py
│   └── state.py
├── RealityManager.spec
├── build_macos.sh
├── build_windows.ps1
├── pyproject.toml
├── requirements.txt
├── run.py
└── README.md
```

## Embedded deployment engine

The lower-level deployment engine lives at:

```text
reality_manager/resources/reality-deploy.sh
```

It is POSIX `/bin/sh` compatible so the same deployment logic can be used manually when the GUI is unavailable.

## Known boundaries

- Current OpenWrt automation is for fw3/iptables, not generic fw4/nftables routers.
- Guest and IoT subnets require their own explicit protection/validation; they are not assumed to inherit the main LAN policy.
- Router-originated traffic and LAN-client traffic are not always equivalent routing domains.
- REALITY provides traffic camouflage, but it is not invisible and does not guarantee operation on every network.
- Blocking of the VPS IP itself cannot be solved simply by changing protocol on the same server.
- For stronger operational redundancy, use a second VPS on a different provider/network.

## Recommended deployment test after setup

Before relying on a new installation:

1. Activate REALITY and verify the expected VPS public IP from a LAN client.
2. Stop sing-box and confirm Internet access fails closed.
3. Restart sing-box and confirm the TUN route returns automatically.
4. Reboot the router while REALITY mode is active and verify protected-mode restoration.
5. Disconnect/reconnect upstream Wi-Fi and verify no ordinary-WAN fallback is observed.
6. Return explicitly to normal mode and verify ordinary Internet is restored.

## Security notice

A REALITY deployment contains sensitive material such as UUIDs and REALITY private keys. Do not commit generated production credentials, router backups, saved Wi-Fi passwords, or private VPS configuration bundles to this repository.

## Status

This repository currently represents an early cross-platform GUI implementation built from a manually validated deployment. It should be treated as a **testable v0.x project**, not as a universal one-click networking appliance.
