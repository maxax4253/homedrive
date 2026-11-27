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

    private func makeRequest(_ endpoint: String, query: [String: String] = [:], method: String = "GET") -> URLRequest {
        var comps = URLComponents(url: baseURL.appendingPathComponent("api/\(endpoint)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func jsonRequest<T: Encodable>(_ endpoint: String, body: T) throws -> URLRequest {
        var req = makeRequest(endpoint, method: "POST")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        return req
    }

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(ServerError.self, from: data))?.detail
            throw APIError(message: detail ?? "Server error (\(http.statusCode))", status: http.statusCode)
        }
    }

    private func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: req)
        try check(data, response)
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(req))
    }

    // MARK: - API

    func health() async throws {
        _ = try await send(makeRequest("health"))
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

    func thumbnail(_ path: String, size: Int) async throws -> Data {
        try await send(makeRequest("thumbnail", query: ["path": path, "size": String(size)]))
    }

    /// Downloads a file and moves it to `destination` (replacing anything there).
    func download(_ path: String, to destination: URL) async throws {
        let (tempURL, response) = try await session.download(for: makeRequest("download", query: ["path": path]))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let data = (try? Data(contentsOf: tempURL)) ?? Data()
            try check(data, response)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: tempURL, to: destination)
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

    /// Uploads one local file into `folder`. The multipart body is written to a
    /// temp file first so big files don't have to fit in memory.
    func upload(file: URL, to folder: String) async throws {
        let boundary = "HomeDrive-\(UUID().uuidString)"
        let bodyURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        FileManager.default.createFile(atPath: bodyURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: bodyURL)
        let filename = file.lastPathComponent.replacingOccurrences(of: "\"", with: "'")
        out.write(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"files\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))

        let input = try FileHandle(forReadingFrom: file)
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            out.write(chunk)
        }
        try input.close()
        out.write(Data("\r\n--\(boundary)--\r\n".utf8))
        try out.close()

        var req = makeRequest("upload", query: ["path": folder], method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, fromFile: bodyURL)
        try check(data, response)
    }
}
