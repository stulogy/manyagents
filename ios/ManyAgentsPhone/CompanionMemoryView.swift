import SwiftUI

/// What the companion has been told, and a way to take it back.
///
/// Memory you can't see is memory you can't trust: it decides how your
/// words get routed, so it has to be inspectable and deletable. Swipe to
/// forget one, or clear the lot.
struct CompanionMemoryView: View {
    @StateObject private var companion = Companion.shared

    var body: some View {
        List {
            if companion.facts.isEmpty {
                Section {
                    Text("Nothing yet. When you tell it something it couldn't have known — who someone is, which project they're on — it keeps that here so you only have to say it once.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(companion.facts, id: \.self) { fact in
                        Text(fact)
                    }
                    .onDelete { offsets in
                        offsets.map { companion.facts[$0] }.forEach(companion.forget)
                    }
                } footer: {
                    Text("Swipe to forget one.")
                }
            }

            Section {
                Button("Start a new conversation") { companion.clearConversation() }
            } footer: {
                Text("Clears what you've been talking about. Keeps what it has learned.")
            }
        }
        .navigationTitle("What it remembers")
        .navigationBarTitleDisplayMode(.inline)
    }
}
