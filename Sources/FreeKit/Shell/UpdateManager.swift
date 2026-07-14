import AppKit
import FreeKitCore

// Git-based self-update: the app is built from a local checkout, so updating is
// fetch -> pull -> build.sh -> relaunch. Strictly user-initiated (the only
// network use besides model downloads), every step logged and surfaced.
final class UpdateManager: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case updateAvailable(Int)
        case rebuildAvailable
        case updating(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private let queue = DispatchQueue(label: "com.cadenwarren.freespeech.update", qos: .userInitiated)
    private var sourcePath: String? {
        Bundle.main.object(forInfoDictionaryKey: "FSSourcePath") as? String
    }
    private var builtRevision: String {
        Bundle.main.object(forInfoDictionaryKey: "FSSourceRevision") as? String ?? "unknown"
    }

    var versionLine: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        return "v\(version) (\(String(builtRevision.prefix(7))))"
    }

    func check() {
        guard status != .checking, !isUpdating else { return }
        guard let source = validatedSource() else { return }
        setStatus(.checking)
        queue.async { [weak self] in
            guard let self else { return }
            Log.info("update check: fetching origin in \(source)")
            let fetch = self.git(["fetch", "--quiet", "origin"], in: source)
            if fetch.code != 0 {
                self.setStatus(.failed("Fetch failed: \(fetch.output.prefix(120))"))
                return
            }
            // No upstream configured counts as zero behind, not an error.
            let behindOut = self.git(["rev-list", "--count", "HEAD..@{upstream}"], in: source)
            let behind = behindOut.code == 0 ? Int(behindOut.output) ?? 0 : 0
            let head = self.git(["rev-parse", "HEAD"], in: source).output

            Log.info("update check: behind=\(behind), head=\(head.prefix(7)), built=\(self.builtRevision.prefix(7))")
            if behind > 0 {
                self.setStatus(.updateAvailable(behind))
            } else if head != self.builtRevision, !head.isEmpty {
                self.setStatus(.rebuildAvailable)
            } else {
                self.setStatus(.upToDate)
            }
        }
    }

    func updateAndRelaunch() {
        guard !isUpdating, let source = validatedSource() else { return }
        let pullFirst = { if case .updateAvailable = self.status { return true } else { return false } }()
        queue.async { [weak self] in
            guard let self else { return }
            if pullFirst {
                self.setStatus(.updating("Pulling changes\u{2026}"))
                let pull = self.git(["pull", "--ff-only"], in: source)
                if pull.code != 0 {
                    Log.error("update pull failed: \(pull.output)")
                    self.setStatus(.failed("Pull failed — local changes in the way? \(pull.output.prefix(100))"))
                    return
                }
            }
            self.setStatus(.updating("Building (runs tests, ~1 min)\u{2026}"))
            let build = self.run("/bin/bash", ["build.sh", "--skip-model"], in: source)
            if build.code != 0 {
                Log.error("update build failed: \(build.output.suffix(400))")
                self.setStatus(.failed("Build failed — see log for details"))
                return
            }
            Log.info("update build succeeded, relaunching")
            self.setStatus(.updating("Relaunching\u{2026}"))
            DispatchQueue.main.async {
                self.relaunch(appPath: "\(source)/dist/FreeKit.app")
            }
        }
    }

    private var isUpdating: Bool {
        if case .updating = status { return true }
        return false
    }

    private func validatedSource() -> String? {
        guard let source = sourcePath,
              FileManager.default.fileExists(atPath: "\(source)/.git") else {
            setStatus(.failed("This build has no source checkout recorded — update from the repo with ./build.sh"))
            return nil
        }
        return source
    }

    // The orphaned shell outlives our process and starts the fresh binary.
    private func relaunch(appPath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "sleep 1; open \"\(appPath)\""]
        do {
            try process.run()
        } catch {
            setStatus(.failed("Relaunch failed: \(error.localizedDescription) — reopen the app manually"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Log.info("terminating for update relaunch")
            NSApp.terminate(nil)
        }
    }

    private func setStatus(_ new: Status) {
        DispatchQueue.main.async { self.status = new }
    }

    private func git(_ args: [String], in cwd: String) -> (code: Int32, output: String) {
        run("/usr/bin/git", args, in: cwd)
    }

    private func run(_ tool: String, _ args: [String], in cwd: String) -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (process.terminationStatus, output)
    }
}
