import MSNKit
import SwiftUI

/// mainwnd (msgsres.dll UIFILE 923 / mainwndss): WLM frame, "Me" area
/// (tile, name + status dropdown, personal message, toolbar), then the
/// AddressBook panel (UIFILE 1001: search + toolbar; rows from 1009 "Basic").
struct ContactListView: View {
	@EnvironmentObject var app: AppModel
	@State private var search = ""
	@State private var collapsed: Set<String> = []
	@State private var selection: String?
	@State private var showAddContact = false
	@State private var pendingDelete: Contact?
	@FocusState private var searchFocused: Bool

	var body: some View {
		WLMChrome {
			VStack(spacing: 0) {
				MeArea()
				addressBook
					.padding(EdgeInsets(top: 0, leading: 0, bottom: 5, trailing: 8))
					.padding(.leading, 8)
			}
		}
		.sheet(isPresented: $showAddContact) { AddContactSheet() }
		.sheet(item: Binding(get: { app.addRequests.first }, set: { _ in })) { req in
			AddedYouSheet(request: req)
		}
		.confirmationDialog("Delete contact", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
		                    presenting: pendingDelete) { c in
			Button("Delete contact") { app.removeContact(c.email, block: false) }
			Button("Delete and block") { app.removeContact(c.email, block: true) }
			Button("Cancel", role: .cancel) {}
		} message: { c in
			Text("Are you sure you want to delete \(c.displayName) (\(c.email)) from your contact list?")
		}
		.onReceive(NotificationCenter.default.publisher(for: .addContactRequested)) { _ in showAddContact = true }
	}

	// MARK: AddressBook (UIFILE 1001)

	private var addressBook: some View {
		VStack(spacing: 0) {
			HStack(spacing: 0) {
				searchField
				HStack(spacing: 2) {
					ToolbarIconButton(id: R.addContact, symbol: "person.badge.plus", help: Skin.shared.string(49110, "Add a contact")) {
						showAddContact = true
					}
					Menu {
						Toggle("Sort contacts by groups", isOn: $app.settings.sortByGroups)
						Toggle("Show offline contacts", isOn: $app.settings.showOfflineContacts)
						Toggle("Show emoticons", isOn: $app.settings.convertEmoticons)
					} label: {
						HStack(spacing: 1) {
							SkinImage(R.viewMenu) { Image(systemName: "list.bullet") }
							SkinImage(R.caret) { Image(systemName: "chevron.down").font(.system(size: 7)) }
						}
						.padding(3)
					}
					.menuStyle(.borderlessButton)
					.menuIndicator(.hidden)
					.fixedSize()
				}
				.padding(EdgeInsets(top: 0, leading: 7, bottom: 0, trailing: 5))
			}
			.padding(EdgeInsets(top: 7, leading: 7, bottom: 7, trailing: 2))
			.overlay(alignment: .bottom) { R.searchBorder.frame(height: 1) }

			list
		}
		.background(Color.white)
		.overlay(Rectangle().stroke(R.listBorder, lineWidth: 1))
	}

	/// wordWheelTextBackground: min height 23, hint "Find a contact or number..." in #ACA899.
	private var searchField: some View {
		ZStack(alignment: .leading) {
			if search.isEmpty {
				Text(Skin.shared.string(45845, "Find a contact or number..."))
					.font(WLMFont.regular())
					.foregroundStyle(R.hint)
					.padding(.leading, 9)
					.allowsHitTesting(false)
			}
			HStack(spacing: 0) {
				TextField("", text: $search)
					.textFieldStyle(.plain)
					.font(WLMFont.regular(12))
					.focused($searchFocused)
					.padding(.leading, 9)
				if !search.isEmpty {
					Button { search = "" } label: {
						SkinImage(R.searchClear) { Image(systemName: "xmark.circle.fill").foregroundStyle(R.hint) }
					}
					.buttonStyle(.plain)
					.padding(.trailing, 5)
				}
			}
		}
		.frame(minHeight: 23)
		.background(Color.white)
		.overlay(Rectangle().stroke(Color(rgb: 0xAAB7C7), lineWidth: 1))
	}

	private struct Section: Identifiable {
		let id: String
		let title: String
		let contacts: [Contact]
		let onlineCount: Int
		let showsOnline: Bool
	}

	private var sections: [Section] {
		let q = search.trimmingCharacters(in: .whitespaces).lowercased()
		let visible = app.contacts.filter {
			q.isEmpty || $0.displayName.lowercased().contains(q) || $0.email.contains(q) || $0.personalMessage.lowercased().contains(q)
		}
		let order: (Contact, Contact) -> Bool = { a, b in
			if a.status.isOnline != b.status.isOnline { return a.status.isOnline }
			return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
		}
		func online(_ cs: [Contact]) -> Int { cs.filter { $0.status.isOnline }.count }
		if app.settings.sortByGroups {
			var out: [Section] = []
			for g in app.groups.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
				let members = visible.filter { $0.groupIDs.contains(g.groupID) }.sorted(by: order)
				out.append(Section(id: g.groupID, title: g.name, contacts: members, onlineCount: online(members), showsOnline: true))
			}
			let known = Set(app.groups.map(\.groupID))
			let other = visible.filter { Set($0.groupIDs).isDisjoint(with: known) }.sorted(by: order)
			out.append(Section(id: "other", title: Skin.shared.string(45469, "Other Contacts"), contacts: other, onlineCount: online(other), showsOnline: true))
			return out
		}
		let on = visible.filter { $0.status.isOnline }.sorted(by: order)
		let off = visible.filter { !$0.status.isOnline }.sorted(by: order)
		var out = [Section(id: "online", title: Skin.shared.string(45207, "Online"), contacts: on, onlineCount: on.count, showsOnline: false)]
		if app.settings.showOfflineContacts {
			out.append(Section(id: "offline", title: Skin.shared.string(45208, "Offline"), contacts: off, onlineCount: 0, showsOnline: false))
		}
		return out
	}

	private var list: some View {
		ScrollView {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(sections) { section in
					GroupRow(title: section.title, online: section.onlineCount, total: section.contacts.count,
					         showsOnline: section.showsOnline, collapsed: collapsed.contains(section.id)) {
						if collapsed.contains(section.id) { collapsed.remove(section.id) } else { collapsed.insert(section.id) }
					}
					if !collapsed.contains(section.id) {
						ForEach(section.contacts) { c in
							// Section-scoped identity: the same contact moves between
							// Online/Offline and LazyVStack would otherwise reuse a stale row.
							BuddyRow(contact: c, selected: selection == c.email)
								.id("\(section.id)|\(c.email)")
								.contentShape(Rectangle())
								.onTapGesture(count: 2) { app.openConversation(c.email) }
								.simultaneousGesture(TapGesture().onEnded { selection = c.email })
								.contextMenu { contextMenu(c) }
						}
					}
				}
				if app.contacts.isEmpty {
					VStack(alignment: .leading, spacing: 6) {
						Text("You don't have any contacts yet.").font(WLMFont.regular()).foregroundStyle(R.text)
						WLMLink(title: Skin.shared.string(49110, "Add a contact")) { showAddContact = true }
					}
					.padding(10)
				}
			}
			.padding(.vertical, 3)
		}
		.background(Color.white)
	}

	@ViewBuilder
	private func contextMenu(_ c: Contact) -> some View {
		Button("Send an instant message") { app.openConversation(c.email) }
		Button("Send a nudge") { app.openConversation(c.email); app.nudge(c.email) }.disabled(!c.status.isOnline)
		Divider()
		Button("Copy e-mail address") {
			NSPasteboard.general.clearContents()
			NSPasteboard.general.setString(c.email, forType: .string)
		}
		Divider()
		if c.isBlocked {
			Button("Unblock contact") { app.setBlocked(c.email, false) }
		} else {
			Button("Block contact") { app.setBlocked(c.email, true) }
		}
		Button("Delete contact...") { pendingDelete = c }
	}
}

/// Group header (UIFILE 1004 GroupTemplate): expand/collapse icon 1382,
/// bold #333 name, "(online/total)".
private struct GroupRow: View {
	let title: String
	let online: Int
	let total: Int
	let showsOnline: Bool
	let collapsed: Bool
	let toggle: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			SkinImage(R.expandCollapse, frame: collapsed ? 1 : 0) {
				Image(systemName: collapsed ? "plus.square" : "minus.square").font(.system(size: 9)).foregroundStyle(R.hint)
			}
			.frame(width: 14)
			Text(title).font(WLMFont.bold()).foregroundStyle(R.text).padding(.leading, 5)
			Text(showsOnline ? " (\(online)/\(total))" : " (\(total))").font(WLMFont.bold()).foregroundStyle(R.text)
			Spacer(minLength: 0)
		}
		.padding(EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 2))
		.frame(minHeight: 19)
		.contentShape(Rectangle())
		.onTapGesture(perform: toggle)
	}
}

/// BuddyTemplate (UIFILE 1009, class "Light"): 41pt left gutter with the
/// status pill right-aligned, then name and " - personal message".
private struct BuddyRow: View {
	let contact: Contact
	let selected: Bool
	@EnvironmentObject var app: AppModel
	@Environment(\.controlActiveState) private var active

	var body: some View {
		HStack(spacing: 0) {
			HStack {
				Spacer(minLength: 0)
				StatusIcon(presence: contact.status, blocked: contact.isBlocked)
			}
			.frame(width: 41)
			HStack(spacing: 0) {
				Emoticons.text(contact.displayName, enabled: app.settings.convertEmoticons)
					.foregroundStyle(Color.black)
				if contact.status.isOnline, contact.status != .online {
					Text(" (\(contact.status.displayName))").foregroundStyle(Color.black)
				}
				let psm = contact.currentMedia.isEmpty ? contact.personalMessage : "♫ \(contact.currentMedia)"
				if !psm.isEmpty {
					Text(" - ").foregroundStyle(Color(rgb: 0x777777))
					Emoticons.text(psm, enabled: app.settings.convertEmoticons).foregroundStyle(Color(rgb: 0x777777))
				}
			}
			.font(WLMFont.regular())
			.lineLimit(1)
			.truncationMode(.tail)
			.padding(.leading, 3)
			Spacer(minLength: 0)
		}
		.frame(minHeight: 20)
		.background(selected ? (active == .inactive ? R.selectionInactive : R.selection) : Color.clear)
		.help("\(contact.displayName) <\(contact.email)>")
	}
}

/// MeArea (mainwndss): background 638, tile at left, name/status dropdown,
/// personal message, toolbar of service icons.
private struct MeArea: View {
	@EnvironmentObject var app: AppModel

	var body: some View {
		HStack(alignment: .top, spacing: 0) {
			UserTile(seed: app.myEmail, size: 48)
				.padding(.trailing, 5)
			VStack(alignment: .leading, spacing: 0) {
				StatusMenu(current: app.myStatus, pick: app.setStatus) {
					TransparentHover {
						HStack(spacing: 3) {
							Emoticons.text(app.myName, enabled: app.settings.convertEmoticons)
								.font(WLMFont.bold()).foregroundStyle(R.text).lineLimit(1)
							Text("(\(app.myStatus.displayName))").font(WLMFont.regular()).foregroundStyle(R.text)
							SkinImage(R.caret) { Image(systemName: "chevron.down").font(.system(size: 7)) }
								.padding(.leading, 2)
							Spacer(minLength: 0)
						}
						.padding(EdgeInsets(top: 3, leading: 2, bottom: 3, trailing: 4))
					}
				}
				TransparentHover {
					InlineEditable(text: app.myMessage, placeholder: Skin.shared.string(61130, "<Enter a personal message>"),
					               font: WLMFont.regular(), color: R.text) {
						app.setPersonalMessage($0)
					}
					.padding(EdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2))
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				HStack(spacing: 2) {
					ForEach(R.toolbarIcons, id: \.self) { id in
						ToolbarIconButton(id: id, symbol: "circle", help: "") {}
							.opacity(0.9)
					}
				}
				.padding(EdgeInsets(top: 4, leading: 0, bottom: 3, trailing: 0))
			}
		}
		.padding(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 10))
		.background { SkinFill(id: R.meAreaBackground) }
	}
}

/// TransparentButton toolbar icon with the 20201 hover background.
struct ToolbarIconButton: View {
	let id: Int
	let symbol: String
	let help: String
	let action: () -> Void

	var body: some View {
		Button(action: action) {
			TransparentHover {
				SkinImage(id) { Image(systemName: symbol).foregroundStyle(R.text) }
					.padding(3)
			}
		}
		.buttonStyle(.plain)
		.help(help)
	}
}

struct AddContactSheet: View {
	@EnvironmentObject var app: AppModel
	@Environment(\.dismiss) private var dismiss
	@State private var email = ""

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			Text("Add a Contact").font(.system(size: 15, weight: .semibold)).foregroundStyle(WLM.ink)
			Text("Instant messaging address:").font(.system(size: 11)).foregroundStyle(WLM.ink)
			TextField("Example: someone@escargot.chat", text: $email)
				.textFieldStyle(.roundedBorder)
				.onSubmit(add)
			Text("Your contact will be asked to approve your request before you can see their status.")
				.font(.system(size: 10)).foregroundStyle(WLM.muted)
				.fixedSize(horizontal: false, vertical: true)
			HStack {
				Spacer()
				Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
				Button("Add contact", action: add).keyboardShortcut(.defaultAction).disabled(!email.contains("@"))
			}
		}
		.padding(18)
		.frame(width: 340)
	}

	private func add() {
		app.addContact(email)
		dismiss()
	}
}

/// "X has added you to their contact list" (WLM 8.1 wording).
struct AddedYouSheet: View {
	@EnvironmentObject var app: AppModel
	let request: AppModel.AddRequest
	@State private var allow = true
	@State private var addToList = true

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 10) {
				UserTile(seed: request.email, size: 40)
				VStack(alignment: .leading, spacing: 2) {
					Text("\(request.displayName) (\(request.email))").font(.system(size: 12, weight: .semibold)).foregroundStyle(WLM.ink)
					Text("has added you to his or her contact list.").font(.system(size: 12)).foregroundStyle(WLM.ink)
				}
			}
			Picker("", selection: $allow) {
				Text("Allow this person to see when you are online and contact you").tag(true)
				Text("Block this person from seeing when you are online and contacting you").tag(false)
			}
			.pickerStyle(.radioGroup)
			.labelsHidden()
			.font(.system(size: 11))
			Toggle("Add this person to my contact list", isOn: $addToList)
				.toggleStyle(.checkbox)
				.font(.system(size: 11))
				.disabled(!allow)
			HStack {
				Spacer()
				Button("OK") { app.respond(to: request, allow: allow, addToList: allow && addToList) }
					.keyboardShortcut(.defaultAction)
			}
		}
		.padding(18)
		.frame(width: 420)
	}
}

extension Notification.Name {
	static let addContactRequested = Notification.Name("addContactRequested")
}
