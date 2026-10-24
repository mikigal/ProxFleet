# ProxFleet Privacy Policy

Effective date: October 24, 2026

ProxFleet does not collect, share or sell any data about you. The app has no account, no analytics, no advertising, no crash reporting and no tracking. It connects only to the Proxmox servers you add, directly from your device. No developer server sits in between.

## What stays on your device

ProxFleet keeps only what it needs to connect to your servers, and only on your device:

- **Your server list:** the name, address, port, user name and realm of each server you add, and the fingerprints of certificates you chose to trust. It is stored in the app's private storage and protected by iOS data protection.
- **Passwords and sessions:** a server's password, only if you ask the app to remember it, and the session ticket of the last sign-in. Both are stored in the iOS Keychain, on this device only. They are not synced to iCloud Keychain and are not moved to another device.
- **App lock PIN:** if you turn on the app lock, the PIN is kept in the Keychain as a salted hash, never as the PIN itself.
- **App settings:** preferences such as console options.

When you remove a server in the app, its saved password and session are deleted too. When you delete the app, iOS deletes the server list and settings. If iOS keeps Keychain items after the app is deleted, ProxFleet does not use them after a reinstall.

## Network connections

ProxFleet connects only to the servers you add, over HTTPS. Consoles use secure WebSocket connections to the same servers. Everything you view or change in the app, such as virtual machines, containers, logs and settings, travels only between your device and your server. ProxFleet makes no connections to the developer or to third parties.

Actions such as downloading an ISO image from a URL are carried out by your Proxmox server, not by the app.

## Device permissions

- **Face ID:** optional, to unlock the app lock. iOS performs the check, and the app never receives your biometric data.
- **Local network:** to reach Proxmox servers on your local network.
- **Clipboard and files:** read only when you choose to, for example when you tap Paste in a console or pick a file to import. Their contents go only to your server.

## Apple

Apple handles App Store downloads and updates under [Apple's privacy policy](https://www.apple.com/legal/privacy/). If you allowed iOS to share analytics with app developers, Apple may give the developer anonymous crash reports and usage statistics. ProxFleet itself adds nothing to them.

## Children

ProxFleet is a tool for server administrators. It is not directed at children and collects no data from anyone.

## Changes

If this policy changes, the new version will be published in this file, with the effective date updated. Earlier versions remain in the repository's history.

## Contact

Questions about privacy? Open an issue at [github.com/mikigal/ProxFleet/issues](https://github.com/mikigal/ProxFleet/issues).
