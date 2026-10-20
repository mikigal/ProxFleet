#!/usr/bin/env python3
"""Prepares a disposable Proxmox VE server for development and tests.

Creates (idempotently):
  - tfa@pve       Administrator with a TOTP second factor
  - limited@pve   read-only user (PVEAuditor)
  - a few VMs, a VM template and LXC containers, some running

Generated passwords and the TOTP secret are appended to the env file, which must be git-ignored.
Only use this against a server whose contents you do not care about.

Usage: python3 -I scripts/seed-test-server.py Config/TestServer.local.env
"""
import base64
import hashlib
import hmac
import json
import secrets
import ssl
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ENV_PATH = Path(sys.argv[1])


def read_env():
    return dict(
        line.split("=", 1)
        for line in ENV_PATH.read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )


def append_env(key, value):
    with ENV_PATH.open("a") as file:
        file.write(f"{key}={value}\n")


env = read_env()
BASE = f"https://{env['ADDRESS']}/api2/json"
CONTEXT = ssl.create_default_context()
CONTEXT.check_hostname = False
CONTEXT.verify_mode = ssl.CERT_NONE  # disposable test server with a self-signed certificate


class API:
    def __init__(self):
        data = self.request("POST", "/access/ticket", {
            "username": env["USER"], "realm": env["REALM"], "password": env["PASSWORD"],
        }, auth=False)
        self.ticket = data["ticket"]
        self.csrf = data["CSRFPreventionToken"]

    def request(self, method, path, params=None, auth=True):
        url = BASE + path
        body = None
        if params and method in ("POST", "PUT"):
            body = urllib.parse.urlencode(params).encode()
        elif params:
            url += "?" + urllib.parse.urlencode(params)
        request = urllib.request.Request(url, data=body, method=method)
        if auth:
            request.add_header("Cookie", f"PVEAuthCookie={self.ticket}")
            request.add_header("CSRFPreventionToken", self.csrf)
        try:
            with urllib.request.urlopen(request, context=CONTEXT, timeout=60) as response:
                return json.loads(response.read() or b"{}").get("data")
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: {error.code} {error.reason} {error.read().decode()}") from None

    def wait(self, node, upid):
        while True:
            status = self.request("GET", f"/nodes/{node}/tasks/{urllib.parse.quote(upid)}/status")
            if status["status"] == "stopped":
                if status.get("exitstatus") != "OK":
                    raise RuntimeError(f"task {upid} failed: {status.get('exitstatus')}")
                return
            time.sleep(1)


def totp(secret_b32, at=None):
    counter = int((at or time.time()) // 30)
    digest = hmac.new(base64.b32decode(secret_b32), struct.pack(">Q", counter), hashlib.sha1).digest()
    offset = digest[-1] & 0x0F
    code = (struct.unpack(">I", digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 1_000_000
    return f"{code:06d}"


api = API()
node = api.request("GET", "/nodes")[0]["node"]
existing_users = {user["userid"] for user in api.request("GET", "/access/users")}

# Users
if "tfa@pve" not in existing_users:
    password = secrets.token_urlsafe(12)
    secret = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    api.request("POST", "/access/users", {"userid": "tfa@pve", "password": password, "comment": "Test user with TOTP"})
    api.request("PUT", "/access/acl", {"path": "/", "roles": "Administrator", "users": "tfa@pve"})
    uri = f"otpauth://totp/ProxFleet:tfa@pve?secret={secret}&issuer=ProxFleet&algorithm=SHA1&digits=6&period=30"
    api.request("POST", "/access/tfa/tfa@pve", {
        "type": "totp", "description": "ProxFleet tests", "totp": uri, "value": totp(secret), "password": env["PASSWORD"],
    })
    append_env("TFA_USER", "tfa")
    append_env("TFA_REALM", "pve")
    append_env("TFA_PASSWORD", password)
    append_env("TFA_TOTP_SECRET", secret)
    print("created tfa@pve")

if "limited@pve" not in existing_users:
    password = secrets.token_urlsafe(12)
    api.request("POST", "/access/users", {"userid": "limited@pve", "password": password, "comment": "Read-only test user"})
    api.request("PUT", "/access/acl", {"path": "/", "roles": "PVEAuditor", "users": "limited@pve"})
    append_env("LIMITED_USER", "limited")
    append_env("LIMITED_REALM", "pve")
    append_env("LIMITED_PASSWORD", password)
    print("created limited@pve")

# Guests
existing = {int(r["vmid"]) for r in api.request("GET", "/cluster/resources", {"type": "vm"})}


def create_vm(vmid, name, memory, start=False, template=False, **extra):
    if vmid in existing:
        return
    params = {
        "vmid": vmid, "name": name, "memory": memory, "cores": 2, "ostype": "l26",
        "scsihw": "virtio-scsi-single", "scsi0": "local-lvm:4", "net0": "virtio,bridge=vmbr0",
        "agent": 1, **extra,
    }
    api.wait(node, api.request("POST", f"/nodes/{node}/qemu", params))
    if template:
        api.request("POST", f"/nodes/{node}/qemu/{vmid}/template")
    elif start:
        api.wait(node, api.request("POST", f"/nodes/{node}/qemu/{vmid}/status/start"))
    print(f"created VM {vmid} {name}")


create_vm(100, "web-server", 1024, start=True, tags="prod;web", description="Test VM without an OS")
create_vm(101, "windows-test", 2048, ostype="win11", tags="test", bios="ovmf", machine="q35",
          efidisk0="local-lvm:1,efitype=4m,pre-enrolled-keys=1")
create_vm(102, "db-server", 1024, start=True, tags="prod;db", onboot=1)
create_vm(9000, "debian-13-template", 512, template=True)

containers = [(200, "alpine-dns", True, "network"), (201, "nginx-proxy", True, "network;prod"), (202, "backup-agent", False, "")]
if any(vmid not in existing for vmid, *_ in containers):
    templates = api.request("GET", f"/nodes/{node}/storage/local/content", {"content": "vztmpl"})
    if not any("alpine" in t["volid"] and "_amd64" in t["volid"] for t in templates):
        available = api.request("GET", f"/nodes/{node}/aplinfo")
        alpine = sorted((t for t in available if t["template"].startswith("alpine-") and "_amd64" in t["template"]), key=lambda t: t["template"])[-1]
        api.wait(node, api.request("POST", f"/nodes/{node}/aplinfo", {"storage": "local", "template": alpine["template"]}))
        templates = api.request("GET", f"/nodes/{node}/storage/local/content", {"content": "vztmpl"})
    ostemplate = next(t["volid"] for t in templates if "alpine" in t["volid"] and "_amd64" in t["volid"])
    for vmid, name, start, tags in containers:
        if vmid in existing:
            continue
        params = {
            "vmid": vmid, "hostname": name, "ostemplate": ostemplate, "memory": 256, "cores": 1,
            "rootfs": "local-lvm:1", "net0": "name=eth0,bridge=vmbr0,ip=dhcp", "unprivileged": 1,
            "password": secrets.token_urlsafe(12), "start": int(start),
        }
        if tags:
            params["tags"] = tags
        api.wait(node, api.request("POST", f"/nodes/{node}/lxc", params))
        print(f"created CT {vmid} {name}")

print("done")
