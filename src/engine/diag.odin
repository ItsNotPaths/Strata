package engine

// Engine diagnostics sink. The compiler is a vendorable library (README
// "Using strata as a game's level pipeline"): parse warnings, eval skips,
// and I/O failures go through ONE emit point the embedder can redirect —
// the editor captures them into its log panel, a game routes them to its
// own UI/logging. Default sink prints to stderr, which is the CLI/golden
// contract (tests/golden.sh captures stderr; skip warnings are part of it).
//
// Emission contract: engine code emits ONLY from serial phases (document
// load/save, eval_world_build). Mesh extraction workers never emit, so a
// sink does not need to be thread-safe.

import "core:fmt"

Diag_Level :: enum u8 {
	Warn,  // something was skipped/ignored; the operation continued
	Error, // the operation failed (load refused, write failed, empty eval)
}

Diag_Sink :: #type proc(level: Diag_Level, text: string, user: rawptr)

@(private = "file") diag_sink: Diag_Sink = diag_stderr
@(private = "file") diag_user: rawptr

// diag_set_sink — install a sink (nil restores the stderr default). `user`
// is handed back verbatim on every emit (typically the embedder's state).
diag_set_sink :: proc(sink: Diag_Sink, user: rawptr = nil) {
	diag_sink = sink if sink != nil else diag_stderr
	diag_user = user
}

diag_stderr :: proc(level: Diag_Level, text: string, user: rawptr) {
	fmt.eprintln(text)
}

// diagf — format (temp allocator) and hand to the sink. The text is only
// valid for the duration of the call; sinks that keep it must clone.
diagf :: proc(level: Diag_Level, format: string, args: ..any) {
	diag_sink(level, fmt.tprintf(format, ..args), diag_user)
}
