import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh-Hans"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: LocalizedStringKey {
        switch self {
        case .english: "English"
        case .chinese: "简体中文"
        }
    }
}

struct AppSettingsView: View {
    @Binding var language: AppLanguage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(AppLanguage.allCases) { option in
                        Button {
                            language = option
                        } label: {
                            HStack {
                                Text(option.displayName)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if language == option {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Language")
                } footer: {
                    Text("The app language changes immediately.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
