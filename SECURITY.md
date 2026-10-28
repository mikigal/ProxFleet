# Security Policy

ProxFleet holds the keys to your servers, so security reports are taken seriously. Thank you for helping keep its users safe.

## Reporting a vulnerability

Please don't report security issues in public issues, pull requests or discussions. Report them privately through [GitHub's private vulnerability reporting](https://github.com/mikigal/ProxFleet/security/advisories/new). Only the maintainer can see the report.

A good report includes:

- The ProxFleet version, shown under Settings → Version, or the commit if you built it from source.
- Your device and its iOS or iPadOS version.
- The Proxmox VE or Proxmox Backup Server version, if a server is involved.
- The steps to reproduce the issue, and what an attacker gains from it.

Please don't send real passwords, session tickets, certificates or addresses of your servers. Reproduce the issue on a disposable test server, or remove them from logs and screenshots.

## What to expect

- You get a reply within 7 days, confirming that the report arrived.
- Within 14 days, you learn whether the issue is accepted as a vulnerability and how severe it is.
- ProxFleet is maintained by one person. Fixes are made as quickly as possible, with the most severe issues first, but without a fixed deadline. You are kept up to date in the advisory.
- Fixes ship as an App Store update, so Apple's review can add a few days before users get them.
- Once the fix is available, a [security advisory](https://github.com/mikigal/ProxFleet/security/advisories) is published, with a CVE when the issue warrants one. You are credited in it, unless you prefer not to be.

Please keep the issue private until the fixed version is available on the App Store, or until we agree on a date. There is no bug bounty.

## Supported versions

| Version | Supported |
| --- | --- |
| Latest release on the App Store | Yes |
| `main` branch | Yes |
| Older releases | No |

Security fixes are released only as a new version. If you build ProxFleet from source, use the latest release tag or `main`.

## Scope

In scope is the ProxFleet app and the code in this repository. For example:

- Passwords or session tickets that leave the device or the Keychain, or end up in logs, files or other places they should not.
- A connection to a server whose certificate is neither trusted by iOS nor confirmed by the user, or any other way to read or change the traffic between the app and a server.
- Data the app sends anywhere other than the servers the user added.
- Getting past the app lock without the PIN or a face or fingerprint enrolled when Face ID was turned on.
- A server, a guest or console output that makes the app do more than show data: run code, read local data, or reach another saved server.

Out of scope:

- Vulnerabilities in Proxmox VE or Proxmox Backup Server themselves. Report them to Proxmox as described in [Security Reporting](https://pve.proxmox.com/wiki/Security_Reporting).
- Vulnerabilities in iOS, the Keychain or Face ID. Report them to [Apple](https://security.apple.com).
- Vulnerabilities in [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), the only third-party library in the app. Report them upstream, and here too if ProxFleet is affected.
- Actions the signed-in Proxmox user is allowed to do anyway. The server decides what a user may do; the app only hides actions the user has no privilege for.
- Attacks that need a jailbroken device, or an unlocked device in the attacker's hands with the app lock turned off.
- A user who trusts a certificate without comparing its fingerprint.
- Demo mode, options of debug builds, and the scripts in `scripts/`, which run only against disposable test servers.
- Reports of automated scanners without a demonstrated impact.

## How ProxFleet protects your data

- **Direct connections only.** The app connects only to the servers you add, over HTTPS, and to their consoles over secure WebSockets. There is no developer server, and no analytics or tracking. See the [privacy policy](PRIVACY.md).
- **Certificates.** A certificate that iOS trusts is accepted as usual. When iOS doesn't trust it, for example the self-signed certificate that Proxmox creates during installation, the app shows its SHA-256 fingerprint and connects only after you confirm it. The confirmed fingerprint is pinned to that server, and any other untrusted certificate is shown to you again. A pinned certificate is accepted as long as it stays the same, even after it expires. Before trusting a fingerprint, compare it with the one shown by `pvenode cert info` or `proxmox-backup-manager cert info` on the server.
- **Passwords and sessions.** A password is saved only if you ask the app to remember it. Passwords and session tickets are stored in the iOS Keychain, readable only while the device is unlocked, and never synced to iCloud or moved to another device. Removing a server deletes them. Two-factor codes are never stored.
- **Server list.** Addresses, user names and trusted fingerprints are stored in the app's private storage with complete iOS data protection, so they can't be read while the device is locked.
- **App lock.** The optional PIN is stored in the Keychain as a salted PBKDF2-SHA256 hash, never as the PIN itself. After 5 wrong PINs, the app makes you wait, from 30 seconds up to 15 minutes. Face ID unlocks the app only with the faces enrolled when you turned it on; after a change, the PIN is needed. While the lock is on, the app hides its content whenever it leaves the screen, so the app switcher shows nothing. The lock protects the interface; the data itself is protected by iOS and the Keychain.

## Recommendations

- Sign in with a dedicated user that has only the roles you need, rather than `root@pam`.
- Turn on two-factor authentication for your Proxmox users.
- Give your servers a certificate that iOS trusts, for example from Let's Encrypt through ACME, or compare the fingerprint before you trust it.
- Turn on the app lock if other people may use your unlocked device.
