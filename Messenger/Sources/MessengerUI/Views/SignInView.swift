import MSNKit
import SwiftUI

/// logonFrame (msgsres.dll UIFILE 947 / logonFrameSS): user tile at 30pt, a
/// 226pt column of fields, three checkboxes, "Sign in", help links, and the
/// "Windows Live ID" footer.
struct SignInView: View {
	@EnvironmentObject var app: AppModel
	@State private var email = ""
	@State private var password = ""
	@State private var status: Presence = .online
	@State private var rememberMe = true
	@State private var rememberPassword = false
	@State private var auto = false
	@State private var showServer = false
	@State private var didAutoSignIn = false
	/// Shown instead of the password box when this account needs none here
	/// (Matrix: browser sign-in, a saved session); nil asks for the password.
	@State private var passwordNote: String?
	@State private var noteCheck: Task<Void, Never>?
	private let s = Skin.shared

	var body: some View {
		WLMChrome {
			VStack(spacing: 0) {
				UserTile(seed: email)
					.padding(.top, 30)
					.padding(.bottom, 17)
				if case let .signingIn(message) = app.phase {
					signingIn(message)
				} else {
					form
				}
				Spacer(minLength: 0)
				links
				footer
			}
			.padding(.horizontal, 8)
		}
		.frame(minWidth: 280, minHeight: 560)
		.onAppear(perform: restore)
	}

	private var form: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let error = app.signInError {
				Text(error)
					.font(WLMFont.regular())
					.foregroundStyle(Color(rgb: 0xCC0000))
					.fixedSize(horizontal: false, vertical: true)
					.padding(.bottom, 8)
			}
			label(app.profile.connection == .msnServer ? s.string(61279, app.profile.accountLabel) : app.profile.accountLabel)
			HStack(spacing: 0) {
				TextField("", text: $email)
					.textFieldStyle(.plain)
					.font(WLMFont.regular(13))
					.textContentType(.username)
					.padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
					.onChange(of: email) { _, new in
						loadSaved(for: new)
						checkPasswordNote(new)
					}
				Menu {
					ForEach(app.settings.rememberedAccounts, id: \.self) { acct in Button(acct) { email = acct } }
				} label: {
					SkinImage(R.caret) { Image(systemName: "chevron.down") }
				}
				.menuStyle(.borderlessButton)
				.menuIndicator(.hidden)
				.frame(width: 17)
				.disabled(app.settings.rememberedAccounts.isEmpty)
			}
			.background(Color.white)
			.overlay(Rectangle().stroke(Color(rgb: 0xAAB7C7), lineWidth: 1))
			.padding(EdgeInsets(top: 2, leading: 0, bottom: 8, trailing: 0))

			if let note = passwordNote {
				Text(note)
					.font(WLMFont.regular())
					.foregroundStyle(R.hint)
					.fixedSize(horizontal: false, vertical: true)
					.padding(EdgeInsets(top: 0, leading: 0, bottom: 5, trailing: 0))
			} else {
				label(s.string(61282, "Password:"))
				SecureField("", text: $password)
					.textFieldStyle(WLMTextFieldStyle())
					.textContentType(.password)
					.onSubmit(signIn)
					.padding(EdgeInsets(top: 2, leading: 0, bottom: 5, trailing: 0))
			}

			HStack(spacing: 2) {
				label(s.string(61286, "Status:")).padding(.vertical, 4)
				StatusMenu(current: status, pick: { status = $0 }) {
					HStack(spacing: 4) {
						Text(status.displayName).font(WLMFont.regular()).foregroundStyle(R.text)
						SkinImage(R.caret) { Image(systemName: "chevron.down").font(.system(size: 7)) }
					}
					.padding(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 1))
				}
			}

			VStack(alignment: .leading, spacing: 0) {
				WLMCheckbox(title: s.string(61288, "Remember me"), isOn: $rememberMe)
					.padding(.vertical, 3)
				Spacer().frame(height: 18)
				WLMCheckbox(title: s.string(61295, "Remember my password"), isOn: $rememberPassword, enabled: passwordNote == nil)
					.padding(.vertical, 3)
				WLMCheckbox(title: s.string(61298, "Sign me in automatically"), isOn: $auto, enabled: rememberPassword && passwordNote == nil)
					.padding(.vertical, 3)
			}
			.padding(.top, 30)

			HStack {
				Spacer()
				Button(s.string(61219, "Sign in"), action: signIn)
					.buttonStyle(WLMPushButtonStyle(isDefault: true))
					.keyboardShortcut(.defaultAction)
				Spacer()
			}
			.padding(.top, 18)
		}
		.frame(width: 226)
	}

	private func signingIn(_ message: String) -> some View {
		VStack(spacing: 10) {
			Text(s.string(11, "Signing in...")).font(WLMFont.regular()).foregroundStyle(R.text)
			Text(email).font(WLMFont.bold()).foregroundStyle(R.text)
			ProgressView().controlSize(.small)
			Text(message).font(WLMFont.regular()).foregroundStyle(R.hint)
			Button(s.string(2054, "Cancel")) { app.cancelSignIn() }
				.buttonStyle(WLMPushButtonStyle())
				.padding(.top, 8)
		}
		.frame(width: 226)
		.padding(.top, 10)
	}

	private var links: some View {
		VStack(alignment: .leading, spacing: 0) {
			if let url = app.profile.forgotPasswordURL {
				WLMLink(title: s.string(61301, "Forgot your password?")) { NSWorkspace.shared.open(url) }
			}
			if let url = app.profile.serviceStatusURL {
				WLMLink(title: s.string(61303, "Service status")) { NSWorkspace.shared.open(url) }
			}
			WLMLink(title: connectionTitle) { showServer.toggle() }
				.popover(isPresented: $showServer) { serverPicker }
		}
		.frame(width: 226, alignment: .leading)
		.padding(.bottom, 12)
	}

	private var connectionTitle: String {
		switch app.profile.connection {
		case .msnServer:
			return "Connect to: \(app.settings.server == .escargot ? "escargot.chat" : app.settings.server.title)"
		case .matrixHomeserver:
			return "Homeserver: \(app.settings.matrixHomeserverURL?.host ?? "found from your Matrix ID")"
		}
	}

	private var serverPicker: some View {
		VStack(alignment: .leading, spacing: 8) {
			switch app.profile.connection {
			case .msnServer:
				Picker("", selection: $app.settings.server) {
					ForEach(AppSettings.ServerChoice.allCases) { Text($0.title).tag($0) }
				}
				.labelsHidden()
				.pickerStyle(.radioGroup)
				if app.settings.server == .custom {
					TextField("Notification server host", text: $app.settings.customNSHost)
					TextField("HTTPS base URL", text: $app.settings.customHTTPBase)
				}
			case .matrixHomeserver:
				Text("Leave this empty to find your homeserver from your Matrix ID.")
					.fixedSize(horizontal: false, vertical: true)
				TextField("https://matrix.example.org", text: Binding(
					get: { app.settings.matrixHomeserver ?? "" },
					set: { app.settings.matrixHomeserver = $0.isEmpty ? nil : $0 }
				))
			}
		}
		.font(WLMFont.regular())
		.padding(12)
		.frame(width: 260)
	}

	private var footer: some View {
		HStack(spacing: 2) {
			SkinImage(R.liveIDLogo)
			Text(s.string(20000, "Windows Live ID")).font(WLMFont.regular()).foregroundStyle(R.text)
			Spacer()
			SkinImage(R.gripper)
		}
		.padding(4)
	}

	private func label(_ text: String) -> some View {
		Text(text).font(WLMFont.regular()).foregroundStyle(R.text)
	}

	private func restore() {
		let st = app.settings
		email = st.lastAccount ?? ""
		status = st.signInStatus
		rememberPassword = st.rememberPassword
		auto = st.signInAutomatically
		loadSaved(for: email)
		checkPasswordNote(email)
		if auto, !didAutoSignIn, !password.isEmpty, app.signInError == nil {
			didAutoSignIn = true
			signIn()
		}
	}

	private func loadSaved(for account: String) {
		if app.settings.rememberPassword, let saved = Keychain.password(for: account.lowercased()) {
			password = saved
		}
	}

	/// Asks the service whether this account needs a password here (Matrix:
	/// the homeserver may sign in through the browser, or there's a saved session).
	private func checkPasswordNote(_ account: String) {
		noteCheck?.cancel()
		passwordNote = nil
		let id = account.trimmingCharacters(in: .whitespaces).lowercased()
		guard !id.isEmpty, app.profile.problem(withAccount: id) == nil else { return }
		let profile = app.profile, homeserver = app.settings.matrixHomeserverURL
		noteCheck = Task {
			try? await Task.sleep(nanoseconds: 500_000_000)  // wait for typing to pause
			guard !Task.isCancelled else { return }
			let note = await profile.passwordNote(for: id, homeserver: homeserver)
			if !Task.isCancelled { passwordNote = note }
		}
	}

	private func signIn() {
		let noPassword = passwordNote != nil
		app.signIn(email: email, password: noPassword ? "" : password, status: status, rememberMe: rememberMe,
		           rememberPassword: rememberPassword && !noPassword, auto: auto && !noPassword)
	}
}
