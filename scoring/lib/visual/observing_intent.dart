// lib/visual/observing_intent.dart
//
// The observer's intent for a given target — is this a Favorite they
// plan to image (long-exposure astrophotography) or observe visually
// (real-time eyepiece view)? This choice drives a different set of
// scoring weights per target type (§9 of the Plan 5 spec / §4 of the
// Plan 5.5 spec for the equipment-aware columns).
//
// Why an enum rather than a bool: Plan 5.5 and Plan 6 both discuss
// possible future intents (sketching, EAA, narrowband-only). An enum
// lets new variants land without every `bool isVisual` call site
// needing to sprout a new branch — the exhaustive switch on the
// sealed-style enum catches the misses at compile time.
//
// Persistence: a target can carry BOTH intents simultaneously (a user
// may favorite M42 for visual AND imaging). Storage is a JSON array
// of [persistenceKey] strings on the Favorites row, never a single
// enum value. The parse/serialize helpers here are deliberately
// per-value (one at a time) so the Drift column-adapter can iterate
// without needing a collection-level codec.

/// What the observer plans to do with a target. Drives per-target-type
/// scoring weights, tile display, and Settings observing-preference.
enum ObservingIntent {
	/// Long-exposure imaging: weights favor darkness, seeing, moon
	/// angular distance. Equipment scoring (Plan 5.5) cares about
	/// pixel scale, FOV, dithering window duration.
	imaging,

	/// Real-time visual observation through an eyepiece: weights favor
	/// transparency, magnification band, exit pupil, Dawes limit.
	/// Dark adaptation (Plan 5.5) modulates low-surface-brightness
	/// target scoring for this intent.
	visual;

	/// Short display string used on compact UI surfaces (target-list
	/// tiles, intent sort toggle). 3 characters max so dual-score
	/// tiles fit on narrow phones.
	String get shortLabel => switch (this) {
		ObservingIntent.imaging => 'Img',
		ObservingIntent.visual => 'Vis',
	};

	/// Long display name for Settings, target-detail rationale
	/// sections, and any full-word UI.
	String get fullLabel => switch (this) {
		ObservingIntent.imaging => 'Imaging',
		ObservingIntent.visual => 'Visual',
	};

	/// Parses from persistence — a single entry in the JSON array
	/// stored on Favorites.intents. Returns null for unknown strings
	/// (forward-compat: if Plan 5.5+ adds `sketching` and an old app
	/// version reads a new cache row, unknown entries drop out rather
	/// than crashing the whole favorites stream).
	///
	/// Symmetric with [persistenceKey] — round-trips losslessly for
	/// every defined variant.
	static ObservingIntent? parse(String raw) {
		return switch (raw) {
			'imaging' => ObservingIntent.imaging,
			'visual' => ObservingIntent.visual,
			_ => null,
		};
	}

	/// Value written to persistence. Stable across releases — changing
	/// this would orphan every Favorites row. Equivalent to the enum's
	/// declared `.name`, spelled out here so anyone refactoring the
	/// enum knows the string is load-bearing.
	String get persistenceKey => name;
}
