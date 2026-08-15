import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandRunnerError: Error, CustomStringConvertible {
    case timedOut(seconds: Int)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .timedOut(let s): return "command timed out after \(s)s"
        case .launchFailed(let m): return "failed to launch command: \(m)"
        }
    }
}

/// Abstraction over running an external command. The protocol is platform-agnostic
/// so `TranscriptsCore` builds on iOS (where there is no `Process`); only the concrete
/// `ProcessCommandRunner` is gated to platforms that have a shell.
public protocol CommandRunner: Sendable {
    /// Runs `command` (already template-substituted) feeding `stdin` if provided.
    func run(_ command: ExternalCommand, stdin: Data?) async throws -> CommandResult
}

#if os(macOS) || os(Linux)
/// Foundation `Process`-backed runner with a timeout.
public struct ProcessCommandRunner: CommandRunner {
    public init() {}

    public func run(_ command: ExternalCommand, stdin: Data?) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: command.executable)
            process.arguments = command.arguments
            if let wd = command.workingDirectory {
                process.currentDirectoryURL = URL(fileURLWithPath: (wd as NSString).expandingTildeInPath)
            }

            var env = ProcessInfo.processInfo.environment
            for (k, v) in command.environment { env[k] = v }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let inPipe = Pipe()
            process.standardInput = inPipe

            // Single-fire guard so timeout and termination don't both resume.
            let resumed = NSLock()
            var didResume = false
            func finish(_ result: Result<CommandResult, Error>) {
                resumed.lock(); defer { resumed.unlock() }
                guard !didResume else { return }
                didResume = true
                continuation.resume(with: result)
            }

            process.terminationHandler = { proc in
                let out = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                let err = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                finish(.success(CommandResult(
                    exitCode: proc.terminationStatus,
                    stdout: out ?? Data(),
                    stderr: err ?? Data()
                )))
            }

            do {
                try process.run()
            } catch {
                finish(.failure(CommandRunnerError.launchFailed(error.localizedDescription)))
                return
            }

            if let stdin {
                inPipe.fileHandleForWriting.write(stdin)
            }
            try? inPipe.fileHandleForWriting.close()

            // Timeout watchdog.
            let deadline = DispatchTime.now() + .seconds(command.timeoutSeconds)
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                    finish(.failure(CommandRunnerError.timedOut(seconds: command.timeoutSeconds)))
                }
            }
        }
    }
}
#endif
