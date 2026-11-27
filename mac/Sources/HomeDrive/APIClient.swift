import CryptoKit
import Foundation

struct APIError: LocalizedError {
    let message: String
    let status: Int
    var errorDescription: String? { message }
}

/// Talks to the HomeDrive server.
final class APIClient {
    let baseURL: URL
    var token: String?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 6 // big uploads/downloads
        return URLSession(configuration: config)
    }()

    init(baseURL: URL, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
    }

    // MARK: - Requests

    func makeRequest(_ endpoint: String, query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/\(endpoint)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func jsonRequest<T: Encodable>(_ endpoint: String, body: T) throws -> URLRequest {
        var req = makeRequest(endpoint, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data))?.detail
            throw APIError(message: detail ?? "Server error (\(http.statusCode))", status: http.statusCode)
        }
    }

    func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        try check(data, response)
        return data
    }

    func decode<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(req))
    }

    // MARK: - API

    func health() async throws {
        _ = try await send(makeRequest("health"))
    }

    func serverVersion() async throws -> String {
        struct Health: Decodable { let version: String }
        return try await decode(Health.self, makeRequest("health")).version
    }

    func login(username: String, password: String) async throws -> LoginResponse {
        try await decode(LoginResponse.self, try jsonRequest("login", body: ["username": username, "password": password]))
    }

    func me() async throws -> MeResponse {
        try await decode(MeResponse.self, makeRequest("me"))
    }

    func list(_ path: String) async throws -> [Entry] {
        try await decode(ListResponse.self, makeRequest("list", query: ["path": path])).entries
    }

    func recent(limit: Int) async throws -> [Entry] {
        try await decode(EntriesResponse.self, makeRequest("recent", query: ["limit": String(limit)])).entries
    }

    func search(_ query: String) async throws -> [Entry] {
        try await decode(EntriesResponse.self, makeRequest("search", query: ["q": query])).entries
    }

    func trash() async throws -> [Entry] {
        try await decode(EntriesResponse.self, makeRequest("trash")).entries
    }

    func restore(_ trashName: String) async throws {
        _ = try await send(try jsonRequest("trash/restore", body: ["name": trashName]))
    }

    func deleteForever(_ trashName: String) async throws {
        _ = try await send(try jsonRequest("trash/delete", body: ["name": trashName]))
    }

    func emptyTrash() async throws {
        _ = try await send(makeRequest("trash/empty", method: "POST"))
    }

    func thumbnail(_ path: String, size: Int) async throws -> Data {
        try await send(makeRequest("thumbnail", query: ["path": path, "size": String(size)]))
    }

    /// Downloads a file and moves it to `destination` (replacing anything there).
    func download(_ path: String, to destination: URL, progress: @escaping ProgressHandler = { _, _ in }) async throws {
        try await fetchFile(makeRequest("download", query: ["path": path]), to: destination, progress: progress)
    }

    /// Downloads files/folders as one zip.
    func downloadZip(_ paths: [String], to destination: URL, progress: @escaping ProgressHandler = { _, _ in }) async throws {
        var req = makeRequest("zip")
        var comps = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!
        comps.queryItems = paths.map { URLQueryItem(name: "path", value: $0) }
        req.url = comps.url
        try await fetchFile(req, to: destination, progress: progress)
    }

    func fetchFile(_ request: URLRequest, to destination: URL, progress: @escaping ProgressHandler) async throws {
        let (tempURL, response) = try await TransferSession.shared.download(request, progress: progress)
        defer { try? FileManager.default.removeItem(at: tempURL) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: tempURL)) ?? Data()
            try check(data, response)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tempURL, to: destination)
    }

    func starred() async throws -> [Entry] {
        try await decode(EntriesResponse.self, makeRequest("starred")).entries
    }

    func setStar(_ path: String, starred: Bool) async throws {
        struct Body: Encodable { let path: String; let starred: Bool }
        _ = try await send(try jsonRequest("star", body: Body(path: path, starred: starred)))
    }

    func mkdir(_ path: String) async throws {
        _ = try await send(try jsonRequest("mkdir", body: ["path": path]))
    }

    func move(from src: String, to dst: String) async throws {
        _ = try await send(try jsonRequest("move", body: ["src": src, "dst": dst]))
    }

    func delete(_ path: String) async throws {
        _ = try await send(try jsonRequest("delete", body: ["path": path]))
    }

    /// Uploads one local file into `folder` and confirms the server stored an
    /// identical copy (same SHA-256 fingerprint). Throws if it doesn't match.
    ///
    /// The multipart body is written to a temp file first so big files don't have
    /// to fit in memory; the fingerprint is computed in the same pass.
    @discardableResult
    func upload(file: URL, to folder: String, replace: Bool = false, ifModified: Double? = nil,
                progress: @escaping ProgressHandler = { _, _ in }) async throws -> UploadResult.Saved {
        let boundary = "HomeDrive-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))

        var hasher = SHA256()
        var localSize: Int64 = 0
        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            localSize += Int64(chunk.count)
            out.write(chunk)
        }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()
        let localHash = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        var query = ["path": folder]
        if replace { query["replace"] = "true" }
        if let ifModified { query["if_modified"] = String(ifModified) }
        var req = makeRequest("upload", query: query, method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await TransferSession.shared.upload(req, fromFile: bodyURL, progress: progress)
        try check(data, response)

        guard let saved = try? JSONDecoder().decode(UploadResult.self, from: data).saved.first,
              let remoteHash = saved.sha256 else {
            throw APIError(message: "The server didn't confirm the upload. Update the HomeDrive server.", status: 0)
        }
        guard remoteHash == localHash, saved.size == localSize else {
            throw APIError(message: "Upload check failed: the copy on the server doesn't match. Nothing was deleted.", status: 0)
        }
        return saved
    }
}
