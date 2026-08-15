/// The three things about the seam between a panel and its content that nobody
/// has measured, named so they can be changed in one line each.
///
/// DESIGN.md A5: *a measured fact is a constant, an unmeasured or subjective one
/// is a policy*, and *a policy is only worth the name if both ends are tested*.
/// All three here are the second kind. `PanelScrollPolicy` reads an SDK header
/// that Apple's own website contradicts (§6 of DESIGN.md); [PanelRefreshPolicy]
/// arbitrates a conflict A6.5 says nobody has found a rule for;
/// [MomentumCarry] is `[OPEN]` with no ground truth and three shipped packages
/// disagreeing.
///
/// They live together rather than beside the code that reads them because a
/// reader asking "what can I change about the handoff" should find the whole
/// answer in one file. DESIGN.md §6 files `PanelScrollPolicy` in `link.dart`;
/// putting the arbiter's *decisions* next to the arbiter's *machinery* is how a
/// fourth one gets added without anyone noticing it was a decision.
library;

import 'package:meta/meta.dart';
import '../physics/momentum.dart';

/// Who gets a drag delta when a scrollable inside the panel is the thing being
/// dragged.
///
/// A closed set with no payload, so an enum. iOS spells the same choice as two
/// booleans on `UISheetPresentationController`
/// (`prefersScrollingExpandsWhenScrolledToEdge` and the scroll view's own
/// position), and the two-boolean form is what makes `.resizesAlways` read as a
/// bug rather than a mode.
///
/// **The SDK header and the website disagree about S3 and this follows the
/// header**, on the research document's own stated rule ("Trust the SDK header
/// over the website"), in the three-value shape that separates the offset-zero
/// precondition from the priority. The grabber bypasses all three (S4): dragging
/// the handle always resizes, because a handle is not a scrollable.
enum PanelScrollPolicy {
  /// The panel resizes only while the content is scrolled to its start.
  ///
  /// The SDK header's precondition, verbatim: the sheet expands *"and a
  /// descendent scroll view is scrolled to top"*. Drag up at scroll offset zero
  /// and the panel grows; drag up anywhere else and the list scrolls. Drag down
  /// at scroll offset zero and the panel shrinks — S6 — which is also where
  /// [PanelRefreshPolicy] enters, because that is the one gesture two correct
  /// answers both claim.
  ///
  /// S5 falls out with no special case written: a single-detent panel has no
  /// neighbour above, so a drag up is never the panel's and scrolling simply
  /// scrolls.
  ///
  /// The default, and the only one of the three with a measured platform behind
  /// it.
  resizesFromEdge,

  /// The panel resizes first whatever the content's offset is.
  ///
  /// Drag down on a list scrolled to the middle and the *panel* shrinks; the
  /// list keeps its offset and starts scrolling only once the panel is at its
  /// smallest. Growing still stops at the largest detent, because there is
  /// nothing above it to grow into.
  ///
  /// Here because a panel whose detents are discrete *modes* rather than sizes
  /// wants the panel to win every time — a media sheet where the small state is
  /// a mini-player, and scrolling the queue should never be what closes it.
  resizesAlways,

  /// The content always wins; the panel is moved only by its handle, its
  /// background, or code.
  ///
  /// The end of the policy that proves it is a policy. A panel with a map or a
  /// canvas in it, where every drag belongs to the content and the sheet is
  /// driven by its grabber, is this — and expressing it as a mode is the
  /// alternative to an author reaching for `primary: false` and tripping the
  /// escape detector to get the same effect.
  scrollsFirst,
}

/// Who wins the one gesture that two correct answers both claim: a drag
/// downwards, from a list already at its top, on a panel that is fully open.
///
/// DESIGN.md A6.5, in full: iOS says that gesture moves the sheet toward its
/// next-smaller detent (S6); every list in every app says it refreshes. Both are
/// right and only one can happen. `smooth_sheets` hands the choice to the
/// developer behind `SheetScrollConfiguration.delegateUnhandledOverscrollToChild`
/// and defaults it off, so a `RefreshIndicator` in a sheet silently does nothing
/// — which is the same shape as `SheetScrollConfiguration.disabled` being the
/// default, and requirement 6 forbids us the equivalent.
///
/// So this is a policy and not a flag, and **the argument is about the default,
/// not about whether the knob exists**. The default has to be the one that makes
/// an ordinary `RefreshIndicator` work when the panel is fully open with the
/// panel keeping the gesture everywhere else, because our claim is that the
/// common case needs no configuration.
///
/// What it costs, said plainly: under [whenFullyOpen] a fully-open panel can no
/// longer be shrunk by dragging its list. The handle, the background and
/// `PanelController` still shrink it, and every smaller detent still does. That
/// is the price of the claim, and `refresh_test.dart` asserts it in the same
/// group as the capability it buys, so nobody discovers it as a bug.
///
/// **And it cannot be flung shut by its list either**, which is the same
/// sentence read through a release. `PanelScrollLink.panelMayTakeRelease` asks
/// this table at `FusedAxis.seam` — the panel at its largest, the content at its
/// own start — so a throw that runs the list back to its top stops there instead
/// of carrying into the panel. The alternative is a drag and a fling disagreeing
/// about the same gesture: the pull that arms the spinner would close the sheet
/// it is on, but only if the finger was still moving when it left. It does mean
/// [MomentumCarry]'s into-the-panel crossing is unreachable at the largest
/// detent while this policy is in force; it is reachable at every detent under
/// [never], which is the row `position_test.dart` keeps for it.
enum PanelRefreshPolicy {
  /// The content keeps a downward drag from its own start **only while the
  /// panel is at its largest resting height**. Anywhere smaller, the panel
  /// shrinks.
  ///
  /// The default. It is the reading of A6.5's "fully open" that makes an
  /// unmodified `RefreshIndicator` work and leaves S6 intact at every other
  /// detent.
  ///
  /// A6.5 asks which of two readings "fully open" is — *the largest detent*, or
  /// *no larger detent exists in this direction*. **They are the same predicate**
  /// given a strictly-greater `neighbourAbove`: at `extent == max` one is true by
  /// equality and the other by there being nothing above; below max both are
  /// false; above max — a rubber-banded overdrag — both are true.
  /// `refresh_test.dart` asserts that equivalence over the whole travel rather
  /// than leaving a choice recorded as open that has no two sides.
  ///
  /// What is *not* the same is the third reading neither option names: a panel
  /// that a spring left a tenth of a pixel short of its largest detent is
  /// visually fully open and fails both. So the predicate compares at
  /// [Extent.isCloseTo] — half a physical pixel of the display the panel is
  /// actually on — and the test that fires at 811.9 and does not at 811.5 on a
  /// 3x screen is what keeps a refresh from silently not happening on a panel
  /// the user has already finished opening.
  ///
  /// **A single-detent panel is fully open at the only height it has**, so this
  /// gives its list every downward drag from its own start, always. That is the
  /// wanted answer and not a degenerate one — there is nowhere for a one-size
  /// sheet to shrink to, so the alternative is a rubber band instead of a
  /// refresh — and it is the same sentence as the paragraph above rather than a
  /// special case: once `Detent.dismissed` lands, a `[dismissed, full]` sheet
  /// cannot be dismissed by dragging its list either, for the identical reason.
  /// `refresh_test.dart` decides both rows deliberately.
  whenFullyOpen,

  /// The panel always keeps it. Pure S6: a `RefreshIndicator` inside this panel
  /// never fires from a drag.
  ///
  /// The iOS-fidelity end. Correct for a panel whose content is not a feed —
  /// a place detail, a form — where a downward drag means "make this smaller"
  /// and a refresh spinner appearing would be the surprise.
  never,

  /// The content always keeps it. The panel never shrinks from a drag on its
  /// list, at any detent.
  ///
  /// The other end, and the reason this is three values rather than a boolean
  /// over the default: a panel whose whole content is a refreshable feed wants
  /// the refresh available at *every* detent, and under [whenFullyOpen] it is
  /// available at exactly one.
  always,
}

/// How one drag delta divides between the panel and the content.
///
/// **Both shares are on the extent axis, in logical pixels, positive when the
/// panel would grow.** That is the whole reason this is a named type rather than
/// the record DESIGN.md's `preScroll`/`scroll`/`postScroll` triple implies: the
/// two numbers are in the same units and mean different things, and a record
/// with two `double` fields is where a scroll-space delta gets handed to the
/// panel with the sign already wrong once. `PanelAnchor` converts the content
/// share back to scroll space at exactly one call site.
///
/// **One value instead of three calls.** DESIGN.md §3.2 gives the link a
/// three-step protocol — `preScroll` takes the panel's share, `scroll` moves the
/// list, `postScroll` hands the leftover back. Three calls are three chances for
/// the steps to disagree about state that moved in between, and the same
/// document rejects `smooth_sheets`' `dryApplyNewLayout`/`applyNewLayout` pair
/// for exactly that. One decision, computed once, applied twice.
@immutable
final class PanelScrollSplit {
  /// Divides a delta into a [panel] share and a [content] share.
  const PanelScrollSplit({required this.panel, required this.content});

  /// Nobody moves. The answer for a zero delta, and for a panel whose model has
  /// no gesture installed.
  static const PanelScrollSplit none = PanelScrollSplit(panel: 0, content: 0);

  /// The panel's share, in extent-axis px, positive when the panel grows.
  ///
  /// Handed to `PanelDragMechanics.update`, which accumulates it un-resisted and
  /// applies the rubber band to whatever falls outside the travel. So a share
  /// larger than the travel left is not a bug here — it is the overdrag, and the
  /// band is what shapes it.
  final double panel;

  /// The content's share, in extent-axis px, positive when the panel *would*
  /// have grown.
  ///
  /// Converted to a scroll delta by `PanelAnchor.extentDeltaFromScrollDelta`,
  /// which is its own inverse because every anchor's scroll sign is ±1 —
  /// asserted in `split_test.dart` over all five anchors and both reading
  /// directions rather than assumed, because the day an anchor needs a scale
  /// factor this is the call site that silently keeps working.
  final double content;

  /// The delta this split divided. Always exactly the input: the arbiter loses
  /// nothing and invents nothing.
  double get total => panel + content;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PanelScrollSplit &&
          other.panel == panel &&
          other.content == content;

  @override
  int get hashCode => Object.hash(panel, content);

  @override
  String toString() => 'PanelScrollSplit(panel: $panel, content: $content)';
}
