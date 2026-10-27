import AppKit
import SwiftUI

/// Keeps the rule page's drive and app lists, and whether the rule is true right now, up to date
/// while the page is showing.
final class RuleMonitor: ObservableObject {
    static let refreshInterval: TimeInterval = 2

    @Published private(set) var snapshot = SystemSnapshot()
    /// Regular apps that are running, for the "App Is Running" picker.
    @Published private(set) var apps: [AppChoice] = []

    private var timer: Timer?
    private var isCapturing = false
    private let queue = DispatchQueue(label: "io.github.wakeful.rule-monitor")
    private let provider: (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot

    init(provider: @escaping (Set<RuleCondition.Kind>, Set<String>) -> SystemSnapshot = SystemSnapshot.capture) {
        self.provider = provider
    }

    deinit {
        timer?.invalidate()
    }

    func setActive(_ active: Bool) {
        timer?.invalidate()
        timer = nil
        guard active else { return }
        refresh()
        let timer = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app in app.bundleIdentifier.map { AppChoice(bundleID: $0, name: app.localizedName ?? $0) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if running != apps { apps = running }

        guard !isCapturing else { return }
        isCapturing = true
        let ids = SystemSnapshot.runningBundleIDs()
        let provider = provider
        queue.async { [weak self] in
            let snapshot = provider(Set(RuleCondition.Kind.allCases), ids)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                isCapturing = false
                if snapshot != self.snapshot { self.snapshot = snapshot }
            }
        }
    }
}

/// "While Custom Rule…": pick conditions, then start a session that lasts while they hold.
struct RulePage: View {
    @ObservedObject var manager: SessionManager
    @ObservedObject var settings: Settings
    let isVisible: Bool
    let onBack: () -> Void
    @StateObject private var monitor = RuleMonitor()

    private var rule: CustomRule { settings.customRule }
    private var isMet: Bool { rule.isMet(in: monitor.snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            PageHeader(title: "While Custom Rule", onBack: onBack)

            VStack(alignment: .leading, spacing: 8) {
                matchLine

                if rule.conditions.isEmpty {
                    Text("Add conditions below. Your Mac stays awake while they're true, and the session ends a few seconds after they stop being true.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(spacing: 6) {
                        ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                            conditionRow(condition, at: index)
                        }
                    }
                }

                addMenu

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: isMet ? "checkmark.circle.fill" : "circle.dashed")
                        .foregroundStyle(isMet ? Color.green : .secondary)
                    Text(statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Start") {
                        manager.start(.rule(rule))
                        onBack()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isMet)
                    .help(isMet ? "Keep your Mac awake while this rule is true"
                                : "The rule has to be true right now to start")
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .onAppear { monitor.setActive(isVisible) }
        .onChange(of: isVisible) { monitor.setActive($0) }
        .onDisappear { monitor.setActive(false) }
    }

    private var statusText: String {
        if rule.conditions.isEmpty { return "No conditions yet" }
        return isMet ? "True right now" : "Not true right now"
    }

    @ViewBuilder private var matchLine: some View {
        if rule.conditions.count > 1 {
            HStack(spacing: 4) {
                Text("Keep awake while")
                Picker("Match", selection: binding(\.match)) {
                    Text("all").tag(CustomRule.Match.all)
                    Text("any").tag(CustomRule.Match.any)
                }
                .labelsHidden()
                .fixedSize()
                Text("of these are true:")
            }
        } else {
            Text("Keep awake while this is true:")
        }
    }

    // MARK: - Conditions

    private func conditionRow(_ condition: RuleCondition, at index: Int) -> some View {
        let met = condition.isMet(in: monitor.snapshot)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: condition.kind.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(met ? Color.white : Color.primary)
                .frame(width: 22, height: 22)
                .background(Circle().fill(met ? Color.accentColor : Color.primary.opacity(0.12)))
                .help(met ? "True right now" : "Not true right now")
            VStack(alignment: .leading, spacing: 3) {
                Text(condition.kind.title)
                    .frame(minHeight: 22)
                choicePicker(for: condition, at: index)
            }
            Spacer(minLength: 0)
            Button {
                updateRule { $0.conditions.remove(at: index) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Remove this condition")
            .accessibilityLabel("Remove \(condition.kind.title)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityValue(met ? "True right now" : "Not true right now")
    }

    @ViewBuilder private func choicePicker(for condition: RuleCondition, at index: Int) -> some View {
        switch condition {
        case .externalDrive(let drive):
            drivePicker(kind: .external, anyTitle: "Any External Drive", choice: drive) { updated in
                updateRule { $0.conditions[index] = .externalDrive(updated) }
            }
        case .networkDrive(let share):
            drivePicker(kind: .network, anyTitle: "Any Network Drive", choice: share) { updated in
                updateRule { $0.conditions[index] = .networkDrive(updated) }
            }
        case .appRunning(let app):
            appPicker(choice: app) { updated in
                updateRule { $0.conditions[index] = .appRunning(updated) }
            }
        case .charger, .externalDisplay, .audioPlaying:
            EmptyView()
        }
    }

    private func drivePicker(kind: MountedVolume.Kind, anyTitle: String, choice: DriveChoice?,
                             onChange: @escaping (DriveChoice?) -> Void) -> some View {
        let volumes = Self.unique(monitor.snapshot.volumes.filter { $0.kind == kind })
        return Picker("Drive", selection: Binding<String?>(
            get: { choice?.id },
            set: { id in
                guard let id else { return onChange(nil) }
                if let volume = volumes.first(where: { $0.id == id }) {
                    onChange(DriveChoice(id: volume.id, name: volume.name))
                }
            }
        )) {
            Text(anyTitle).tag(String?.none)
            ForEach(volumes, id: \.id) { volume in
                Text(Self.label(for: volume)).tag(String?.some(volume.id))
            }
            if let choice, !volumes.contains(where: { $0.id == choice.id }) {
                Text("\(choice.name) (not connected)").tag(String?.some(choice.id))
            }
        }
        .labelsHidden()
        .frame(maxWidth: 190, alignment: .leading)
    }

    private func appPicker(choice: AppChoice, onChange: @escaping (AppChoice) -> Void) -> some View {
        let apps = monitor.apps
        return Picker("App", selection: Binding<String>(
            get: { choice.bundleID },
            set: { id in
                if let app = apps.first(where: { $0.bundleID == id }) { onChange(app) }
            }
        )) {
            ForEach(apps, id: \.bundleID) { app in
                Text(app.name).tag(app.bundleID)
            }
            if !apps.contains(where: { $0.bundleID == choice.bundleID }) {
                Text("\(choice.name) (not running)").tag(choice.bundleID)
            }
        }
        .labelsHidden()
        .frame(maxWidth: 190, alignment: .leading)
    }

    private var addMenu: some View {
        Menu {
            ForEach(RuleCondition.Kind.allCases, id: \.self) { kind in
                Button {
                    add(kind)
                } label: {
                    Label(kind.title, systemImage: kind.icon)
                }
                .disabled(kind == .appRunning && monitor.apps.isEmpty)
            }
        } label: {
            Label("Add Condition", systemImage: "plus.circle")
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(rule.conditions.count >= CustomRule.maxConditions)
    }

    private func add(_ kind: RuleCondition.Kind) {
        let condition: RuleCondition
        switch kind {
        case .externalDrive: condition = .externalDrive(nil)
        case .networkDrive: condition = .networkDrive(nil)
        case .charger: condition = .charger
        case .externalDisplay: condition = .externalDisplay
        case .audioPlaying: condition = .audioPlaying
        case .appRunning:
            guard let first = monitor.apps.first else { return }
            condition = .appRunning(first)
        }
        updateRule { rule in
            guard rule.conditions.count < CustomRule.maxConditions, !rule.conditions.contains(condition) else { return }
            rule.conditions.append(condition)
        }
    }

    // MARK: - Helpers

    private func updateRule(_ change: (inout CustomRule) -> Void) {
        var rule = settings.customRule
        change(&rule)
        settings.customRule = rule
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<CustomRule, Value>) -> Binding<Value> {
        Binding(get: { settings.customRule[keyPath: keyPath] },
                set: { value in updateRule { $0[keyPath: keyPath] = value } })
    }

    /// The same volume can be mounted twice (e.g. a share connected by name and by address).
    static func unique(_ volumes: [MountedVolume]) -> [MountedVolume] {
        var seen = Set<String>()
        return volumes.filter { seen.insert($0.id).inserted }
    }

    /// Network shares show their server too, since different servers often use the same share names.
    static func label(for volume: MountedVolume) -> String {
        guard volume.kind == .network,
              let host = volume.id.split(whereSeparator: { $0 == "/" || $0 == ":" }).first
        else { return volume.name }
        return "\(volume.name) on \(host)"
    }
}
