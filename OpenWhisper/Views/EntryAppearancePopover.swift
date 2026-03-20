import SwiftUI

/// Popover for customizing a single entry's bar and background appearance.
struct EntryAppearancePopover: View {
    let entryID: UUID
    @State var overrides: EntryAppearanceOverride
    let onSave: (EntryAppearanceOverride) -> Void
    let onReset: () -> Void

    @State private var customizeBar = false
    @State private var customizeEntry = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Entry Appearance")
                .font(.headline)

            // Bar appearance
            Toggle("Custom bar style", isOn: $customizeBar)
                .font(.caption)
                .onChange(of: customizeBar) { _, on in
                    if on {
                        if overrides.barAppearance == nil {
                            overrides.barAppearance = AppearanceStore.globalBarAppearance
                        }
                    } else {
                        overrides.barAppearance = nil
                    }
                    onSave(overrides)
                }

            if customizeBar, overrides.barAppearance != nil {
                AppearanceEditor(
                    label: "Bars",
                    appearance: Binding(
                        get: { overrides.barAppearance ?? .defaultBar },
                        set: {
                            overrides.barAppearance = $0
                            onSave(overrides)
                        }
                    )
                )
            }

            Divider()

            // Entry background appearance
            Toggle("Custom background style", isOn: $customizeEntry)
                .font(.caption)
                .onChange(of: customizeEntry) { _, on in
                    if on {
                        if overrides.entryAppearance == nil {
                            overrides.entryAppearance = AppearanceStore.globalEntryAppearance
                        }
                    } else {
                        overrides.entryAppearance = nil
                    }
                    onSave(overrides)
                }

            if customizeEntry, overrides.entryAppearance != nil {
                AppearanceEditor(
                    label: "Background",
                    appearance: Binding(
                        get: { overrides.entryAppearance ?? .defaultEntry },
                        set: {
                            overrides.entryAppearance = $0
                            onSave(overrides)
                        }
                    )
                )
            }

            Divider()

            HStack {
                Button("Reset to Default") {
                    overrides = EntryAppearanceOverride()
                    customizeBar = false
                    customizeEntry = false
                    onReset()
                }
                .controlSize(.small)
                .font(.caption)

                Spacer()
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            customizeBar = overrides.barAppearance != nil
            customizeEntry = overrides.entryAppearance != nil
        }
    }
}
