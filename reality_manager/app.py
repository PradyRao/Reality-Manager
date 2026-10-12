from __future__ import annotations

import json
from pathlib import Path
import socket
import sys
import urllib.request
from typing import Callable, Optional

import keyring
from PySide6.QtCore import QObject, QRunnable, QThreadPool, Qt, Signal, Slot
from PySide6.QtGui import QFont, QIcon
from PySide6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QFileDialog, QFormLayout, QFrame,
    QGridLayout, QHBoxLayout, QLabel, QLineEdit, QMainWindow, QMessageBox,
    QPlainTextEdit, QProgressBar, QPushButton, QScrollArea, QSpinBox,
    QStackedWidget, QVBoxLayout, QWidget
)

from .deploy import Deployer, ServerSettings, TargetSettings
from .ssh_client import SSHConfig, SSHSession, SSHError
from .state import load_settings, save_settings, public_ssh_dict

APP_SERVICE = "RealityManager"


STYLE = r"""
QWidget { background: #0b1020; color: #e7ecf5; font-size: 14px; }
QMainWindow { background: #0b1020; }
QFrame#card { background: #121a2b; border: 1px solid #24324b; border-radius: 16px; }
QLabel#title { font-size: 30px; font-weight: 700; }
QLabel#subtitle { color: #94a3b8; font-size: 14px; }
QLabel#section { font-size: 17px; font-weight: 650; }
QLabel#statusOn { color: #4ade80; font-size: 18px; font-weight: 700; }
QLabel#statusOff { color: #f59e0b; font-size: 18px; font-weight: 700; }
QLineEdit, QComboBox, QSpinBox, QPlainTextEdit {
    background: #0f172a; border: 1px solid #334155; border-radius: 9px;
    padding: 8px; selection-background-color: #2563eb;
}
QLineEdit:focus, QComboBox:focus, QSpinBox:focus, QPlainTextEdit:focus { border: 1px solid #60a5fa; }
QPushButton { background: #1d4ed8; border: 0; border-radius: 10px; padding: 10px 16px; font-weight: 650; }
QPushButton:hover { background: #2563eb; }
QPushButton:disabled { background: #334155; color: #94a3b8; }
QPushButton#secondary { background: #1e293b; border: 1px solid #334155; }
QPushButton#danger { background: #991b1b; }
QPushButton#bigToggle { font-size: 22px; padding: 22px; border-radius: 18px; }
QCheckBox { spacing: 8px; }
QProgressBar { border: 1px solid #334155; border-radius: 8px; background: #0f172a; text-align: center; }
QProgressBar::chunk { background: #2563eb; border-radius: 7px; }
"""


class WorkerSignals(QObject):
    finished = Signal(object)
    failed = Signal(str)
    log = Signal(str)


class Worker(QRunnable):
    def __init__(self, fn: Callable, *args, **kwargs):
        super().__init__()
        self.fn = fn
        self.args = args
        self.kwargs = kwargs
        self.signals = WorkerSignals()

    @Slot()
    def run(self):
        try:
            result = self.fn(self.signals.log.emit, *self.args, **self.kwargs)
            self.signals.finished.emit(result)
        except Exception as exc:
            self.signals.failed.emit(str(exc))


class Card(QFrame):
    def __init__(self, layout: QVBoxLayout | QFormLayout | QGridLayout | None = None):
        super().__init__()
        self.setObjectName("card")
        if layout is None:
            layout = QVBoxLayout()
        layout.setContentsMargins(22, 22, 22, 22)
        layout.setSpacing(12)
        self.setLayout(layout)


class ConnectPage(QWidget):
    connect_requested = Signal(dict, dict)

    def __init__(self, settings: dict):
        super().__init__()
        root = QVBoxLayout(self)
        root.setContentsMargins(42, 34, 42, 34)
        root.setSpacing(18)
        title = QLabel("Reality Manager")
        title.setObjectName("title")
        subtitle = QLabel("Connect securely to your router/computer and VPS. Passwords can be kept in the OS keychain, never in the project files.")
        subtitle.setWordWrap(True); subtitle.setObjectName("subtitle")
        root.addWidget(title); root.addWidget(subtitle)

        grid = QGridLayout(); grid.setSpacing(18)
        self.target = self._connection_card("Router / computer", settings.get("target", {}), "target")
        self.vps = self._connection_card("VPS", settings.get("vps", {}), "vps")
        grid.addWidget(self.target[0], 0, 0)
        grid.addWidget(self.vps[0], 0, 1)
        root.addLayout(grid)

        self.remember = QCheckBox("Remember passwords in macOS Keychain / Windows Credential Manager")
        self.remember.setChecked(settings.get("remember_passwords", False))
        root.addWidget(self.remember)
        self.connect_btn = QPushButton("Connect to both")
        self.connect_btn.clicked.connect(self._emit)
        root.addWidget(self.connect_btn)
        root.addStretch(1)

    def _connection_card(self, title: str, s: dict, key: str):
        form = QFormLayout()
        label = QLabel(title); label.setObjectName("section")
        form.addRow(label)
        host = QLineEdit(s.get("host", "192.168.8.1" if key == "target" else ""))
        port = QSpinBox(); port.setRange(1, 65535); port.setValue(int(s.get("port", 22)))
        user = QLineEdit(s.get("username", "root"))
        password = QLineEdit(); password.setEchoMode(QLineEdit.Password)
        saved_pw = keyring.get_password(APP_SERVICE, f"{key}:{host.text()}:{user.text()}") if s.get("host") else None
        if saved_pw: password.setText(saved_pw)
        key_path = QLineEdit(s.get("key_path", ""))
        choose = QPushButton("Choose key…"); choose.setObjectName("secondary")
        choose.clicked.connect(lambda: self._pick_key(key_path))
        keyrow = QHBoxLayout(); keyrow.addWidget(key_path); keyrow.addWidget(choose)
        form.addRow("Host", host); form.addRow("Port", port); form.addRow("Username", user); form.addRow("Password", password); form.addRow("SSH key", keyrow)
        return Card(form), host, port, user, password, key_path, key

    def _pick_key(self, edit: QLineEdit):
        path, _ = QFileDialog.getOpenFileName(self, "Choose SSH private key", str(Path.home()))
        if path: edit.setText(path)

    def _payload(self, data):
        _, host, port, user, pw, key, name = data
        return dict(host=host.text().strip(), port=port.value(), username=user.text().strip(), password=pw.text(), key_path=key.text().strip(), name=name)

    def _emit(self):
        a, b = self._payload(self.target), self._payload(self.vps)
        if not a["host"] or not b["host"]:
            QMessageBox.warning(self, "Missing host", "Enter both the target and VPS SSH hosts.")
            return
        self.connect_requested.emit(a, b)


class SetupPage(QWidget):
    deploy_requested = Signal(dict, dict)

    def __init__(self):
        super().__init__()
        root = QVBoxLayout(self); root.setContentsMargins(42, 30, 42, 30); root.setSpacing(16)
        t = QLabel("First-time setup"); t.setObjectName("title")
        s = QLabel("The app detected that REALITY is not installed on the target. Review the environment-specific values, then deploy the VPS and client automatically.")
        s.setWordWrap(True); s.setObjectName("subtitle")
        root.addWidget(t); root.addWidget(s)
        scroll = QScrollArea(); scroll.setWidgetResizable(True); scroll.setFrameShape(QFrame.NoFrame)
        body = QWidget(); body_l = QVBoxLayout(body); body_l.setSpacing(16)
        server_form = QFormLayout()
        self.server_address = QLineEdit(); self.server_port = QSpinBox(); self.server_port.setRange(1,65535); self.server_port.setValue(8443)
        self.sni = QLineEdit("www.microsoft.com"); self.sb_version = QLineEdit("1.14.1")
        server_form.addRow("VPS public IPv4 / domain", self.server_address)
        server_form.addRow("REALITY TCP port", self.server_port)
        server_form.addRow("Camouflage / SNI hostname", self.sni)
        server_form.addRow("sing-box version", self.sb_version)
        sc = Card(server_form); sc.layout().insertRow(0, QLabel("VPS configuration")) if isinstance(sc.layout(), QFormLayout) else None
        body_l.addWidget(sc)

        target_form = QFormLayout()
        self.kind = QComboBox(); self.kind.addItem("OpenWrt router (fw3 / iptables)", "openwrt"); self.kind.addItem("Linux computer (systemd + nftables)", "linux")
        self.lan_if = QLineEdit("br-lan"); self.lan_subnet = QLineEdit("192.168.8.0/24"); self.forwarding = QLineEdit("firewall.@forwarding[0]")
        self.tun_if = QLineEdit("sb-tun"); self.tun_addr = QLineEdit("172.19.0.1/30"); self.mtu = QSpinBox(); self.mtu.setRange(576,9000); self.mtu.setValue(1400)
        self.remote_dns = QLineEdit("1.1.1.1"); self.allow_lan = QCheckBox("Allow direct private-LAN access on Linux computer"); self.allow_lan.setChecked(True)
        target_form.addRow("Target type", self.kind); target_form.addRow("LAN interface", self.lan_if); target_form.addRow("Protected LAN subnet", self.lan_subnet); target_form.addRow("UCI LAN→WAN selector", self.forwarding)
        target_form.addRow("TUN interface", self.tun_if); target_form.addRow("TUN address", self.tun_addr); target_form.addRow("MTU", self.mtu); target_form.addRow("Remote DNS", self.remote_dns); target_form.addRow("", self.allow_lan)
        body_l.addWidget(Card(target_form))
        self.kind.currentIndexChanged.connect(self._update_kind)
        scroll.setWidget(body); root.addWidget(scroll, 1)
        self.deploy = QPushButton("Deploy VLESS + REALITY")
        self.deploy.clicked.connect(self._emit); root.addWidget(self.deploy)

    def set_probe(self, probe: dict, vps_host: str):
        self.server_address.setText(vps_host)
        if probe.get("kind") == "linux": self.kind.setCurrentIndex(1)
        if probe.get("lan_subnet"): self.lan_subnet.setText(probe["lan_subnet"])
        self._update_kind()

    def _update_kind(self):
        is_router = self.kind.currentData() == "openwrt"
        for w in (self.lan_if, self.lan_subnet, self.forwarding): w.setEnabled(is_router)
        self.allow_lan.setVisible(not is_router)

    def _emit(self):
        server = dict(address=self.server_address.text().strip(), port=self.server_port.value(), sni=self.sni.text().strip(), handshake_port=443, singbox_version=self.sb_version.text().strip())
        target = dict(kind=self.kind.currentData(), lan_if=self.lan_if.text().strip(), lan_subnet=self.lan_subnet.text().strip(), forwarding=self.forwarding.text().strip(), tun_if=self.tun_if.text().strip(), tun_addr=self.tun_addr.text().strip(), tun_mtu=self.mtu.value(), dns_port=15353, table_id=200, remote_dns=self.remote_dns.text().strip(), allow_lan=self.allow_lan.isChecked())
        self.deploy_requested.emit(server, target)


class ProgressPage(QWidget):
    def __init__(self):
        super().__init__(); root=QVBoxLayout(self); root.setContentsMargins(42,30,42,30); root.setSpacing(14)
        t=QLabel("Deploying REALITY"); t.setObjectName("title"); root.addWidget(t)
        self.progress=QProgressBar(); self.progress.setRange(0,0); root.addWidget(self.progress)
        self.log=QPlainTextEdit(); self.log.setReadOnly(True); root.addWidget(self.log,1)
    def append(self, text: str): self.log.appendPlainText(text)


class DashboardPage(QWidget):
    toggle_requested = Signal(bool)
    refresh_requested = Signal()
    reconnect_requested = Signal()

    def __init__(self):
        super().__init__(); root=QVBoxLayout(self); root.setContentsMargins(42,30,42,30); root.setSpacing(18)
        h=QHBoxLayout(); left=QVBoxLayout(); title=QLabel("REALITY"); title.setObjectName("title"); self.status=QLabel("Checking…"); left.addWidget(title); left.addWidget(self.status); h.addLayout(left); h.addStretch(1)
        self.refresh=QPushButton("Refresh"); self.refresh.setObjectName("secondary"); self.refresh.clicked.connect(self.refresh_requested.emit); h.addWidget(self.refresh)
        self.reconnect=QPushButton("Connections"); self.reconnect.setObjectName("secondary"); self.reconnect.clicked.connect(self.reconnect_requested.emit); h.addWidget(self.reconnect)
        root.addLayout(h)
        grid=QGridLayout(); grid.setSpacing(16)
        status_card=Card(); self.toggle=QPushButton("Turn REALITY on"); self.toggle.setObjectName("bigToggle"); self.toggle.clicked.connect(self._toggle); status_card.layout().addWidget(self.toggle)
        self.public_ip=QLabel("Public IP: —"); self.public_ip.setObjectName("subtitle"); status_card.layout().addWidget(self.public_ip); grid.addWidget(status_card,0,0)
        conn=Card(); l=QLabel("Connections"); l.setObjectName("section"); conn.layout().addWidget(l); self.target_conn=QLabel("Target: connected"); self.vps_conn=QLabel("VPS: connected"); conn.layout().addWidget(self.target_conn); conn.layout().addWidget(self.vps_conn); grid.addWidget(conn,0,1)
        root.addLayout(grid)
        diag=Card(); dl=QLabel("Diagnostics"); dl.setObjectName("section"); diag.layout().addWidget(dl); self.diag=QPlainTextEdit(); self.diag.setReadOnly(True); self.diag.setMaximumHeight(300); diag.layout().addWidget(self.diag); root.addWidget(diag,1)
        self._is_on=False

    def set_state(self, on: bool, diagnostic: str, public_ip: str = ""):
        self._is_on=on
        self.status.setText("Protected — REALITY ON" if on else "Normal Internet — REALITY OFF")
        self.status.setObjectName("statusOn" if on else "statusOff"); self.status.style().unpolish(self.status); self.status.style().polish(self.status)
        self.toggle.setText("Turn REALITY off" if on else "Turn REALITY on")
        self.toggle.setObjectName("danger" if on else "bigToggle"); self.toggle.style().unpolish(self.toggle); self.toggle.style().polish(self.toggle)
        self.diag.setPlainText(diagnostic.strip()); self.public_ip.setText(f"Public IP: {public_ip or 'unavailable'}")
    def _toggle(self): self.toggle_requested.emit(not self._is_on)


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__(); self.setWindowTitle("Reality Manager"); self.resize(1040,760); self.setMinimumSize(860,640)
        self.settings=load_settings(); self.pool=QThreadPool.globalInstance(); self.target_session: Optional[SSHSession]=None; self.vps_session: Optional[SSHSession]=None; self.target_kind="openwrt"
        self.stack=QStackedWidget(); self.setCentralWidget(self.stack)
        self.connect_page=ConnectPage(self.settings); self.setup_page=SetupPage(); self.progress_page=ProgressPage(); self.dashboard=DashboardPage()
        for p in (self.connect_page,self.setup_page,self.progress_page,self.dashboard): self.stack.addWidget(p)
        self.connect_page.connect_requested.connect(self.connect_both); self.setup_page.deploy_requested.connect(self.deploy); self.dashboard.toggle_requested.connect(self.toggle); self.dashboard.refresh_requested.connect(self.refresh); self.dashboard.reconnect_requested.connect(lambda:self.stack.setCurrentWidget(self.connect_page))
        self.stack.setCurrentWidget(self.connect_page)

    def _run(self, fn: Callable, done: Callable, *args):
        worker=Worker(fn,*args); worker.signals.log.connect(self.progress_page.append); worker.signals.finished.connect(done); worker.signals.failed.connect(self._error); self.pool.start(worker)

    def connect_both(self, target_d: dict, vps_d: dict):
        self.connect_page.connect_btn.setEnabled(False)
        def work(log, a, b):
            log("Connecting to target…"); target=SSHSession(SSHConfig(**{k:v for k,v in a.items() if k!='name'})); target.connect(); log("Target connected.")
            log("Connecting to VPS…"); vps=SSHSession(SSHConfig(**{k:v for k,v in b.items() if k!='name'})); vps.connect(); log("VPS connected.")
            deployer=Deployer(target,vps,resource_path("reality-deploy.sh"),log); probe=deployer.probe_target(); existing=deployer.detect_existing(probe["kind"])
            return target,vps,probe,existing,a,b
        def done(result):
            self.connect_page.connect_btn.setEnabled(True); self.target_session,self.vps_session,probe,existing,a,b=result; self.target_kind=probe["kind"]
            self.settings["target"]={k:v for k,v in a.items() if k not in ("password","name")}; self.settings["vps"]={k:v for k,v in b.items() if k not in ("password","name")}; self.settings["remember_passwords"]=self.connect_page.remember.isChecked(); self.settings["target_kind"]=self.target_kind; save_settings(self.settings)
            if self.connect_page.remember.isChecked():
                if a.get("password"): keyring.set_password(APP_SERVICE,f"target:{a['host']}:{a['username']}",a["password"])
                if b.get("password"): keyring.set_password(APP_SERVICE,f"vps:{b['host']}:{b['username']}",b["password"])
            if existing:
                self.stack.setCurrentWidget(self.dashboard); self.refresh()
            else:
                self.setup_page.set_probe(probe,b["host"]); self.stack.setCurrentWidget(self.setup_page)
        self.stack.setCurrentWidget(self.progress_page); self.progress_page.log.clear(); self._run(work,done,target_d,vps_d)

    def deploy(self, server_d: dict, target_d: dict):
        if not self.target_session or not self.vps_session: return self._error("SSH sessions are not connected")
        self.stack.setCurrentWidget(self.progress_page); self.progress_page.log.clear()
        def work(log):
            dep=Deployer(self.target_session,self.vps_session,resource_path("reality-deploy.sh"),log); cred=dep.deploy(ServerSettings(**server_d),TargetSettings(**target_d)); return cred,target_d["kind"]
        def done(result):
            _,kind=result; self.target_kind=kind; self.settings["target_kind"]=kind; save_settings(self.settings); QMessageBox.information(self,"Setup complete","VLESS + REALITY was installed successfully. The target was deliberately left in normal mode."); self.stack.setCurrentWidget(self.dashboard); self.refresh()
        self._run(work,done)

    def _remote_status(self) -> tuple[bool,str]:
        assert self.target_session
        if self.target_kind=="openwrt":
            cmd="cat /etc/reality/mode 2>/dev/null; echo '---'; /etc/reality/control.sh status 2>&1"
            _,out,_=self.target_session.run_root(cmd,timeout=45,check=False); first=out.splitlines()[0].strip() if out.splitlines() else ""; return first=="reality",out
        cmd="if nft list table inet reality_killswitch >/dev/null 2>&1 && systemctl is-active --quiet sing-box-reality-client.service; then echo reality; else echo normal; fi; echo '---'; reality status 2>&1"
        _,out,_=self.target_session.run_root(cmd,timeout=45,check=False); first=out.splitlines()[0].strip() if out.splitlines() else ""; return first=="reality",out

    def refresh(self):
        if not self.target_session: return
        def work(log):
            on,diag=self._remote_status(); return on,diag,public_ip()
        self._run(work,lambda r:self.dashboard.set_state(*r))

    def toggle(self, turn_on: bool):
        if not self.target_session: return self._error("Target SSH connection is unavailable")
        self.dashboard.toggle.setEnabled(False)
        def work(log):
            if self.target_kind=="openwrt": cmd="/etc/reality/control.sh reality" if turn_on else "/etc/reality/control.sh normal"
            else: cmd="reality on" if turn_on else "reality off"
            self.target_session.run_root(cmd,timeout=180,on_line=log); on,diag=self._remote_status(); return on,diag,public_ip()
        def done(r): self.dashboard.toggle.setEnabled(True); self.dashboard.set_state(*r)
        worker=Worker(work); worker.signals.log.connect(lambda s:self.dashboard.diag.appendPlainText(s)); worker.signals.finished.connect(done); worker.signals.failed.connect(lambda e:(self.dashboard.toggle.setEnabled(True),self._error(e))); self.pool.start(worker)

    def _error(self, message: str):
        self.connect_page.connect_btn.setEnabled(True); QMessageBox.critical(self,"Reality Manager",message)


def public_ip() -> str:
    try:
        with urllib.request.urlopen("https://api.ipify.org",timeout=8) as r:
            return r.read().decode().strip()
    except Exception:
        return "unavailable"


def resource_path(name: str) -> Path:
    base=Path(getattr(sys,"_MEIPASS",Path(__file__).resolve().parent))
    p=base / "resources" / name
    if not p.exists():
        p=Path(__file__).resolve().parent / "resources" / name
    return p


def run_app():
    app=QApplication(sys.argv); app.setApplicationName("Reality Manager"); app.setStyle("Fusion"); app.setStyleSheet(STYLE)
    icon = resource_path("icon.png")
    if icon.exists(): app.setWindowIcon(QIcon(str(icon)))
    w=MainWindow(); w.show(); sys.exit(app.exec())
