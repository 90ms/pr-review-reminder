import SwiftUI
import UniformTypeIdentifiers

public struct SettingsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var reposText = ""
    @State private var showingImporter = false

    public init() {}

    private func langLabel(_ lang: AppLanguage) -> String {
        switch lang {
        case .system: return app.l("lang_system")
        case .korean: return app.l("lang_korean")
        case .english: return app.l("lang_english")
        }
    }

    public var body: some View {
        Form {
            Section(app.l("sec_lang")) {
                Picker(app.l("app_language"), selection: $app.settings.appLanguage) {
                    ForEach(AppLanguage.allCases) { Text(langLabel($0)).tag($0) }
                }
                Picker(app.l("review_language"), selection: $app.settings.reviewLanguage) {
                    ForEach(AppLanguage.allCases) { Text(langLabel($0)).tag($0) }
                }
            }

            Section(app.l("sec_github")) {
                TextField(app.l("owner"), text: $app.settings.owner)
                TextField(app.l("repos_ph"), text: $reposText)
                    .onAppear { reposText = app.settings.repositories.joined(separator: ", ") }
            }

            Section(app.l("sec_ai")) {
                Picker(app.l("tool"), selection: $app.settings.aiTool) {
                    ForEach(AITool.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
                if app.settings.aiTool == .codex {
                    TextField(app.l("codex_input_price"), value: $app.settings.codexInputPricePerMillion, format: .number)
                    TextField(app.l("codex_output_price"), value: $app.settings.codexOutputPricePerMillion, format: .number)
                    Text(app.l("codex_price_help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(app.l("sec_budget")) {
                TextField(app.l("token_budget"), value: $app.settings.reviewTokenBudget, format: .number)
                Stepper(
                    String(format: app.l("budget_window_days"), app.settings.reviewBudgetWindowDays),
                    value: $app.settings.reviewBudgetWindowDays,
                    in: 1...365
                )
                Text(app.l("budget_help"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Section(app.l("sec_schedule")) {
                Picker(app.l("mode"), selection: $app.settings.scheduleMode) {
                    Text(app.l("daily_at")).tag(ScheduleMode.dailyAt)
                    Text(app.l("every_n")).tag(ScheduleMode.everyNHours)
                }.pickerStyle(.segmented)
                if app.settings.scheduleMode == .dailyAt {
                    HStack {
                        Stepper("\(app.l("hour")): \(app.settings.dailyHour)", value: $app.settings.dailyHour, in: 0...23)
                        Stepper("\(app.l("minute")): \(app.settings.dailyMinute)", value: $app.settings.dailyMinute, in: 0...59)
                    }
                } else {
                    Stepper(String(format: app.l("every_h"), app.settings.intervalHours), value: $app.settings.intervalHours, in: 1...24)
                }
                if !app.scheduleRuns.isEmpty {
                    Text(app.l("recent_schedule_runs"))
                        .font(.caption.weight(.semibold))
                        .padding(.top, 4)
                    ForEach(app.scheduleRuns.prefix(5)) { run in
                        HStack(alignment: .top) {
                            Image(systemName: run.outcome == .success
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill")
                                .foregroundStyle(run.outcome == .success ? .green : .orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(run.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                Text(scheduleRunMessage(run))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
            }

            Section {
                Toggle(app.l("enable_notifications"), isOn: $app.settings.notificationsEnabled)
                Toggle(app.l("auto_review"), isOn: $app.settings.autoReview)
                Toggle(app.l("launch_at_login"), isOn: $app.settings.launchAtLogin)
                if let error = app.launchAtLoginError {
                    Text(String(format: app.l("launch_at_login_failed"), error))
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            Section(app.l("sec_history")) {
                Toggle(app.l("save_history"), isOn: $app.settings.historyEnabled)
                if app.settings.historyEnabled {
                    Stepper(
                        app.settings.historyRetentionDays == 0
                            ? app.l("retention_forever")
                            : String(format: app.l("retention_days"), app.settings.historyRetentionDays),
                        value: $app.settings.historyRetentionDays,
                        in: 0...365
                    )
                    Text(app.l("history_privacy_help"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section(app.l("sec_prompt")) {
                TextEditor(text: $app.settings.promptTemplate)
                    .font(.caption.monospaced()).frame(minHeight: 100)
                Text(app.l("prompt_help")).font(.caption2).foregroundStyle(.secondary)
            }

            Section(app.l("sec_skill")) {
                TextEditor(text: $app.settings.reviewSkill)
                    .font(.caption.monospaced()).frame(minHeight: 80)
                Text(app.l("skill_help")).font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button(app.l("load_file")) { showingImporter = true }
                    if !app.settings.reviewSkill.isEmpty {
                        Button(app.l("clear")) { app.settings.reviewSkill = "" }
                    }
                }
            }

            Section(app.l("sec_deps")) {
                dependencyRows
                Button(app.l("recheck")) { Task { await app.diagnose() } }
            }

            Section(app.l("sec_update")) {
                if let info = app.updateInfo {
                    LabeledContent(app.l("current_version"), value: info.currentVersion)
                    LabeledContent(app.l("latest_version"), value: info.latestVersion)
                    if info.updateAvailable {
                        Button(app.l("install_update")) {
                            app.startUpdateInstall()
                        }
                        .disabled(app.updateStage.isBusy)
                    } else {
                        Label(app.l("up_to_date"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                Button(app.l("check_update")) {
                    app.startUpdateCheck()
                }
                .disabled(app.updateStage.isBusy)
                if app.updateStage.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(updateStageLabel)
                        Spacer()
                        if app.updateStage != .restarting && app.updateStage != .cancelling {
                            Button(app.l("cancel")) { app.cancelUpdate() }
                        }
                    }
                }
                if case let .failed(operation, message) = app.updateStage {
                    Text(operation.map(updateFailureLabel) ?? app.l("update_failed"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if operation == .restartApplication {
                        Button(app.l("restart_now")) {
                            Task { await app.restartAfterUpdate() }
                        }
                    }
                } else if app.updateStage == .restartRequired {
                    Text(app.l("update_restart"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(app.l("restart_now")) {
                        Task { await app.restartAfterUpdate() }
                    }
                } else if app.updateStage == .cancelled {
                    Text(app.l("update_cancelled"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(app.l("sec_storage")) {
                storageRow(
                    title: app.l("settings_storage"),
                    diagnostic: app.settingsStorageDiagnostic
                )
                storageRow(
                    title: app.l("history_storage"),
                    diagnostic: app.historyStorageDiagnostic
                )
            }

            HStack {
                Spacer()
                Button(app.l("save")) {
                    app.settings.repositories = reposText
                        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if app.saveSettings() {
                        dismiss()
                        NSApplication.shared.keyWindow?.close()
                    }
                }.keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 720)
        .fileImporter(isPresented: $showingImporter, allowedContentTypes: [.plainText, .text, UTType(filenameExtension: "md") ?? .plainText]) { result in
            if case .success(let url) = result,
               url.startAccessingSecurityScopedResource() {
                defer { url.stopAccessingSecurityScopedResource() }
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    app.settings.reviewSkill = text
                }
            }
        }
    }

    private func scheduleRunMessage(_ run: ScheduleRunRecord) -> String {
        if run.outcome == .success {
            return String(format: app.l("scheduled_refresh_succeeded"), run.itemCount)
        }
        return run.message ?? app.l("scheduled_refresh_unknown_error")
    }

    private func storageRow(title: String, diagnostic: StorageDiagnostic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: diagnostic.health.isFailure
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill")
                    .foregroundStyle(diagnostic.health.isFailure ? .orange : .green)
                Text(title)
                Spacer()
                if diagnostic.byteCount > 0 {
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(diagnostic.byteCount),
                        countStyle: .file
                    ))
                    .foregroundStyle(.secondary)
                }
            }
            Text(storageHealthLabel(diagnostic.health))
                .font(.caption)
                .foregroundStyle(diagnostic.health.isFailure ? .orange : .secondary)
                .textSelection(.enabled)
            Text(diagnostic.location)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let saved = diagnostic.lastSavedAt {
                Text("\(app.l("last_saved")) \(saved.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let backup = diagnostic.backupLocation {
                Text("\(app.l("corrupt_backup")) \(backup)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }

    private func storageHealthLabel(_ health: StorageHealth) -> String {
        switch health {
        case .healthy: return app.l("storage_healthy")
        case .empty: return app.l("storage_empty")
        case .readFailed(let message): return "\(app.l("storage_read_failed")): \(message)"
        case .decodeFailed(let message): return "\(app.l("storage_decode_failed")): \(message)"
        case .writeFailed(let message): return "\(app.l("storage_write_failed")): \(message)"
        }
    }

    private var updateStageLabel: String {
        switch app.updateStage {
        case .refreshingTap: return app.l("update_stage_refresh")
        case .readingVersion: return app.l("update_stage_version")
        case .upgradingFormula: return app.l("update_stage_build")
        case .relinkingApplication: return app.l("update_stage_link")
        case .restarting: return app.l("update_stage_restart")
        case .cancelling: return app.l("update_stage_cancelling")
        default: return ""
        }
    }

    private func updateFailureLabel(_ operation: HomebrewUpdateOperation) -> String {
        switch operation {
        case .refreshTap: return app.l("update_failed_refresh")
        case .readVersion: return app.l("update_failed_version")
        case .upgradeFormula: return app.l("update_failed_build")
        case .relinkApplication: return app.l("update_failed_link")
        case .restartApplication: return app.l("update_failed_restart")
        }
    }

    @ViewBuilder private var dependencyRows: some View {
        if let s = app.status {
            row(app.l("gh_installed"), s.ghInstalled)
            row(app.l("gh_authed") + (s.ghLogin.map { " (\($0))" } ?? ""), s.ghAuthenticated)
            row(app.l("claude_cli"), s.claudeInstalled)
            row(app.l("codex_cli"), s.codexInstalled)
            ForEach(s.problems, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        } else {
            Text(app.l("not_checked")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func row(_ label: String, _ ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill").foregroundStyle(ok ? .green : .red)
            Text(label).font(.caption)
        }
    }
}
