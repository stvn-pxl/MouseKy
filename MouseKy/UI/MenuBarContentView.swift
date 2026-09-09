import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

    private var panelMaxHeight: CGFloat {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        return min(visibleHeight - 48, 720)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("MouseKy").font(.headline)
                PermissionStatusView()
                Divider()
                HStack {
                    Text("Mice").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Scan Mice") { model.refreshMice() }
                        .focusable(false)
                }
                if model.hidDevices.mice.isEmpty {
                    Text("No compatible pointing devices found. Connect a mouse, then scan again.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.hidDevices.mice) { mouse in
                        Button {
                            model.addProfile(for: mouse)
                        } label: {
                            HStack {
                                Image(systemName: model.configuration.activeProfileID == mouse.id ? "checkmark.circle.fill" : "circle")
                                Text(mouse.name)
                                Spacer()
                                if let buttons = model.hidDevices.declaredButtonNumbersByMouseID[mouse.id] {
                                    Text("\(buttons.count) HID buttons")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Text(String(format: "%04X:%04X", mouse.identifier.vendorID, mouse.identifier.productID))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                    }
                }
                if let profile = model.activeProfile {
                    Divider()
                    HStack {
                        Text("Shortcut Mappings")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Text("\(model.visibleMappings(for: profile).count) buttons")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ShortcutMappingsView(
                        profile: profile
                    )
                } else {
                    Text("Select a mouse to create a profile.").foregroundStyle(.secondary)
                }
                if let error = model.saveError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Divider()
                Button("Quit MouseKy") { NSApplication.shared.terminate(nil) }
                    .focusable(false)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 390)
        .frame(maxHeight: panelMaxHeight)
        .task { permissions.refresh() }
    }
}

private struct ShortcutMappingsView: View {
    @EnvironmentObject private var model: AppModel
    let profile: MouseProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            onboardStatus
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.visibleMappings(for: profile)) { mapping in
                    MappingRow(mapping: mapping)
                }
            }
            if model.onboardSnapshot == nil,
               profile.identifier.productID != G502OnboardMemoryService.g502C08DProductID {
                Button(model.scanner.isScanning ? "Finish Scan" : "Scan Buttons") {
                    model.scanner.isScanning ? model.stopScan() : model.startScan()
                }
                .focusable(false)
            }
        }
    }

    @ViewBuilder
    private var onboardStatus: some View {
        if profile.identifier.vendorID == G502OnboardMemoryService.logitechVendorID,
           profile.identifier.productID == G502OnboardMemoryService.g502C08DProductID {
            Group {
                switch model.onboardStatus {
                case .probing, .readOnly:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading onboard profile…")
                    }
                    .foregroundStyle(.secondary)
                case let .failed(message):
                    Text(message).foregroundStyle(.red)
                case .backupReady, .verified:
                    Text("Onboard profile loaded")
                        .foregroundStyle(.green)
                default:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Loading onboard profile…")
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .frame(height: 18, alignment: .leading)
        }
    }
}

private struct MappingRow: View {
    @EnvironmentObject private var model: AppModel
    let mapping: MouseMapping

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName(for: mapping))
                if mapping.isPrimaryButton {
                    Text("Protected system button").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if mapping.isPrimaryButton {
                Text("Not remappable").foregroundStyle(.secondary)
            } else if model.recordingButton == mapping.buttonNumber {
                Button("Press shortcut…") { model.recorder.cancel(); model.recordingButton = nil }
                    .focusable(false)
            } else if let shortcut = model.displayedShortcut(for: mapping.buttonNumber) {
                Button(shortcut.displayName) { model.startRecording(button: mapping.buttonNumber) }
                    .focusable(false)
                Button(role: .destructive) { model.clearShortcut(button: mapping.buttonNumber) } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .help("Restore system default")
            } else {
                Button("Record Shortcut") { model.startRecording(button: mapping.buttonNumber) }
                    .focusable(false)
            }
        }
    }
}

private struct PermissionStatusView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var permissions: PermissionManager

    var body: some View {
        if permissions.hasRequiredPermissions {
            Label("Input permissions granted", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("Input permissions required").foregroundStyle(.orange)
                Label(
                    "Accessibility: \(permissions.accessibilityGranted ? "granted" : "missing")",
                    systemImage: permissions.accessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(permissions.accessibilityGranted ? .green : .red)
                Label(
                    "Input Monitoring: \(permissions.inputMonitoringGranted ? "granted" : "missing")",
                    systemImage: permissions.inputMonitoringGranted ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(permissions.inputMonitoringGranted ? .green : .red)
                Text("After granting a permission, return here and choose Check Again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Request Permissions") {
                    permissions.requestPermissions()
                    startEventTapIfAllowed()
                }
                .focusable(false)
                Button("Open Privacy & Security") { permissions.openSettings() }
                    .focusable(false)
                Button("Check Again") {
                    permissions.refresh()
                    startEventTapIfAllowed()
                }
                .focusable(false)
            }
        }
    }

    private func startEventTapIfAllowed() {
        guard permissions.hasRequiredPermissions else { return }
        _ = model.startEventTap()
    }
}
