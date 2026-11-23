import FSKit
import SwiftUI

struct DrivesView: View {
	let store: DriveStore
	@State private var adding = false
	@State private var removing: DriveConfig?

	var body: some View {
		Group {
			if store.drives.isEmpty {
				ContentUnavailableView {
					Label("No Drives", systemImage: "externaldrive")
				} description: {
					Text("Connect an S3-compatible bucket to use it as a drive in Finder.")
				} actions: {
					Button("Add Drive…") { adding = true }
				}
			} else {
				list
			}
		}
		.frame(minWidth: 480, minHeight: 320)
		.sheet(isPresented: $adding) { AddDriveView(store: store) }
		.onAppear { store.refresh() }
	}

	private var list: some View {
		Form {
			if store.isExtensionDisabled {
				Section {
					LabeledContent("Stash is turned off in File System Extensions settings.") {
						Button("Open Settings") { FSClient.shared.openFileSystemExtensionsSettings() }
					}
				}
			} else if let error = store.mountError {
				Section { Label(error.localizedDescription, systemImage: "exclamationmark.triangle") }
			}
			Section {
				ForEach(store.drives) { drive in
					LabeledContent {
						Text(store.mountPoints[drive.id] != nil ? "Mounted" : "Not mounted")
							.foregroundStyle(.secondary)
						Button("Remove", systemImage: "trash") { removing = drive }
							.labelStyle(.iconOnly)
							.buttonStyle(.borderless)
					} label: {
						Label {
							Text(drive.name)
							Text("\(URL(string: drive.endpoint)?.host() ?? drive.endpoint)/\(drive.bucket)")
						} icon: {
							Image(systemName: "externaldrive.fill")
						}
					}
				}
			}
		}
		.formStyle(.grouped)
		.safeAreaInset(edge: .bottom) {
			HStack {
				Spacer()
				Button("Add Drive…") { adding = true }
			}
			.padding([.horizontal, .bottom], 20)
		}
		.confirmationDialog("Remove “\(removing?.name ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { drive in
			Button("Remove", role: .destructive) { Task { await store.remove(drive) } }
		} message: { _ in
			Text("The drive is ejected and its keys are deleted from this Mac. Files in the bucket stay.")
		}
	}
}

struct AddDriveView: View {
	let store: DriveStore
	@Environment(\.dismiss) private var dismiss
	@State private var name = ""
	@State private var endpoint = ""
	@State private var bucket = ""
	@State private var accessKey = ""
	@State private var secretKey = ""
	@State private var encrypted = false
	@State private var password = ""
	@State private var connecting = false
	@State private var error: String?

	private var canConnect: Bool {
		![endpoint, bucket, accessKey, secretKey].contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }
			&& (!encrypted || !password.isEmpty)
	}

	var body: some View {
		Form {
			Section {
				TextField("Name", text: $name, prompt: Text(bucket.isEmpty ? "My Drive" : bucket))
				TextField("Endpoint", text: $endpoint, prompt: Text("https://hel1.your-objectstorage.com"))
				TextField("Bucket", text: $bucket)
			}
			Section {
				TextField("Access key", text: $accessKey)
				SecureField("Secret key", text: $secretKey)
			}
			Section {
				Toggle("Encrypt files", isOn: $encrypted)
				if encrypted { SecureField("Password", text: $password) }
			} footer: {
				Text("Compatible with rclone crypt.")
					.foregroundStyle(.secondary)
			}
			if let error {
				Section { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
			}
		}
		.formStyle(.grouped)
		.disabled(connecting)
		.safeAreaInset(edge: .bottom) {
			HStack {
				if connecting { ProgressView().controlSize(.small) }
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Connect", action: connect)
					.keyboardShortcut(.defaultAction)
					.disabled(!canConnect || connecting)
			}
			.padding([.horizontal, .bottom], 20)
		}
		.frame(width: 480)
		.fixedSize(horizontal: false, vertical: true)
	}

	private func connect() {
		let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
		let config = DriveConfig(
			name: trim(name).isEmpty ? trim(bucket) : trim(name),
			endpoint: trim(endpoint),
			bucket: trim(bucket),
			encrypted: encrypted
		)
		let secrets = DriveSecrets(accessKey: trim(accessKey), secretKey: secretKey, password: encrypted ? password : nil)
		connecting = true
		error = nil
		Task {
			do {
				try await store.add(config, secrets: secrets)
				dismiss()
			} catch {
				self.error = error.localizedDescription
			}
			connecting = false
		}
	}
}
