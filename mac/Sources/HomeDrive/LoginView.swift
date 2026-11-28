import SwiftUI

struct LoginView: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        if model.showConnectForm || LocalServer.helper == nil {
            connectForm
        } else {
            FirstLaunchChoice()
        }
    }

    private var connectForm: some View {
        @Bindable var model = model
        return VStack(spacing: 20) {
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

            if LocalServer.helper != nil {
                Button("Keep my files on this Mac instead") { model.showConnectForm = false }
                    .buttonStyle(.link)
            }

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

/// First launch: is this the Mac that keeps the files, or one that connects?
struct FirstLaunchChoice: View {
    @Environment(DriveModel.self) private var model

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to HomeDrive")
                .font(.largeTitle.weight(.semibold))
            Text("Your own Google Drive. How do you want to use it on this Mac?")
                .foregroundStyle(.secondary)

            VStack(spacing: 12) {
                choice(icon: "internaldrive", title: "Keep my files on this Mac",
                       detail: "This Mac becomes your HomeDrive. Your other computers and phones connect to it.") {
                    Task { await model.setUpThisMac() }
                }
                choice(icon: "laptopcomputer.and.arrow.down", title: "Connect to my HomeDrive",
                       detail: "Your files are on another computer that runs HomeDrive.") {
                    model.showConnectForm = true
                }
            }
            .frame(maxWidth: 460)
            .disabled(model.busyMessage != nil)

            if let busy = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func choice(icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .light))
                    .frame(width: 40)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.1)))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
