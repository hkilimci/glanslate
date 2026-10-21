import GlanslateCore
import GlanslateSystem
import SwiftUI

/// The Software Update section of Settings › About: the automatic-check switch,
/// the current status, and, when a newer release exists, its notes and install button.
struct SoftwareUpdateSection: View {
    let updates: UpdateController
    @Environment(AppEnvironment.self) private var app

    var body: some View {
        @Bindable var settings = app.settings
        Section {
            Toggle("Check for updates automatically", isOn: $settings.checksForUpdates)
            status
            if let problem = updates.problem {
                ProblemRow(problem: problem, releasePage: updates.available?.releasePage)
            }
        } header: {
            Text("Software Update")
        } footer: {
            Text("Glanslate asks GitHub for the latest release once a day. The request includes Glanslate’s version, never anything you’ve captured or translated.")
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updates.activity {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…").foregroundStyle(.secondary)
            }
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Downloading Glanslate \(updates.available?.version.description ?? "")…")
                    Spacer()
                    Button("Cancel") { updates.cancelInstall() }
                        .controlSize(.small)
                }
                ProgressView(value: fraction)
                    .accessibilityLabel("Download progress")
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing and relaunching…").foregroundStyle(.secondary)
            }
        case .idle:
            if let update = updates.available {
                AvailableUpdateRow(update: update, updates: updates)
            } else {
                LabeledContent {
                    Button("Check Now") { updates.checkNow() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updates.isUpToDate ? "Glanslate is up to date" : "Version \(updates.currentVersion.description)")
                        Text(lastCheckedText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var lastCheckedText: String {
        guard let date = updates.lastChecked else { return "Not checked yet" }
        return "Last checked \(date.formatted(.relative(presentation: .named)))"
    }
}

private struct AvailableUpdateRow: View {
    let update: AvailableUpdate
    let updates: UpdateController
    @Environment(\.openURL) private var openURL

    var body: some View {
        let canInstall = updates.availability == .available && update.archive != nil
        VStack(alignment: .leading, spacing: 10) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(update.title) is available").font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }

            if !update.notes.isEmpty {
                ScrollView {
                    Text(notes)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 150)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8, style: .continuous))
            }

            if let reason = reason(canInstall: canInstall) {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if !updates.isSkipped(update) {
                    Button("Skip This Version") { updates.skip() }
                }
                Link("Release Page", destination: update.releasePage)
                Spacer()
                if canInstall {
                    Button("Install and Relaunch") { updates.install() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Download…") { openURL(update.releasePage) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var subtitle: String {
        var parts = ["You have \(updates.currentVersion)"]
        if let published = update.publishedAt {
            parts.append("Released \(published.formatted(date: .abbreviated, time: .omitted))")
        }
        return parts.joined(separator: " · ")
    }

    /// Release notes are Markdown; inline styling and links render, block syntax stays as typed.
    private var notes: AttributedString {
        (try? AttributedString(markdown: update.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(update.notes)
    }

    private func reason(canInstall: Bool) -> String? {
        guard !canInstall else { return nil }
        if update.archive == nil {
            return "This release can’t be installed automatically. Download it from the release page."
        }
        switch updates.availability {
        case .available: return nil
        case .notDeveloperIDSigned:
            return "This build of Glanslate isn’t signed for automatic updates. Download the new version and replace it."
        case .locationNotWritable:
            return "Glanslate can’t replace itself where it is. Move it to Applications, or download the new version."
        }
    }
}

private struct ProblemRow: View {
    let problem: UpdateError
    let releasePage: URL?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(problem.title)
                    Text(problem.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Spacer()
            if problem.suggestsManualDownload, let releasePage {
                Link("Release Page", destination: releasePage)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
