import AppKit
import CodexBarCore
import SwiftUI

@MainActor
struct GeneralPane: View {
    @Bindable var settings: SettingsStore
    @Bindable var store: UsageStore
    @State private var browserOSConnectionState: BrowserOSConnectionState = .unknown

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSection(contentSpacing: 12) {
                    Text("System")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    PreferenceToggleRow(
                        title: "Start at Login",
                        subtitle: "Automatically opens CodexBar when you start your Mac.",
                        binding: self.$settings.launchAtLogin)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text("Usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle(isOn: self.$settings.costUsageEnabled) {
                                Text("Show cost summary")
                                    .font(.body)
                            }
                            .toggleStyle(.checkbox)

                            Text("Reads local usage logs. Shows today + last 30 days cost in the menu.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                                .fixedSize(horizontal: false, vertical: true)

                            if self.settings.costUsageEnabled {
                                Text("Auto-refresh: hourly · Timeout: 10m")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)

                                self.costStatusLine(provider: .claude)
                                self.costStatusLine(provider: .codex)
                            }
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text("Automation")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Refresh cadence")
                                    .font(.body)
                                Text("How often CodexBar polls providers in the background.")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Picker("Refresh cadence", selection: self.$settings.refreshFrequency) {
                                ForEach(RefreshFrequency.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        if self.settings.refreshFrequency == .manual {
                            Text("Auto-refresh is off; use the menu's Refresh command.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    PreferenceToggleRow(
                        title: "Check provider status",
                        subtitle: "Polls OpenAI/Claude status pages and Google Workspace for " +
                            "Gemini/Antigravity, surfacing incidents in the icon and menu.",
                        binding: self.$settings.statusChecksEnabled)
                    PreferenceToggleRow(
                        title: "Session quota notifications",
                        subtitle: "Notifies when the 5-hour session quota hits 0% and when it becomes " +
                            "available again.",
                        binding: self.$settings.sessionQuotaNotificationsEnabled)
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    Text("BrowserOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 10) {
                        PreferenceToggleRow(
                            title: "Enable BrowserOS MCP",
                            subtitle: "Use BrowserOS MCP server for cookie fetching instead of browser keychain.",
                            binding: self.$settings.browserOSEnabled)

                        if self.settings.browserOSEnabled {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("MCP URL")
                                        .font(.body)
                                    TextField("", text: self.$settings.browserOSEndpoint)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.footnote)
                                        .monospaced()
                                }

                                HStack(alignment: .center, spacing: 10) {
                                    Button("Test Connection") {
                                        Task { await self.testBrowserOSConnection() }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)

                                    if self.browserOSConnectionState == .testing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        self.browserOSConnectionState.icon
                                    }

                                    Spacer()
                                }

                                Text("URL of your BrowserOS MCP server for cookie fetching.")
                                    .font(.footnote)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                Divider()

                SettingsSection(contentSpacing: 12) {
                    HStack {
                        Spacer()
                        Button("Quit CodexBar") { NSApp.terminate(nil) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func costStatusLine(provider: UsageProvider) -> some View {
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName

        guard provider == .claude || provider == .codex else {
            return Text("\(name): unsupported")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }

        if self.store.isTokenRefreshInFlight(for: provider) {
            let elapsed: String = {
                guard let startedAt = self.store.tokenLastAttemptAt(for: provider) else { return "" }
                let seconds = max(0, Date().timeIntervalSince(startedAt))
                let formatter = DateComponentsFormatter()
                formatter.allowedUnits = seconds < 60 ? [.second] : [.minute, .second]
                formatter.unitsStyle = .abbreviated
                return formatter.string(from: seconds).map { " (\($0))" } ?? ""
            }()
            return Text("\(name): fetching…\(elapsed)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let snapshot = self.store.tokenSnapshot(for: provider) {
            let updated = UsageFormatter.updatedString(from: snapshot.updatedAt)
            let cost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
            return Text("\(name): \(updated) · 30d \(cost)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let error = self.store.tokenError(for: provider), !error.isEmpty {
            let truncated = UsageFormatter.truncatedSingleLine(error, max: 120)
            return Text("\(name): \(truncated)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        if let lastAttempt = self.store.tokenLastAttemptAt(for: provider) {
            let rel = RelativeDateTimeFormatter()
            rel.unitsStyle = .abbreviated
            let when = rel.localizedString(for: lastAttempt, relativeTo: Date())
            return Text("\(name): last attempt \(when)")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        return Text("\(name): no data yet")
            .font(.footnote)
            .foregroundStyle(.tertiary)
    }

    private func testBrowserOSConnection() async {
        self.browserOSConnectionState = .testing
        let available = await Task.detached {
            BrowserOSCookieProvider.isAvailable()
        }.value
        await MainActor.run {
            self.browserOSConnectionState = available ? .connected : .failed
        }
    }
}

enum BrowserOSConnectionState {
    case unknown
    case testing
    case connected
    case failed

    @ViewBuilder
    var icon: some View {
        switch self {
        case .unknown:
            EmptyView()
        case .testing:
            EmptyView()
        case .connected:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        }
    }
}
