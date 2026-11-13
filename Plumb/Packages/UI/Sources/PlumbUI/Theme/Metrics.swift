import CoreGraphics

extension Theme {
    /// Every tunable number in the interface, with its default.
    /// Lengths are in reference points: the size they have on the phone, before the screen unit scales them.
    public struct Metrics: Sendable, Equatable {
        // MARK: Screen

        /// The canvas everything is drawn for: the phone in landscape.
        public var referenceSize = CGSize(width: 874, height: 402)
        /// The smallest scale a screen is ever drawn at, so a collapsed window never asks for zero-point type.
        public var minimumUnit: CGFloat = 0.25
        /// Width over height of the camera and depth pictures. They are never cropped to another shape.
        public var pictureAspect: CGFloat = 4.0 / 3.0
        /// Narrowest the coach panel may be. On the phone this is exactly what a full-height picture leaves.
        public var panelWidth: CGFloat = 338
        /// Narrowest the right-hand side of the show-working screen may be.
        public var workingPanelWidth: CGFloat = 540
        /// Space between the coach panel's edges and its content.
        public var panelPadding: CGFloat = 20
        /// Space above the first row of a panel or page.
        public var topPadding: CGFloat = 10
        /// Space between the handoff page's edges and its content.
        public var pagePadding: CGFloat = 24
        /// Space between neighbouring rows.
        public var rowGap: CGFloat = 8
        /// Space between two things that belong together, such as two sentences.
        public var tightGap: CGFloat = 4
        /// Space between the lines of a list.
        public var listGap: CGFloat = 2
        /// Space that sets one group of rows apart from the next.
        public var groupGap: CGFloat = 16

        // MARK: Rows

        /// Height of the command slot. Fixed, so the instrument below never moves when a command comes or goes.
        /// Tall enough for one line of the command, or two lines of the first instruction.
        public var commandSlotHeight: CGFloat = 76
        /// Height of the row holding the rate and the elapsed time.
        public var rateRowHeight: CGFloat = 58
        /// Hit height of every plain-word control.
        public var controlHeight: CGFloat = 64
        /// Thickness of the rules that separate rows and that bars hang from.
        public var ruleWidth: CGFloat = 1
        /// Strength of a rule against its ground. Rules organise; they are not content.
        public var ruleOpacity: Double = 0.55

        // MARK: Type

        /// Size of the command face. Chosen so "PUSH HARDER" fits the phone's panel on one line.
        public var commandSize: CGFloat = 60
        /// Size of the one large number on a screen: the rate, and the pause count.
        public var numeralLarge: CGFloat = 48
        /// Size of the handoff headline and its four numbers, of the scoreboard, and of the first instruction.
        public var numeralFigure: CGFloat = 32
        /// Size of quiet numbers such as the elapsed time.
        public var numeralSmall: CGFloat = 20
        /// Size of the labels on the depth lines and time axes.
        public var numeralLabel: CGFloat = 15
        /// Size of sentences and controls.
        public var textBody: CGFloat = 17
        /// Size of captions and lists.
        public var textSmall: CGFloat = 15
        /// Most lines a headline, a sentence or a caption may wrap to. Nothing runs longer.
        public var wrapLines = 2

        // MARK: Bars

        /// Slots across the live field. The rightmost is the live bar.
        public var barSlots = 18
        /// History entries the field's model keeps: a little more than can be seen.
        public var barHistory = 40
        /// Millimetres of travel that fill the field from the top rule to its bottom edge.
        public var fullScaleMM: Double = 70
        /// Share of a slot's width that a bar fills. The rest is the gap between bars.
        public var barFill: CGFloat = 0.62
        /// Width of the column left of the bars that holds the depth labels.
        public var fieldGutter: CGFloat = 34
        /// Thickness of the target line.
        public var lineWidth: CGFloat = 2
        /// Extra thickness the target line takes on at the instant a push reaches it.
        public var linePulseWidth: CGFloat = 4
        /// Thickness of the maximum-depth hairline.
        public var hairlineWidth: CGFloat = 0.5
        /// Stroke of an outlined bar, drawn while depth is only an estimate.
        public var outlineWidth: CGFloat = 1.5
        /// Length of the equal ticks drawn when only the rhythm is trusted.
        public var tickLength: CGFloat = 20
        /// How many label heights apart the two depth lines must be for both to carry a label.
        public var labelLeading: CGFloat = 1.3
        /// Space between the pause count and the edges of its block.
        public var blockInset: CGFloat = 8
        /// Narrowest a pause is ever drawn in a record, so a short one cannot vanish.
        public var minimumPauseWidth: CGFloat = 2
        /// Clear space between a pause's block and the bars beside it in a record.
        public var pauseMargin: CGFloat = 3
        /// Smallest share of a bar that may be left standing beside a pause. Less than this is a sliver, and is not drawn.
        public var sliverShare: CGFloat = 0.4
        /// Longest the field extends a pause on its own when the app stops reporting it, in seconds.
        public var pauseCoastSeconds: Double = 1

        // MARK: Motion and timing

        /// How long anything other than the bars takes to appear or go, in seconds.
        public var fadeSeconds: Double = 0.12
        /// How long the bars take to step one slot left, in seconds.
        public var stepSeconds: Double = 0.12
        /// Shape of the step: the power of its ease-out. Higher starts faster and settles longer.
        public var stepEase: Double = 3
        /// How long a push that reached the line stays emphasised, in seconds.
        public var emphasisSeconds: Double = 0.45
        /// Shape of the emphasis as it dies away: the power of its ease-out.
        public var emphasisEase: Double = 2
        /// How long an affirming command such as "GOOD" shows before it goes, in seconds.
        public var affirmSeconds: Double = 2
        /// How long "New rescue" must be held before it confirms, in seconds.
        public var holdSeconds: Double = 1.2
        /// How long "Hold to ask" takes to fill, in seconds. Listening starts at once; the fill only acknowledges.
        public var askFillSeconds: Double = 0.3
        /// Opacity of a plain-word control while it is pressed.
        public var pressedOpacity: Double = 0.5
        /// Size of the plain chevron on the one control that goes back.
        public var chevronSize = CGSize(width: 6, height: 12)
        /// How often the trust caption re-reads the model, in seconds.
        public var trustPollSeconds: Double = 0.25

        // MARK: Hold to confirm

        /// Thickness of the fill that runs along a held control's baseline.
        public var holdFillWidth: CGFloat = 2
        /// Distance from a control's text baseline down to its fill.
        public var holdBaselineDrop: CGFloat = 4

        // MARK: Handoff

        /// Shortest the session record's bars may be drawn.
        public var sessionBarsMinHeight: CGFloat = 56
        /// Tallest the session record's bars may be drawn, however much room there is.
        public var sessionBarsMaxHeight: CGFloat = 170
        /// Height kept under a record's bars for its time labels.
        public var axisLabelHeight: CGFloat = 20
        /// Most model-written sentences the handoff will show.
        public var sentenceLimit = 2

        // MARK: Show working

        /// Width of the column that names the three rows.
        public var rowLabelWidth: CGFloat = 84
        /// Shortest the three rows together may be drawn.
        public var workingRowsMinHeight: CGFloat = 190
        /// Tallest the three rows together may be drawn, however much room there is.
        public var workingRowsMaxHeight: CGFloat = 280
        /// Height of one line of marks or labels in the "Suggested" and "Decided" lanes.
        public var laneLineHeight: CGFloat = 20
        /// Lines in the "Suggested" lane: the spans, and one line for labels that do not fit beside them.
        public var suggestedLines = 2
        /// Lines in the "Decided" lane: the marks, and two lines for labels that do not fit beside them.
        public var decidedLines = 3
        /// Side of the square that marks a decision, and height of a suggestion's span.
        public var markSize: CGFloat = 8
        /// Space between a mark and its label, and between neighbouring labels.
        public var labelGap: CGFloat = 6
        /// How far from a mark a tap may land and still select it.
        public var hitSlop: CGFloat = 14
        /// Height kept for the one sentence about the selected mark: two lines.
        public var sentenceSlotHeight: CGFloat = 46
        /// Numbers on the scoreboard.
        public var scoreLimit = 3
        /// Most "Fails when" conditions listed. The list must fit the phone without scrolling.
        public var failsWhenLimit = 4

        /// The defaults.
        public init() {}
    }
}
