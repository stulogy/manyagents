import SwiftUI

/// Which board you're talking to.
///
/// Only reachable when the Mac has more than one orchestrator, which is
/// the only time the question exists. It lists them by project with the
/// number of tabs each one covers, because "the UHP one" is how you think
/// about it, not "the tab called Orchestrator".
struct CompanionPicker: View {
    @EnvironmentObject var link: MacLink
    @Environment(\.dismiss) private var dismiss
    let onPick: (MacLink.Tab) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(link.orchestrators) { tab in
                        Button {
                            onPick(tab)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "waveform")
                                    .foregroundStyle(Theme.orange)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(link.scopeName(of: tab))
                                        .foregroundStyle(Theme.text)
                                    Text("\(link.tabCount(inScopeOf: tab)) tabs · \(tab.title)")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                if tab.id == link.companionTab {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Theme.orange)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Talk to")
                } footer: {
                    Text("Each orchestrator sees the tabs in its own project. Whichever you pick is the one the button at the top of the board talks to, until you change it.")
                }
            }
            .navigationTitle("Which project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
