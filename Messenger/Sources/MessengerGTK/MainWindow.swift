import CGtk
import Foundation
import MSNKit

/// The Messenger main window: sign-in (UIFILE 947) and contact list
/// (UIFILE 923 + 1001/1009) pages in a GtkStack.
@MainActor
final class MainWindow {
	let window: Ptr
	private let stack: Ptr
	private let state = AppState.shared
	private let skin = Skin.shared

	// Sign-in widgets
	private var emailEntry: Ptr!
	private var passwordEntry: Ptr!
	private var statusLabel: Ptr!
	private var statusPopover: Ptr!
	private var rememberMe: Ptr!
	private var rememberPassword: Ptr!
	private var errorLabel: Ptr!
	private var form: Ptr!
	private var progress: Ptr!
	private var progressLabel: Ptr!
	private var signInStatus: Presence = .online

	// Contact list widgets
	private var meName: Ptr!
	private var mePSM: Ptr!
	private var meStatusPopover: Ptr!
	private var list: Ptr!
	private var search: Ptr!
	private var collapsed: Set<String> = []
	private var selected: String?
	private var selectedRow: Ptr?

	init(app: Ptr) {
		(window, _) = Chrome.window(app: app, width: 310, height: 700)
		stack = raw(gtk_stack_new())
		gtk_stack_set_vhomogeneous(c(stack), 0)
		gtk_stack_add_named(c(stack), c(buildSignIn()), "signin")
		gtk_stack_add_named(c(stack), c(buildContactList()), "contacts")
		gtk_window_set_child(c(window), c(stack))
		state.mainWindow = window
		state.onPhase.append { [weak self] in self?.phaseChanged() }
		state.onContacts.append { [weak self] in self?.rebuildList() }
		state.onProfile.append { [weak self] in self?.refreshMe() }
		state.onAddRequest = { [weak self] in self?.showAddRequests() }
		phaseChanged()
	}

	func present() { gtk_window_present(c(window)) }

	// MARK: - Sign in (logonFrame)

	private func buildSignIn() -> Ptr {
		let page = vbox(0)
		margins(page, start: 8, end: 8)

		let tile = userTile(size: 96)
		align(tile, h: GTK_ALIGN_CENTER)
		margins(tile, top: 30, bottom: 17)
		append(page, tile)

		let column = vbox(0)
		gtk_widget_set_size_request(c(column), 226, -1)
		align(column, h: GTK_ALIGN_CENTER, v: GTK_ALIGN_START)
		expand(column)  // explicit: don't let a descendant's vexpand take the slack

		form = vbox(0)
		errorLabel = label("", css: ["wlm-error"], wrap: true)
		gtk_label_set_max_width_chars(c(errorLabel), 30)
		margins(errorLabel, bottom: 8)
		append(form, errorLabel)

		append(form, label(skin.string(61279, "E-mail address:"), css: ["wlm-label"]))
		let emailRow = hbox(0, css: ["wlm-input"])
		emailEntry = raw(gtk_entry_new())
		gtk_entry_set_has_frame(c(emailEntry), 0)
		expand(emailEntry, h: true)
		append(emailRow, emailEntry)
		let accounts = vbox(0)
		let (accountsButton, accountsPopover) = menuButton(picture(skin.image(R.caret)), content: accounts, css: ["wlm-flat"])
		for acct in state.settings.rememberedAccounts {
			append(accounts, menuItem(acct) { [weak self] in
				setText(editable: self!.emailEntry, acct)
				popdown(accountsPopover)
			})
		}
		append(emailRow, accountsButton)
		margins(emailRow, top: 2, bottom: 8)
		append(form, emailRow)

		append(form, label(skin.string(61282, "Password:"), css: ["wlm-label"]))
		passwordEntry = entry(password: true)
		margins(passwordEntry, top: 2, bottom: 5)
		on(passwordEntry, "activate") { [weak self] in self?.signIn() }
		append(form, passwordEntry)

		let statusRow = hbox(4)
		append(statusRow, label(skin.string(61286, "Status:"), css: ["wlm-label"]))
		statusLabel = label(signInStatus.displayName, css: ["wlm-label"])
		let statusContent = hbox(4, [statusLabel, picture(skin.image(R.caret))])
		let statuses = vbox(0)
		let (statusButton, pop) = menuButton(statusContent, content: statuses, css: ["wlm-flat"])
		statusPopover = pop
		for p in Presence.selectable {
			append(statuses, statusItem(p) { [weak self] in
				guard let self else { return }
				self.signInStatus = p
				setText(self.statusLabel, p.displayName)
				popdown(self.statusPopover)
			})
		}
		append(statusRow, statusButton)
		append(form, statusRow)

		let options = vbox(0)
		margins(options, top: 30)
		rememberMe = checkbox(skin.string(61288, "Remember me"), active: true)
		append(options, rememberMe)
		let gap = vbox(0)
		gtk_widget_set_size_request(c(gap), -1, 18)
		append(options, gap)
		rememberPassword = checkbox(skin.string(61295, "Remember my password"), active: state.settings.rememberPassword)
		append(options, rememberPassword)
		append(form, options)

		let signIn = button(label: skin.string(61219, "Sign in"), css: ["wlm-push", "default"]) { [weak self] in self?.signIn() }
		align(signIn, h: GTK_ALIGN_CENTER)
		margins(signIn, top: 18)
		append(form, signIn)
		append(column, form)

		progress = vbox(8)
		align(progress, h: GTK_ALIGN_CENTER)
		append(progress, label(skin.string(11, "Signing in..."), css: ["wlm-label"], xalign: 0.5))
		progressLabel = label("", css: ["wlm-hint"], xalign: 0.5)
		let spinner = raw(gtk_spinner_new())
		gtk_spinner_start(c(spinner))
		append(progress, spinner)
		append(progress, progressLabel)
		append(progress, button(label: skin.string(2054, "Cancel"), css: ["wlm-push"]) { AppState.shared.cancelSignIn() })
		visible(progress, false)
		append(column, progress)
		append(page, column)

		append(page, spacer(v: true))
		let links = vbox(0)
		gtk_widget_set_size_request(c(links), 226, -1)
		align(links, h: GTK_ALIGN_CENTER)
		append(links, link(skin.string(61301, "Forgot your password?"), "https://escargot.chat/forgot/"))
		append(links, link(skin.string(61303, "Service status"), "https://escargot.chat/"))
		append(links, serverPicker())
		margins(links, bottom: 12)
		append(page, links)

		let footer = hbox(2)
		append(footer, picture(skin.image(R.liveIDLogo)))
		append(footer, label(skin.string(20000, "Windows Live ID"), css: ["wlm-label"]))
		append(footer, spacer())
		append(footer, picture(skin.image(R.gripper)))
		margins(footer, top: 4, start: 4, bottom: 4, end: 4)
		append(page, footer)

		setText(editable: emailEntry, state.settings.lastAccount ?? "")
		signInStatus = state.settings.signInStatus
		setText(statusLabel, signInStatus.displayName)
		if state.settings.rememberPassword, let acct = state.settings.lastAccount, let pw = SecretStore.get(acct) {
			setText(editable: passwordEntry, pw)
		}
		return page
	}

	private func link(_ title: String, _ url: String) -> Ptr {
		let b = button(label: title, css: ["wlm-link"]) {
			let launcher = gtk_uri_launcher_new(url)
			gtk_uri_launcher_launch(launcher, nil, nil, nil, nil)
		}
		align(b, h: GTK_ALIGN_START)
		return b
	}

	private func statusItem(_ p: Presence, _ action: @escaping () -> Void) -> Ptr {
		let row = hbox(6, [StatusIcon.picture(p), label(p.displayName, css: ["wlm-label"])])
		return button(row, css: ["wlm-flat"], action)
	}

	private func userTile(size: Int32) -> Ptr {
		let path = skin.image(size > 64 ? R.defaultTileLarge : R.defaultTileSmall)
		let p = picture(path, size: (size, size))
		// A horizontal frame: a vertical box would measure the picture's
		// height at the full column width (GtkPicture keeps aspect ratio).
		expand(p)
		let frame = hbox(0, [p], css: ["wlm-tile"])
		align(frame, h: GTK_ALIGN_START, v: GTK_ALIGN_START)
		expand(frame)
		return frame
	}

	private func signIn() {
		state.signIn(email: text(of: emailEntry), password: text(of: passwordEntry), status: signInStatus,
		             rememberMe: isActive(rememberMe), rememberPassword: isActive(rememberPassword))
	}

	private func phaseChanged() {
		switch state.phase {
		case .signedOut:
			visible(form, true)
			visible(progress, false)
			setText(errorLabel, state.signInError ?? "")
			visible(errorLabel, state.signInError != nil)
			gtk_stack_set_visible_child_name(c(stack), "signin")
		case let .signingIn(message):
			visible(form, false)
			visible(progress, true)
			setText(progressLabel, message)
			gtk_stack_set_visible_child_name(c(stack), "signin")
		case .signedIn:
			refreshMe()
			rebuildList()
			gtk_stack_set_visible_child_name(c(stack), "contacts")
		}
	}

	// MARK: - Contact list (mainwnd + AddressBook)

	private func buildContactList() -> Ptr {
		let page = vbox(0)

		// MeArea: tile, name ▾ (status), personal message, service toolbar.
		let me = hbox(5)
		margins(me, top: 4, start: 12, bottom: 4, end: 10)
		append(me, userTile(size: 48))
		let meText = vbox(0)
		expand(meText, h: true)
		meName = hbox(3)
		let statuses = vbox(0)
		let (nameButton, pop) = menuButton(meName, content: statuses, css: ["wlm-flat"])
		meStatusPopover = pop
		for p in Presence.selectable {
			append(statuses, statusItem(p) { [weak self] in
				AppState.shared.setStatus(p)
				if let self { popdown(self.meStatusPopover) }
			})
		}
		append(statuses, button(label: "Sign out", css: ["wlm-flat"]) { [weak self] in
			if let self { popdown(self.meStatusPopover) }
			AppState.shared.signOut()
		})
		align(nameButton, h: GTK_ALIGN_START)
		append(meText, nameButton)

		mePSM = raw(gtk_editable_label_new(""))
		addClass(mePSM, "wlm-label")
		on(mePSM, "changed") {}
		let psmDone = { [weak self] in
			guard let self else { return }
			let t = text(of: self.mePSM)
			if t != AppState.shared.myMessage, t != self.psmPlaceholder { AppState.shared.setPersonalMessage(t) }
		}
		let focus = raw(gtk_event_controller_focus_new())
		on(focus, "leave", psmDone)
		gtk_widget_add_controller(c(mePSM), c(focus))
		margins(mePSM, start: 4)
		append(meText, mePSM)

		let toolbar = hbox(2)
		for id in R.toolbarIcons {
			append(toolbar, button(picture(skin.image(id)), css: ["wlm-flat"]) {})
		}
		margins(toolbar, top: 4, bottom: 3)
		append(meText, toolbar)
		append(me, meText)
		append(page, me)

		// AddressBook panel.
		let book = vbox(0, css: ["wlm-addressbook"])
		margins(book, start: 8, bottom: 5, end: 8)
		expand(book, v: true)
		let searchRow = hbox(4, css: ["wlm-searchbar"])
		search = entry(placeholder: skin.string(45845, "Find a contact or number..."))
		expand(search, h: true)
		on(search, "changed") { [weak self] in self?.rebuildList() }
		append(searchRow, search)
		append(searchRow, button(picture(skin.image(R.addContact)), css: ["wlm-flat"], tooltip: skin.string(49110, "Add a contact")) { [weak self] in
			self?.promptAddContact()
		})
		append(searchRow, button(picture(skin.image(R.viewMenu)), css: ["wlm-flat"]) {})
		append(book, searchRow)
		list = vbox(0)
		margins(list, top: 3, bottom: 3)
		append(book, scrolled(list))
		append(page, book)
		return page
	}

	private var psmPlaceholder: String { skin.string(61130, "<Enter a personal message>") }

	private func refreshMe() {
		removeAllChildren(meName)
		append(meName, RichText.line(state.myName.isEmpty ? state.myEmail : state.myName, css: ["wlm-bold"]))
		append(meName, label("(\(state.myStatus.displayName))", css: ["wlm-label"]))
		append(meName, picture(skin.image(R.caret)))
		setText(editable: mePSM, state.myMessage.isEmpty ? psmPlaceholder : state.myMessage)
	}

	private func rebuildList() {
		guard state.phase == .signedIn else { return }
		selectedRow = nil
		removeAllChildren(list)
		let q = text(of: search).lowercased()
		let visibleContacts = state.contacts.filter {
			q.isEmpty || $0.displayName.lowercased().contains(q) || $0.email.contains(q)
		}
		let order: (Contact, Contact) -> Bool = { a, b in
			a.status.isOnline != b.status.isOnline ? a.status.isOnline
				: a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
		}
		var sections: [(id: String, title: String, members: [Contact])] = state.groups
			.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
			.map { g in (g.groupID, g.name, visibleContacts.filter { $0.groupIDs.contains(g.groupID) }.sorted(by: order)) }
		let known = Set(state.groups.map(\.groupID))
		sections.append(("other", skin.string(45469, "Other Contacts"),
		                 visibleContacts.filter { Set($0.groupIDs).isDisjoint(with: known) }.sorted(by: order)))
		for s in sections {
			let online = s.members.filter { $0.status.isOnline }.count
			let isCollapsed = collapsed.contains(s.id)
			let header = hbox(0, css: ["wlm-group"])
			let toggle = picture(skin.image(R.expandCollapse, frame: isCollapsed ? 1 : 0))
			gtk_widget_set_size_request(c(toggle), 14, -1)
			append(header, toggle)
			let title = label(" \(s.title) (\(online)/\(s.members.count))", css: ["wlm-group"])
			append(header, title)
			clickGesture(header) { [weak self] _ in
				guard let self else { return }
				if self.collapsed.contains(s.id) { self.collapsed.remove(s.id) } else { self.collapsed.insert(s.id) }
				self.rebuildList()
			}
			append(list, header)
			if isCollapsed { continue }
			for contact in s.members { append(list, buddyRow(contact)) }
		}
		if state.contacts.isEmpty {
			let empty = vbox(4)
			margins(empty, top: 10, start: 10)
			append(empty, label("You don't have any contacts yet.", css: ["wlm-label"]))
			append(empty, button(label: skin.string(49110, "Add a contact"), css: ["wlm-link"]) { [weak self] in self?.promptAddContact() })
			append(list, empty)
		}
	}

	/// BuddyTemplate (Basic view): 41px gutter with the status pill, then
	/// name and " - personal message".
	private func buddyRow(_ contact: Contact) -> Ptr {
		let row = hbox(0, css: ["wlm-buddy"])
		if selected == contact.email {
			addClass(row, "selected")
			selectedRow = row
		}
		let gutter = hbox(0)
		gtk_widget_set_size_request(c(gutter), 41, -1)
		append(gutter, spacer())
		append(gutter, StatusIcon.picture(contact.status, blocked: contact.isBlocked))
		expand(gutter)  // keep the spacer's hexpand from propagating to the row
		append(row, gutter)
		let text = hbox(0)
		margins(text, start: 3)
		expand(text, h: true)
		append(text, RichText.line(contact.displayName))
		if contact.status.isOnline, contact.status != .online {
			append(text, label(" (\(contact.status.displayName))"))
		}
		let psm = contact.currentMedia.isEmpty ? contact.personalMessage : "♫ \(contact.currentMedia)"
		if !psm.isEmpty {
			append(text, label(" - ", css: ["wlm-muted"]))
			append(text, RichText.line(psm, css: ["wlm-muted"]))
		}
		append(row, text)
		gtk_widget_set_tooltip_text(c(row), "\(contact.displayName) <\(contact.email)>")
		clickGesture(row) { [weak self] n in
			guard let self else { return }
			// Restyle in place: rebuilding the list here would replace the row
			// under the pointer and swallow the second click of a double-click.
			if let old = self.selectedRow { removeClass(old, "selected") }
			addClass(row, "selected")
			self.selectedRow = row
			self.selected = contact.email
			if n == 2 { AppState.shared.openConversation(contact.email) }
		}
		clickGesture(row, button: 3) { [weak self] _ in self?.contextMenu(for: contact, on: row) }
		return row
	}

	private func contextMenu(for contact: Contact, on row: Ptr) {
		let menu = vbox(0)
		let pop = raw(gtk_popover_new())
		func item(_ title: String, _ action: @escaping () -> Void) {
			append(menu, menuItem(title) { popdown(pop); action() })
		}
		item("Send an instant message") { AppState.shared.openConversation(contact.email) }
		item("Send a nudge") { AppState.shared.nudge(contact.email) }
		item(contact.isBlocked ? "Unblock contact" : "Block contact") { AppState.shared.setBlocked(contact.email, !contact.isBlocked) }
		item("Delete contact") { AppState.shared.removeContact(contact.email) }
		gtk_popover_set_child(c(pop), c(menu))
		gtk_widget_set_parent(c(pop), c(row))
		on(pop, "closed") { gtk_widget_unparent(c(pop)) }
		gtk_popover_popup(c(pop))
	}

	/// Which Escargot server to sign in to (the macOS app's service picker).
	private func serverPicker() -> Ptr {
		let name = label("", css: ["wlm-hint"])
		let show = { [weak self] in
			guard let self else { return }
			setText(name, "Service: \(self.state.settings.serverName)")
		}
		show()
		let items = vbox(0)
		let (picker, pop) = menuButton(hbox(4, [name, picture(skin.image(R.caret))]), content: items, css: ["wlm-flat"])
		let choices: [(String, Settings.Server)] = [("Escargot (escargot.chat)", .escargot), ("Local dev server", .local), ("Other server...", .custom)]
		for (title, server) in choices {
			append(items, menuItem(title) { [weak self] in
				guard let self else { return }
				popdown(pop)
				guard server == .custom else {
					self.state.settings.server = server
					return show()
				}
				Dialog.prompt(title: "Other server", message: "Host name or address of the Escargot server:",
				              placeholder: "127.0.0.1", text: self.state.settings.customHost, ok: "OK", parent: self.window) { host in
					let h = host.trimmingCharacters(in: .whitespaces)
					guard !h.isEmpty else { return }
					self.state.settings.customHost = h
					self.state.settings.server = .custom
					show()
				}
			})
		}
		align(picker, h: GTK_ALIGN_START)
		return picker
	}

	private func promptAddContact() {
		Dialog.prompt(title: skin.string(45278, "Add a Contact"), message: "Instant messaging address:",
		              placeholder: "someone@escargot.chat", ok: "Add contact", parent: window) { email in
			let e = email.trimmingCharacters(in: .whitespaces)
			if e.contains("@") { AppState.shared.addContact(e) }
		}
	}

	private func showAddRequests() {
		guard let req = state.addRequests.first else { return }
		let (w, _) = Chrome.window(app: nil, width: 420, height: 230)
		let body = vbox(8)
		margins(body, top: 12, start: 16, bottom: 12, end: 16)
		append(body, hbox(10, [userTile(size: 48), vbox(2, [
			label("\(req.name) (\(req.email))", css: ["wlm-bold"]),
			label("has added you to his or her contact list.", css: ["wlm-label"]),
		])]))
		let allow = checkbox("Allow this person to see when you are online and contact you", active: true)
		let add = checkbox("Add this person to my contact list", active: true)
		append(body, allow)
		append(body, add)
		append(body, spacer(v: true))
		let ok = button(label: "OK", css: ["wlm-push", "default"]) { [weak self] in
			AppState.shared.respond(req.email, allow: isActive(allow), add: isActive(add))
			gtk_window_destroy(c(w))
			self?.showAddRequests()
		}
		align(ok, h: GTK_ALIGN_END)
		append(body, ok)
		gtk_window_set_child(c(w), c(body))
		Dialog.present(w, modalTo: window)
	}
}

/// Status pill strip 46611: 0 online, 1 offline, 2 busy, 3 away, 11/12 blocked.
enum StatusIcon {
	static func frame(_ p: Presence, blocked: Bool = false) -> Int {
		if blocked { return p.isOnline ? 11 : 12 }
		switch p.tint {
		case .green: return 0
		case .gray: return 1
		case .red: return 2
		case .orange: return 3
		}
	}

	static func picture(_ p: Presence, blocked: Bool = false) -> Ptr {
		let pic = CGtkBridge.picture(Skin.shared.image(R.statusPill, frame: frame(p, blocked: blocked)))
		align(pic, v: GTK_ALIGN_CENTER)
		return pic
	}
}

/// Disambiguates the free `picture` builder from the static method above.
enum CGtkBridge {
	static func picture(_ path: String?) -> Ptr { MessengerGTK.picture(path) }
}
