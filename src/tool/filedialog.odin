package tool

// In-app file browser for Open / Save As (§6 shell). ImGui modal, no OS
// dialog dependency (SDL3's native dialogs need a portal/zenity on Linux —
// this box has neither, and a modal we own stays drivable by synthetic
// input). Directory navigation + click-to-select, double-click to descend /
// open; Save gets an editable filename that auto-appends .strata.svg.
//
// The dialog also anchors the unsaved-changes flow: fd_confirm_modal guards
// New / Open / Quit while the document is dirty.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import imgui "../../vendor/odin-imgui"

import "../engine"

FD_Mode :: enum {
	Open,
	Save,
}

FD_Entry :: struct {
	name:   string, // heap clone
	is_dir: bool,
}

File_Dialog :: struct {
	want_open:  bool, // OpenPopup fires on the next fd_draw
	mode:       FD_Mode,
	cwd:        string, // heap, cleaned; remembered across opens
	entries:    [dynamic]FD_Entry,
	sel:        int,
	name_buf:   [256]u8,
	err:        string, // heap
	quit_after: bool,   // Save invoked from the quit guard: quit on success
}

// Confirm_Action — what to do once the user agrees to discard/save changes.
Confirm_Action :: enum {
	None,
	New,
	Open_Browse,
	Open_Path, // path in Editor.confirm_path
	Quit,
}

fd_destroy :: proc(fd: ^File_Dialog) {
	fd_clear_entries(fd)
	delete(fd.entries)
	delete(fd.cwd)
	delete(fd.err)
	fd^ = {}
}

@(private = "file")
fd_clear_entries :: proc(fd: ^File_Dialog) {
	for &e in fd.entries {delete(e.name)}
	clear(&fd.entries)
}

@(private = "file")
fd_set_err :: proc(fd: ^File_Dialog, msg: string) {
	delete(fd.err)
	fd.err = strings.clone(msg)
}

// fd_set_cwd — store `dir` cleaned and absolute (relative paths anchor at
// the process working directory so "Up" behaves at the tree top).
@(private = "file")
fd_set_cwd :: proc(fd: ^File_Dialog, dir: string) {
	d := dir
	if !strings.has_prefix(d, "/") {
		wd, werr := os.get_working_directory(context.temp_allocator)
		if werr == nil {
			d, _ = filepath.join({wd, d}, context.temp_allocator)
		}
	}
	cleaned, _ := filepath.clean(d, context.temp_allocator)
	delete(fd.cwd)
	fd.cwd = strings.clone(cleaned)
}

// fd_open — arm the dialog. Starts in the current document's directory,
// else wherever the dialog last browsed, else the process cwd.
fd_open :: proc(ed: ^Editor, mode: FD_Mode, quit_after := false) {
	fd := &ed.fdlg
	fd.mode = mode
	fd.want_open = true
	fd.quit_after = quit_after
	fd_set_err(fd, "")

	if ed.doc_path != "" {
		dir, _ := os.split_path(ed.doc_path)
		fd_set_cwd(fd, dir != "" ? dir : ".")
	} else if fd.cwd == "" {
		fd_set_cwd(fd, ".")
	}

	fd.name_buf = {}
	if mode == .Save {
		base := "untitled.strata.svg"
		if ed.doc_path != "" {
			_, base = os.split_path(ed.doc_path)
		}
		copy(fd.name_buf[:len(fd.name_buf) - 1], base)
	}
	fd_populate(fd)
}

// fd_populate — list cwd: directories + *.svg files, dirs first, sorted,
// hidden entries skipped.
@(private = "file")
fd_populate :: proc(fd: ^File_Dialog) {
	fd_clear_entries(fd)
	fd.sel = -1

	infos, rerr := os.read_all_directory_by_path(fd.cwd, context.temp_allocator)
	if rerr != nil {
		fd_set_err(fd, "cannot read directory")
		return
	}
	for fi in infos {
		if len(fi.name) == 0 || fi.name[0] == '.' {continue}
		is_dir := fi.type == .Directory
		if !is_dir && !strings.has_suffix(fi.name, ".svg") {continue}
		append(&fd.entries, FD_Entry{name = strings.clone(fi.name), is_dir = is_dir})
	}
	slice.sort_by(fd.entries[:], proc(a, b: FD_Entry) -> bool {
		if a.is_dir != b.is_dir {return a.is_dir}
		return name_less_ci(a.name, b.name)
	})
}

@(private = "file")
name_less_ci :: proc(a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		ca, cb := a[i], b[i]
		if ca >= 'A' && ca <= 'Z' {ca += 32}
		if cb >= 'A' && cb <= 'Z' {cb += 32}
		if ca != cb {return ca < cb}
	}
	return len(a) < len(b)
}

@(private = "file")
fd_target_path :: proc(fd: ^File_Dialog) -> (path: string, ok: bool) {
	name := string(cstring(&fd.name_buf[0]))
	if name == "" {return}
	if fd.mode == .Save && !strings.has_suffix(name, ".svg") {
		name = strings.concatenate({name, ".strata.svg"}, context.temp_allocator)
	}
	path, _ = filepath.join({fd.cwd, name}, context.temp_allocator)
	return path, true
}

@(private = "file")
fd_confirm :: proc(ed: ^Editor) -> (close: bool) {
	fd := &ed.fdlg
	path, ok := fd_target_path(fd)
	if !ok {
		fd_set_err(fd, "enter a file name")
		return false
	}
	switch fd.mode {
	case .Open:
		if doc, lok := engine.document_load_svg(path); lok {
			editor_set_doc(ed, doc, path)
			return true
		}
		fd_set_err(fd, "cannot load file (see terminal)")
	case .Save:
		if editor_save(ed, path) {
			if fd.quit_after {ed.quit = true}
			return true
		}
		fd_set_err(fd, "cannot write file (see terminal)")
	}
	return false
}

// fd_draw — call once per frame from the shell scope.
fd_draw :: proc(ed: ^Editor) {
	fd := &ed.fdlg
	title: cstring = fd.mode == .Open ? "Open document##fdlg" : "Save document##fdlg"
	if fd.want_open {
		fd.want_open = false
		imgui.OpenPopup(title)
	}

	center := imgui.GetMainViewport().WorkPos + imgui.GetMainViewport().WorkSize * 0.5
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	imgui.SetNextWindowSize({620, 460}, .Appearing)
	if !imgui.BeginPopupModal(title, nil, {.NoSavedSettings}) {return}

	// header: up + current directory
	if imgui.Button("Up") && fd.cwd != "/" {
		parent, _ := os.split_path(fd.cwd)
		fd_set_cwd(fd, parent != "" ? parent : "/")
		fd_populate(fd)
	}
	imgui.SameLine()
	imgui.TextDisabled("%s", strings.clone_to_cstring(fd.cwd, context.temp_allocator))

	// entry list
	footer := imgui.GetFrameHeightWithSpacing() * (fd.err != "" ? 3.2 : 2.2)
	if imgui.BeginChild("##fdlist", {0, -footer}, {.Borders}) {
		for &e, i in fd.entries {
			imgui.PushIDInt(i32(i))
			label := e.is_dir ? fmt.ctprintf("[dir]  %s", e.name) : fmt.ctprintf("       %s", e.name)
			if imgui.Selectable(label, fd.sel == i, {.AllowDoubleClick}) {
				fd.sel = i
				if !e.is_dir {
					fd.name_buf = {}
					copy(fd.name_buf[:len(fd.name_buf) - 1], e.name)
				}
				if imgui.IsMouseDoubleClicked(.Left) {
					if e.is_dir {
						sub, _ := filepath.join({fd.cwd, e.name}, context.temp_allocator)
						fd_set_cwd(fd, sub)
						fd_populate(fd)
						imgui.PopID()
						break // entries just changed; stop iterating
					} else if fd.mode == .Open {
						if fd_confirm(ed) {imgui.CloseCurrentPopup()}
					}
				}
			}
			imgui.PopID()
		}
	}
	imgui.EndChild()

	// filename + overwrite hint
	imgui.SetNextItemWidth(-140)
	enter := imgui.InputTextWithHint(
		"##fdname", "file name", cstring(&fd.name_buf[0]), len(fd.name_buf),
		{.EnterReturnsTrue} | (fd.mode == .Open ? imgui.InputTextFlags{.ReadOnly} : {}),
	)
	imgui.SameLine()
	confirm_label: cstring = fd.mode == .Open ? "Open" : "Save"
	do_confirm := imgui.Button(confirm_label, {60, 0}) || enter
	imgui.SameLine()
	if imgui.Button("Cancel", {60, 0}) {
		fd.quit_after = false
		imgui.CloseCurrentPopup()
	}
	if fd.mode == .Save {
		if path, ok := fd_target_path(fd); ok && os.exists(path) && path != ed.doc_path {
			imgui.TextColored({1, 0.75, 0.35, 1}, "will overwrite an existing file")
		}
	}
	if fd.err != "" {
		imgui.TextColored({1, 0.45, 0.4, 1}, "%s", strings.clone_to_cstring(fd.err, context.temp_allocator))
	}

	if do_confirm && fd_confirm(ed) {imgui.CloseCurrentPopup()}
	imgui.EndPopup()
}

// --- unsaved-changes guard --------------------------------------------------

// editor_request — run a destructive action, or arm the confirm modal first
// when the document has unsaved changes.
editor_request :: proc(ed: ^Editor, action: Confirm_Action, path := "") {
	ed.confirm_path = {}
	copy(ed.confirm_path[:len(ed.confirm_path) - 1], path)
	if ed.doc_rev != ed.saved_rev {
		ed.confirm = action
		return
	}
	confirm_proceed(ed, action)
}

@(private = "file")
confirm_proceed :: proc(ed: ^Editor, action: Confirm_Action) {
	switch action {
	case .None:
	case .New:
		editor_set_doc(ed, engine.Document{name = engine.name32("untitled")}, "")
	case .Open_Browse:
		fd_open(ed, .Open)
	case .Open_Path:
		path := string(cstring(&ed.confirm_path[0]))
		if doc, ok := engine.document_load_svg(path); ok {
			editor_set_doc(ed, doc, path)
		}
	case .Quit:
		ed.quit = true
	}
}

// fd_confirm_modal — "you have unsaved changes": Save (then proceed),
// Discard, or Cancel. Untitled docs route Save through the Save dialog; the
// pending action survives only for Quit (save-dialog success quits).
fd_confirm_modal :: proc(ed: ^Editor) {
	if ed.confirm != .None {
		imgui.OpenPopup("Unsaved changes##confirm")
	}
	center := imgui.GetMainViewport().WorkPos + imgui.GetMainViewport().WorkSize * 0.5
	imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
	if !imgui.BeginPopupModal("Unsaved changes##confirm", nil, {.AlwaysAutoResize, .NoSavedSettings}) {return}

	imgui.TextUnformatted("The document has unsaved changes.")
	imgui.Spacing()
	action := ed.confirm
	if imgui.Button("Save", {100, 0}) {
		ed.confirm = .None
		imgui.CloseCurrentPopup()
		if ed.doc_path != "" {
			if editor_save(ed, ed.doc_path) {confirm_proceed(ed, action)}
		} else {
			// untitled: Save As; only a pending quit survives the detour
			fd_open(ed, .Save, action == .Quit)
		}
	}
	imgui.SameLine()
	if imgui.Button("Discard", {100, 0}) {
		ed.confirm = .None
		ed.saved_rev = ed.doc_rev // silence the guard for this doc state
		imgui.CloseCurrentPopup()
		confirm_proceed(ed, action)
	}
	imgui.SameLine()
	if imgui.Button("Cancel", {100, 0}) {
		ed.confirm = .None
		imgui.CloseCurrentPopup()
	}
	imgui.EndPopup()
}
