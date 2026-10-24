#!/usr/bin/env python3
"""Records API responses of a Proxmox Backup Server as test fixtures. Read-only: it only sends GET requests.

Run it after scripts/seed-backup-server.py, so the lists have entries. Responses are written pretty-printed with their
envelope, like the Proxmox VE fixtures, into Packages/ProxFleetKit/Tests/PBSKitTests/Fixtures/pbs-<version>/.
Certificates are shortened and the subscription's server ID replaced; nothing else is secret in GET responses.

Usage: python3 -I scripts/record-backup-server-fixtures.py Config/TestServerPBS.local.env
"""
import base64
import json
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ENV_PATH = Path(sys.argv[1])
ROOT = Path(__file__).resolve().parent.parent
CONTEXT = ssl.create_default_context()
CONTEXT.check_hostname = False
CONTEXT.verify_mode = ssl.CERT_NONE  # disposable test server with a self-signed certificate

env = dict(
    line.split("=", 1)
    for line in ENV_PATH.read_text().splitlines()
    if "=" in line and not line.startswith("#")
)
HOST = f"https://{env['ADDRESS']}"


def call(method, path, params=None, ticket=None, csrf=None, api_format="json"):
    url = f"{HOST}/api2/{api_format}{path}"
    body = None
    if params and method == "POST":
        body = urllib.parse.urlencode(params, doseq=True).encode()
    elif params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    request = urllib.request.Request(url, data=body, method=method)
    if ticket:
        request.add_header("Cookie", f"PBSAuthCookie={urllib.parse.quote(ticket)}")
    try:
        with urllib.request.urlopen(request, context=CONTEXT, timeout=60) as response:
            return json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        text = error.read().decode()
        try:
            return json.loads(text)
        except ValueError:
            raise RuntimeError(f"{method} {path}: {error.code} {text}") from None


login = call("POST", "/access/ticket", {"username": f"{env['USER']}@{env['REALM']}", "password": env["PASSWORD"]})["data"]
TICKET = login["ticket"]


def get(path, params=None, api_format="json"):
    return call("GET", path, params, ticket=TICKET, api_format=api_format)


version = get("/version")["data"]["version"]
OUT = ROOT / f"Packages/ProxFleetKit/Tests/PBSKitTests/Fixtures/pbs-{version}"
OUT.mkdir(parents=True, exist_ok=True)


def sanitize(value):
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            if key == "pem" and isinstance(item, str):
                cleaned[key] = "-----BEGIN CERTIFICATE-----\n(shortened)\n-----END CERTIFICATE-----\n"
            elif key == "serverid" and isinstance(item, str):
                cleaned[key] = "00000000000000000000000000000000"
            else:
                cleaned[key] = sanitize(item)
        return cleaned
    if isinstance(value, list):
        return [sanitize(item) for item in value]
    return value


def save(name, response):
    (OUT / f"{name}.json").write_text(json.dumps(sanitize(response), indent=2, sort_keys=True) + "\n")
    print(f"{name}.json")


def b64(path):
    return base64.b64encode(path.encode()).decode()


# Without login.
save("ping", call("GET", "/ping", api_format="extjs"))
save("access-domains", call("GET", "/access/domains"))

# Server and node.
for name, path, params in [
    ("version", "/version", None),
    ("nodes", "/nodes", None),
    ("node-status", "/nodes/localhost/status", None),
    ("node-rrd-hour", "/nodes/localhost/rrd", {"timeframe": "hour", "cf": "AVERAGE"}),
    ("node-config", "/nodes/localhost/config", None),
    ("node-dns", "/nodes/localhost/dns", None),
    ("node-time", "/nodes/localhost/time", None),
    ("node-network", "/nodes/localhost/network", None),
    ("node-services", "/nodes/localhost/services", None),
    ("node-subscription", "/nodes/localhost/subscription", None),
    ("node-certificates-info", "/nodes/localhost/certificates/info", None),
    ("node-apt-versions", "/nodes/localhost/apt/versions", None),
    ("node-apt-update", "/nodes/localhost/apt/update", None),
    ("node-apt-repositories", "/nodes/localhost/apt/repositories", None),
    ("node-disks-list", "/nodes/localhost/disks/list", None),
    ("node-disks-directory", "/nodes/localhost/disks/directory", None),
    ("node-disks-zfs", "/nodes/localhost/disks/zfs", None),
    ("node-journal", "/nodes/localhost/journal", {"lastentries": 10}),
    ("node-identity", "/nodes/localhost/identity", None),
    ("status-datastore-usage", "/status/datastore-usage", None),
]:
    save(name, get(path, params))

tasks = get("/nodes/localhost/tasks", {"limit": 100})
save("node-tasks", tasks)
for task in tasks["data"]:
    kind = {"verificationjob": "verify", "garbage_collection": "gc", "syncjob": "sync"}.get(task["worker_type"])
    status = task.get("status", "")
    label = "ok" if status == "OK" else "warnings" if status.startswith("WARNINGS") else "failed" if status else None
    if kind and label and not (OUT / f"task-status-{kind}-{label}.json").exists():
        upid = urllib.parse.quote(task["upid"], safe="")
        save(f"task-status-{kind}-{label}", get(f"/nodes/localhost/tasks/{upid}/status"))
        save(f"task-log-{kind}-{label}", get(f"/nodes/localhost/tasks/{upid}/log", {"limit": 500}))

# Datastores and their content.
for name, path, params in [
    ("config-datastore", "/config/datastore", None),
    ("config-datastore-store1", "/config/datastore/store1", None),
    ("admin-datastore", "/admin/datastore", None),
    ("datastore-status", "/admin/datastore/store1/status", {"verbose": 1}),
    ("datastore-gc", "/admin/datastore/store1/gc", None),
    ("datastore-rrd-hour", "/admin/datastore/store1/rrd", {"timeframe": "hour", "cf": "AVERAGE"}),
    ("datastore-active-operations", "/admin/datastore/store1/active-operations", None),
    ("datastore-namespaces", "/admin/datastore/store1/namespace", None),
    ("datastore-groups", "/admin/datastore/store1/groups", None),
    ("datastore-groups-ns-pve", "/admin/datastore/store1/groups", {"ns": "pve"}),
    ("datastore-snapshots", "/admin/datastore/store1/snapshots", None),
    ("datastore-snapshots-ns-pve", "/admin/datastore/store1/snapshots", {"ns": "pve"}),
]:
    save(name, get(path, params))

snapshots = get("/admin/datastore/store1/snapshots", {"ns": "pve"})["data"] + get("/admin/datastore/store1/snapshots")["data"]
for kind in ("ct", "vm", "host"):
    snapshot = next(item for item in snapshots if item["backup-type"] == kind)
    ns = {"ns": "pve"} if kind != "host" else {}
    key = {"backup-type": kind, "backup-id": snapshot["backup-id"], "backup-time": snapshot["backup-time"], **ns}
    save(f"snapshot-files-{kind}", get("/admin/datastore/store1/files", key))
    if kind in ("ct", "host"):
        archive = next(file["filename"] for file in snapshot["files"] if file["filename"].endswith(".pxar.didx"))
        save(f"catalog-{kind}-root", get("/admin/datastore/store1/catalog", {**key, "filepath": "/"}))
        listing = get("/admin/datastore/store1/catalog", {**key, "filepath": b64(f"/{archive}")})
        save(f"catalog-{kind}-archive", listing)
        # Entries carry their own base64 path, which is what the app sends to open them.
        directory = next(entry for entry in listing["data"] if entry["type"] == "d")
        save(f"catalog-{kind}-directory", get("/admin/datastore/store1/catalog", {**key, "filepath": directory["filepath"]}))
group = next(item for item in snapshots if item["backup-type"] == "ct")
save("group-notes", get("/admin/datastore/store1/group-notes", {"ns": "pve", "backup-type": "ct", "backup-id": group["backup-id"]}))

# Jobs and remotes.
for name, path, params in [
    ("config-verify", "/config/verify", None),
    ("config-prune", "/config/prune", None),
    ("config-sync", "/config/sync", None),
    ("admin-verify", "/admin/verify", None),
    ("admin-prune", "/admin/prune", None),
    ("admin-sync", "/admin/sync", None),
    ("admin-sync-push", "/admin/sync", {"sync-direction": "push"}),
    ("admin-gc", "/admin/gc", None),
    ("config-remote", "/config/remote", None),
    ("config-remote-self", "/config/remote/self", None),
    ("remote-scan", "/config/remote/self/scan", None),
    ("remote-scan-namespaces", "/config/remote/self/scan/store1/namespaces", None),
    ("remote-scan-groups", "/config/remote/self/scan/store1/groups", {"namespace": "pve"}),
    ("config-traffic-control", "/config/traffic-control", None),
    ("admin-traffic-control", "/admin/traffic-control", None),
]:
    save(name, get(path, params))

# Access control.
for name, path, params in [
    ("access-users", "/access/users", {"include_tokens": 1}),
    ("access-user-root-tokens", "/access/users/root@pam/token", None),
    ("access-acl", "/access/acl", None),
    ("access-roles", "/access/roles", None),
    ("access-permissions", "/access/permissions", None),
    ("access-permissions-limited", "/access/permissions", {"auth-id": "limited@pbs"}),
    ("access-tfa", "/access/tfa", None),
    ("config-access-pam", "/config/access/pam", None),
    ("config-access-pbs", "/config/access/pbs", None),
    ("config-access-ldap", "/config/access/ldap", None),
    ("config-access-webauthn", "/config/access/tfa/webauthn", None),
]:
    save(name, get(path, params))

# Notifications, metrics, S3 and keys.
for name, path, params in [
    ("notification-targets", "/config/notifications/targets", None),
    ("notification-matchers", "/config/notifications/matchers", None),
    ("notification-sendmail", "/config/notifications/endpoints/sendmail", None),
    ("notification-matcher-fields", "/config/notifications/matcher-fields", None),
    ("notification-matcher-field-values", "/config/notifications/matcher-field-values", None),
    ("admin-metrics", "/admin/metrics", None),
    ("config-s3", "/config/s3", None),
    ("config-encryption-keys", "/config/encryption-keys", None),
]:
    save(name, get(path, params))

# Error formats of the extjs API, which the app uses.
save("error-unknown-datastore", get("/admin/datastore/missing/status", api_format="extjs"))
save("error-parameter", get("/nodes/localhost/disks/smart", {"disk": "not a disk"}, api_format="extjs"))
