import CGtk
import Foundation

// Thin Swift layer over GTK4's C API: widgets are kept as raw pointers and
// cast to whatever pointer type each C function wants (complete GTK structs
// import as UnsafeMutablePointer<T>, opaque ones as OpaquePointer).

typealias Ptr = UnsafeMutableRawPointer

protocol CPtr { init(_ raw: Ptr) }
extension OpaquePointer: CPtr {}
extension UnsafeMutablePointer: CPtr {
	init(_ raw: Ptr) { self = raw.assumingMemoryBound(to: Pointee.self) }
}

@inline(__always) func c<T: CPtr>(_ p: Ptr) -> T { T(p) }
@inline(__always) func raw<T>(_ p: UnsafeMutablePointer<T>!) -> Ptr { Ptr(p) }
@inline(__always) func raw(_ p: OpaquePointer!) -> Ptr { Ptr(p) }

// MARK: - Signals

private final class Callback {
	let fn: (Ptr?, [Any]) -> Int32
	init(_ fn: @escaping (Ptr?, [Any]) -> Int32) { self.fn = fn }
}

private let release: GClosureNotify = { data, _ in
	if let data { Unmanaged<Callback>.fromOpaque(data).release() }
}

private func connectRaw(_ obj: Ptr, _ signal: String, _ handler: GCallback, _ cb: Callback) {
	g_signal_connect_data(obj, signal, handler, Unmanaged.passRetained(cb).toOpaque(), release, GConnectFlags(rawValue: 0))
}

private func box(_ data: Ptr?) -> Callback { Unmanaged<Callback>.fromOpaque(data!).takeUnretainedValue() }

/// `void handler(GObject*, gpointer)` signals: clicked, activate, changed, destroy…
func on(_ obj: Ptr, _ signal: String, _ fn: @escaping () -> Void) {
	let t: @convention(c) (Ptr?, Ptr?) -> Void = { _, d in box(d).fn(nil, []) ; return }
	connectRaw(obj, signal, unsafeBitCast(t, to: GCallback.self), Callback { _, _ in fn(); return 0 })
}

/// `gboolean handler(GObject*, gpointer)` signals, e.g. close-request.
func onBool(_ obj: Ptr, _ signal: String, _ fn: @escaping () -> Bool) {
	let t: @convention(c) (Ptr?, Ptr?) -> Int32 = { _, d in box(d).fn(nil, []) }
	connectRaw(obj, signal, unsafeBitCast(t, to: GCallback.self), Callback { _, _ in fn() ? 1 : 0 })
}

/// GtkEventControllerKey::key-pressed (keyval, keycode, state) → handled.
func onKey(_ ctrl: Ptr, _ fn: @escaping (UInt32, UInt32) -> Bool) {
	let t: @convention(c) (Ptr?, UInt32, UInt32, UInt32, Ptr?) -> Int32 = { _, keyval, _, state, d in
		box(d).fn(nil, [keyval, state])
	}
	connectRaw(ctrl, "key-pressed", unsafeBitCast(t, to: GCallback.self), Callback { _, a in
		fn(a[0] as! UInt32, a[1] as! UInt32) ? 1 : 0
	})
}

/// GtkGestureClick::pressed (n_press, x, y).
func onPressed(_ gesture: Ptr, _ fn: @escaping (Int32) -> Void) {
	let t: @convention(c) (Ptr?, Int32, Double, Double, Ptr?) -> Void = { _, n, _, _, d in
		_ = box(d).fn(nil, [n])
	}
	connectRaw(gesture, "pressed", unsafeBitCast(t, to: GCallback.self), Callback { _, a in fn(a[0] as! Int32); return 0 })
}

/// Runs `fn` on the GLib main loop every `ms` milliseconds while it returns true.
func every(_ ms: UInt32, _ fn: @escaping () -> Bool) {
	let cb = Callback { _, _ in fn() ? 1 : 0 }
	let t: @convention(c) (Ptr?) -> Int32 = { d in
		let r = box(d).fn(nil, [])
		if r == 0 { Unmanaged<Callback>.fromOpaque(d!).release() }
		return r
	}
	g_timeout_add(ms, unsafeBitCast(t, to: GSourceFunc.self), Unmanaged.passRetained(cb).toOpaque())
}

/// Calls `fn` with the frame clock's time (µs) on each frame while `widget` is
/// mapped, until it returns false. GTK drops it when the widget is destroyed.
func onTick(_ widget: Ptr, _ fn: @escaping (Int64) -> Bool) {
	let cb = Callback { _, a in fn(a[0] as! Int64) ? 1 : 0 }
	let t: GtkTickCallback = { _, clock, d in box(d).fn(nil, [Int64(gdk_frame_clock_get_frame_time(clock))]) }  // gint64 imports as Int
	let free: GDestroyNotify = { d in if let d { Unmanaged<Callback>.fromOpaque(d).release() } }
	gtk_widget_add_tick_callback(c(widget), t, Unmanaged.passRetained(cb).toOpaque(), free)
}

// MARK: - Images and files

/// A paintable for image bytes (PNG, JPEG, GIF…), or nil if they don't decode.
func texture(from data: Data) -> OpaquePointer? {
	let bytes = data.withUnsafeBytes { g_bytes_new($0.baseAddress, gsize($0.count)) }
	defer { g_bytes_unref(bytes) }
	return gdk_texture_new_from_bytes(bytes, nil)
}

/// Shows `data` in a picture, or the file at `fallback` when there's none.
func setPicture(_ p: Ptr, data: Data?, fallback: String?) {
	if let data, let t = texture(from: data) {
		gtk_picture_set_paintable(c(p), t)
		g_object_unref(UnsafeMutableRawPointer(t))
	} else {
		setPicture(p, fallback)
	}
}

private final class PathsCallback {
	let fn: ([String]) -> Void
	init(_ fn: @escaping ([String]) -> Void) { self.fn = fn }
}

/// GtkFileDialog: lets the user pick files (or one image) and calls back with
/// their paths; nothing if they cancel.
func chooseFiles(parent: Ptr?, title: String, multiple: Bool, imagesOnly: Bool = false, _ done: @escaping ([String]) -> Void) {
	let dialog = gtk_file_dialog_new()!
	gtk_file_dialog_set_title(dialog, title)
	if imagesOnly {
		let filter = gtk_file_filter_new()!
		gtk_file_filter_set_name(filter, "Images")
		gtk_file_filter_add_mime_type(filter, "image/*")
		let filters = g_list_store_new(gtk_file_filter_get_type())!
		g_list_store_append(filters, UnsafeMutableRawPointer(filter))
		gtk_file_dialog_set_filters(dialog, filters)
		g_object_unref(UnsafeMutableRawPointer(filter))
		g_object_unref(UnsafeMutableRawPointer(filters))
	}
	let box = Unmanaged.passRetained(PathsCallback(done)).toOpaque()
	let window: UnsafeMutablePointer<GtkWindow>? = parent.map { c($0) }
	if multiple {
		let cb: GAsyncReadyCallback = { source, result, data in
			let callback = Unmanaged<PathsCallback>.fromOpaque(data!).takeRetainedValue()
			var paths: [String] = []
			if let list = gtk_file_dialog_open_multiple_finish(OpaquePointer(source), result, nil) {
				for i in 0..<g_list_model_get_n_items(list) {
					guard let file = g_list_model_get_item(list, i) else { continue }
					if let path = g_file_get_path(OpaquePointer(file)) {
						paths.append(String(cString: path))
						g_free(path)
					}
					g_object_unref(file)
				}
				g_object_unref(UnsafeMutableRawPointer(list))
			}
			callback.fn(paths)
			g_object_unref(UnsafeMutableRawPointer(source))
		}
		gtk_file_dialog_open_multiple(dialog, window, nil, cb, box)
	} else {
		let cb: GAsyncReadyCallback = { source, result, data in
			let callback = Unmanaged<PathsCallback>.fromOpaque(data!).takeRetainedValue()
			var paths: [String] = []
			if let file = gtk_file_dialog_open_finish(OpaquePointer(source), result, nil) {
				if let path = g_file_get_path(file) {
					paths.append(String(cString: path))
					g_free(path)
				}
				g_object_unref(UnsafeMutableRawPointer(file))
			}
			callback.fn(paths)
			g_object_unref(UnsafeMutableRawPointer(source))
		}
		gtk_file_dialog_open(dialog, window, nil, cb, box)
	}
}

/// WLM's display pictures are 96×96: the image centre-cropped and scaled, as PNG.
func tilePNG(path: String) -> Data? {
	guard let full = gdk_pixbuf_new_from_file(path, nil) else { return nil }
	defer { g_object_unref(UnsafeMutableRawPointer(full)) }
	let w = gdk_pixbuf_get_width(full), h = gdk_pixbuf_get_height(full), side = min(w, h)
	guard side > 0, let square = gdk_pixbuf_new_subpixbuf(full, (w - side) / 2, (h - side) / 2, side, side) else { return nil }
	defer { g_object_unref(UnsafeMutableRawPointer(square)) }
	guard let scaled = gdk_pixbuf_scale_simple(square, 96, 96, GDK_INTERP_BILINEAR) else { return nil }
	defer { g_object_unref(UnsafeMutableRawPointer(scaled)) }
	var buffer: UnsafeMutablePointer<gchar>?
	var size: gsize = 0
	guard gdk_pixbuf_save_to_bufferv(scaled, &buffer, &size, "png", nil, nil, nil) != 0, let buffer else { return nil }
	defer { g_free(buffer) }
	return Data(bytes: buffer, count: Int(size))
}

/// Opens a file or folder with the desktop's default app.
func openWithDefaultApp(_ path: String) {
	let uri = URL(fileURLWithPath: path).absoluteString
	g_app_info_launch_default_for_uri(uri, nil, nil)
}

/// Swift's main queue (and MainActor jobs) on Linux run from Foundation's
/// main run loop; GTK owns the main thread, so pump it from GLib.
func pumpSwiftMainQueue() {
	every(8) {
		RunLoop.main.run(until: Date())
		return true
	}
}

// MARK: - Widget builders

enum Orientation { case horizontal, vertical }

func vbox(_ spacing: Int32 = 0, _ children: [Ptr] = [], css: [String] = []) -> Ptr {
	let b = raw(gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing))
	children.forEach { append(b, $0) }
	css.forEach { addClass(b, $0) }
	return b
}

func hbox(_ spacing: Int32 = 0, _ children: [Ptr] = [], css: [String] = []) -> Ptr {
	let b = raw(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing))
	children.forEach { append(b, $0) }
	css.forEach { addClass(b, $0) }
	return b
}

func append(_ box: Ptr, _ child: Ptr) { gtk_box_append(c(box), c(child)) }

func removeAllChildren(_ box: Ptr) {
	while let child = gtk_widget_get_first_child(c(box)) {
		gtk_box_remove(c(box), child)
	}
}

func label(_ text: String, css: [String] = [], xalign: Float = 0, ellipsize: Bool = false, wrap: Bool = false) -> Ptr {
	let l = raw(gtk_label_new(text))
	gtk_label_set_xalign(c(l), xalign)
	if ellipsize { gtk_label_set_ellipsize(c(l), PANGO_ELLIPSIZE_END) }
	if wrap { gtk_label_set_wrap(c(l), 1) }
	css.forEach { addClass(l, $0) }
	return l
}

func setText(_ l: Ptr, _ text: String) { gtk_label_set_text(c(l), text) }

func button(_ child: Ptr? = nil, label text: String? = nil, css: [String] = [], tooltip: String? = nil, _ action: @escaping () -> Void) -> Ptr {
	let b = text.map { raw(gtk_button_new_with_label($0)) } ?? raw(gtk_button_new())
	if let child { gtk_button_set_child(c(b), c(child)) }
	css.forEach { addClass(b, $0) }
	if let tooltip { gtk_widget_set_tooltip_text(c(b), tooltip) }
	on(b, "clicked", action)
	return b
}

/// A flat, left-aligned popover menu item.
func menuItem(_ title: String, _ action: @escaping () -> Void) -> Ptr {
	button(label(title, css: ["wlm-label"]), css: ["wlm-flat"], action)
}

/// A picture shown at its natural pixel size (skin resources are 96 DPI art).
func picture(_ path: String?, size: (Int32, Int32)? = nil, css: [String] = []) -> Ptr {
	let p: Ptr
	if let path, FileManager.default.fileExists(atPath: path) {
		p = raw(gtk_picture_new_for_filename(path))
	} else {
		p = raw(gtk_picture_new())
	}
	gtk_picture_set_can_shrink(c(p), size == nil ? 0 : 1)
	if let size {
		gtk_widget_set_size_request(c(p), size.0, size.1)
	} else {
		// Never enlarge the art when a container hands the picture more room.
		gtk_picture_set_content_fit(c(p), GTK_CONTENT_FIT_SCALE_DOWN)
	}
	css.forEach { addClass(p, $0) }
	return p
}

func setPicture(_ p: Ptr, _ path: String?) {
	gtk_picture_set_filename(c(p), path)
}

func addClass(_ w: Ptr, _ cls: String) { gtk_widget_add_css_class(c(w), cls) }
func removeClass(_ w: Ptr, _ cls: String) { gtk_widget_remove_css_class(c(w), cls) }

func margins(_ w: Ptr, top: Int32 = 0, start: Int32 = 0, bottom: Int32 = 0, end: Int32 = 0) {
	gtk_widget_set_margin_top(c(w), top)
	gtk_widget_set_margin_start(c(w), start)
	gtk_widget_set_margin_bottom(c(w), bottom)
	gtk_widget_set_margin_end(c(w), end)
}

func expand(_ w: Ptr, h: Bool = false, v: Bool = false) {
	gtk_widget_set_hexpand(c(w), h ? 1 : 0)
	gtk_widget_set_vexpand(c(w), v ? 1 : 0)
}

func align(_ w: Ptr, h: GtkAlign? = nil, v: GtkAlign? = nil) {
	if let h { gtk_widget_set_halign(c(w), h) }
	if let v { gtk_widget_set_valign(c(w), v) }
}

func visible(_ w: Ptr, _ on: Bool) { gtk_widget_set_visible(c(w), on ? 1 : 0) }

func spacer(v: Bool = false) -> Ptr {
	let s = raw(gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0))
	expand(s, h: !v, v: v)
	return s
}

func scrolled(_ child: Ptr, css: [String] = []) -> Ptr {
	let s = raw(gtk_scrolled_window_new())
	gtk_scrolled_window_set_child(c(s), c(child))
	gtk_scrolled_window_set_policy(c(s), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
	expand(s, h: true, v: true)
	css.forEach { addClass(s, $0) }
	return s
}

func entry(password: Bool = false, placeholder: String? = nil) -> Ptr {
	let e = password ? raw(gtk_password_entry_new()) : raw(gtk_entry_new())
	if let placeholder, !password { gtk_entry_set_placeholder_text(c(e), placeholder) }
	addClass(e, "wlm-input")
	return e
}

func text(of editable: Ptr) -> String { String(cString: gtk_editable_get_text(c(editable))) }
func setText(editable: Ptr, _ s: String) { gtk_editable_set_text(c(editable), s) }

func checkbox(_ title: String, active: Bool) -> Ptr {
	let cb = raw(gtk_check_button_new_with_label(title))
	gtk_check_button_set_active(c(cb), active ? 1 : 0)
	addClass(cb, "wlm-check")
	return cb
}

func isActive(_ check: Ptr) -> Bool { gtk_check_button_get_active(c(check)) != 0 }

/// A button that opens a popover with `content`.
func menuButton(_ child: Ptr, content: Ptr, css: [String] = []) -> (button: Ptr, popover: Ptr) {
	let mb = raw(gtk_menu_button_new())
	gtk_menu_button_set_child(c(mb), c(child))
	let pop = raw(gtk_popover_new())
	gtk_popover_set_child(c(pop), c(content))
	gtk_menu_button_set_popover(c(mb), c(pop))
	css.forEach { addClass(mb, $0) }
	return (mb, pop)
}

func popdown(_ popover: Ptr) { gtk_popover_popdown(c(popover)) }

func clickGesture(_ w: Ptr, button: UInt32 = 1, _ fn: @escaping (Int32) -> Void) {
	let g = raw(gtk_gesture_click_new())
	gtk_gesture_single_set_button(c(g), button)
	onPressed(g, fn)
	gtk_widget_add_controller(c(w), c(g))
}

func keyController(_ w: Ptr, _ fn: @escaping (UInt32, UInt32) -> Bool) {
	let k = raw(gtk_event_controller_key_new())
	onKey(k, fn)
	gtk_widget_add_controller(c(w), c(k))
}

// MARK: - CSS

func loadCSS(_ css: String) {
	let provider = gtk_css_provider_new()
	gtk_css_provider_load_from_string(provider, css)
	gtk_style_context_add_provider_for_display(gdk_display_get_default(), OpaquePointer(provider), UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
}

func pangoEscape(_ s: String) -> String {
	let p = g_markup_escape_text(s, -1)!
	defer { g_free(p) }
	return String(cString: p)
}
