import SwiftUI

struct SettingsView: View {
    @StateObject private var settingsModel = SettingsModel()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Camera Settings")) {
                    if settingsModel.isAppleLogSupported {
                        Toggle("Apple Log", isOn: $settingsModel.isAppleLogEnabled)
                    } else {
                        Text("Apple Log not supported on this device")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
        }
    }
}

#Preview {
    SettingsView()
} 