import AppKit
import Darwin
import Foundation
import SwiftUI

private enum UsageError: LocalizedError {
    case codexMissing
    case serverUnavailable(String)
    case invalidResponse
    case weeklyLimitMissing

    var errorDescription: String? {
        switch self {
        case .codexMissing:
            return "Codex CLI was not found."
        case .serverUnavailable(let detail):
            return detail
        case .invalidResponse:
            return "Codex returned an unreadable response."
        case .weeklyLimitMissing:
            return "Codex did not return a weekly usage limit."
        }
    }
}

private struct UsageSnapshot {
    let remainingPercent: Int
    let resetAt: Date?
}

private enum UsageClient {
    static func weeklyUsage() throws -> UsageSnapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        guard let executable = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw UsageError.codexMissing
        }

        for arguments in [["app-server", "proxy"], ["app-server"]] {
            if let snapshot = try? readWeeklyUsage(executable: executable, arguments: arguments) {
                return snapshot
            }
        }
        throw UsageError.serverUnavailable("Could not read Codex usage. Check your Codex sign-in.")
    }

    private static func describe(_ error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code): \(error.localizedDescription)"
    }

    private static func readWeeklyUsage(executable: String, arguments: [String]) throws -> UsageSnapshot {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.arguments = arguments
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw UsageError.serverUnavailable("Could not start Codex: \(error.localizedDescription)")
        }

        // A failed server can otherwise leave a menu bar refresh waiting forever.
        let timeout = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
        defer {
            timeout.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            input.fileHandleForWriting.closeFile()
            output.fileHandleForReading.closeFile()
            errors.fileHandleForReading.closeFile()
        }

        var buffer = Data()
        var phase = "initialize write"
        let message: [String: Any]
        do {
            try send([
                "method": "initialize",
                "id": 0,
                "params": ["clientInfo": [
                    "name": "codex_usage_menu",
                    "title": "Codex Usage Menu",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
                ]]
            ], to: input.fileHandleForWriting)
            phase = "initialize response"
            let initialization = try response(id: 0, from: output.fileHandleForReading, buffer: &buffer)
            guard initialization["result"] != nil else {
                throw UsageError.serverUnavailable("Codex rejected the app server connection.")
            }

            phase = "initialized write"
            try send(["method": "initialized"], to: input.fileHandleForWriting)
            phase = "usage request write"
            try send(["method": "account/rateLimits/read", "id": 1], to: input.fileHandleForWriting)
            phase = "usage response"
            message = try response(id: 1, from: output.fileHandleForReading, buffer: &buffer)
        } catch {
            let originalError = describe(error)
            // Wait for the child to finish writing stderr. The timeout above
            // terminates it if it stays open.
            process.waitUntilExit()
            let data = (try? errors.fileHandleForReading.readToEnd()) ?? Data()
            let stderr = String(decoding: data, as: UTF8.self)
            let detail = stderr.split(separator: "\n")
                .map(String.init)
                .last(where: { $0.hasPrefix("Error:") })
                ?? stderr.split(separator: "\n").last.map(String.init)
                ?? originalError
            let reason = process.terminationReason == .exit ? "exit" : "signal"
            throw UsageError.serverUnavailable(
                "\(phase); \(reason) \(process.terminationStatus); \(String(detail.prefix(300)))"
            )
        }
        guard let result = message["result"] as? [String: Any] else {
            let detail = (message["error"] as? [String: Any])?["message"] as? String
            throw UsageError.serverUnavailable(detail ?? "Codex returned no usage data.")
        }

        let buckets = result["rateLimitsByLimitId"] as? [String: [String: Any]]
        let codex = buckets?["codex"] ?? result["rateLimits"] as? [String: Any]
        guard let codex else { throw UsageError.weeklyLimitMissing }
        for windowName in ["primary", "secondary"] {
            guard let window = codex[windowName] as? [String: Any],
                  let minutes = window["windowDurationMins"] as? Int,
                  minutes == 10_080,
                  let used = window["usedPercent"] as? Double else { continue }
            let resetAt = (window["resetsAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            return UsageSnapshot(
                remainingPercent: Int((100 - used).rounded().clamped(to: 0...100)),
                resetAt: resetAt
            )
        }
        throw UsageError.weeklyLimitMissing
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private static func response(
        id: Int,
        from handle: FileHandle,
        buffer: inout Data
    ) throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw UsageError.invalidResponse
                }
                if message["id"] as? Int == id { return message }
                continue
            }
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                throw UsageError.serverUnavailable("Codex closed the connection.")
            }
            buffer.append(chunk)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

@MainActor
private final class UsageModel: ObservableObject {
    private static let refreshInterval: TimeInterval = 30

    @Published private(set) var title = "…"
    @Published private(set) var status = "Reading weekly usage…"
    @Published private(set) var resetDescription = "Reading…"
    @Published private(set) var nextRefreshAt: Date?
    private var refreshing = false
    private var refreshTimer: Timer?

    init() {
        DispatchQueue.main.async { self.refresh() }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        refreshTimer?.invalidate()
        refreshTimer = nil
        nextRefreshAt = nil
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try UsageClient.weeklyUsage() }
            DispatchQueue.main.async {
                self.refreshing = false
                switch result {
                case .success(let snapshot):
                    self.title = "\(snapshot.remainingPercent)%"
                    self.status = "Codex weekly: \(snapshot.remainingPercent)% remaining"
                    if let resetAt = snapshot.resetAt {
                        let formatter = DateFormatter()
                        formatter.timeZone = .current
                        formatter.dateFormat = "EEE, MMM d, yyyy 'at' h:mm a z"
                        self.resetDescription = formatter.string(from: resetAt)
                    } else {
                        self.resetDescription = "Unavailable"
                    }
                case .failure(let error):
                    self.title = "—%"
                    self.status = error.localizedDescription
                    self.resetDescription = "Unavailable"
                }
                self.scheduleNextRefresh()
            }
        }
    }

    private func scheduleNextRefresh() {
        nextRefreshAt = Date().addingTimeInterval(Self.refreshInterval)
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

@main
private struct CodexUsageMenuApp: App {
    @StateObject private var usage = UsageModel()

    init() {
        // The Codex subprocess can exit before a write; handle EPIPE as an error.
        _ = signal(SIGPIPE, SIG_IGN)
    }

    var body: some Scene {
        MenuBarExtra {
            VStack(alignment: .leading, spacing: 12) {
                Text(usage.status)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Next reset")
                        .foregroundStyle(.secondary)
                    Text(usage.resetDescription)
                }
                HStack {
                    Text("Next refresh")
                    Spacer()
                    if let nextRefreshAt = usage.nextRefreshAt {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = max(0, Int(ceil(nextRefreshAt.timeIntervalSince(context.date))))
                            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                                .monospacedDigit()
                        }
                    } else {
                        Text("Refreshing…")
                    }
                }
                Divider()
                HStack {
                    Button("Refresh") { usage.refresh() }
                    Spacer()
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
            }
            .padding(16)
            .frame(width: 300)
        } label: {
            Text(usage.title).monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
