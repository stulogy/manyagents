import SwiftUI
import AVFoundation

/// First run: point the camera at the QR in ManyAgents → Settings → Phone.
/// Pasting the code works too, which is what makes this testable in the
/// simulator, where there is no camera.
struct PairView: View {
    @EnvironmentObject var link: MacLink
    @State private var pasted = ""
    @State private var scanError: String?
    @State private var showPaste = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Text("ManyAgents")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Open ManyAgents on your Mac → Settings → Phone, then scan the code.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            .padding(.top, 48)
            .padding(.bottom, 24)

            ZStack {
                QRScanner { code in
                    guard let p = MacLink.Pairing.parse(code) else {
                        scanError = "That isn't a ManyAgents pairing code."
                        return
                    }
                    link.pairing = p
                }
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(Color.brandOrange.opacity(0.9), lineWidth: 3)
                    .padding(28)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .padding(.horizontal, 20)

            if let scanError {
                Text(scanError)
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding(.top, 12)
            }

            Button("Paste the code instead") { showPaste = true }
                .font(.footnote)
                .padding(.vertical, 18)

            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showPaste) {
            NavigationStack {
                Form {
                    Section {
                        TextField("manyagents://pair?d=…", text: $pasted, axis: .vertical)
                            .lineLimit(3...8)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } footer: {
                        Text("Copy it from the Mac: Settings → Phone → right-click the QR.")
                    }
                }
                .navigationTitle("Paste pairing code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Pair") {
                            if let p = MacLink.Pairing.parse(pasted.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                link.pairing = p
                                showPaste = false
                            } else {
                                scanError = "That isn't a ManyAgents pairing code."
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { showPaste = false }
                    }
                }
            }
        }
    }
}

/// Thin AVFoundation wrapper — one callback, fires once per distinct code.
struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerController {
        let vc = ScannerController()
        vc.coordinator = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        private var lastCode: String?

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput objects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard let obj = objects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue, value != lastCode
            else { return }
            lastCode = value
            DispatchQueue.main.async { self.onCode(value) }
        }
    }

    final class ScannerController: UIViewController {
        var coordinator: Coordinator?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else { return }   // no camera (simulator) — the paste path covers it
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(coordinator, queue: .main)
            output.metadataObjectTypes = [.qr]

            let layer = AVCaptureVideoPreviewLayer(session: session)
            layer.videoGravity = .resizeAspectFill
            view.layer.addSublayer(layer)
            preview = layer
            Task.detached { [session] in session.startRunning() }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }
    }
}
