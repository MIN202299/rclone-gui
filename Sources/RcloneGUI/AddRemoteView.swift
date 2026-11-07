import SwiftUI

/// Creates a remote using rclone's non-interactive config state machine,
/// so follow-up questions (OAuth sign-in, team drives…) are asked in the GUI.
struct AddRemoteView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var providers: [Provider] = []
    @State private var loadError: String?
    @State private var providerFilter = ""
    @State private var provider: Provider?
    @State private var name = ""
    @State private var values: [String: String] = [:]
    @State private var showOptional = false

    // State machine
    @State private var created = false
    @State private var working = false
    @State private var workingMessage = ""
    @State private var question: ConfigQuestion?
    @State private var answer = ""
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let question, let option = question.option {
                    questionForm(question, option)
                } else if let provider {
                    optionsForm(provider)
                } else {
                    providerPicker
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .disabled(working)

            Divider()
            footer.padding(12)
        }
        .frame(width: 540, height: 440)
        .task {
            do { providers = try await Rclone.providers().sorted { $0.description.localizedStandardCompare($1.description) == .orderedAscending } }
            catch { loadError = error.localizedDescription }
        }
    }

    // MARK: Step 1 — pick a provider

    private var filteredProviders: [Provider] {
        let q = providerFilter.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return providers }
        return providers.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.description.localizedCaseInsensitiveContains(q) }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a Remote").font(.title2.bold())
            Text("Choose the kind of storage you want to connect.").foregroundStyle(.secondary)
            TextField("Search providers", text: $providerFilter)
                .textFieldStyle(.roundedBorder)
            if let loadError {
                Text(loadError).foregroundStyle(.red)
            }
            List(filteredProviders) { p in
                Button {
                    select(p)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(p.description).lineLimit(2).truncationMode(.tail)
                                .help(p.description)
                            Text(p.name).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            .listStyle(.bordered)
            .overlay { if providers.isEmpty && loadError == nil { ProgressView() } }
        }
        .padding(20)
    }

    private func select(_ p: Provider) {
        provider = p
        values = [:]
        for option in p.options where !option.advanced && !option.defaultString.isEmpty {
            values[option.name] = option.defaultString
        }
        if name.isEmpty {
            var base = p.name, n = 2
            while model.remotes.contains(where: { $0.name == base }) { base = "\(p.name)\(n)"; n += 1 }
            name = base
        }
    }

    // MARK: Step 2 — fill in options

    private func visibleOptions(_ p: Provider) -> [ProviderOption] {
        let sub = values["provider"] ?? ""
        return p.options.filter { !$0.advanced && $0.applies(toProvider: sub) }
    }

    private func optionsForm(_ p: Provider) -> some View {
        let options = visibleOptions(p)
        let required = options.filter(\.required)
        let optional = options.filter { !$0.required }
        return Form {
            Section {
                TextField("Remote name", text: $name)
                if nameProblem != nil {
                    Text(nameProblem!).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text(p.description).font(.headline)
            }
            if !required.isEmpty {
                Section("Required") { ForEach(required) { optionField($0) } }
            }
            if !optional.isEmpty {
                Section {
                    DisclosureGroup("Optional settings (\(optional.count))", isExpanded: $showOptional) {
                        ForEach(optional) { optionField($0) }
                    }
                } footer: {
                    Text("Leave optional settings blank to use rclone's defaults. Providers that use OAuth will ask you to sign in with your browser next.")
                        .formFooter()
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func optionField(_ option: ProviderOption) -> some View {
        let binding = Binding(get: { values[option.name] ?? "" }, set: { values[option.name] = $0 })
        VStack(alignment: .leading, spacing: 4) {
            OptionInput(option: option, text: binding)
            if !option.shortHelp.isEmpty {
                Text(option.shortHelp).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var nameProblem: String? {
        let n = name.trimmingCharacters(in: .whitespaces)
        if n.isEmpty { return String(localized: "Enter a name.") }
        if n.contains(":") || n.hasPrefix("-") { return String(localized: "Names can't contain “:” or start with “-”.") }
        if model.remotes.contains(where: { $0.name == n }) && !created { return String(localized: "A remote with this name already exists.") }
        return nil
    }

    private var missingRequired: Bool {
        guard let provider else { return true }
        return visibleOptions(provider).contains { $0.required && (values[$0.name] ?? "").isEmpty }
    }

    // MARK: Step 3 — follow-up questions

    private func questionForm(_ q: ConfigQuestion, _ option: ProviderOption) -> some View {
        Form {
            Section {
                Text(option.help).fixedSize(horizontal: false, vertical: true)
                OptionInput(option: option, text: $answer)
                if let err = q.error, !err.isEmpty {
                    Text(err).foregroundStyle(.red)
                }
            } header: {
                Text("Set up “\(name)”").font(.headline)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if working {
                ProgressView().controlSize(.small)
                Text(workingMessage).foregroundStyle(.secondary).lineLimit(2)
            } else if let error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            Button("Cancel", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
            if provider != nil && question == nil && !created {
                Button("Back") { provider = nil; error = nil }
                    .disabled(working)
                Button("Create") { Task { await create() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || nameProblem != nil || missingRequired)
            } else if question != nil {
                Button("Continue") { Task { await answerQuestion() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
    }

    // MARK: Actions

    private func create() async {
        guard let provider else { return }
        let remoteName = name.trimmingCharacters(in: .whitespaces)
        var args = ["config", "create", remoteName, provider.name]
        for option in visibleOptions(provider) {
            let v = values[option.name] ?? ""
            // Only pass values the user set or that differ from rclone's default.
            if !v.isEmpty && (v != option.defaultString || option.required) { args.append("\(option.name)=\(v)") }
        }
        args += ["--non-interactive", "--obscure"]
        await step(args, message: String(localized: "Creating remote…"))
    }

    private func answerQuestion() async {
        guard let q = question else { return }
        let remoteName = name.trimmingCharacters(in: .whitespaces)
        let isOAuth = q.state.contains("oauth") || (q.option?.name ?? "").contains("auth")
        await step(["config", "update", remoteName, "--continue", "--state", q.state, "--result", answer, "--non-interactive"],
                   message: isOAuth && answer == "true" ? String(localized: "Waiting for you to sign in with your browser…") : String(localized: "Configuring…"))
    }

    private func step(_ args: [String], message: String) async {
        working = true
        workingMessage = message
        error = nil
        defer { working = false }
        do {
            let data = try await Rclone.run(args)
            created = true
            let q = try? JSONDecoder().decode(ConfigQuestion.self, from: data)
            if let q, !q.state.isEmpty, let option = q.option {
                answer = option.defaultString
                question = q
            } else {
                if let err = q?.error, !err.isEmpty { error = err; return }
                await model.loadRemotes()
                model.selectedRemoteName = name.trimmingCharacters(in: .whitespaces)
                dismiss()
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func cancel() {
        // Remove a half-configured remote so it doesn't linger in rclone.conf.
        if created {
            let n = name.trimmingCharacters(in: .whitespaces)
            Task {
                _ = try? await Rclone.run(["config", "delete", n])
                await model.loadRemotes()
            }
        }
        dismiss()
    }
}

/// Text field, secure field, picker or toggle depending on what the option expects.
private struct OptionInput: View {
    let option: ProviderOption
    @Binding var text: String

    private var label: String {
        option.name.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private var isBool: Bool {
        Set(option.examples.map { $0.value.lowercased() }) == ["true", "false"]
            || ["true", "false"].contains(option.defaultString.lowercased()) && option.examples.isEmpty
    }

    var body: some View {
        if isBool {
            Toggle(label, isOn: Binding(get: { text.lowercased() == "true" }, set: { text = $0 ? "true" : "false" }))
        } else if !option.examples.isEmpty && option.exclusive {
            Picker(label, selection: $text) {
                if !option.required { Text("Default").tag("") }
                ForEach(option.examples, id: \.value) { ex in
                    Text(ex.help.isEmpty ? ex.value : "\(ex.value) — \(ex.help.split(separator: "\n").first ?? "")").tag(ex.value)
                }
            }
        } else if option.isPassword {
            SecureField(label, text: $text)
        } else {
            HStack {
                TextField(label, text: $text, prompt: Text(option.defaultString.isEmpty ? (option.required ? String(localized: "Required") : String(localized: "Optional")) : option.defaultString))
                if !option.examples.isEmpty {
                    Menu {
                        ForEach(option.examples, id: \.value) { ex in
                            Button(ex.help.isEmpty ? ex.value : "\(ex.value) — \(ex.help.split(separator: "\n").first ?? "")") { text = ex.value }
                        }
                    } label: { Image(systemName: "chevron.down.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            }
        }
    }
}
