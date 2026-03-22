import SwiftUI

struct DictionaryView: View {
    let appState: AppState

    @State private var searchQuery = ""
    @State private var selectedTag: String?
    @State private var showAddForm = false
    @State private var pendingSpelling: String?

    private var dictionaryManager: DictionaryManager { appState.dictionaryManager }

    private var filteredEntries: [DictionaryEntry] {
        var result: [DictionaryEntry]
        if searchQuery.isEmpty {
            result = dictionaryManager.entries
        } else {
            result = dictionaryManager.search(query: searchQuery)
        }
        if let tag = selectedTag {
            result = result.filter { $0.tags.contains(tag) }
        }
        return result.sorted { $0.spelling.localizedCaseInsensitiveCompare($1.spelling) == .orderedAscending }
    }

    private var tier1Count: Int {
        dictionaryManager.entries.filter { dictionaryManager.tier(for: $0) == .tier1 }.count
    }

    private var tier2Count: Int {
        dictionaryManager.entries.filter { dictionaryManager.tier(for: $0) == .tier2 }.count
    }

    private var tier3Count: Int {
        dictionaryManager.entries.filter { dictionaryManager.tier(for: $0) == .tier3 }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Search words, tags, notes…", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                    if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))

                Spacer()

                Button {
                    pendingSpelling = nil
                    showAddForm = true
                } label: {
                    Label("Add Word", systemImage: "plus")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button {
                    // Placeholder for Task 11: Document Scanner
                } label: {
                    Label("Scan Document", systemImage: "doc.viewfinder")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Scan a document to extract vocabulary (coming soon)")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Tag filter chips
            if !dictionaryManager.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        tagChip(label: "All", isSelected: selectedTag == nil) {
                            selectedTag = nil
                        }
                        ForEach(dictionaryManager.allTags, id: \.self) { tag in
                            tagChip(label: tag, isSelected: selectedTag == tag) {
                                selectedTag = selectedTag == tag ? nil : tag
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
                Divider()
            }

            // Entry list
            if filteredEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredEntries) { entry in
                            DictionaryEntryRow(entry: entry, appState: appState)
                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }

            // Status bar
            Divider()
            HStack(spacing: 12) {
                Label("\(dictionaryManager.entries.count) words", systemImage: "character.book.closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 12)

                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Tier 1: \(tier1Count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                    Text("Tier 2: \(tier2Count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 4) {
                    Circle().fill(.gray).frame(width: 6, height: 6)
                    Text("Tier 3: \(tier3Count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .sheet(isPresented: $showAddForm) {
            DictionaryEntryForm(appState: appState, initialSpelling: pendingSpelling) {
                showAddForm = false
            }
        }
        .onAppear {
            if let word = dictionaryManager.pendingWordToAdd {
                pendingSpelling = word
                dictionaryManager.pendingWordToAdd = nil
                showAddForm = true
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "character.book.closed")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            if searchQuery.isEmpty && selectedTag == nil {
                Text("No words yet")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Add words you frequently use to improve transcription accuracy.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("Add Your First Word") {
                    pendingSpelling = nil
                    showAddForm = true
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            } else {
                Text("No matching words")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("Try adjusting your search or tag filter.")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func tagChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                            in: Capsule())
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }
}
