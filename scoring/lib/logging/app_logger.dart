// lib/logging/app_logger.dart
// Application-wide logger wrapper — Stipulation A.
//
// Wraps the logger package with:
//  - Category prefixes (db, http, scoring, provider, ui, cache, import)
//  - ErrorCode-aware error methods
//  - Ring-buffer file output in release builds
//
// Call sites use the singleton `logger` for convenience:
//   logger.info('http', 'GET weather', data: {'url': ...});
//   logger.errorCode(ErrorCode.wxManualRefreshFailed, error: e, stackTrace: s);
import 'package:logger/logger.dart' as pkg;
import 'error_codes.dart';
import 'log_ring_buffer.dart';

// kReleaseMode replacement (was: `import 'package:flutter/foundation.dart' show kReleaseMode;`).
//
// Replaced 2026-05-28 to make scoring_engine.dart compilable as a standalone
// Dart native binary via `dart compile exe` (no Flutter SDK on the build host).
// `dart.vm.product` is `true` when the Dart VM is compiled in product (release)
// mode — semantically identical to Flutter's kReleaseMode for the three sites
// where it's used below. Invisible to Flutter builds: the env constant is
// still set by `flutter build --release`.
//
// Downstream consumer: astrowidget (KDE Plasma 6 plasmoid) pulls this file
// transitively via scoring_engine.dart → target_type.dart → app_logger.dart.
// See ~/Claude/astrowidget/docs/superpowers/specs/2026-05-28-astrowidget-design.md §6.2.
const bool kReleaseMode = bool.fromEnvironment('dart.vm.product');

/// Thin wrapper over the logger package with category + ErrorCode support.
class AppLogger {
	/// The underlying logger from the logger package.
	final pkg.Logger _log;

	/// Optional file buffer for release-build persistent logs.
	/// Null in debug builds (console output only).
	final LogRingBuffer? _buffer;

	AppLogger._(this._log, this._buffer);

	/// Creates an AppLogger for normal use.
	///
	/// [buffer] is optional — pass a LogRingBuffer in release builds for
	/// persistent logs; leave null in debug for console-only output.
	factory AppLogger({LogRingBuffer? buffer}) {
		final output = _CompositeOutput(
			buffer: buffer,
			includeConsole: !kReleaseMode,
		);
		final logger = pkg.Logger(
			printer: pkg.PrettyPrinter(
				methodCount: 0,
				errorMethodCount: 8,
				colors: !kReleaseMode,
				printEmojis: false,
				dateTimeFormat: pkg.DateTimeFormat.dateAndTime,
			),
			output: output,
			level: kReleaseMode ? pkg.Level.info : pkg.Level.debug,
		);
		return AppLogger._(logger, buffer);
	}

	/// Debug-level log. Gated out in release builds.
	void debug(String category, String message, {Map<String, Object?>? data}) {
		_log.d(_format(category, message, data));
	}

	/// Info-level log. Persisted in release builds.
	void info(String category, String message, {Map<String, Object?>? data}) {
		_log.i(_format(category, message, data));
	}

	/// Warning-level log. Persisted in release builds.
	void warning(
		String category,
		String message, {
		Map<String, Object?>? data,
		Object? error,
		StackTrace? stackTrace,
	}) {
		_log.w(
			_format(category, message, data),
			error: error,
			stackTrace: stackTrace,
		);
	}

	/// Error-level log. Always includes the exception if provided.
	void error(
		String category,
		String message, {
		Object? error,
		StackTrace? stackTrace,
		Map<String, Object?>? data,
	}) {
		_log.e(
			_format(category, message, data),
			error: error,
			stackTrace: stackTrace,
		);
	}

	/// Logs an ErrorCode at its declared level and category.
	/// Call this at every try/catch in the app (Stipulation A rule 1).
	void errorCode(
		ErrorCode code, {
		Object? error,
		StackTrace? stackTrace,
		Map<String, Object?>? data,
	}) {
		final category = code.category.name;
		final message = '[${code.code}] ${code.messageKey}';
		switch (code.logLevel) {
			case pkg.Level.warning:
				warning(category, message, data: data, error: error, stackTrace: stackTrace);
				break;
			case pkg.Level.error:
			case pkg.Level.fatal:
				this.error(category, message, error: error, stackTrace: stackTrace, data: data);
				break;
			default:
				info(category, message, data: data);
		}
	}

	/// Exposes the ring buffer for diagnostic export. Null in debug builds.
	LogRingBuffer? get buffer => _buffer;

	String _format(String category, String message, Map<String, Object?>? data) {
		if (data == null || data.isEmpty) return '[$category] $message';
		final parts = data.entries.map((e) => '${e.key}=${e.value}').join(' ');
		return '[$category] $message | $parts';
	}
}

/// Composite output — writes to console (debug builds) AND ring buffer (release).
class _CompositeOutput extends pkg.LogOutput {
	final LogRingBuffer? buffer;
	final bool includeConsole;

	_CompositeOutput({this.buffer, required this.includeConsole});

	@override
	void output(pkg.OutputEvent event) {
		if (includeConsole) {
			for (final line in event.lines) {
				// ignore: avoid_print
				print(line);
			}
		}
		if (buffer != null) {
			final blob = event.lines.join('\n');
			// Fire-and-forget — logger output methods are synchronous in signature.
			buffer!.append(blob);
		}
	}
}

/// Global logger instance. Nullable instead of `late` so that code running
/// before main.dart initialization (e.g., DB migrations in tests) doesn't
/// crash with LateInitializationError. Access via the top-level `logger`
/// getter which returns a no-op instance when `_logger` is null.
///
/// Set in main.dart: `logger = AppLogger(buffer: ...)`.
/// In tests: `logger = AppLogger(buffer: tempBuffer)` or just leave null
/// (log calls become no-ops, removing the try-catch boilerplate in migrations).
///
/// Bug fix: GitHub #61 — the only global mutable state in the codebase.
AppLogger? _logger;

/// Safe accessor for the global logger. Returns a no-op logger if not yet
/// initialized, preventing LateInitializationError in tests and migrations.
// ignore: unnecessary_non_null_assertion
AppLogger get logger => _logger ?? _noOpLogger;
set logger(AppLogger value) => _logger = value;

/// Minimal no-op logger used before main.dart initializes the real one.
/// All methods are inherited from AppLogger but the null buffer means
/// file-based logging is skipped — only console output in debug mode.
final _noOpLogger = AppLogger();
