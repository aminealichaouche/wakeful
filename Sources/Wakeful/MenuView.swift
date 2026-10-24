import ServiceManagement
import SwiftUI

/// Which page and section of the menu are showing. Owned by the panel, which re-measures the menu
/// whenever they change.
final class MenuNavigation: ObservableObject {
    @Published var page: MenuView.Page = .main
    @Published var expanded: MenuView.Section?
    @Published var showsOptionHelp = false
}

/// The dropdown panel shown from the menu bar icon.
struct MenuView: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: Settings
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var navigation: MenuNavigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Section {
        case minutes, hours, custom, apps
    }

    enum Page {
        case main, settings
    }

    static let width: CGFloat = 300
    /// Also used for the panel's own resize, so the window and its content move together.
    static let animationDuration: TimeInterval = 0.22

    private static let minutePresets = [5, 10, 15, 30, 45]
    private static let hourPresets = [1, 2, 3, 4, 6, 8, 12, 24]

    /// Both pages sit side by side and slide horizontally. The hidden page gets zero layout height
    /// (it still draws, so it can slide out), so the menu's size always comes from the visible page.
    /// Nothing is clipped here: the panel's edges clip, and the panel animates its own height, so
    /// there's exactly one height animation and it stays in step with the window.
    var body: some View {
        let animation = Animation.easeInOut(duration: Self.animationDuration)
        HStack(alignment: .top, spacing: 0) {
            pageContainer(.main) { mainPage }
            pageContainer(.settings) {
                SettingsPage(manager: manager, settings: settings, updater: updater,
                             isVisible: page == .settings) { navigation.page = .main }
            }
        }
        .frame(width: Self.width * 2, alignment: .topLeading)
        .offset(x: page == .settings ? -Self.width : 0)
        .frame(width: Self.width, alignment: .topLeading)
        .animation(reduceMotion ? nil : animation, value: page)
        .animation(animation, value: navigation.expanded)
        .animation(animation, value: navigation.showsOptionHelp)
    }

    private func pageContainer<Content: View>(_ which: Page, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(8)
            .frame(width: Self.width)
            .fixedSize(horizontal: false, vertical: true)
            .frame(height: page == which ? nil : 0, alignment: .top)
            .opacity(page == which ? 1 : 0)
            .accessibilityHidden(page != which)
    }

    private var mainPage: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionCard(manager: manager)

            VStack(spacing: 0) {
                SectionTitle("Session Options")
                    .overlay(alignment: .trailing) {
                        InfoButton(isOn: $navigation.showsOptionHelp)
                    }
                ToggleRow(icon: "display", title: "Allow Display Sleep", isOn: settings.allowDisplaySleep,
                          detail: optionHelp("""
                              Lets the screen turn off as usual. The Mac itself stays awake, so downloads \
                              and other work keep running.
                              """)) {
                    settings.allowDisplaySleep.toggle()
                    manager.applyPowerSettings()
                }
                ToggleRow(icon: "laptopcomputer", title: "Allow Sleep When Lid Is Closed",
                          isOn: settings.allowSleepWhenDisplayClosed,
                          detail: optionHelp("""
                              Turn off to keep the Mac awake with the lid closed. The first time, \
                              Wakeful asks for your password once to allow this.
                              """)) {
                    manager.setAllowSleepWhenDisplayClosed(!settings.allowSleepWhenDisplayClosed)
                }
                ToggleRow(icon: "sparkles.tv",
                          title: "Allow Screen Saver After \(settings.screenSaverDelayMinutes)m",
                          isOn: settings.allowScreenSaver,
                          detail: optionHelp("""
                              Starts the screen saver after \(settings.screenSaverDelayMinutes) minutes \
                              without mouse or keyboard input, while the Mac stays awake. Change the delay \
                              in Settings.
                              """)) {
                    settings.allowScreenSaver.toggle()
                }
            }

            VStack(spacing: 0) {
                SectionTitle("Start New Session")
                ActionRow(icon: "infinity", title: "Indefinitely") {
                    manager.start(.manual(until: nil))
                }
                ExpandableRow(icon: "timer", title: "Minutes", section: .minutes, expanded: $navigation.expanded) {
                    ChipRow(values: Self.minutePresets, columns: 5, label: { "\($0)m" }) { start(minutes: $0) }
                }
                ExpandableRow(icon: "clock", title: "Hours", section: .hours, expanded: $navigation.expanded) {
                    ChipRow(values: Self.hourPresets, columns: 4, label: { "\($0)h" }) { start(minutes: $0 * 60) }
                }
                ExpandableRow(icon: "calendar.badge.clock", title: "Other Time/Until", section: .custom,
                              expanded: $navigation.expanded) {
                    CustomTimePanel(manager: manager)
                }
                ExpandableRow(icon: "app.badge", title: "While App Is Running", section: .apps,
                              expanded: $navigation.expanded) {
                    RunningAppsList { manager.start(.app($0)) }
                }
                ActionRow(icon: "arrow.down.circle", title: "While File Is Downloading…") {
                    if let url = Dialogs.askDownloadFile() {
                        manager.start(.download(DownloadWatcher(url: url)))
                    }
                }
            }

            Divider().padding(.horizontal, 6)

            NavigationRow(icon: "gearshape", title: "Settings") { navigation.page = .settings }

            HStack(spacing: 8) {
                UpdateButton(updater: updater)
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
    }

    private var page: Page { navigation.page }

    private func optionHelp(_ text: String) -> String? {
        navigation.showsOptionHelp ? text : nil
    }

    private func start(minutes: Int) {
        manager.start(.manual(until: Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }
}

// MARK: - Settings page

/// Second page with a back button, slid in from the right.
private struct SettingsPage: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: Settings
    let updater: UpdateChecker
    let isVisible: Bool
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onBack) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    Text("Settings").font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(height: 26)
            }
            .buttonStyle(RowButtonStyle())
            .accessibilityLabel("Back")

            SettingsPanel(manager: manager, settings: settings, updater: updater, isVisible: isVisible)
                .padding(.horizontal, 6)
        }
    }
}

// MARK: - Session card

/// Header card with the session status and an on/off switch, like BetterDisplay's display cards.
private struct SessionCard: View {
    @ObservedObject var manager: SessionManager
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Everything but the switch is one big button that does the same as the switch.
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: manager.isActive ? StatusIcon.active : StatusIcon.inactive)
                        .renderingMode(.template)
                        .foregroundStyle(manager.isActive ? Color.accentColor : .secondary)
                        .frame(width: 22, height: 22)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wakeful")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.primary)
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
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(manager.isActive ? "End Wakeful session" : "Start Wakeful session")

            Toggle("Session active", isOn: Binding(
                get: { manager.isActive },
                set: { $0 ? manager.start(.manual(until: nil)) : manager.end() }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.primary.opacity(isHovering ? 0.11 : 0.07)))
        .onHover { isHovering = $0 }
    }

    private func toggle() {
        manager.isActive ? manager.end() : manager.start(.manual(until: nil))
    }
}

// MARK: - Footer

/// "Check for Updates" pill. Checking and the result play out inside the pill: the arrows spin,
/// then the label rolls over to the result and, unless an update was found, back again.
private struct UpdateButton: View {
    @ObservedObject var updater: UpdateChecker
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                icon.frame(width: 12, height: 12)
                Text(title).lineLimit(1)
            }
            .foregroundStyle(tint ?? .primary)
            .id(title)
            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .move(edge: .top).combined(with: .opacity)))
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill((tint ?? .primary).opacity(isHovering ? 0.22 : tint == nil ? 0.1 : 0.15)))
            .clipShape(Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: updater.status)
        .accessibilityLabel(title)
    }

    private func action() {
        switch updater.status {
        case .checking: break
        case .available: updater.openReleasePage()
        case .idle, .upToDate, .failed: updater.checkNow()
        }
    }

    @ViewBuilder private var icon: some View {
        switch updater.status {
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath")
        case .checking:
            TimelineView(.animation) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
                Image(systemName: "arrow.triangle.2.circlepath").rotationEffect(.degrees(turn * 360))
            }
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
        case .available:
            Image(systemName: "arrow.down.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        }
    }

    private var title: String {
        switch updater.status {
        case .idle: return "Check for Updates"
        case .checking: return "Checking…"
        case .upToDate: return "Up to Date!"
        case .available(let version): return "Update to \(version)"
        case .failed: return "Couldn't Check"
        }
    }

    private var tint: Color? {
        switch updater.status {
        case .idle, .checking: return nil
        case .upToDate: return .green
        case .available: return .accentColor
        case .failed: return .orange
        }
    }

    private var help: String {
        switch updater.status {
        case .available(let version): return "Open the Wakeful \(version) release page on GitHub"
        case .upToDate: return "Wakeful \(updater.currentVersion) is the latest version"
        case .failed(let reason): return reason
        case .idle, .checking: return "Check GitHub for a newer version of Wakeful"
        }
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
    let updater: UpdateChecker
    /// The page stays rendered while hidden, so its state is refreshed each time it slides in.
    let isVisible: Bool
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
            SwitchRow(title: "Check for Updates Automatically", isOn: Binding(
                get: { settings.checkForUpdatesAutomatically },
                set: {
                    settings.checkForUpdatesAutomatically = $0
                    updater.setAutomaticChecks($0)
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
        .onAppear(perform: refresh)
        .onChange(of: isVisible) { if $0 { refresh() } }
    }

    private func refresh() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        helperInstalled = ClosedDisplayGuard.isHelperInstalled
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
