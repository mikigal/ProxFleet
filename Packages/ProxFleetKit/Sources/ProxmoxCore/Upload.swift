import Foundation

/// A transport that can send a large body from a file and report how much of it was sent.
public protocol FileUploadTransport: HTTPTransport {
    func upload(_ request: HTTPRequest, bodyFile: URL, progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> HTTPResponse
}

/// A `multipart/form-data` body written to a temporary file, so files of several gigabytes (ISO images) are
/// never held in memory. The fields come first and the file last, as the web interface sends them.
public struct MultipartBody: Sendable {
    public let boundary: String
    public let file: URL

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Copies `source` into the body in chunks. Delete `file` when done.
    public static func write(fields: [(name: String, value: String)], fileField: String, fileName: String, source: URL,
                             directory: URL = FileManager.default.temporaryDirectory) throws -> MultipartBody {
        let boundary = "ProxFleet-" + UUID().uuidString
        let file = directory.appending(path: "upload-\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw ProxmoxError.transport("Could not prepare the upload.")
        }
        do {
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var head = ""
            for field in fields {
                head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n\(field.value)\r\n"
            }
            let safeName = fileName.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
            head += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safeName)\"\r\n"
            head += "Content-Type: application/octet-stream\r\n\r\n"
            try output.write(contentsOf: Data(head.utf8))

            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return MultipartBody(boundary: boundary, file: file)
    }

    /// Reads the text fields and the file name back, for fake servers. Only looks at the parts before the file data.
    public static func fields(of body: URL, boundary: String) -> [String: String] {
        guard let handle = try? FileHandle(forReadingFrom: body), let head = try? handle.read(upToCount: 64 * 1024) else { return [:] }
        try? handle.close()
        let text = String(decoding: head, as: UTF8.self)
        var fields: [String: String] = [:]
        for part in text.components(separatedBy: "--\(boundary)\r\n").dropFirst() {
            let sections = part.components(separatedBy: "\r\n\r\n")
            guard let header = sections.first, let nameRange = header.range(of: "name=\"") else { continue }
            let name = String(header[nameRange.upperBound...].prefix { $0 != "\"" })
            if let fileRange = header.range(of: "filename=\"") {
                fields[name] = String(header[fileRange.upperBound...].prefix { $0 != "\"" })
            } else if sections.count > 1 {
                fields[name] = sections[1].components(separatedBy: "\r\n").first ?? ""
            }
        }
        return fields
    }
}

extension ProxmoxSession {
    /// Uploads a file with `multipart/form-data`, as `POST .../storage/{storage}/upload` expects. The request's
    /// parameters become form fields before the file.
    public func upload<Response>(_ request: APIRequest<Response>, fileField: String, fileName: String, source: URL,
                                 progress: @escaping @Sendable (_ sent: Int64, _ total: Int64) -> Void) async throws -> Response {
        guard let uploader = transport as? any FileUploadTransport else {
            throw ProxmoxError.transport("Uploading files is not supported here.")
        }
        // Renews the ticket first when it is due, as `send` does, so a long upload starts with a fresh one.
        try await prepareAuthenticatedRequest()
        let body = try MultipartBody.write(fields: request.parameters.items.map { ($0.name, $0.value.encoded) },
                                           fileField: fileField, fileName: fileName, source: source)
        defer { try? FileManager.default.removeItem(at: body.file) }

        var bare = request
        bare.parameters = APIParameters()
        var httpRequest = try buildRequest(bare, authenticated: true)
        httpRequest.body = nil
        httpRequest.headers["Content-Type"] = body.contentType
        let response: HTTPResponse
        do {
            response = try await uploader.upload(httpRequest, bodyFile: body.file, progress: progress)
        } catch let error as ProxmoxError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxmoxError.transport(error.localizedDescription)
        }
        return try ResponseDecoder.decode(Response.self, from: response)
    }
}
