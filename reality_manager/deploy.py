from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import ipaddress
import re
import secrets
import uuid
from typing import Callable

from .ssh_client import SSHSession, shell_quote


@dataclass
class ServerSettings:
    address: str
    port: int = 8443
    sni: str = "www.microsoft.com"
    handshake_port: int = 443
    singbox_version: str = "1.14.1"


@dataclass
class TargetSettings:
    kind: str = "openwrt"  # openwrt | linux
    lan_if: str = "br-lan"
    lan_subnet: str = "192.168.8.0/24"
    forwarding: str = "firewall.@forwarding[0]"
    tun_if: str = "sb-tun"
    tun_addr: str = "172.19.0.1/30"
    tun_mtu: int = 1400
    dns_port: int = 15353
    table_id: int = 200
    remote_dns: str = "1.1.1.1"
    allow_lan: bool = True


@dataclass
class Credentials:
    server: str
    port: int
    uuid: str
    public_key: str
    short_id: str
    sni: str
    singbox_version: str


class DeploymentError(RuntimeError):
    pass


class Deployer:
    def __init__(self, router: SSHSession, vps: SSHSession, deploy_script: Path,
                 log: Callable[[str], None] = lambda _: None):
        self.router = router
        self.vps = vps
        self.deploy_script = deploy_script
        self.log = log

    def probe_target(self) -> dict[str, str]:
        out = self.router.run("uname -s; [ -f /etc/openwrt_release ] && echo OPENWRT || true; command -v iptables || true; command -v nft || true", check=False)[1]
        mode = "openwrt" if "OPENWRT" in out else "linux"
        info = {"kind": mode}
        if mode == "openwrt":
            _, lan, _ = self.router.run("ip -4 -o addr show dev br-lan 2>/dev/null | awk '{print $4; exit}'", check=False)
            if lan.strip():
                info["lan_subnet"] = network_from_interface(lan.strip())
        return info

    def detect_existing(self, target_kind: str) -> bool:
        if target_kind == "openwrt":
            cmd = "[ -x /etc/reality/control.sh ] && [ -f /etc/reality/mode ]"
        else:
            cmd = "[ -x /usr/local/sbin/reality ] && [ -f /etc/sing-box/reality-client.json ]"
        return self.router.run(cmd, check=False)[0] == 0

    def deploy(self, server: ServerSettings, target: TargetSettings) -> Credentials:
        self._validate(server, target)
        self.log("Uploading deployment engine to VPS…")
        script_data = self.deploy_script.read_bytes()
        self.vps.upload_bytes(script_data, "/tmp/reality-deploy-gui.sh", "700")

        generated_uuid = str(uuid.uuid4())
        short_id = secrets.token_hex(4)
        server_env = env_text({
            "ROLE": "server",
            "SB_VERSION": server.singbox_version,
            "SERVER_ADDR": server.address,
            "LISTEN_PORT": str(server.port),
            "SNI": server.sni,
            "HANDSHAKE_PORT": str(server.handshake_port),
            "UUID": generated_uuid,
            "SHORT_ID": short_id,
        })
        self.vps.upload_bytes(server_env.encode(), "/tmp/reality-server.env", "600")
        self.log("Configuring VLESS + REALITY server…")
        self.vps.run_root(
            "sh /tmp/reality-deploy-gui.sh --config /tmp/reality-server.env",
            timeout=1200,
            on_line=self.log,
        )
        bundle = self.vps.run_root("cat /root/reality-deploy/client.env", timeout=30)[1]
        credentials = parse_client_env(bundle)
        self.log("Server is active; deploying client target…")

        self.router.upload_bytes(script_data, "/tmp/reality-deploy-gui.sh", "700")
        values = {
            "ROLE": "router" if target.kind == "openwrt" else "linux",
            "SB_VERSION": credentials.singbox_version,
            "SERVER_ADDR": credentials.server,
            "SERVER_PORT": str(credentials.port),
            "UUID": credentials.uuid,
            "PUBLIC_KEY": credentials.public_key,
            "SHORT_ID": credentials.short_id,
            "SNI": credentials.sni,
            "REMOTE_DNS": target.remote_dns,
            "TUN_IF": target.tun_if,
            "TUN_ADDR": target.tun_addr,
            "TUN_MTU": str(target.tun_mtu),
        }
        if target.kind == "openwrt":
            values.update({
                "LAN_IF": target.lan_if,
                "LAN_SUBNET": target.lan_subnet,
                "FORWARDING": target.forwarding,
                "DNS_PORT": str(target.dns_port),
                "TABLE_ID": str(target.table_id),
            })
        else:
            values["ALLOW_LAN"] = "yes" if target.allow_lan else "no"
        self.router.upload_bytes(env_text(values).encode(), "/tmp/reality-target.env", "600")
        self.router.run_root(
            "sh /tmp/reality-deploy-gui.sh --config /tmp/reality-target.env",
            timeout=1200,
            on_line=self.log,
        )
        self.log("Deployment complete. Target remains in normal/unprotected mode until you turn REALITY on.")
        return credentials

    @staticmethod
    def _validate(server: ServerSettings, target: TargetSettings) -> None:
        if not server.address.strip():
            raise DeploymentError("VPS public address is required")
        if not (1 <= server.port <= 65535):
            raise DeploymentError("Server port must be between 1 and 65535")
        if target.kind == "openwrt":
            try:
                ipaddress.ip_network(target.lan_subnet, strict=False)
            except ValueError as exc:
                raise DeploymentError(f"Invalid LAN subnet: {target.lan_subnet}") from exc


def env_text(values: dict[str, str]) -> str:
    lines = ["# Generated by Reality Manager. Keep private."]
    for key, value in values.items():
        lines.append(f"{key}={shell_quote(str(value))}")
    return "\n".join(lines) + "\n"


def parse_client_env(text: str) -> Credentials:
    vals: dict[str, str] = {}
    for line in text.splitlines():
        m = re.match(r"^([A-Z0-9_]+)='(.*)'$", line.strip())
        if m:
            vals[m.group(1)] = m.group(2).replace("'\"'\"'", "'")
    required = ["REALITY_SERVER", "REALITY_PORT", "REALITY_UUID", "REALITY_PUBLIC_KEY", "REALITY_SHORT_ID", "REALITY_SNI"]
    missing = [x for x in required if not vals.get(x)]
    if missing:
        raise DeploymentError("Could not parse generated VPS client bundle: " + ", ".join(missing))
    return Credentials(
        server=vals["REALITY_SERVER"],
        port=int(vals["REALITY_PORT"]),
        uuid=vals["REALITY_UUID"],
        public_key=vals["REALITY_PUBLIC_KEY"],
        short_id=vals["REALITY_SHORT_ID"],
        sni=vals["REALITY_SNI"],
        singbox_version=vals.get("REALITY_SINGBOX_VERSION", "1.14.1"),
    )


def network_from_interface(cidr: str) -> str:
    try:
        return str(ipaddress.ip_interface(cidr).network)
    except ValueError:
        return cidr
