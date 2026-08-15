/// What a fling does when it reaches the seam between the panel's travel and the
/// content's scrollable distance.
///
/// DESIGN.md §3.3 marks S7 `[OPEN]` **with no ground truth**: Compose transfers
/// momentum across the seam, FloatingPanel and gorhom destroy it, and Flutter's
/// own `DraggableScrollableSheet` is asymmetric (flutter#116981). Nothing in a
/// test settles which is right — it needs hands on a device — so all three ship
/// and the default is argued rather than measured.
///
/// This is *not* a claim of iOS fidelity, and the doc says so where a reader
/// will find it: [both] follows `NestedScrollView`'s single-simulation-over-
/// combined-space template because that is the precedent inside Flutter, not
/// because a sheet was observed doing it.
enum MomentumCarry {
  /// One simulation over the whole axis: a fling that runs out of list keeps
  /// going into the panel, and a fling that runs out of panel keeps going into
  /// the list.
  ///
  /// The default. The risk, named: a fling that expands the panel *and* keeps
  /// scrolling may read as a loss of control, and that is the thing to try on a
  /// device before 1.0.
  both,

  /// A fling in the content may cross into the panel; a fling in the panel stops
  /// at the seam.
  ///
  /// Asymmetric on purpose, and it is the asymmetry flutter#116981 describes as
  /// a bug in `DraggableScrollableSheet` — kept as a *choice* because the
  /// argument for it is real: opening a sheet is a deliberate act and should
  /// end where the sheet ends, while closing one by flinging its list is a
  /// continuation of the same motion.
  intoPanelOnly,

  /// The seam is a wall. A fling is confined to the side it started on and
  /// whatever momentum is left at the seam is spent there.
  ///
  /// What FloatingPanel and gorhom do. It is the only one of the three that
  /// cannot surprise, and the only one that makes a two-part gesture out of a
  /// one-part throw.
  none,
}
