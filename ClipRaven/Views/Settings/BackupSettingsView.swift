import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Backup / Restore tab under Settings.
/// Wraps `BackupService` in NSSavePanel / NSOpenPanel flows.
struct BackupSettingsView: View {
    @State private var isExporting = false
    @State private var isImporting = false
    @State private var lastExportResult: String?
    @State private var lastImportResult: String?
    @State private var errorMessage: String?

    @State private var showOverwriteConfirm = false
    @State private var pendingImportURL: URL?

    var body: some View {
        Form {
            // MARK: - Export
            Section {
                Group {
                    HStack {
                        Button {
                            presentExportPanel()
                        } label: {
                            if isExporting {
                                Label("내보내는 중...", systemImage: "arrow.down.circle")
                            } else {
                                Label("전체 데이터 내보내기 (ZIP)", systemImage: "square.and.arrow.up")
                            }
                        }
                        .disabled(isExporting || isImporting)

                        if let result = lastExportResult {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("클립, 태그, 자동화 규칙, 태그 배정 관계를 ZIP 파일로 저장합니다. 이미지 원본 파일도 함께 포함되어 다른 기기에서도 완전히 복원됩니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                sectionHeader("내보내기")
            }

            // MARK: - Import
            Section {
                Group {
                    HStack {
                        Button {
                            presentImportPanel()
                        } label: {
                            if isImporting {
                                Label("가져오는 중...", systemImage: "arrow.up.circle")
                            } else {
                                Label("백업 가져오기...", systemImage: "square.and.arrow.down")
                            }
                        }
                        .disabled(isExporting || isImporting)

                        if let result = lastImportResult {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                            Text(result)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text("이전에 내보낸 ZIP 또는 JSON 백업 파일을 불러옵니다. 기본적으로 기존 데이터는 유지되며 동일한 클립/태그는 건너뜁니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color(NSColor.controlBackgroundColor))
            } header: {
                sectionHeader("가져오기")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("오류", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("확인") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog(
            "기존 데이터를 덮어쓸까요?",
            isPresented: $showOverwriteConfirm,
            titleVisibility: .visible
        ) {
            Button("병합 (기존 데이터 유지)") {
                if let url = pendingImportURL { runImport(from: url, strategy: .merge) }
                pendingImportURL = nil
            }
            Button("덮어쓰기 (기존 데이터 삭제)", role: .destructive) {
                if let url = pendingImportURL { runImport(from: url, strategy: .overwrite) }
                pendingImportURL = nil
            }
            Button("취소", role: .cancel) {
                pendingImportURL = nil
            }
        } message: {
            Text("병합은 안전합니다. 덮어쓰기를 선택하면 현재 저장된 모든 클립·태그·규칙이 삭제됩니다.")
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }

    // MARK: - Export flow

    private func presentExportPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        let dateStr = formatter.string(from: Date())
        panel.nameFieldStringValue = "ClipRaven-Backup-\(dateStr).zip"
        panel.title = String(localized: "백업 저장 위치")
        panel.prompt = String(localized: "내보내기")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        isExporting = true
        lastExportResult = nil
        errorMessage = nil

        Task.detached {
            do {
                let count = try BackupService.shared.exportBackup(to: url)
                await MainActor.run {
                    lastExportResult = String(localized: "\(count)개 클립 저장됨")
                    isExporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isExporting = false
                }
            }
        }
    }

    // MARK: - Import flow

    private func presentImportPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .json]  // also accept legacy .json backups
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = String(localized: "불러올 백업 파일 선택")
        panel.prompt = String(localized: "가져오기")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
        showOverwriteConfirm = true
    }

    private func runImport(from url: URL, strategy: BackupService.ImportStrategy) {
        isImporting = true
        lastImportResult = nil
        errorMessage = nil

        Task.detached {
            do {
                let result = try BackupService.shared.importBackup(from: url, strategy: strategy)
                await MainActor.run {
                    lastImportResult = summarize(result: result, strategy: strategy)
                    isImporting = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func summarize(
        result: BackupService.ImportResult,
        strategy: BackupService.ImportStrategy
    ) -> String {
        let clipsLine: String
        switch strategy {
        case .merge:
            clipsLine = String(localized: "클립 \(result.clipsImported)개 추가 · \(result.clipsSkipped)개 건너뜀")
        case .overwrite:
            clipsLine = String(localized: "클립 \(result.clipsImported)개")
        }
        let tags = String(localized: "태그 \(result.tagsImported)개")
        let rules = String(localized: "규칙 \(result.rulesImported)개")
        let images = result.imagesRestored > 0 ? String(localized: " · 이미지 \(result.imagesRestored)개") : ""
        return "\(clipsLine) · \(tags) · \(rules)\(images)"
    }
}
