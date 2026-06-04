#!/usr/bin/env python3
"""
nightly_decision.py — astrowidget's persistent nightly decision form (Phase 3 Part 2).

Fired ~11 PM by the user's scheduler, this asks whether they imaged the HOME site
tonight and, if not, WHY — capturing the SKIP nights + reasons the FITS alone can't
(the survivorship-bias half of the calibration dataset the re-tune needs). The
answer upserts into the `decisions` table of the calibration DB, joined to the
already-logged forecast by observing-night date.

PERSISTENT (per Dustin's request): the window stays open until you answer, and a
"Night" dropdown surfaces any EARLIER nights still awaiting an answer — so if you
weren't home at 11 PM, you can respond later. A pending (imaged = NULL) row is
recorded on open, so even closing without answering leaves a re-promptable record.

Built on tkinter (Python stdlib) — NO new dependency. The rich desktop dashboard
uses Qt/QML, but this simple yes/no form doesn't warrant forcing a PySide6 install
on Linux (where the desktop app runs on the system `qml` runtime, not PySide6).

Run manually with:  python forms/nightly_decision.py [--site Bainbridge]
The scheduler (systemd timer / Task Scheduler / launchd) runs the same command.
"""

import argparse
import sys
import tkinter as tk
from datetime import datetime
from pathlib import Path
from tkinter import ttk

# calibration_log lives in fetcher/; add it to the path so this standalone UI can
# import the shared DB schema + the (unit-tested) decision helpers.
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "fetcher"))
import calibration_log as cl  # noqa: E402  (path insert must precede the import)

# Quick-pick reasons for a SKIP night (free-text notes always available too); these
# map to the survivorship-bias categories the spec calls out.
REASONS = [
	"Cloudy / overcast",
	"Moon too bright",
	"Wind / weather / dew",
	"Equipment / setup issue",
	"Too tired / busy / away",
	"Other (see notes)",
]


class DecisionForm:
	"""The nightly form. Holds one DB connection for its lifetime; the window
	persists (mainloop) until the user answers or closes it (leaving the pending
	row). Construction does NOT start the event loop — main() does — so the form is
	headlessly testable."""

	def __init__(self, root: tk.Tk, site_id: str):
		self.root = root
		self.site_id = site_id
		self.conn = cl.connect()
		# Record tonight as PENDING up front so it appears in the dropdown and stays
		# answerable later even if this window is closed without an answer.
		self._tonight = cl.observing_date(datetime.now().astimezone())
		cl.ensure_pending(self.conn, self._tonight, site_id)
		self._build_ui()
		self._reload_nights(select=self._tonight)
		root.protocol("WM_DELETE_WINDOW", self._on_close)

	# ── UI construction ──────────────────────────────────────────────────────
	def _build_ui(self) -> None:
		self.root.title("astrowidget — nightly log")
		self.root.minsize(420, 0)
		frm = ttk.Frame(self.root, padding=(16, 14))
		frm.grid(sticky="nsew")
		self.root.columnconfigure(0, weight=1)
		frm.columnconfigure(1, weight=1)

		ttk.Label(frm, text=f"Did you image  {self.site_id}  tonight?",
				  font=("", 12, "bold")).grid(row=0, column=0, columnspan=2,
											   sticky="w", pady=(0, 10))

		ttk.Label(frm, text="Night:").grid(row=1, column=0, sticky="w")
		self.night_var = tk.StringVar()
		self.night_combo = ttk.Combobox(frm, textvariable=self.night_var,
										state="readonly")
		self.night_combo.grid(row=1, column=1, sticky="ew", pady=2)
		self.night_combo.bind("<<ComboboxSelected>>", self._update_context)

		# Forecast context for the selected night (what we predicted), so the answer
		# is informed and you can sanity-check the verdict against reality.
		self.ctx = ttk.Label(frm, text="", foreground="#888", wraplength=380)
		self.ctx.grid(row=2, column=0, columnspan=2, sticky="w", pady=(2, 8))

		ttk.Separator(frm, orient="horizontal").grid(
			row=3, column=0, columnspan=2, sticky="ew", pady=4)

		# Imaged? Yes / No. 0 = No (default — the common, must-explain case), 1 = Yes.
		self.imaged_var = tk.IntVar(value=0)
		yn = ttk.Frame(frm)
		yn.grid(row=4, column=0, columnspan=2, sticky="w", pady=4)
		ttk.Radiobutton(yn, text="Yes, imaged", variable=self.imaged_var, value=1,
						command=self._update_reason_enabled).grid(row=0, column=0, padx=(0, 16))
		ttk.Radiobutton(yn, text="No", variable=self.imaged_var, value=0,
						command=self._update_reason_enabled).grid(row=0, column=1)

		ttk.Label(frm, text="Reason:").grid(row=5, column=0, sticky="w")
		self.reason_var = tk.StringVar(value=REASONS[0])
		self.reason_combo = ttk.Combobox(frm, textvariable=self.reason_var,
										 values=REASONS, state="readonly")
		self.reason_combo.grid(row=5, column=1, sticky="ew", pady=2)

		ttk.Label(frm, text="Notes:").grid(row=6, column=0, sticky="w")
		self.notes_var = tk.StringVar()
		ttk.Entry(frm, textvariable=self.notes_var).grid(
			row=6, column=1, sticky="ew", pady=2)

		btns = ttk.Frame(frm)
		btns.grid(row=7, column=0, columnspan=2, sticky="e", pady=(12, 0))
		ttk.Button(btns, text="Later", command=self._on_close).grid(row=0, column=0, padx=4)
		save = ttk.Button(btns, text="Save", command=self._save)
		save.grid(row=0, column=1)
		save.focus_set()

		self._update_reason_enabled()

	# ── Behaviour ────────────────────────────────────────────────────────────
	def _reload_nights(self, select: str | None = None) -> None:
		"""Repopulate the night dropdown from the pending list (newest first),
		falling back to tonight if nothing is pending."""
		nights = cl.pending_nights(self.conn, self.site_id) or [self._tonight]
		self.night_combo["values"] = nights
		self.night_var.set(select if select in nights else nights[0])
		self._update_context()

	def _update_context(self, *_) -> None:
		"""Show the latest logged forecast for the selected night as context."""
		nd = self.night_var.get()
		if not nd:
			self.ctx.config(text="")
			return
		fc = cl.latest_forecast(self.conn, nd, self.site_id)
		if fc:
			self.ctx.config(text=(
				f"Forecast that night:  {fc['recommendation']}  ·  "
				f"BB {fc['bb_score']} / NB {fc['nb_score']}  ·  {fc['cloud']}% cloud"))
		else:
			self.ctx.config(text="No forecast was logged for this night.")

	def _update_reason_enabled(self, *_) -> None:
		"""The reason preset only applies to a skip; disable it for an imaged night
		(notes stay enabled either way)."""
		self.reason_combo.config(
			state="readonly" if self.imaged_var.get() == 0 else "disabled")

	def _save(self) -> None:
		nd = self.night_var.get()
		if not nd:
			return
		imaged = self.imaged_var.get() == 1
		reason = "" if imaged else self.reason_var.get()
		cl.upsert_decision(self.conn, nd, self.site_id, imaged, reason,
						   self.notes_var.get().strip())
		# Advance to the next still-pending night, or close when the queue is empty.
		remaining = cl.pending_nights(self.conn, self.site_id)
		if remaining:
			self.notes_var.set("")
			self.imaged_var.set(0)
			self._reload_nights(select=remaining[0])
		else:
			self._on_close()

	def _on_close(self) -> None:
		self.conn.close()
		self.root.destroy()


def main() -> int:
	ap = argparse.ArgumentParser(description="astrowidget nightly decision form")
	ap.add_argument(
		"--site", default="Bainbridge",
		help="site id to log a decision for (the HOME site you image yourself)",
	)
	args = ap.parse_args()
	root = tk.Tk()
	DecisionForm(root, args.site)
	root.mainloop()
	return 0


if __name__ == "__main__":
	sys.exit(main())
