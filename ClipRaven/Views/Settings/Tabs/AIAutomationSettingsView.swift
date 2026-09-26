import SwiftUI
import ClipRavenSync
#if canImport(FoundationModels)
import FoundationModels
#endif

/// AI · 자동화 설정 탭 — Apple Intelligence 상태 + Smart Rules CRUD.
struct AIAutomationSettingsView: View {
    private enum SubTab: String, CaseIterable, Identifiable {
        case ai, rules
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .ai:    return "subtab.appleIntelligence"
            case .rules: return "subtab.autoRules"
            }
        }
    }

    @State private var subTab: SubTab = .ai

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $subTab) {
                ForEach(SubTab.allCases) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)

            switch subTab {
            case .ai:    AppleIntelligenceView()
            case .rules: SmartRulesSettingsView()
            }
        }
    }
}

/// Apple Intelligence controls — extracted from the old General tab into its
/// own view so `AIAutomationSettingsView` can swap it in on sub-tab selection.
struct AppleIntelligenceView: View {
    @AppStorage("aiCategorizationEnabled") private var aiCategorizationEnabled = true

    @State private var batchInProgress = false
    @State private var batchProgress = ""
    @State private var batchResult: String? = nil
    @State private var showForceReclassifyAlert = false

    var body: some View {
        Form {
            if #available(macOS 26, *) {
                Section {
                    Group {
                        LabeledContent("상태") {
                            Text(appleIntelligenceStatusText())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        Text("시스템 설정 → Apple Intelligence & Siri에서 활성화하고, 모델 다운로드가 완료되어야 분류가 작동합니다.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        LabeledContent("AI 자동 분류") {
                            Toggle("", isOn: $aiCategorizationEnabled)
                                .labelsHidden()
                        }

                        if aiCategorizationEnabled {
                            Text("클립 저장 시 Apple 온디바이스 AI가 자동으로 카테고리를 분류합니다 (영수증, 이메일, 코드 등).")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            LabeledContent("기존 클립 일괄 분류") {
                                HStack(spacing: 8) {
                                    if batchInProgress {
                                        Text(batchProgress)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        ProgressView().controlSize(.small)
                                    } else {
                                        if let result = batchResult {
                                            Text(result)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Button("미분류만") { runBatchReclassify(force: false) }
                                        Button("모두 재분류") { showForceReclassifyAlert = true }
                                    }
                                }
                            }
                        }

                        // "AI 요약" 토글은 v1.0 에서 숨긴다. 요약 버튼이 있는 프리뷰 패널을 여는
                        // 진입점이 없어(`togglePreview` 호출자 없음) 토글과 "프리뷰 패널의 '요약'
                        // 버튼" 안내가 존재하지 않는 기능을 가리켰다 (v1 리뷰). 상세 보기에 요약
                        // 버튼을 붙일 때 다시 노출한다.
                    }
                    .listRowBackground(Color(NSColor.controlBackgroundColor))
                } header: {
                    SectionHeader(title: "Apple Intelligence")
                }
            } else {
                Section {
                    Text("Apple Intelligence는 macOS 26 이상에서 사용할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color(NSColor.controlBackgroundColor))
                } header: {
                    SectionHeader(title: "Apple Intelligence")
                }
            }
        }
        .darkFormStyle()
        .alert("모든 클립을 다시 분류할까요?", isPresented: $showForceReclassifyAlert) {
            Button("취소", role: .cancel) {}
            Button("재분류", role: .destructive) { runBatchReclassify(force: true) }
        } message: {
            Text("기존 AI 카테고리를 모두 초기화하고 새 프롬프트로 다시 분류합니다. 클립 수에 따라 시간이 걸릴 수 있습니다.")
        }
    }

    private func runBatchReclassify(force: Bool) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            batchInProgress = true
            batchResult = nil
            batchProgress = "준비 중…"
            Task.detached(priority: .utility) {
                let progressCB: @Sendable (Int, Int) -> Void = { done, total in
                    Task { @MainActor in
                        batchProgress = "\(done) / \(total)"
                    }
                }
                let count: Int
                if force {
                    count = await AICategoryService.shared.batchReclassifyAll(progress: progressCB)
                } else {
                    count = await AICategoryService.shared.batchReclassifyUnclassified(progress: progressCB)
                }
                await MainActor.run {
                    batchInProgress = false
                    batchResult = "완료: \(count)개 처리"
                }
            }
        }
        #endif
    }
}

// MARK: - Smart Rules

struct SmartRulesSettingsView: View {
    @State private var rules: [SmartRule] = []
    @State private var tags: [Tag] = []
    @State private var showingAddSheet = false

    private let ruleRepo = SmartRuleRepository()
    private let tagRepo  = TagRepository()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Toolbar
            HStack {
                Text("자동 태그 규칙")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    showingAddSheet = true
                } label: {
                    Label("규칙 추가", systemImage: "plus")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            if rules.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("등록된 규칙이 없습니다")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("새 클립이 복사되면 조건에 맞는 태그를 자동으로 할당합니다.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 260)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        SmartRuleRow(
                            rule: rule,
                            tagName: {
                            let tagId = rule.actions.compactMap { if case .assignTag(let id) = $0 { return id } else { return nil } }.first
                            return tags.first(where: { $0.id == tagId })?.name ?? "?"
                        }(),
                            onToggle: { toggleRule(rule) },
                            onDelete: { deleteRule(rule) }
                        )
                        .listRowBackground(Color(NSColor.controlBackgroundColor))
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                // Semantic window background adapts to dark/light — the
                // previous literal `Color(white: 0.09)` rendered as a
                // near-black panel in light mode and hid the list rows.
                .background(Color(NSColor.windowBackgroundColor))
            }
        }
        .onAppear { loadData() }
        .sheet(isPresented: $showingAddSheet) {
            AddSmartRuleView(tags: tags) { newRule in
                var rule = newRule
                _ = try? ruleRepo.save(&rule)
                Task { await SmartRuleEngine.shared.reloadRules() }
                loadData()
            }
        }
    }

    private func loadData() {
        rules = (try? ruleRepo.fetchAll()) ?? []
        tags  = (try? tagRepo.fetchAll()) ?? []
    }

    private func toggleRule(_ rule: SmartRule) {
        guard let id = rule.id else { return }
        try? ruleRepo.toggleEnabled(id: id)
        Task { await SmartRuleEngine.shared.reloadRules() }
        loadData()
    }

    private func deleteRule(_ rule: SmartRule) {
        guard let id = rule.id else { return }
        try? ruleRepo.delete(id: id)
        Task { await SmartRuleEngine.shared.reloadRules() }
        loadData()
    }
}

struct SmartRuleRow: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    let rule: SmartRule
    let tagName: String
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            Toggle("", isOn: .init(get: { rule.isEnabled }, set: { _ in onToggle() }))
                .toggleStyle(.switch)
                .labelsHidden()

            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    Text(rule.condition.displayType)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(themeManager.colorPreset.accentColor.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(rule.condition.displayValue)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Text(tagName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(themeManager.colorPreset.accentColor)
                }
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

struct AddSmartRuleView: View {
    let tags: [Tag]
    let onSave: (SmartRule) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var conditionType = 0
    @State private var conditionValue = ""
    @State private var selectedContentType = "text"
    @State private var selectedTagId: Int64?

    private let conditionTypes = [
        NSLocalizedString("앱 (번들 ID)", comment: "Rule condition: app bundle ID"),
        NSLocalizedString("콘텐츠 유형", comment: "Rule condition: content type"),
        NSLocalizedString("텍스트 포함", comment: "Rule condition: text contains"),
        NSLocalizedString("URL 도메인", comment: "Rule condition: URL domain")
    ]

    var body: some View {
        VStack(spacing: 16) {
            Text("규칙 추가")
                .font(.headline)

            Form {
                TextField("규칙 이름", text: $name)

                Picker("조건 유형", selection: $conditionType) {
                    ForEach(0..<conditionTypes.count, id: \.self) { i in
                        Text(conditionTypes[i]).tag(i)
                    }
                }

                if conditionType == 1 {
                    Picker("콘텐츠 유형", selection: $selectedContentType) {
                        ForEach(ContentType.allCases, id: \.rawValue) { ct in
                            Text(ct.displayName).tag(ct.rawValue)
                        }
                    }
                } else {
                    TextField(conditionPlaceholder, text: $conditionValue)
                }

                if tags.isEmpty {
                    Text("태그를 먼저 만들어 주세요")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    Picker("태그 할당", selection: $selectedTagId) {
                        Text("선택...").tag(nil as Int64?)
                        ForEach(tags) { tag in
                            Text(tag.name).tag(tag.id as Int64?)
                        }
                    }
                }
            }

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: {
                    guard let tagId = selectedTagId, !name.isEmpty else { return }
                    let rule = SmartRule(
                        name: name,
                        isEnabled: true,
                        condition: buildCondition(),
                        actions: [.assignTag(tagId: tagId)],
                        createdAt: Date()
                    )
                    onSave(rule)
                    dismiss()
                }) {
                    Text("저장")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || selectedTagId == nil || !isConditionValid)
            }
        }
        .padding()
        .frame(width: 380, height: 300)
    }

    private var conditionPlaceholder: String {
        switch conditionType {
        case 0: return "com.apple.Safari"
        case 2: return NSLocalizedString("검색할 키워드", comment: "Placeholder: keyword to search")
        case 3: return "github.com"
        default: return ""
        }
    }

    private var isConditionValid: Bool {
        conditionType == 1 || !conditionValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func buildCondition() -> RuleCondition {
        let value = conditionValue.trimmingCharacters(in: .whitespacesAndNewlines)
        switch conditionType {
        case 0: return .sourceApp(bundleId: value)
        case 1: return .contentType(selectedContentType)
        case 2: return .textContains(value)
        case 3: return .urlDomain(value)
        default: return .textContains(value)
        }
    }
}
