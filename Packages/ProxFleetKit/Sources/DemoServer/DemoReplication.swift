import Foundation
import ProxmoxCore

/// A storage replication job in demo mode. The demo does not check that the guest's disks are on ZFS.
struct DemoReplicationJob: Sendable {
    var guest: Int
    var jobNumber: Int
    var target: String
    var schedule: String?
    var rate: String?
    var comment: String?
    var isDisabled = false
    /// `local` or `full` once deleted; the job goes away on its next run.
    var removal: String?
    var lastSync: Date?
    var duration: Double?
    var failCount = 0
    var error: String?
    /// Runs scheduled with Run Now finish at this time.
    var runningUntil: Date?

    var id: String { "\(guest)-\(jobNumber)" }
}

/// `/cluster/replication` and `/nodes/{node}/replication` in demo mode.
extension DemoState {
    static func sampleReplicationJobs(for cluster: DemoCluster, now: Date) -> [DemoReplicationJob] {
        guard cluster.clusterName != nil else { return [] }
        return [
            DemoReplicationJob(guest: 101, jobNumber: 0, target: "pve2", rate: "100", comment: "NAS to pve2", lastSync: now.addingTimeInterval(-260), duration: 4.8),
            DemoReplicationJob(guest: 200, jobNumber: 0, target: "pve2", schedule: "*/30", lastSync: now.addingTimeInterval(-900), duration: 1.2),
            // pve3 is offline, so the job fails.
            DemoReplicationJob(
                guest: 104, jobNumber: 0, target: "pve3", schedule: "*/30", lastSync: now.addingTimeInterval(-86_400 * 2), duration: 9.6, failCount: 96,
                error: "command '/usr/bin/ssh -e none -o 'BatchMode=yes' -o 'HostKeyAlias=pve3' root@10.0.10.13 -- pvesr prepare-local-job 104-0 --scan local-lvm --last_sync 0' failed: exit code 255"
            ),
            DemoReplicationJob(guest: 202, jobNumber: 0, target: "pve2", schedule: "21:00", comment: "Media library, nightly", isDisabled: true),
        ]
    }

    /// Routes for replication jobs. nil for other paths.
    func handleReplication(_ method: HTTPMethod, parts: [String], parameters: [String: String], user: String) -> HTTPResponse? {
        settleReplication()
        if parts.first == "cluster", parts.dropFirst().first == "replication" {
            return clusterReplication(method, id: parts.count > 2 ? parts[2] : nil, parameters: parameters, user: user)
        }
        guard parts.count >= 3, parts[0] == "nodes", parts[2] == "replication" else { return nil }
        let node = parts[1]
        guard cluster.nodes.first(where: { $0.name == node })?.isOnline == true else {
            return failure(595, "Connection refused: node '\(node)' seems to be offline")
        }
        switch (method, Array(parts.dropFirst(3))) {
        case (.get, []):
            let guest = parameters["guest"].flatMap(Int.init)
            return success(.array(replicationJobs.filter { job in
                cluster.guests.first { $0.vmid == job.guest }?.node == node && (guest.map { $0 == job.guest } ?? true)
            }.map { replicationJSON($0, withState: true) }))
        case (.get, let rest) where rest.count == 2 && rest[1] == "status":
            guard let job = replicationJobs.first(where: { $0.id == rest[0] }) else { return failure(500, "no such replication job '\(rest[0])'") }
            return success(replicationJSON(job, withState: true))
        case (.get, let rest) where rest.count == 2 && rest[1] == "log":
            guard let job = replicationJobs.first(where: { $0.id == rest[0] }) else { return failure(500, "no such replication job '\(rest[0])'") }
            return success(.array(replicationLog(job).enumerated().map { ["n": .int($0.offset + 1), "t": .string($0.element)] }))
        case (.post, let rest) where rest.count == 2 && rest[1] == "schedule_now":
            guard let index = replicationJobs.firstIndex(where: { $0.id == rest[0] }) else { return failure(500, "no such replication job '\(rest[0])'") }
            replicationJobs[index].runningUntil = Date().addingTimeInterval(3)
            return success("")
        default:
            return nil
        }
    }

    private func clusterReplication(_ method: HTTPMethod, id: String?, parameters: [String: String], user: String) -> HTTPResponse? {
        let canModify = privileges(for: user).contains("VM.Allocate")
        guard let id else {
            switch method {
            case .get:
                return success(.array(replicationJobs.map { replicationJSON($0, withState: false) }))
            case .post:
                guard canModify else { return failure(403, "Permission check failed (/vms, VM.Replicate)") }
                return createReplicationJob(parameters)
            default:
                return nil
            }
        }
        guard let index = replicationJobs.firstIndex(where: { $0.id == id }) else { return failure(500, "replication job '\(id)' does not exist") }
        switch method {
        case .get:
            var json = replicationJSON(replicationJobs[index], withState: false)
            if case .object(var object) = json {
                object["digest"] = .string(String(id.hashValue, radix: 16))
                json = .object(object)
            }
            return success(json)
        case .put:
            guard canModify else { return failure(403, "Permission check failed (/vms/\(replicationJobs[index].guest), VM.Replicate)") }
            if let schedule = parameters["schedule"], Self.nextRuns(of: schedule, count: 1) == nil {
                return fieldFailure(["schedule": "invalid format - invalid calendar event '\(schedule)'"])
            }
            for key in (parameters["delete"] ?? "").split(separator: ",") {
                switch key {
                case "schedule": replicationJobs[index].schedule = nil
                case "rate": replicationJobs[index].rate = nil
                case "comment": replicationJobs[index].comment = nil
                case "disable": replicationJobs[index].isDisabled = false
                default: break
                }
            }
            if let schedule = parameters["schedule"] { replicationJobs[index].schedule = schedule }
            if let rate = parameters["rate"] { replicationJobs[index].rate = rate }
            if let comment = parameters["comment"] { replicationJobs[index].comment = comment }
            if let disable = parameters["disable"] { replicationJobs[index].isDisabled = disable == "1" }
            return success(nil)
        case .delete:
            guard canModify else { return failure(403, "Permission check failed (/vms/\(replicationJobs[index].guest), VM.Replicate)") }
            if parameters["force"] == "1" {
                replicationJobs.remove(at: index)
            } else {
                replicationJobs[index].removal = parameters["keep"] == "1" ? "local" : "full"
            }
            return success(nil)
        default:
            return nil
        }
    }

    private func createReplicationJob(_ parameters: [String: String]) -> HTTPResponse {
        let id = parameters["id"] ?? ""
        let pieces = id.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 2, pieces[0] >= 100 else { return fieldFailure(["id": "invalid format - value does not look like a valid replication job ID"]) }
        guard !replicationJobs.contains(where: { $0.id == id }) else { return failure(500, "replication job '\(id)' already exists") }
        guard let guest = cluster.guests.first(where: { $0.vmid == pieces[0] }) else { return failure(500, "guest '\(pieces[0])' does not exist") }
        let target = parameters["target"] ?? ""
        guard cluster.nodes.contains(where: { $0.name == target }) else { return fieldFailure(["target": "no such cluster node '\(target)'"]) }
        guard target != guest.node else { return failure(500, "Source and target must not be identical") }
        if let schedule = parameters["schedule"], Self.nextRuns(of: schedule, count: 1) == nil {
            return fieldFailure(["schedule": "invalid format - invalid calendar event '\(schedule)'"])
        }
        replicationJobs.append(DemoReplicationJob(
            guest: pieces[0], jobNumber: pieces[1], target: target, schedule: parameters["schedule"], rate: parameters["rate"], comment: parameters["comment"],
            isDisabled: parameters["disable"] == "1"
        ))
        return success(nil)
    }

    /// Finishes runs started with Run Now; a deleted job goes away on its run.
    private func settleReplication() {
        let now = Date()
        for index in replicationJobs.indices.reversed() {
            guard let until = replicationJobs[index].runningUntil, until <= now else { continue }
            replicationJobs[index].runningUntil = nil
            if replicationJobs[index].removal != nil {
                replicationJobs.remove(at: index)
                continue
            }
            let target = replicationJobs[index].target
            if cluster.nodes.first(where: { $0.name == target })?.isOnline == true {
                replicationJobs[index].lastSync = until
                replicationJobs[index].duration = 2.4
                replicationJobs[index].failCount = 0
                replicationJobs[index].error = nil
            } else {
                replicationJobs[index].failCount += 1
            }
        }
    }

    private func replicationJSON(_ job: DemoReplicationJob, withState: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(job.id), "guest": .int(job.guest), "jobnum": .int(job.jobNumber), "target": .string(job.target), "type": "local",
        ]
        let guest = cluster.guests.first { $0.vmid == job.guest }
        if let node = guest?.node { object["source"] = .string(node) }
        if let schedule = job.schedule { object["schedule"] = .string(schedule) }
        if let rate = job.rate, let value = Double(rate) { object["rate"] = .double(value) }
        if let comment = job.comment { object["comment"] = .string(comment) }
        if job.isDisabled { object["disable"] = 1 }
        if let removal = job.removal { object["remove_job"] = .string(removal) }
        guard withState else { return .object(object) }
        object["vmtype"] = .string(guest?.kind.rawValue ?? "qemu")
        object["last_sync"] = .int(Int(job.lastSync?.timeIntervalSince1970 ?? 0))
        object["last_try"] = .int(Int(job.lastSync?.timeIntervalSince1970 ?? 0))
        object["fail_count"] = .int(job.failCount)
        if let duration = job.duration { object["duration"] = .double(duration) }
        if let error = job.error { object["error"] = .string(error) }
        if job.runningUntil != nil { object["pid"] = 48_213 }
        let next = job.isDisabled ? nil : Self.nextRuns(of: job.schedule ?? "*/15", count: 1)?.first
        object["next_sync"] = .int(job.lastSync == nil ? 1800 : Int(next?.timeIntervalSince1970 ?? 0))
        return .object(object)
    }

    private func replicationLog(_ job: DemoReplicationJob) -> [String] {
        guard let last = job.lastSync else { return [] }
        let stamp = last.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.colon).dateTimeSeparator(.space))
        let volume = "local-lvm:vm-\(job.guest)-disk-0"
        var lines = [
            "\(job.id): start replication job",
            "\(job.id): guest => VM \(job.guest), running => 1",
            "\(job.id): volumes => \(volume)",
            "\(job.id): create snapshot '__replicate_\(job.id)_\(Int(last.timeIntervalSince1970))__' on \(volume)",
            "\(job.id): using secure transmission, rate limit: \(job.rate.map { "\($0) MByte/s" } ?? "none")",
            "\(job.id): incremental sync '\(volume)' (__replicate_\(job.id)_\(Int(last.timeIntervalSince1970) - 900)__ => __replicate_\(job.id)_\(Int(last.timeIntervalSince1970))__)",
        ]
        if let error = job.error {
            lines.append("\(job.id): end replication job with error: \(error)")
        } else {
            lines += ["\(job.id): successfully imported '\(volume)'", "\(job.id): end replication job"]
        }
        return lines.map { "\(stamp) \($0)" }
    }
}
