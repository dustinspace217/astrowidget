// lib/logging/error_codes.dart
// Sealed error code system — Stipulation B.
//
// Every user-facing error carries a code like "WX-502" that maps to:
//   - a plain-language user message
//   - a recovery hint
//   - a log level + category for diagnostic logging
//
// Codes live here, not at call sites, so the Error Matrix is the single
// source of truth. Adding a code = adding a named constructor here +
// an entry in error_messages.dart.
import 'package:logger/logger.dart';

/// Category groups — used as log category prefixes (Stipulation A).
enum ErrorCategory {
	db,
	weather,
	routing,
	scoring,
	importExport,
	network,
	filesystem,
	ui,
}

/// Sealed error code bundle.
///
/// Each code is a const instance with: string code, category, log level,
/// i18n message key, and a recovery hint for the user.
///
/// Not an enum because enums can't carry heterogeneous construction data
/// cleanly in Dart. This class-with-const-instances pattern gives the
/// same exhaustiveness benefits plus per-code data.
class ErrorCode {
	/// Short identifier like "WX-502". Appears in user messages and logs.
	final String code;

	/// Grouping — also used as the log category prefix.
	final ErrorCategory category;

	/// Default log level when this error fires.
	final Level logLevel;

	/// Key into the message bundle (see error_messages.dart).
	/// Format: "error.<code_lowercased_underscored>" e.g. "error.wx_502".
	/// Localization seam for later — for now resolved from an English map.
	final String messageKey;

	/// One-sentence hint describing what the user can try.
	/// Kept short — the full message comes from the bundle.
	final String recoveryHint;

	/// Private const constructor — only the named instances below are usable.
	const ErrorCode._({
		required this.code,
		required this.category,
		required this.logLevel,
		required this.messageKey,
		required this.recoveryHint,
	});

	// ─── Database errors ──────────────────────────────────────────────────
	static const dbMigrationFailed = ErrorCode._(
		code: 'DB-001',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_001',
		recoveryHint: 'Copy error details and contact support.',
	);
	static const dbCatalogQueryFailed = ErrorCode._(
		code: 'DB-101',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_101',
		recoveryHint: 'Retry. If it persists, restart the app.',
	);
	static const dbSessionConstraintFailed = ErrorCode._(
		code: 'DB-201',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_201',
		recoveryHint: 'Review highlighted fields for invalid values.',
	);
	static const dbSessionIoFailed = ErrorCode._(
		code: 'DB-202',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_202',
		recoveryHint: 'Free up device storage and retry.',
	);
	static const dbTargetStatusFailed = ErrorCode._(
		code: 'DB-203',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_203',
		recoveryHint: 'Tap to retry.',
	);
	static const dbDraftRestoreFailed = ErrorCode._(
		code: 'DB-301',
		category: ErrorCategory.db,
		logLevel: Level.warning,
		messageKey: 'error.db_301',
		recoveryHint: 'Starting with a blank form.',
	);
	static const dbSessionDeleteFailed = ErrorCode._(
		code: 'DB-401',
		category: ErrorCategory.db,
		logLevel: Level.error,
		messageKey: 'error.db_401',
		recoveryHint: 'Retry. If it persists, contact support.',
	);

	// ─── Weather errors ───────────────────────────────────────────────────
	static const wxBackgroundRefreshFailed = ErrorCode._(
		code: 'WX-301',
		category: ErrorCategory.weather,
		logLevel: Level.warning,
		messageKey: 'error.wx_301',
		recoveryHint: 'Tap the stale-data badge to retry.',
	);
	static const wxManualRefreshFailed = ErrorCode._(
		code: 'WX-302',
		category: ErrorCategory.weather,
		logLevel: Level.error,
		messageKey: 'error.wx_302',
		recoveryHint: 'Check your connection and retry.',
	);

	// ─── Routing errors ───────────────────────────────────────────────────
	static const rtPathParamInvalid = ErrorCode._(
		code: 'RT-101',
		category: ErrorCategory.routing,
		logLevel: Level.warning,
		messageKey: 'error.rt_101',
		recoveryHint: 'Returning to the list.',
	);

	// ─── Scoring errors ───────────────────────────────────────────────────
	static const scTargetCatalogRace = ErrorCode._(
		code: 'SC-101',
		category: ErrorCategory.scoring,
		logLevel: Level.warning,
		messageKey: 'error.sc_101',
		recoveryHint: 'Go back and pick another target.',
	);
	static const scScoringFailed = ErrorCode._(
		code: 'SC-201',
		category: ErrorCategory.scoring,
		logLevel: Level.error,
		messageKey: 'error.sc_201',
		recoveryHint: 'Try again or contact support.',
	);

	@override
	String toString() => code;
}
