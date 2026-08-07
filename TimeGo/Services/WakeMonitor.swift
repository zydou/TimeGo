import AppKit

enum PresenceEvent: Sendable {
    case wake
    case unlock
    case lock
    case sleep
}

@MainActor
final class WakeMonitor {
    private var observers: [NSObjectProtocol] = []
    var onEvent: ((PresenceEvent) -> Void)?
    var onAbsence: ((PresenceEvent) -> Void)?

    func start() {
        stop()
        let center = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        observers.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?(.wake)
                }
            }
        )

        observers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onEvent?(.unlock)
                }
            }
        )

        observers.append(
            distributed.addObserver(
                forName: Notification.Name("com.apple.screenIsLocked"),
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onAbsence?(.lock)
                }
            }
        )

        observers.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor [weak self] in
                    self?.onAbsence?(.sleep)
                }
            }
        )
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
            distributed.removeObserver(observer)
        }
        observers.removeAll()
    }
}
