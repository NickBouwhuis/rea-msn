import SwiftUI

/// "Verify this session" for Matrix accounts: compare emoji with another of
/// your sessions (either side can start), or enter your recovery key. Until
/// it's verified, other people's clients may not share message keys with it.
struct VerificationView: View {
	@EnvironmentObject var app: AppModel
	@State private var recoveryKey = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 8) {
				Image(systemName: "lock.shield").font(.system(size: 22)).foregroundStyle(Color(rgb: 0x1E3287))
				Text("Verify this session").font(WLMFont.bold(13)).foregroundStyle(Color(rgb: 0x1E3287))
			}
			content
		}
		.padding(18)
		.frame(width: 400)
		.background(LinearGradient(colors: [.white, Color(rgb: 0xEAF1F6)], startPoint: .top, endPoint: .bottom))
	}

	@ViewBuilder
	private var content: some View {
		switch app.verification {
		case .prompt?, nil:
			text("Messenger is a new session on your Matrix account. Verify it, and your other sessions (such as Element) will trust it with the keys to your encrypted conversations.")
			buttons {
				Button("Not now") { app.closeVerification() }.buttonStyle(WLMPushButtonStyle())
				Button("Use recovery key") { app.verification = .recoveryKey }.buttonStyle(WLMPushButtonStyle())
				Button("Use another session") { app.verifyWithOtherSession() }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
			}
		case let .waiting(message)?:
			HStack(spacing: 8) {
				ProgressView().controlSize(.small)
				text(message)
			}
			buttons { Button("Cancel") { app.closeVerification() }.buttonStyle(WLMPushButtonStyle()) }
		case let .incoming(device)?:
			text("Your session \u{201C}\(device)\u{201D} wants to verify this one. Accept, then compare the emoji on both screens.")
			buttons {
				Button("Not now") { app.closeVerification() }.buttonStyle(WLMPushButtonStyle())
				Button("Accept") { app.acceptIncomingVerification() }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
			}
		case let .emojis(emojis)?:
			text("Do these appear on your other session, in the same order?")
			emojiGrid(emojis)
			buttons {
				Button("They don't match") { app.confirmEmojis(false) }.buttonStyle(WLMPushButtonStyle())
				Button("They match") { app.confirmEmojis(true) }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
			}
		case .recoveryKey?:
			text("Enter the recovery key you saved when you set up secure backup (it starts with \u{201C}Es\u{201D}).")
			TextField("", text: $recoveryKey, prompt: Text("EsTc ..."))
				.textFieldStyle(WLMTextFieldStyle())
				.font(.system(size: 12, design: .monospaced))
				.onSubmit { if !recoveryKey.isEmpty { app.recover(recoveryKey) } }
			buttons {
				Button("Back") { app.verification = .prompt }.buttonStyle(WLMPushButtonStyle())
				Button("Verify") { app.recover(recoveryKey) }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
					.disabled(recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
			}
		case .done?:
			text("This session is verified. Your other sessions can now share keys with it, and new encrypted messages will open here.")
			buttons {
				Button("OK") { app.verification = nil }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
			}
		case let .failed(message)?:
			text(message)
			buttons {
				Button("Close") { app.closeVerification() }.buttonStyle(WLMPushButtonStyle())
				Button("Try again") { app.verification = .prompt }
					.buttonStyle(WLMPushButtonStyle(isDefault: true)).keyboardShortcut(.defaultAction)
			}
		}
	}

	/// Seven emoji, as Element lays them out: four, then three.
	private func emojiGrid(_ emojis: [AppModel.Emoji]) -> some View {
		VStack(spacing: 10) {
			ForEach([Array(emojis.prefix(4)), Array(emojis.dropFirst(4))], id: \.self) { row in
				HStack(spacing: 14) {
					ForEach(Array(row.enumerated()), id: \.offset) { _, emoji in
						VStack(spacing: 4) {
							Text(emoji.symbol).font(.system(size: 34))
							Text(emoji.name).font(WLMFont.regular()).foregroundStyle(R.text)
						}
						.frame(width: 76)
					}
				}
			}
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 6)
	}

	private func text(_ s: String) -> some View {
		Text(s).font(WLMFont.regular(12)).foregroundStyle(R.text).fixedSize(horizontal: false, vertical: true)
	}

	private func buttons<B: View>(@ViewBuilder _ content: () -> B) -> some View {
		HStack(spacing: 6) {
			Spacer()
			content()
		}
	}
}
