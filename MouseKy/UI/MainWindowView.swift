import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct MainWindowView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var profileSheet: ProfileSheet?
    @State private var isConfirmingDeletion = false

    private enum ProfileSheet: Identifiable {
        case create
        case rename(MouseProfile)

        var id: String {
            switch self {
            case .create: "create"
            case let .rename(profile): "rename-\(profile.id)"
            }
        }
    }

    private enum SidebarItem: Hashable {
        case device(String)
        case profile(UUID)
    }

    var body: some View {
        ZStack {
            NavigationSplitView {
                sidebar
                    .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 310)
            } detail: {
                detail
            }

            if !permissions.hasRequiredPermissions {
                PermissionRequiredOverlay()
            }
        }
        .navigationTitle("MouseKy")
        .task {
            while !Task.isCancelled {
                updatePermissionState()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $profileSheet) { sheet in
            switch sheet {
            case .create:
                ProfileEditorSheet(
                    title: "New Profile",
                    initialName: "",
                    allowsCopy: true
                ) { name, copyCurrent in
                    model.createProfile(name: name, copyingActiveProfile: copyCurrent)
                }
            case let .rename(profile):
                ProfileEditorSheet(
                    title: "Rename Profile",
                    initialName: profile.name,
                    allowsCopy: false
                ) { name, _ in
                    model.renameActiveProfile(to: name)
                }
            }
        }
        .confirmationDialog(
            "Delete Profile?",
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Profile", role: .destructive) {
                model.deleteActiveProfile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All shortcut mappings in this profile will be deleted. The Default profile remains available.")
        }
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Text("Devices")
            if model.hidDevices.mice.isEmpty {
                Text("No compatible mice found")
            } else {
                ForEach(model.hidDevices.mice) { mouse in
                    Label {
                        Text(mouse.name)
                    } icon: {
                        Image(systemName: "computermouse")
                            .foregroundStyle(sidebarIconColor)
                    }
                        .tag(SidebarItem.device(mouse.id))
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Button("Scan Mice") {
                model.refreshMice()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
    }

    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(
            get: {
                guard let deviceID = model.configuration.selectedDeviceID else { return nil }
                return .device(deviceID)
            },
            set: { selection in
                switch selection {
                case let .device(id):
                    if let mouse = model.hidDevices.mice.first(where: { $0.id == id }) {
                        model.selectDevice(mouse)
                    }
                case .profile:
                    break
                case nil:
                    break
                }
            }
        )
    }

    private var sidebarIconColor: Color {
        colorScheme == .dark ? .white : .primary
    }

    @ViewBuilder
    private var detail: some View {
        if let device = model.selectedDevice, let profile = model.selectedProfile {
            ProfileDetailView(
                device: device,
                profile: profile,
                onCreate: { profileSheet = .create },
                onRename: { profileSheet = .rename(profile) },
                onDelete: { isConfirmingDeletion = true }
            )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "computermouse")
                Text("Select a Mouse")
                Text("Connect a mouse and select it in the sidebar.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func updatePermissionState() {
        permissions.refresh()
        if permissions.hasRequiredPermissions {
            _ = model.startEventTap()
        } else {
            model.stopEventTap()
        }
    }
}

private struct PermissionRequiredOverlay: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Label("MouseKy needs permission", systemImage: "lock.trianglebadge.exclamationmark")
                    .font(.title2.bold())

                Text("Grant the missing permissions in System Settings before MouseKy can detect mouse buttons and trigger shortcuts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(permissions.missingPermissions) { permission in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(permission.title)
                                    .fontWeight(.semibold)
                                Text(permission.description)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button("Request Permission") {
                                permissions.request(permission)
                                permissions.openSettings(for: permission)
                            }
                        }
                    }
                }

                HStack {
                    Button("Check Again") {
                        checkPermissions()
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .shadow(radius: 20)
            .padding(32)
        }
        .accessibilityAddTraits(.isModal)
    }

    private func checkPermissions() {
        permissions.refresh()
        if permissions.hasRequiredPermissions {
            _ = model.startEventTap()
        }
    }
}

private struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    @State private var pendingAssignment: PendingAssignment?
    @State private var isShowingAddMenu = false
    @State private var isConfirmingOnboardClear = false
    let device: MouseDeviceConfiguration
    let profile: MouseProfile
    let onCreate: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Form {
            Section("Device") {
                LabeledContent("Name", value: device.name)
                LabeledContent(
                    "Manufacturer",
                    value: connectedMouse?.manufacturer ?? "Unknown"
                )
                LabeledContent(
                    "Connection",
                    value: connectedMouse?.connection ?? "Disconnected"
                )
                if supportsC08DOnboardMemory {
                    LabeledContent(
                        "Onboard Shortcuts",
                        value: "\(model.onboardShortcutCount)"
                    )
                    Button("Clear Onboard Shortcuts", role: .destructive) {
                        isConfirmingOnboardClear = true
                    }
                    .disabled(!model.canResetOnboardProfile || model.onboardShortcutCount == 0)
                }
            }

            Section("Profile") {
                HStack {
                    Picker("Profile", selection: Binding(
                        get: { device.selectedProfileID },
                        set: { model.selectProfile($0) }
                    )) {
                        ForEach(device.profiles) { profile in
                            Text(profile.name).tag(profile.id)
                        }
                    }
                    Button(action: onCreate) {
                        Image(systemName: "plus")
                    }
                    .help("Add Profile")
                }
                HStack {
                    if !profile.isDefault {
                        Button("Set as Default") {
                            model.setSelectedProfileAsDefault()
                        }
                    }
                    Button("Rename", action: onRename)
                    if !profile.isDefault {
                        Button("Delete", role: .destructive, action: onDelete)
                    }
                }
            }
            Section("Apps") {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.flexible(minimum: 56), spacing: 16),
                        count: 6
                    ),
                    alignment: .center,
                    spacing: 12
                ) {
                    if profile.isDefault {
                        AllAppsIcon()
                    }
                        ForEach(profile.appBundleIdentifiers, id: \.self) { bundleID in
                            AppAssignmentIcon(bundleIdentifier: bundleID) {
                                model.removeApplication(bundleIdentifier: bundleID)
                            }
                        }
                        Button {
                            isShowingAddMenu = true
                        } label: {
                            VStack(spacing: 5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(.quaternary)
                                    RoundedRectangle(cornerRadius: 13)
                                        .strokeBorder(.tertiary)
                                    Image(systemName: "plus")
                                        .font(.system(size: 30, weight: .medium))
                                }
                                .frame(width: 56, height: 56)
                                Text("Add")
                                    .font(.caption)
                                    .lineLimit(1)
                                    .frame(width: 72)
                            }
                        }
                        .buttonStyle(.plain)
                        .help("Add App")
                        .popover(isPresented: $isShowingAddMenu, arrowEdge: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 2) {
                                        ForEach(runningApplications) { application in
                                            Button(application.name) {
                                                assign(application.bundleIdentifier)
                                                isShowingAddMenu = false
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                        }
                                    }
                                }
                                .frame(maxHeight: 240)
                                Divider()
                                Button("Use Globally") {
                                    model.setSelectedProfileAsDefault()
                                    isShowingAddMenu = false
                                }
                                .disabled(profile.isDefault)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                Button("Add More Apps…") {
                                    isShowingAddMenu = false
                                    chooseApplications()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .frame(minWidth: 220)
                            .padding(6)
                        }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
            }
            Section("Shortcut Mappings") {
                ForEach(model.visibleMappings(for: profile).filter {
                    !$0.isPrimaryButton && model.control(for: $0)?.isPrimary != true
                }) { mapping in
                    MappingRow(mapping: mapping)
                }
                if case let .failed(message) = model.backendStatus {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if case let .unsupported(message) = model.backendStatus {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if model.shouldShowButtonScan {
                Section {
                    Button(model.scanner.isScanning ? "Finish Button Scan" : "Scan Buttons") {
                        model.scanner.isScanning ? model.stopScan() : model.startScan()
                    }
                }
            }

            if let error = model.saveError {
                Section {
                    Text(error)
                }
            }
        }
        .formStyle(.grouped)
        .buttonStyle(.bordered)
        .navigationTitle(device.name)
        .confirmationDialog(
            "Move App Assignment?",
            isPresented: Binding(
                get: { pendingAssignment != nil },
                set: { if !$0 { pendingAssignment = nil } }
            ),
            presenting: pendingAssignment
        ) { assignment in
            Button("Move from “\(assignment.sourceProfileName)”") {
                model.assignApplication(
                    bundleIdentifier: assignment.bundleIdentifier,
                    confirmMove: true
                )
                pendingAssignment = nil
            }
            Button("Cancel", role: .cancel) {
                pendingAssignment = nil
            }
        } message: { assignment in
            Text("This app is already assigned to the “\(assignment.sourceProfileName)” profile.")
        }
        .confirmationDialog(
            "Clear Onboard Shortcuts?",
            isPresented: $isConfirmingOnboardClear
        ) {
            Button("Clear Onboard Shortcuts", role: .destructive) {
                model.clearOnboardShortcuts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only keyboard and media assignments will be removed. Mouse, DPI, and device functions remain unchanged.")
        }
    }

    private var connectedMouse: ConnectedMouse? {
        model.hidDevices.mice.first { $0.id == device.id }
    }

    private var supportsC08DOnboardMemory: Bool {
        device.identifier.vendorID == G502OnboardMemoryService.logitechVendorID &&
            device.identifier.productID == G502OnboardMemoryService.g502C08DProductID
    }

    private var runningApplications: [RunningApplication] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular,
                  let bundleIdentifier = application.bundleIdentifier,
                  let normalized = MouseProfile.normalizeBundleIdentifier(bundleIdentifier),
                  normalized != MouseProfile.normalizeBundleIdentifier(Bundle.main.bundleIdentifier ?? "")
            else { return nil }
            return RunningApplication(
                bundleIdentifier: normalized,
                name: application.localizedName ?? normalized
            )
        }
        .reduce(into: [String: RunningApplication]()) { $0[$1.bundleIdentifier] = $1 }
        .values
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func chooseApplications() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let bundleIdentifier = Bundle(url: url)?.bundleIdentifier {
                assign(bundleIdentifier)
            }
        }
    }

    private func assign(_ bundleIdentifier: String) {
        switch model.assignApplication(bundleIdentifier: bundleIdentifier) {
        case .assigned, .invalid:
            break
        case let .requiresConfirmation(sourceProfileName):
            pendingAssignment = PendingAssignment(
                bundleIdentifier: bundleIdentifier,
                sourceProfileName: sourceProfileName
            )
        }
    }
}

private struct PendingAssignment: Identifiable {
    let bundleIdentifier: String
    let sourceProfileName: String
    var id: String { bundleIdentifier }
}

private struct RunningApplication: Identifiable {
    let bundleIdentifier: String
    let name: String
    var id: String { bundleIdentifier }
}

private struct AppAssignmentIcon: View {
    let bundleIdentifier: String
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 5) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            Text(displayName)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 72)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove", role: .destructive, action: onRemove)
        }
        .help(bundleIdentifier)
    }

    private var displayName: String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleIdentifier
    }

    private var icon: NSImage {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
        else { return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage() }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

private struct AllAppsIcon: View {
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                RoundedRectangle(cornerRadius: 13)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white)
            }
            .frame(width: 56, height: 56)
            Text("All Apps")
                .font(.caption)
                .lineLimit(1)
                .frame(width: 72)
        }
        .help("All apps without an explicit assignment")
    }
}

private struct MappingRow: View {
    @EnvironmentObject private var model: AppModel
    let mapping: MouseMapping

    var body: some View {
        let control = model.control(for: mapping)
        let isPrimary = control?.isPrimary ?? mapping.isPrimaryButton
        let isRecentlyPressed = model.wasRecentlyPressed(mapping.controlID)
        HStack {
            Text(model.displayName(for: mapping))
                .foregroundStyle(isRecentlyPressed ? .green : .primary)
            Spacer()
            if !isPrimary {
                if model.isBlockedByOnboardAssignment(mapping.controlID) {
                    Label(
                        "Clear Onboard Assignment First",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                } else if model.recordingControlID == mapping.controlID {
                    Button("Press shortcut…") {
                        model.recorder.cancel()
                        model.recordingButton = nil
                        model.recordingControlID = nil
                    }
                    .focusable(false)
                } else if let shortcut = mapping.shortcut {
                    Button(shortcut.displayName) {
                        model.startRecording(controlID: mapping.controlID)
                    }
                    .focusable(false)
                    Button(role: .destructive) {
                        model.setAction(.passthrough, for: mapping.controlID)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                } else {
                    Button("Record Shortcut") {
                        model.startRecording(controlID: mapping.controlID)
                    }
                    .focusable(false)
                }
            }
        }
    }
}

private struct ProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let allowsCopy: Bool
    let onSave: (String, Bool) -> Bool
    @State private var name: String
    @State private var copyCurrent = true

    init(
        title: String,
        initialName: String,
        allowsCopy: Bool,
        onSave: @escaping (String, Bool) -> Bool
    ) {
        self.title = title
        self.allowsCopy = allowsCopy
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.title2.bold())
            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
            if allowsCopy {
                Toggle("Copy current profile", isOn: $copyCurrent)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if onSave(name, allowsCopy && copyCurrent) {
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .buttonStyle(.bordered)
    }
}
