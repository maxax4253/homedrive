import Foundation

/// Progress callback: (bytes done, total bytes or -1 if unknown).
typealias ProgressHandler = @Sendable (Int64, Int64) -> Void

/// Runs uploads and downloads with a session-level delegate so we get reliable
/// byte-by-byte progress, then hands the result back through async/await.
final class TransferSession: NSObject, URLSessionDataDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = TransferSession()

    private final class Job {
        let progress: ProgressHandler
        var lastReport = Date.distantPast
        var body = Data()
        var downloadedFile: URL?
        var downloadContinuation: CheckedContinuation<(URL, URLResponse), Error>?
        var uploadContinuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(progress: @escaping ProgressHandler) { self.progress = progress }
    }

    private var jobs: [Int: Job] = [:]
    private let lock = NSLock()
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private func job(for task: URLSessionTask) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs[task.taskIdentifier]
    }

    private func removeJob(for task: URLSessionTask) -> Job? {
        lock.lock(); defer { lock.unlock() }
        return jobs.removeValue(forKey: task.taskIdentifier)
    }

    private func add(_ job: Job, for task: URLSessionTask) {
        lock.lock(); jobs[task.taskIdentifier] = job; lock.unlock()
    }

    // MARK: - Public

    /// Downloads to a temp file you own (move it where you want).
    func download(_ request: URLRequest, progress: @escaping ProgressHandler) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: request)
        let job = Job(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.downloadContinuation = continuation
                add(job, for: task)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func upload(_ request: URLRequest, fromFile file: URL, progress: @escaping ProgressHandler) async throws -> (Data, URLResponse) {
        let task = session.uploadTask(with: request, fromFile: file)
        let job = Job(progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                job.uploadContinuation = continuation
                add(job, for: task)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    // MARK: - Delegate

    private func report(_ job: Job, _ done: Int64, _ total: Int64, force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(job.lastReport) > 0.1 else { return }
        job.lastReport = now
        job.progress(done, total)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let job = job(for: task) else { return }
        report(job, totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = job(for: downloadTask) else { return }
        report(job, totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = job(for: downloadTask) else { return }
        // The system deletes `location` when this returns, so move it somewhere safe first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("hd-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            job.downloadedFile = keep
        } catch {
            job.downloadedFile = nil
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        job(for: dataTask)?.body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let job = removeJob(for: task) else { return }
        if let error {
            if let file = job.downloadedFile { try? FileManager.default.removeItem(at: file) }
            job.downloadContinuation?.resume(throwing: error)
            job.uploadContinuation?.resume(throwing: error)
            return
        }
        let response = task.response ?? URLResponse()
        if let continuation = job.downloadContinuation {
            if let file = job.downloadedFile {
                let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                report(job, size, size, force: true)
                continuation.resume(returning: (file, response))
            } else {
                continuation.resume(throwing: URLError(.cannotCreateFile))
            }
        }
        if let continuation = job.uploadContinuation {
            continuation.resume(returning: (job.body, response))
        }
    }
}
