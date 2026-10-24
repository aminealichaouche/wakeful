import ServiceManagement
import SwiftUI

/// The dropdown panel shown from the menu bar icon.
struct MenuView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: Settings
    @State private var expanded: Section?

    enum Section {
        case minutes, hours, custom, apps, settings
    }

    private static let minutePresets = [5, 10, 15, 30, 45]
    private static let hourPresets = [1, 2, 3, 4, 6, 8, 12, 24]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionCard(manager: manager)

            VStack(spacing: 0) {
                SectionTitle("Session Options")
                ToggleRow(icon: "display", title: "Allow Display Sleep", isOn: settings.allowDisplaySleep) {
                    settings.allowDisplaySleep.toggle()
                    manager.applyPowerSettings()
                }
                ToggleRow(icon: "laptopcomputer", title: "Allow Sleep When Lid Is Closed",
                          isOn: settings.allowSleepWhenDisplayClosed) {
                    manager.setAllowSleepWhenDisplayClosed(!settings.allowSleepWhenDisplayClosed)
                }
                ToggleRow(icon: "sparkles.tv",
                          title: "Allow Screen Saver After \(settings.screenSaverDelayMinutes)m",
                          isOn: settings.allowScreenSaver) {
                    settings.allowScreenSaver.toggle()
                }
            }

            VStack(spacing: 0) {
                SectionTitle("Start New Session")
                ActionRow(icon: "infinity", title: "Indefinitely") {
                    manager.start(.manual(until: nil))
                }
                ExpandableRow(icon: "timer", title: "Minutes", section: .minutes, expanded: $expanded) {
                    ChipRow(values: Self.minutePresets, columns: 5, label: { "\($0)m" }) { start(minutes: $0) }
                }
                ExpandableRow(icon: "clock", title: "Hours", section: .hours, expanded: $expanded) {
                    ChipRow(values: Self.hourPresets, columns: 4, label: { "\($0)h" }) { start(minutes: $0 * 60) }
                }
                ExpandableRow(icon: "calendar.badge.clock", title: "Other Time/Until", section: .custom,
                              expanded: $expanded) {
                    CustomTimePanel(manager: manager)
                }
                ExpandableRow(icon: "app.badge", title: "While App Is Running", section: .apps,
                              expanded: $expanded) {
                    RunningAppsList { manager.start(.app($0)) }
                }
                ActionRow(icon: "arrow.down.circle", title: "While File Is Downloading…") {
                    if let url = Dialogs.askDownloadFile() {
                        manager.start(.download(DownloadWatcher(url: url)))
                    }
                }
            }

            Divider().padding(.horizontal, 6)

            ExpandableRow(icon: "gearshape", title: "Settings", section: .settings, expanded: $expanded) {
                SettingsPanel(manager: manager, settings: settings)
            }

            HStack(spacing: 8) {
                Spacer()
                CircleButton(icon: "info", help: "About Wakeful") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .credits: NSAttributedString(string: "An open-source app that keeps your Mac awake."),
                    ])
                }
                CircleButton(icon: "xmark", help: "Quit Wakeful") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(8)
        .frame(width: 300)
        .animation(.easeInOut(duration: 0.15), value: expanded)
    }

    private func start(minutes: Int) {
        manager.start(.manual(until: Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }
}

// MARK: - Session card

/// Header card with the session status and an on/off switch, like BetterDisplay's display cards.
private struct SessionCard: View {
    @ObservedObject var manager: SessionManager

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: manager.isActive ? StatusIcon.active : StatusIcon.inactive)
                .renderingMode(.template)
                .foregroundStyle(manager.isActive ? Color.accentColor : .secondary)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wakeful").font(.system(size: 13, weight: .semibold))
                if let session = manager.session {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(session.remainingDescription)
                            .monospacedDigit()
                    }
                    Text(session.triggerDescription)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Inactive")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Toggle("Session active", isOn: Binding(
                get: { manager.isActive },
                set: { $0 ? manager.start(.manual(until: nil)) : manager.end() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.primary.opacity(0.07)))
    }
}

// MARK: - Expandable sections

private struct CustomTimePanel: View {
    @ObservedObject var manager: SessionManager
    @State private var hours = 1
    @State private var minutes = 0
    @State private var until = Date().addingTimeInterval(60 * 60)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("For").frame(width: 34, alignment: .leading)
                Stepper("\(hours)h", value: $hours, in: 0...99)
                Stepper("\(minutes)m", value: $minutes, in: 0...55, step: 5)
                Spacer(minLength: 0)
                Button("Start") {
                    let duration = TimeInterval(hours * 3600 + minutes * 60)
                    manager.start(.manual(until: Date().addingTimeInterval(duration)))
                }
                .disabled(hours == 0 && minutes == 0)
            }
            HStack(spacing: 6) {
                Text("Until").frame(width: 34, alignment: .leading)
                DatePicker("Until", selection: $until, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                Spacer(minLength: 0)
                Button("Start") {
                    manager.start(.manual(until: until))
                }
                .disabled(until <= Date())
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.vertical, 4)
    }
}

private struct RunningAppsList: View {
    let onSelect: (NSRunningApplication) -> Void
    @State private var apps: [NSRunningApplication] = []

    private static let rowHeight: CGFloat = 24

    var body: some View {
        Group {
            if apps.isEmpty {
                Text("No apps running")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(apps, id: \.processIdentifier) { app in
                            Button { onSelect(app) } label: {
                                HStack(spacing: 8) {
                                    Image(nsImage: app.icon ?? NSImage())
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                    Text(app.localizedName ?? app.bundleIdentifier ?? "Unknown")
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .frame(height: Self.rowHeight)
                            }
                            .buttonStyle(RowButtonStyle())
                        }
                    }
                }
                .frame(height: min(CGFloat(apps.count) * Self.rowHeight, 200))
            }
        }
        .onAppear { apps = Self.runningApps() }
    }

    private static func runningApps() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .sorted {
                ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending
            }
    }
}

private struct SettingsPanel: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: Settings
    @State private var launchAtLogin = false
    @State private var helperInstalled = false

    private static let screenSaverDelays = [5, 10, 15, 30, 45, 60]
    private static let batteryThresholds = [0, 10, 20, 30, 50]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwitchRow(title: "Launch at Login", isOn: Binding(
                get: { launchAtLogin },
                set: { setLaunchAtLogin($0) }
            ))
            SwitchRow(title: "Start Session When Wakeful Opens", isOn: Binding(
                get: { settings.startSessionAtLaunch },
                set: { settings.startSessionAtLaunch = $0 }
            ))
            SwitchRow(title: "Notify When Session Ends", isOn: Binding(
                get: { settings.notifyWhenSessionEnds },
                set: {
                    settings.notifyWhenSessionEnds = $0
                    if $0 { Notifier.requestAuthorization() }
                }
            ))

            HStack {
                Text("Screen Saver Delay")
                Spacer()
                Picker("Screen Saver Delay", selection: Binding(
                    get: { settings.screenSaverDelayMinutes },
                    set: { settings.screenSaverDelayMinutes = $0 }
                )) {
                    ForEach(Self.screenSaverDelays, id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            HStack {
                Text("End on Low Battery")
                Spacer()
                Picker("End on Low Battery", selection: Binding(
                    get: { settings.lowBatteryThreshold },
                    set: { settings.lowBatteryThreshold = $0 }
                )) {
                    ForEach(Self.batteryThresholds, id: \.self) { Text($0 == 0 ? "Never" : "Below \($0)%").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }

            if helperInstalled {
                Button("Remove Closed-Display Helper…") {
                    if manager.removeClosedDisplayHelper() == .failed {
                        Dialogs.showError("The closed-display helper couldn't be removed. Nothing was changed.")
                    }
                    helperInstalled = ClosedDisplayGuard.isHelperInstalled
                }
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(.vertical, 4)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            helperInstalled = ClosedDisplayGuard.isHelperInstalled
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Dialogs.showError("Couldn't change Launch at Login: \(error.localizedDescription)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
