import AppKit
import CoreAudio
import IOKit.ps

/// Calls `onChange` as soon as something custom rules look at changes, so rules react right away
/// instead of at the next poll: drives and shares mounting or unmounting, apps launching or
/// quitting, the power source changing, displays being connected, and audio starting or stopping.
final class SystemChangeMonitor {
    private let onChange: () -> Void
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var audioListener: AudioObjectPropertyListenerBlock?
    private var audioDevices: [AudioDeviceID] = []
    private(set) var isRunning = false

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observeNotifications()
        observePowerSource()
        observeAudio()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        stopObservingAudio()
    }

    private func changed() {
        guard isRunning else { return }
        onChange()
    }

    // MARK: - Volumes, apps and displays

    private func observeNotifications() {
        let workspace = NSWorkspace.shared.notificationCenter
        let workspaceEvents: [Notification.Name] = [
            NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
            NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in workspaceEvents {
            observers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.changed()
            }))
        }
        let local = NotificationCenter.default
        observers.append((local, local.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                   object: nil, queue: .main) { [weak self] _ in
            self?.changed()
        }))
    }

    // MARK: - Power source

    private func observePowerSource() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<SystemChangeMonitor>.fromOpaque(context).takeUnretainedValue().changed()
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
    }

    // MARK: - Audio

    private static var devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    /// Listens for each output device starting or stopping, and for devices coming and going
    /// (headphones, AirPlay), re-listening to the new set when they do.
    private func observeAudio() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, isRunning else { return }
            listenToDevices()
            changed()
        }
        audioListener = listener
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, listener)
        listenToDevices()
    }

    private func listenToDevices() {
        guard let audioListener else { return }
        let devices = AudioOutput.devices()
        guard devices != audioDevices else { return }
        for device in audioDevices {
            AudioObjectRemovePropertyListenerBlock(device, &Self.runningAddress, .main, audioListener)
        }
        for device in devices {
            AudioObjectAddPropertyListenerBlock(device, &Self.runningAddress, .main, audioListener)
        }
        audioDevices = devices
    }

    private func stopObservingAudio() {
        guard let audioListener else { return }
        for device in audioDevices {
            AudioObjectRemovePropertyListenerBlock(device, &Self.runningAddress, .main, audioListener)
        }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.devicesAddress, .main, audioListener)
        audioDevices = []
        self.audioListener = nil
    }
}
