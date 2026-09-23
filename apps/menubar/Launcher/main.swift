import Darwin
import Foundation

private final class ChildSignalForwarder: @unchecked Sendable {
    private let lock = NSLock()
    private var child: Process?
    private var pendingSignal: Int32?

    func attach(_ child: Process) {
        lock.lock()
        self.child = child
        let signalNumber = pendingSignal
        pendingSignal = nil
        let pid = child.processIdentifier
        lock.unlock()
        if let signalNumber {
            _ = Darwin.kill(pid, signalNumber)
        }
    }

    func forward(_ signalNumber: Int32) {
        lock.lock()
        guard let child, child.isRunning else {
            pendingSignal = signalNumber
            lock.unlock()
            return
        }
        let pid = child.processIdentifier
        lock.unlock()
        _ = Darwin.kill(pid, signalNumber)
    }
}

// A native bundle executable gives macOS a signed application identity. The
// existing service supervisor still owns shutdown, locking and child recovery.
guard let resources = Bundle.main.resourceURL else {
    fputs("Wonder resources are missing.\n", stderr)
    exit(1)
}
let script = resources.appendingPathComponent("WonderService.sh").path
let child = Process()
child.executableURL = URL(fileURLWithPath: "/bin/bash")
child.arguments = [script] + Array(CommandLine.arguments.dropFirst())
var environment = ProcessInfo.processInfo.environment
environment["WONDER_APP_LAUNCHER_PID"] = String(getpid())
child.environment = environment

// Keep the signed native executable as the LaunchServices responsible process.
// Process inherits the launch environment and the standard streams when these
// properties are left unset.
let signalQueue = DispatchQueue(label: "com.saimun.wonder.launcher-signals")
let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
private let signalForwarder = ChildSignalForwarder()

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
termSource.setEventHandler { signalForwarder.forward(SIGTERM) }
intSource.setEventHandler { signalForwarder.forward(SIGINT) }
termSource.resume()
intSource.resume()

do {
    try child.run()
    signalForwarder.attach(child)
} catch {
    termSource.cancel()
    intSource.cancel()
    fputs("Could not start Wonder: \(error)\n", stderr)
    exit(1)
}

child.waitUntilExit()
termSource.cancel()
intSource.cancel()

switch child.terminationReason {
case .exit:
    exit(child.terminationStatus)
case .uncaughtSignal:
    exit(128 + child.terminationStatus)
@unknown default:
    exit(1)
}
