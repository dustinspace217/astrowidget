// lib/logging/log_ring_buffer.dart
// Rolling 5MB log file writer — Stipulation A.
//
// In release builds, info+ log lines are appended to this file. When size
// exceeds [maxBytes], the file is rotated: diagnostic.log → diagnostic.log.1
// (previous .log.1 is deleted). This caps disk usage at ~10MB total.
//
// The file lives under getApplicationSupportDirectory() so it's not visible
// to other apps or in the Photos library, but survives app updates.
import 'dart:io';

/// A bounded append-only log file with one-level rotation.
class LogRingBuffer {
	/// Max bytes for the active log file before rotation.
	final int maxBytes;

	/// Directory holding the log files. Injected for testability —
	/// production passes getApplicationSupportDirectory().
	final Directory dir;

	/// Base filename for the active log (rotated → baseName.1).
	final String baseName;

	/// Creates a [LogRingBuffer]. Does not create the directory;
	/// caller ensures the directory exists.
	LogRingBuffer({
		required this.dir,
		this.baseName = 'diagnostic.log',
		this.maxBytes = 5 * 1024 * 1024,
	});

	/// The active log file path.
	File get _activeFile => File('${dir.path}/$baseName');

	/// The rotated (previous) log file path.
	File get _rotatedFile => File('${dir.path}/$baseName.1');

	/// Appends [line] to the active log, rotating if size would exceed maxBytes.
	///
	/// A newline is added to the line if it doesn't end with one. All writes
	/// are async — the logger fires these as unawaited Futures.
	///
	/// Wrapped in try-catch so file system errors (disk full, directory deleted,
	/// permission denied) don't crash the app. The logger must never be the
	/// cause of a crash — it degrades silently to console-only if file I/O fails.
	/// Bug fix: GitHub #50.
	Future<void> append(String line) async {
		try {
			final toWrite = line.endsWith('\n') ? line : '$line\n';
			final bytes = toWrite.codeUnits.length;

			// Check current size; rotate if new write would cross the cap.
			int currentSize = 0;
			if (await _activeFile.exists()) {
				currentSize = await _activeFile.length();
			}
			if (currentSize + bytes > maxBytes) {
				await _rotate();
			}

			// Append (creates file if missing).
			await _activeFile.writeAsString(
				toWrite,
				mode: FileMode.append,
				flush: false,
			);
		} catch (_) {
			// Swallow file I/O errors — logging must never crash the app.
			// The console output in _CompositeOutput still works as a fallback.
		}
	}

	/// Rotates the active log to `.1`, deleting any previous rotated file.
	Future<void> _rotate() async {
		if (await _rotatedFile.exists()) {
			await _rotatedFile.delete();
		}
		if (await _activeFile.exists()) {
			await _activeFile.rename(_rotatedFile.path);
		}
	}

	/// Returns the contents of both active and rotated files combined
	/// (rotated first, then active). Used by "Export diagnostic log".
	/// Returns empty string if neither file exists.
	Future<String> readAll() async {
		final buf = StringBuffer();
		if (await _rotatedFile.exists()) {
			buf.write(await _rotatedFile.readAsString());
		}
		if (await _activeFile.exists()) {
			buf.write(await _activeFile.readAsString());
		}
		return buf.toString();
	}

	/// Returns the last [lineCount] lines across both files.
	/// Used when building "Copy error details" payloads.
	Future<List<String>> readTail(int lineCount) async {
		final all = await readAll();
		if (all.isEmpty) return [];
		final lines = all.split('\n').where((l) => l.isNotEmpty).toList();
		if (lines.length <= lineCount) return lines;
		return lines.sublist(lines.length - lineCount);
	}
}
