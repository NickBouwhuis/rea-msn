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
			label(s.string(61279, "E-mail address:"))
			HStack(spacing: 0) {
				TextField("", text: $email)
					.textFieldStyle(.plain)
					.font(WLMFont.regular(13))
					.textContentType(.username)
					.padding(EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4))
					.onChange(of: email) { _, new in loadSaved(for: new) }
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

			label(s.string(61282, "Password:"))
			SecureField("", text: $password)
				.textFieldStyle(WLMTextFieldStyle())
				.textContentType(.password)
				.onSubmit(signIn)
				.padding(EdgeInsets(top: 2, leading: 0, bottom: 5, trailing: 0))

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
				WLMCheckbox(title: s.string(61295, "Remember my password"), isOn: $rememberPassword)
					.padding(.vertical, 3)
				WLMCheckbox(title: s.string(61298, "Sign me in automatically"), isOn: $auto, enabled: rememberPassword)
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
			WLMLink(title: s.string(61301, "Forgot your password?")) { NSWorkspace.shared.open(URL(string: "https://escargot.chat/forgot/")!) }
			WLMLink(title: s.string(61303, "Service status")) { NSWorkspace.shared.open(URL(string: "https://escargot.chat/")!) }
			WLMLink(title: "Connect to: \(app.settings.server == .escargot ? "escargot.chat" : app.settings.server.title)") {
				showServer.toggle()
			}
			.popover(isPresented: $showServer) { serverPicker }
		}
		.frame(width: 226, alignment: .leading)
		.padding(.bottom, 12)
	}

	private var serverPicker: some View {
		VStack(alignment: .leading, spacing: 8) {
			Picker("", selection: $app.settings.server) {
				ForEach(AppSettings.ServerChoice.allCases) { Text($0.title).tag($0) }
			}
			.labelsHidden()
			.pickerStyle(.radioGroup)
			if app.settings.server == .custom {
				TextField("Notification server host", text: $app.settings.customNSHost)
				TextField("HTTPS base URL", text: $app.settings.customHTTPBase)
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

	private func signIn() {
		app.signIn(email: email, password: password, status: status, rememberMe: rememberMe,
		           rememberPassword: rememberPassword, auto: auto)
	}
}
