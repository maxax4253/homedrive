import SwiftUI

struct LoginView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("HomeDrive")
                .font(.largeTitle.weight(.semibold))
            Text("Sign in to the drive on your server.")
                .foregroundStyle(.secondary)

            Form {
                TextField("Server", text: $model.serverURL, prompt: Text("https://homedrive.….ts.net"))
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
                    .onSubmit(signIn)
                if model.needsPairingCode {
                    TextField("Pairing code", text: $model.pairingCode, prompt: Text("123 456"))
                        .onSubmit(signIn)
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: 380)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Button(action: signIn) {
                if model.busyMessage != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign In").frame(minWidth: 80)
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(!canSignIn)

            if model.needsPairingCode {
                if let note = model.pairingNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                Text("New device? Get a 6-digit code on the server computer (HomeDrive in the menu bar), or on a device that's already signed in (Settings → Devices).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Check the server as its address is typed (after a short pause).
        .task(id: model.serverURL + "\n" + model.username) {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await model.checkServerPairing()
        }
    }

    private var canSignIn: Bool {
        !model.serverURL.isEmpty && !model.username.isEmpty && !model.password.isEmpty && model.busyMessage == nil
            && (model.needsPairingCode ? PairingCode.clean(model.pairingCode).count == 6
                                       : [0, 6].contains(PairingCode.clean(model.pairingCode).count))
    }

    private func signIn() {
        guard canSignIn else { return }
        Task { await model.login() }
    }
}
