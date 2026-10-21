import Foundation

/// A pretend Linux shell for demo consoles. It answers a handful of everyday commands and nothing it does is real.
struct DemoShell {
    let hostname: String
    let osName: String
    let isContainer: Bool
    let vmid: Int
    private var mode: Mode
    private var line = ""
    private var directory = "/root"
    private var escape = EscapeState.none
    private let started = Date()

    private enum Mode { case login, password, shell }
    private enum EscapeState { case none, escape, sequence }

    /// Output returned by `input`, and whether the shell ended (`exit`).
    struct Output {
        var text = ""
        var closes = false
    }

    /// Containers open straight into a root shell; VM consoles start at a login prompt that accepts anything.
    init(hostname: String, osName: String, isContainer: Bool, vmid: Int, requiresLogin: Bool) {
        self.hostname = hostname
        self.osName = osName
        self.isContainer = isContainer
        self.vmid = vmid
        mode = requiresLogin ? .login : .shell
    }

    /// What the console shows before any input.
    func greeting() -> String {
        switch mode {
        case .login, .password:
            "\r\n\(osName) \(hostname) tty1\r\n\r\n\(hostname) login: "
        case .shell:
            motd + prompt
        }
    }

    private var motd: String {
        "\r\nWelcome to \(osName) on \(hostname).\r\n"
            + "This is a ProxFleet demo console.\r\nType \u{1B}[1mhelp\u{1B}[0m to see what it knows.\r\n\r\n"
    }

    private var prompt: String {
        let shown = directory == "/root" ? "~" : directory
        return "\u{1B}[1;32mroot@\(hostname)\u{1B}[0m:\u{1B}[1;34m\(shown)\u{1B}[0m# "
    }

    mutating func input(_ bytes: [UInt8]) -> Output {
        var output = Output()
        for byte in bytes {
            switch escape {
            case .escape:
                escape = byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") ? .sequence : .none
                continue
            case .sequence:
                if (0x40...0x7E).contains(byte) { escape = .none }
                continue
            case .none:
                break
            }
            switch byte {
            case 0x1B:
                escape = .escape
            case 0x0D, 0x0A:
                output.text += "\r\n"
                let entered = line
                line = ""
                output.text += submit(entered, closes: &output.closes)
                if output.closes { return output }
            case 0x7F, 0x08:
                if !line.isEmpty {
                    line.removeLast()
                    if mode != .password { output.text += "\u{8} \u{8}" }
                }
            case 0x03:
                line = ""
                output.text += "^C\r\n" + (mode == .shell ? prompt : "\(hostname) login: ")
                if mode == .password { mode = .login }
            case 0x0C:
                output.text += "\u{1B}[H\u{1B}[2J" + (mode == .shell ? prompt + line : "")
            case 0x04 where line.isEmpty && mode == .shell:
                output.text += "logout\r\n"
                output.closes = true
                return output
            case 0x20...0x7E:
                line.append(Character(Unicode.Scalar(byte)))
                if mode != .password { output.text += String(Unicode.Scalar(byte)) }
            default:
                break
            }
        }
        return output
    }

    private mutating func submit(_ entered: String, closes: inout Bool) -> String {
        switch mode {
        case .login:
            if entered.isEmpty { return "\(hostname) login: " }
            mode = .password
            return "Password: "
        case .password:
            mode = .shell
            return "Linux \(hostname) 6.14.8-2-pve #1 SMP PREEMPT_DYNAMIC x86_64\r\n" + motd + prompt
        case .shell:
            let result = run(entered.trimmingCharacters(in: .whitespaces), closes: &closes)
            return closes ? result : result + prompt
        }
    }

    private mutating func run(_ command: String, closes: inout Bool) -> String {
        let words = command.split(separator: " ").map(String.init)
        guard let name = words.first else { return "" }
        let arguments = Array(words.dropFirst())
        let lines: [String]
        switch name {
        case "help":
            lines = [
                "Known commands: ls, cd, pwd, cat, echo, whoami, hostname,",
                "uname, uptime, date, free, df, ip, ps, clear, help and exit.",
                "Nothing you do here changes anything.",
            ]
        case "ls":
            lines = [listing(for: arguments.last { !$0.hasPrefix("-") } ?? directory)]
        case "cd":
            let target = arguments.first ?? "/root"
            if target == "~" || target == "/root" {
                directory = "/root"
            } else if target == ".." {
                directory = "/" + directory.split(separator: "/").dropLast().joined(separator: "/")
            } else if ["/", "/etc", "/var", "/var/log", "/home", "/tmp", "/srv"].contains(target) {
                directory = target
            } else {
                lines = ["-bash: cd: \(target): No such file or directory"]
                return render(lines)
            }
            lines = []
        case "pwd":
            lines = [directory]
        case "cat":
            lines = arguments.flatMap(file)
        case "echo":
            lines = [arguments.joined(separator: " ")]
        case "whoami":
            lines = ["root"]
        case "hostname":
            lines = [hostname]
        case "uname":
            lines = [arguments.contains("-a") ? "Linux \(hostname) 6.14.8-2-pve #1 SMP PREEMPT_DYNAMIC PMX 6.14.8-2 x86_64 GNU/Linux" : "Linux"]
        case "uptime":
            let minutes = Int(Date().timeIntervalSince(started) / 60) + 4_327
            lines = [" \(Self.clock()) up \(minutes / 1440) days, \(minutes % 1440 / 60):\(String(format: "%02d", minutes % 60)),  1 user,  load average: 0.08, 0.05, 0.01"]
        case "date":
            lines = [Date().formatted(.dateTime.weekday().month().day().hour().minute().second().year())]
        case "free":
            lines = [
                "               total        used        free      shared  buff/cache   available",
                "Mem:           2.0Gi       412Mi       1.1Gi       1.2Mi       534Mi       1.6Gi",
                "Swap:          512Mi          0B       512Mi",
            ]
        case "df":
            lines = [
                "Filesystem                       Size  Used Avail Use% Mounted on",
                isContainer ? "/dev/mapper/pve-vm--\(vmid)--disk--0  7.8G  2.1G  5.3G  29% /" : "/dev/sda1                         31G  6.4G   23G  22% /",
                "tmpfs                            1.0G     0  1.0G   0% /dev/shm",
            ]
        case "ip":
            lines = [
                "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN",
                "    inet 127.0.0.1/8 scope host lo",
                "2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP",
                "    inet 10.0.20.\(abs(hostname.hashValue) % 200 + 20)/24 brd 10.0.20.255 scope global eth0",
            ]
        case "ps", "top":
            lines = [
                "    PID TTY          TIME CMD",
                "      1 ?        00:00:02 \(isContainer ? "init" : "systemd")",
                "    112 ?        00:00:00 sshd",
                "    245 pts/0    00:00:00 bash",
                "    301 pts/0    00:00:00 \(name)",
            ]
        case "clear":
            return "\u{1B}[H\u{1B}[2J"
        case "exit", "logout":
            closes = true
            return "logout\r\n"
        case "apt", "apt-get", "systemctl", "reboot", "shutdown", "poweroff", "rm", "nano", "vi", "vim":
            lines = ["\(name): not available in the ProxFleet demo."]
        default:
            lines = ["-bash: \(name): command not found"]
        }
        return render(lines)
    }

    private func listing(for path: String) -> String {
        switch path {
        case "/": "bin  boot  dev  etc  home  lib  media  mnt  opt  proc  root  run  sbin  srv  sys  tmp  usr  var"
        case "/etc": "hostname  hosts  os-release  passwd  resolv.conf  ssh  systemd  timezone"
        case "/var", "/var/": "backups  cache  lib  local  log  mail  opt  spool  tmp"
        case "/var/log": "apt  dpkg.log  journal  syslog"
        case "/root", "~", ".": "backup.sh  notes.txt"
        default: ""
        }
    }

    private func file(_ path: String) -> [String] {
        switch path {
        case "notes.txt", "/root/notes.txt":
            ["Welcome to the ProxFleet demo.", "Every guest, task and number you see is made up."]
        case "/etc/hostname":
            [hostname]
        case "/etc/os-release":
            ["PRETTY_NAME=\"\(osName)\"", "NAME=\"\(osName.split(separator: " ").first ?? "Linux")\"", "HOME_URL=\"https://example.com/\""]
        case "backup.sh", "/root/backup.sh":
            ["#!/bin/sh", "# Backups run from the Proxmox host; this file is only for show.", "echo \"nothing to do\""]
        default:
            ["cat: \(path): No such file or directory"]
        }
    }

    private func render(_ lines: [String]) -> String {
        lines.isEmpty ? "" : lines.joined(separator: "\r\n") + "\r\n"
    }

    private static func clock() -> String {
        Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
    }
}
