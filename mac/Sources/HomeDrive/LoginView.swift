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
                TextField("Server", text: $model.serverURL, prompt: Text("http://100.x.x.x:8090"))
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
                Text("Get a code on a device that's already signed in (Settings → Devices), or on the server computer.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var canSignIn: Bool {
        !model.serverURL.isEmpty && !model.username.isEmpty && !model.password.isEmpty && model.busyMessage == nil
            && [0, 6].contains(PairingCode.clean(model.pairingCode).count)
    }

    private func signIn() {
        guard canSignIn else { return }
        Task { await model.login() }
    }
}
