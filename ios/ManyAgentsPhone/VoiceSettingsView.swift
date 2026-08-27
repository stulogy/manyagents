import SwiftUI

/// Pick the voice that reads replies aloud, and prove it works before
/// you're driving.
struct VoiceSettingsView: View {
    @EnvironmentObject var link: MacLink
    @StateObject private var settings = VoiceSettings.shared
    @StateObject private var voice = Voice.shared

    @State private var typedKey = ""
    @State private var editingKey = false
    @State private var voices: [ElevenVoice] = []
    @State private var loadingVoices = false
    @State private var note: String?
    @State private var noteIsError = false

    var body: some View {
        Form {
            Section {
                Picker("Read replies with", selection: $settings.engine) {
                    ForEach(VoiceSettings.Engine.allCases) { e in
                        Text(e.label).tag(e)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(settings.engine == .elevenLabs
                     ? "An ElevenLabs voice, synthesised a sentence ahead so it starts talking straight away. If the key or the signal isn't there, this iPhone's own voice finishes the job."
                     : "This iPhone's built-in voice. Works with no signal and costs nothing.")
            }

            if settings.engine == .elevenLabs {
                keySection
                if settings.hasKey { voiceSection }
            }

            Section {
                Button {
                    Task {
                        note = nil
                        let failure = await voice.preview(sample)
                        noteIsError = failure != nil
                        note = failure ?? "That's the voice you'll hear."
                    }
                } label: {
                    HStack {
                        Label("Test the voice", systemImage: "speaker.wave.2.fill")
                        Spacer()
                        if voice.isSpeaking { ProgressView().controlSize(.mini) }
                    }
                }
                if let note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(noteIsError ? Color.orange : .secondary)
                }
            }
        }
        .navigationTitle("Voice")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { voice.stopSpeaking() }
        .task {
            if settings.hasKey, voices.isEmpty { await loadVoices() }
        }
    }

    // MARK: - Key

    @ViewBuilder
    private var keySection: some View {
        Section {
            if settings.hasKey && !editingKey {
                LabeledContent("API key") {
                    Text(settings.keySource == .mac ? "From your Mac" : "Set")
                        .foregroundStyle(.secondary)
                }
                Button("Replace it") { typedKey = ""; editingKey = true }
                Button("Forget it", role: .destructive) {
                    settings.forgetKey()
                    voices = []
                }
            } else {
                SecureField("ElevenLabs API key", text: $typedKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Button("Save") {
                        settings.setKeyManually(typedKey)
                        editingKey = false
                        typedKey = ""
                        Task { await loadVoices() }
                    }
                    .disabled(typedKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingKey {
                        Spacer()
                        Button("Cancel") { editingKey = false; typedKey = "" }
                    }
                }
                Button {
                    let asked = link.refreshVoiceConfig { ok in
                        noteIsError = !ok
                        note = ok ? "Got the key from your Mac."
                                  : "Your Mac hasn't got a key set — add one in ManyAgents → Settings → Phone."
                        if ok { Task { await loadVoices() } }
                    }
                    if !asked {
                        noteIsError = true
                        note = "Not connected to your Mac right now."
                    }
                } label: {
                    Label("Get it from my Mac", systemImage: "desktopcomputer")
                }
            }
        } header: {
            Text("ElevenLabs")
        } footer: {
            Text("Stored in this iPhone's Keychain, and sent only to ElevenLabs. Setting one on your Mac under Settings → Phone hands it over automatically; a key you type here is kept in preference to that one.")
        }
    }

    // MARK: - Voice choice

    @ViewBuilder
    private var voiceSection: some View {
        Section {
            if loadingVoices {
                HStack {
                    Text("Loading voices…").foregroundStyle(.secondary)
                    Spacer()
                    ProgressView().controlSize(.mini)
                }
            } else if voices.isEmpty {
                LabeledContent("Voice", value: settings.voiceName)
                Button("Load my voices") { Task { await loadVoices() } }
            } else {
                Picker("Voice", selection: $settings.voiceID) {
                    ForEach(voices) { v in
                        Text(v.name).tag(v.id)
                    }
                }
                .onChange(of: settings.voiceID) { _, new in
                    settings.voiceName = voices.first { $0.id == new }?.name ?? settings.voiceName
                }
            }
        } header: {
            Text("Voice")
        }
    }

    private var sample: String {
        "Pushed the fix and the tests are green. Want me to open the pull request?"
    }

    private func loadVoices() async {
        guard !settings.apiKey.isEmpty else { return }
        loadingVoices = true
        defer { loadingVoices = false }
        do {
            voices = try await ElevenVoice.list(apiKey: settings.apiKey)
            if !voices.contains(where: { $0.id == settings.voiceID }), let first = voices.first {
                settings.voiceID = first.id
                settings.voiceName = first.name
            }
        } catch {
            noteIsError = true
            note = error.localizedDescription
        }
    }
}

/// One voice on the account.
struct ElevenVoice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String

    static func list(apiKey: String) async throws -> [ElevenVoice] {
        var req = URLRequest(url: URL(string: "https://api.elevenlabs.io/v2/voices?page_size=100")!)
        req.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ElevenLabsSpeaker.Failure.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let rows = obj?["voices"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let id = row["voice_id"] as? String else { return nil }
            return ElevenVoice(id: id, name: row["name"] as? String ?? id)
        }
    }
}
