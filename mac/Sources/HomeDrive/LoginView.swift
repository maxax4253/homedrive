import SwiftUI

struct LoginView: View {
    @Environment(DriveModel.self) private var model
    @State private var password = ""

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
                SecureField("Password", text: $password)
                    .onSubmit(signIn)
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
            .disabled(model.serverURL.isEmpty || model.username.isEmpty || password.isEmpty || model.busyMessage != nil)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func signIn() {
        let pw = password
        Task {
            await model.login(password: pw)
            if model.isLoggedIn { password = "" }
        }
    }
}
