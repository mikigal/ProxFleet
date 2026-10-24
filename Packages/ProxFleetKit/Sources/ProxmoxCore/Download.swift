import Foundation

/// A transport that can write a response body straight to a file and report how much of it arrived.
public protocol FileDownloadTransport: HTTPTransport {
    /// The body ends up in a new file in `directory`, also when the server answers with an error.
    /// - Parameter progress: bytes received so far and the expected total, nil when the server does not say.
    func download(_ request: HTTPRequest, into directory: URL, progress: @escaping @Sendable (_ received: Int64, _ total: Int64?) -> Void) async throws -> HTTPDownload
}

/// Status and headers of a downloaded response, and the file that holds its body.
public struct HTTPDownload: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var file: URL

    public init(statusCode: Int, headers: [String: String] = [:], file: URL) {
        self.statusCode = statusCode
        self.headers = headers
        self.file = file
    }
}

extension APIFormat {
    /// Files are served in the plain `json` format: the `extjs` one wraps every answer in JSON.
    public static let downloadPathPrefix = "/api2/json"
}

extension ProxmoxSession {
    /// Downloads a file the API serves as raw bytes, such as a file from a backup, into a new file in `directory`.
    /// The caller moves or deletes the file. Errors come back as the server's message, like other API calls.
    public func download(_ request: APIRequest<Nothing>, into directory: URL = FileManager.default.temporaryDirectory,
                         progress: @escaping @Sendable (_ received: Int64, _ total: Int64?) -> Void = { _, _ in }) async throws -> URL {
        guard let downloader = transport as? any FileDownloadTransport else {
            throw ProxmoxError.transport("Downloading files is not supported here.")
        }
        try await prepareAuthenticatedRequest()
        var httpRequest = try buildRequest(request, authenticated: true, pathPrefix: APIFormat.downloadPathPrefix)
        httpRequest.headers["Accept"] = "*/*"
        let download: HTTPDownload
        do {
            download = try await downloader.download(httpRequest, into: directory, progress: progress)
        } catch let error as ProxmoxError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ProxmoxError.transport(error.localizedDescription)
        }
        guard download.statusCode >= 400 else { return download.file }

        // Error bodies are short: a message as plain text or JSON.
        defer { try? FileManager.default.removeItem(at: download.file) }
        let body = (try? FileHandle(forReadingFrom: download.file)).flatMap { handle in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 64 * 1024)
        } ?? Data()
        let response = HTTPResponse(statusCode: download.statusCode, headers: download.headers, body: body)
        do {
            _ = try ResponseDecoder.decode(Nothing.self, from: response)
        } catch ProxmoxError.unauthorized(let message) {
            if download.statusCode == 401 { logout() }
            throw ProxmoxError.unauthorized(message)
        }
        throw ProxmoxError.api(status: download.statusCode, message: "HTTP \(download.statusCode)", fieldErrors: [:])
    }
}
