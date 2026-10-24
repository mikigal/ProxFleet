#!/usr/bin/env python3
"""Prepares a disposable Proxmox Backup Server for development and tests.

Creates (idempotently):
  - datastores store1 and store2 under /datastore (the root file system, so spare disks stay free for the disk tests)
  - namespaces pve and pve/nested in store1
  - tfa@pbs       Admin with a TOTP second factor
  - limited@pbs   DatastoreAudit on /datastore/store1 only
  - pvebackup@pbs DatastoreAdmin on /datastore/store1, used by the Proxmox VE storage below
  - API token root@pam!seed, the remote `self` (this server) and verify, prune and sync jobs (local, pull, push)

With the env file of a Proxmox VE test server as second argument it also adds the backup server there as storage
`pbs-test` (store1, namespace pve) and backs up CT 200 and VM 102 to it twice, so the datastore has real content.

Generated passwords and the TOTP secret are appended to the backup server's env file, which must be git-ignored.
Only use this against servers whose contents you do not care about.

Usage: python3 -I scripts/seed-backup-server.py Config/TestServerPBS.local.env [Config/TestServer.local.env]
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

PBS_ENV_PATH = Path(sys.argv[1])
PVE_ENV_PATH = Path(sys.argv[2]) if len(sys.argv) > 2 else None

CONTEXT = ssl.create_default_context()
CONTEXT.check_hostname = False
CONTEXT.verify_mode = ssl.CERT_NONE  # disposable test servers with self-signed certificates


def read_env(path):
    return dict(
        line.split("=", 1)
        for line in path.read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )


def append_env(key, value):
    with PBS_ENV_PATH.open("a") as file:
        file.write(f"{key}={value}\n")


class API:
    def __init__(self, env, cookie):
        self.base = f"https://{env['ADDRESS']}/api2/json"
        self.cookie = cookie
        data = self.request("POST", "/access/ticket", {
            "username": f"{env['USER']}@{env['REALM']}", "password": env["PASSWORD"],
        }, auth=False)
        self.ticket = data["ticket"]
        self.csrf = data["CSRFPreventionToken"]

    def request(self, method, path, params=None, auth=True):
        url = self.base + path
        body = None
        if params and method in ("POST", "PUT"):
            body = urllib.parse.urlencode(params, doseq=True).encode()
        elif params:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        request = urllib.request.Request(url, data=body, method=method)
        if auth:
            request.add_header("Cookie", f"{self.cookie}={urllib.parse.quote(self.ticket)}")
            request.add_header("CSRFPreventionToken", self.csrf)
        try:
            with urllib.request.urlopen(request, context=CONTEXT, timeout=120) as response:
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


env = read_env(PBS_ENV_PATH)
pbs = API(env, "PBSAuthCookie")

# Datastores
stores = {store["name"] for store in pbs.request("GET", "/config/datastore")}
for name, comment in [("store1", "Main test datastore"), ("store2", "Sync target")]:
    if name not in stores:
        upid = pbs.request("POST", "/config/datastore", {"name": name, "path": f"/datastore/{name}", "comment": comment})
        pbs.wait("localhost", upid)
        print(f"created datastore {name}")

namespaces = {entry["ns"] for entry in pbs.request("GET", "/admin/datastore/store1/namespace")}
for parent, name in [("", "pve"), ("pve", "nested")]:
    path = f"{parent}/{name}" if parent else name
    if path not in namespaces:
        params = {"name": name}
        if parent:
            params["parent"] = parent
        pbs.request("POST", "/admin/datastore/store1/namespace", params)
        print(f"created namespace store1:{path}")

# Users
existing_users = {user["userid"] for user in pbs.request("GET", "/access/users")}

if "tfa@pbs" not in existing_users:
    password = secrets.token_urlsafe(12)
    secret = base64.b32encode(secrets.token_bytes(20)).decode().rstrip("=")
    pbs.request("POST", "/access/users", {"userid": "tfa@pbs", "password": password, "comment": "Test user with TOTP"})
    pbs.request("PUT", "/access/acl", {"path": "/", "role": "Admin", "auth-id": "tfa@pbs"})
    uri = f"otpauth://totp/ProxFleet:tfa@pbs?secret={secret}&issuer=ProxFleet&algorithm=SHA1&digits=6&period=30"
    pbs.request("POST", "/access/tfa/tfa@pbs", {
        "type": "totp", "description": "ProxFleet tests", "totp": uri, "value": totp(secret), "password": env["PASSWORD"],
    })
    append_env("TFA_USER", "tfa")
    append_env("TFA_REALM", "pbs")
    append_env("TFA_PASSWORD", password)
    append_env("TFA_TOTP_SECRET", secret)
    print("created tfa@pbs")

if "limited@pbs" not in existing_users:
    password = secrets.token_urlsafe(12)
    pbs.request("POST", "/access/users", {"userid": "limited@pbs", "password": password, "comment": "Read-only test user"})
    pbs.request("PUT", "/access/acl", {"path": "/datastore/store1", "role": "DatastoreAudit", "auth-id": "limited@pbs"})
    append_env("LIMITED_USER", "limited")
    append_env("LIMITED_REALM", "pbs")
    append_env("LIMITED_PASSWORD", password)
    print("created limited@pbs")

if "pvebackup@pbs" not in existing_users:
    password = secrets.token_urlsafe(16)
    pbs.request("POST", "/access/users", {"userid": "pvebackup@pbs", "password": password, "comment": "Proxmox VE test cluster"})
    pbs.request("PUT", "/access/acl", {"path": "/datastore/store1", "role": "DatastoreAdmin", "auth-id": "pvebackup@pbs"})
    append_env("PVE_BACKUP_USER", "pvebackup@pbs")
    append_env("PVE_BACKUP_PASSWORD", password)
    env = read_env(PBS_ENV_PATH)
    print("created pvebackup@pbs")

# An API token of root@pam for proxmox-backup-client on the node (live tests make host backups with it) and for the
# remote below, which points the server at itself.
tokens = {token["tokenid"] for token in pbs.request("GET", "/access/users/root@pam/token")}
if "root@pam!seed" not in tokens:
    secret = pbs.request("POST", "/access/users/root@pam/token/seed", {"comment": "ProxFleet seed"})["value"]
    pbs.request("PUT", "/access/acl", {"path": "/", "role": "Admin", "auth-id": "root@pam!seed"})
    append_env("SEED_TOKEN_ID", "root@pam!seed")
    append_env("SEED_TOKEN_SECRET", secret)
    env = read_env(PBS_ENV_PATH)
    print("created token root@pam!seed")

fingerprint = pbs.request("GET", "/nodes/localhost/status")["info"]["fingerprint"]
if "self" not in {remote["name"] for remote in pbs.request("GET", "/config/remote")}:
    pbs.request("POST", "/config/remote", {
        "name": "self", "host": "127.0.0.1", "auth-id": env["SEED_TOKEN_ID"], "password": env["SEED_TOKEN_SECRET"],
        "fingerprint": fingerprint, "comment": "This server, for sync tests",
    })
    print("created remote self")

# Jobs, so every list has entries.
pbs.request("PUT", "/config/datastore/store1", {"gc-schedule": "daily", "comment": "Main test datastore"})
if "pf-verify" not in {job["id"] for job in pbs.request("GET", "/config/verify")}:
    pbs.request("POST", "/config/verify", {
        "id": "pf-verify", "store": "store1", "schedule": "daily", "ignore-verified": 1, "outdated-after": 30,
        "comment": "Daily verification",
    })
    print("created verify job pf-verify")
if "pf-prune" not in {job["id"] for job in pbs.request("GET", "/config/prune")}:
    pbs.request("POST", "/config/prune", {
        "id": "pf-prune", "store": "store1", "schedule": "daily", "keep-last": 3, "keep-daily": 7, "keep-weekly": 4,
        "comment": "Keep a week",
    })
    print("created prune job pf-prune")
sync_jobs = {job["id"] for job in pbs.request("GET", "/config/sync")}
for job in [
    {"id": "pf-sync-local", "store": "store2", "remote-store": "store1", "schedule": "hourly", "comment": "Local pull"},
    {"id": "pf-sync-pull", "store": "store2", "remote": "self", "remote-store": "store1", "remote-ns": "pve",
     "ns": "", "schedule": "weekly", "remove-vanished": 0, "comment": "Pull from remote"},
    {"id": "pf-sync-push", "store": "store1", "remote": "self", "remote-store": "store2", "sync-direction": "push",
     "schedule": "sat 03:00", "group-filter": "type:host", "comment": "Push host backups"},
]:
    if job["id"] not in sync_jobs:
        pbs.request("POST", "/config/sync", {key: value for key, value in job.items() if value != ""})
        print(f"created sync job {job['id']}")

# Verification and garbage collection once, so their states are known.
if not pbs.request("GET", "/admin/datastore/store1/gc").get("upid"):
    pbs.wait("localhost", pbs.request("POST", "/admin/datastore/store1/gc"))
    print("ran garbage collection on store1")

# Proxmox VE side: the backup server as storage, with real backups of a container and a VM.
if PVE_ENV_PATH:
    pve = API(read_env(PVE_ENV_PATH), "PVEAuthCookie")
    fingerprint = pbs.request("GET", "/nodes/localhost/status")["info"]["fingerprint"]
    storages = {storage["storage"] for storage in pve.request("GET", "/storage")}
    if "pbs-test" not in storages:
        pve.request("POST", "/storage", {
            "storage": "pbs-test", "type": "pbs", "server": env["ADDRESS"].split(":")[0], "datastore": "store1",
            "username": env["PVE_BACKUP_USER"], "password": env["PVE_BACKUP_PASSWORD"],
            "fingerprint": fingerprint, "content": "backup",
        })
        # Proxmox VE 9.2 refuses a namespace when the storage is created ("Cannot find datastore"), but takes it later.
        pve.request("PUT", "/storage/pbs-test", {"namespace": "pve"})
        print("added storage pbs-test to Proxmox VE")
    guests = {int(guest["vmid"]): guest["node"] for guest in pve.request("GET", "/cluster/resources", {"type": "vm"})}
    content = pve.request("GET", f"/nodes/{next(iter(guests.values()))}/storage/pbs-test/content")
    backed_up = {}
    for volume in content:
        backed_up[int(volume["vmid"])] = backed_up.get(int(volume["vmid"]), 0) + 1
    for vmid in (200, 102):
        if vmid not in guests:
            print(f"guest {vmid} not found, skipped")
            continue
        for _ in range(max(0, 2 - backed_up.get(vmid, 0))):
            upid = pve.request("POST", f"/nodes/{guests[vmid]}/vzdump", {
                "vmid": vmid, "storage": "pbs-test", "mode": "snapshot", "remove": 0, "notes-template": "{{guestname}} seed",
            })
            pve.wait(guests[vmid], upid)
            print(f"backed up guest {vmid} to pbs-test")
