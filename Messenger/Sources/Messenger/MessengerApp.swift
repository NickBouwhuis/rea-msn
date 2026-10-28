import AppKit
import MSNKit
import SwiftUI

@main
struct MessengerApp: App {
	@NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
	@StateObject private var app = AppModel.shared

	var body: some Scene {
		Window("Windows Live Messenger", id: "main") {
			MainView()
				.environmentObject(app)
				.frame(minWidth: 280, idealWidth: 310, minHeight: 560, idealHeight: 700)
		}
		.defaultSize(width: 310, height: 700)
		.windowStyle(.hiddenTitleBar)
		.windowResizability(.contentMinSize)
		.commands { MessengerCommands(app: app) }

		Settings {
			OptionsView().environmentObject(app)
		}
	}
}

final class AppDelegate: NSObject, NSApplicationDelegate {
	func applicationWillFinishLaunching(_ notification: Notification) {
		// WLM's skin is light-only: in Dark Mode, controls would draw light
		// text into its white fields.
		NSApp.appearance = NSAppearance(named: .aqua)
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		// SwiftPM executables launch as background processes unless told otherwise.
		NSApp.setActivationPolicy(.regular)
		NSApp.activate(ignoringOtherApps: true)
		MainActor.assumeIsolated {
			if let icon = Skin.shared.appIcon { NSApp.applicationIconImage = icon }
		}

		// Development hooks: MESSENGER_SERVER=local|escargot, MESSENGER_AUTOLOGIN=email:password
		let env = ProcessInfo.processInfo.environment
		Task { @MainActor in
			let app = AppModel.shared
			if let server = env["MESSENGER_SERVER"].flatMap(AppSettings.ServerChoice.init(rawValue:)) {
				app.settings.server = server
			}
			if let auto = env["MESSENGER_AUTOLOGIN"], let colon = auto.firstIndex(of: ":") {
				app.signIn(email: String(auto[..<colon]), password: String(auto[auto.index(after: colon)...]),
				           status: .online, rememberMe: true, rememberPassword: false, auto: false)
			}
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

	func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
		if !flag { sender.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Windows Live Messenger" }?.makeKeyAndOrderFront(nil) }
		return true
	}
}

struct MainView: View {
	@EnvironmentObject var app: AppModel

	var body: some View {
		Group {
			if app.phase == .signedIn {
				ContactListView()
			} else {
				SignInView()
			}
		}
		.alert("Windows Live Messenger", isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } })) {
			Button("OK") { app.alert = nil }
		} message: {
			Text(app.alert ?? "")
		}
	}
}

/// Menu bar modelled on WLM 8.1's File / Contacts / Actions / Tools menus.
struct MessengerCommands: Commands {
	@ObservedObject var app: AppModel

	var body: some Commands {
		CommandGroup(replacing: .newItem) {
			if app.phase == .signedIn {
				Menu("My Status") {
					ForEach(Presence.selectable, id: \.self) { p in
						Button(p.displayName) { app.setStatus(p) }
					}
				}
				Divider()
				Button("Sign Out") { app.signOut() }.keyboardShortcut("o", modifiers: [.command, .shift])
			}
		}
		CommandMenu("Contacts") {
			Button("Add a Contact...") { NotificationCenter.default.post(name: .addContactRequested, object: nil) }
				.keyboardShortcut("n", modifiers: [.command, .shift])
				.disabled(app.phase != .signedIn)
			Divider()
			Toggle("Sort Contacts by Groups", isOn: $app.settings.sortByGroups)
			Toggle("Show Offline Contacts", isOn: $app.settings.showOfflineContacts)
		}
		CommandMenu("Actions") {
			Menu("Send an Instant Message") {
				ForEach(app.contacts.filter { $0.status.isOnline }) { c in
					Button(c.displayName) { app.openConversation(c.email) }
				}
			}
			.disabled(app.phase != .signedIn)
			Menu("Send a Nudge") {
				ForEach(app.contacts.filter { $0.status.isOnline }) { c in
					Button(c.displayName) { app.openConversation(c.email); app.nudge(c.email) }
				}
			}
			.disabled(app.phase != .signedIn)
		}
	}
}

struct OptionsView: View {
	@EnvironmentObject var app: AppModel
	@State private var name = ""

	var body: some View {
		TabView {
			Form {
				Section("Personal") {
					TextField("Display name", text: $name)
						.onSubmit { app.setName(name) }
					Button("Save display name") { app.setName(name) }
						.disabled(app.phase != .signedIn || name.isEmpty)
				}
				Section("Messages") {
					Toggle("Show emoticons", isOn: $app.settings.convertEmoticons)
					Toggle("Display alerts when contacts come online or send messages", isOn: $app.settings.showToasts)
					Toggle("Play sounds", isOn: $app.settings.playSounds)
					Text("Original WLM sounds can be imported with scripts/import-wlm-sounds.sh.")
						.font(.caption).foregroundStyle(.secondary)
				}
			}
			.formStyle(.grouped)
			.tabItem { Label("General", systemImage: "person.crop.circle") }

			Form {
				Picker("Service", selection: $app.settings.server) {
					ForEach(AppSettings.ServerChoice.allCases) { Text($0.title).tag($0) }
				}
				if app.settings.server == .custom {
					TextField("Notification server host", text: $app.settings.customNSHost)
					TextField("Port", value: $app.settings.customNSPort, format: .number.grouping(.never))
					TextField("HTTPS base URL (RST.srf, abservice)", text: $app.settings.customHTTPBase)
				}
				Text("Changes apply the next time you sign in.").font(.caption).foregroundStyle(.secondary)
			}
			.formStyle(.grouped)
			.tabItem { Label("Connection", systemImage: "network") }
		}
		.frame(width: 460, height: 340)
		.onAppear { name = app.myName }
	}
}
