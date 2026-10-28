import CGtk
import Foundation
import MSNKit

// Windows Live Messenger 8.1 for Linux (GTK4), on the shared MSNKit protocol
// library. Dev hooks as on macOS: MESSENGER_SERVER=local|escargot|<host>,
// MESSENGER_MATRIX_HOMESERVER=url, MESSENGER_AUTOLOGIN=email:password (or
// @user:server:password), MESSENGER_DEBUG=1 for the protocol log.

let app = raw(gtk_application_new("chat.messenger.wlm81", GApplicationFlags(rawValue: 0)))
var mainWindow: MainWindow?

on(app, "activate") {
	MainActor.assumeIsolated {
		if let existing = mainWindow { existing.present(); return }
		let state = AppState.shared
		state.app = app
		loadCSS(Skin.shared.css)
		// The real Messenger icon, installed under this name by linux/scripts/install.sh.
		gtk_window_set_default_icon_name("chat.messenger.wlm81")
		let env = ProcessInfo.processInfo.environment
		switch env["MESSENGER_SERVER"] {
		case "local": state.settings.server = .local
		case "escargot": state.settings.server = .escargot
		case let host?: state.settings.server = .custom; state.settings.customHost = host
		case nil: break
		}
		if let homeserver = env["MESSENGER_MATRIX_HOMESERVER"] { state.settings.matrixHomeserver = homeserver }
		let w = MainWindow(app: app)
		mainWindow = w
		w.present()
		if let auto = env["MESSENGER_AUTOLOGIN"], let colon = auto.hasPrefix("@") ? auto.lastIndex(of: ":") : auto.firstIndex(of: ":") {
			state.signIn(email: String(auto[..<colon]), password: String(auto[auto.index(after: colon)...]),
			             status: .online, rememberMe: true, rememberPassword: false)
		}
	}
}

pumpSwiftMainQueue()
exit(g_application_run(c(app), CommandLine.argc, CommandLine.unsafeArgv))
