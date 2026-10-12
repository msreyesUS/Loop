//
//  LoopCompletionHUDView.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 5/1/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI
import LoopCore

public final class LoopCompletionHUDView: BaseHUDView {

    @IBOutlet private weak var loopStateView: LoopStateView!

    override public var orderPriority: HUDViewOrderPriority {
        return 2
    }

    /// Supports programmatic instantiation at arbitrary sizes (e.g. the status screen hero ring),
    /// wiring the loop state view the nib otherwise provides. The caption label is intentionally
    /// left nil; all caption updates are optional-chained.
    override public init(frame: CGRect) {
        super.init(frame: frame)

        let stateView = LoopStateView(frame: bounds)
        stateView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stateView)
        NSLayoutConstraint.activate([
            stateView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stateView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stateView.topAnchor.constraint(equalTo: topAnchor),
            stateView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loopStateView = stateView

        updateDisplay(nil)
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }

    /// Notifies interested views (e.g. StatusHeroView) when freshness changes over time
    var freshnessDidChange: (() -> Void)?

    private(set) var freshness = LoopCompletionFreshness.stale {
        didSet {
            updateTintColor()
            freshnessDidChange?()
        }
    }

    /// A one-word loop status under the ring in the status bar ("Connected", "Open Loop",
    /// "12 min ago"); nil for the hero ring, which has no room for it
    private var statusLabel: UILabel?

    override public func awakeFromNib() {
        super.awakeFromNib()

        let label = UILabel()
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        let bottomConstraint = label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4)
        bottomConstraint.priority = UILayoutPriority(999)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: loopStateView.bottomAnchor, constant: 6),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            bottomConstraint,
        ])
        statusLabel = label

        updateDisplay(nil)
    }

    public var loopIconClosed = false {
        didSet {
            loopStateView.open = !loopIconClosed
            updateStatusLabel()
        }
    }

    private func updateStatusLabel() {
        guard let statusLabel = statusLabel else { return }

        guard let lastLoopCompleted = lastLoopCompleted else {
            statusLabel.text = LocalizedString("Waiting", comment: "Status bar loop status before the first loop has run")
            statusLabel.textColor = .secondaryLabel
            return
        }

        switch freshness {
        case .fresh:
            if loopIconClosed {
                statusLabel.text = LocalizedString("Connected", comment: "Status bar loop status when closed loop is running and fresh")
                statusLabel.textColor = stateColors?.normal ?? .systemGreen
            } else {
                statusLabel.text = LocalizedString("Open Loop", comment: "Status bar loop status when the loop is open")
                statusLabel.textColor = .secondaryLabel
            }
        case .aging, .stale:
            // A loop that hasn't completed recently reads as its age, in the ring's color
            let ago = abs(min(0, lastLoopCompleted.timeIntervalSinceNow))
            if let timeString = timeAgoFormatter.string(from: ago) {
                statusLabel.text = String(format: LocalizedString("%@ ago", comment: "Format string describing the time interval since the last completion date. (1: The localized date components"), timeString)
            } else {
                statusLabel.text = "–"
            }
            statusLabel.textColor = freshness == .aging ? (stateColors?.warning ?? .warning) : (stateColors?.error ?? .critical)
        }
    }

    public var lastLoopCompleted: Date? {
        didSet {
            if lastLoopCompleted != oldValue {
                loopInProgress = false
            }
        }
    }

    public var loopInProgress = false {
        didSet {
            loopStateView.animated = loopInProgress

            if !loopInProgress {
                updateTimer = nil
                assertTimer()
            }
        }
    }

    public var closedLoopDisallowedLocalizedDescription: String?

    public func assertTimer(_ active: Bool = true) {
        if active && window != nil, let date = lastLoopCompleted {
            initTimer(date)
        } else {
            updateTimer = nil
        }
    }

    override public func stateColorsDidUpdate() {
        super.stateColorsDidUpdate()
        updateTintColor()
        updateStatusLabel()
    }

    private func updateTintColor() {
        let tintColor: UIColor?

        switch freshness {
        case .fresh:
            tintColor = stateColors?.normal
        case .aging:
            tintColor = stateColors?.warning
        case .stale:
            tintColor = stateColors?.error
        }

        self.tintColor = tintColor
    }

    private func initTimer(_ startDate: Date) {
        let updateInterval = TimeInterval(minutes: 1)

        let timer = Timer(
            fireAt: startDate.addingTimeInterval(2),
            interval: updateInterval,
            target: self,
            selector: #selector(updateDisplay(_:)),
            userInfo: nil,
            repeats: true
        )
        updateTimer = timer

        RunLoop.main.add(timer, forMode: .default)
    }

    private var updateTimer: Timer? {
        willSet {
            if let timer = updateTimer {
                timer.invalidate()
            }
        }
    }

    private lazy var formatterFull: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .full

        return formatter
    }()

    private var lastLoopMessage: String = ""

    private lazy var timeAgoFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()

        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 1
        formatter.unitsStyle = .short

        return formatter
    }()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var timeDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale.current
        return formatter
    }()

    @objc private func updateDisplay(_: Timer?) {
        lastLoopMessage = ""
        let timeAgoToIncludeTimeStamp: TimeInterval = .minutes(20)
        let timeAgoToIncludeDate: TimeInterval = .hours(4)
        if let date = lastLoopCompleted {
            let ago = abs(min(0, date.timeIntervalSinceNow))

            freshness = LoopCompletionFreshness(age: ago)

            if let timeString = timeAgoFormatter.string(from: ago) {
                switch traitCollection.preferredContentSizeCategory {
                case UIContentSizeCategory.extraSmall,
                     UIContentSizeCategory.small,
                     UIContentSizeCategory.medium,
                     UIContentSizeCategory.large:
                    // Use a longer form only for smaller text sizes
                    caption?.text = String(format: LocalizedString("%@ ago", comment: "Format string describing the time interval since the last completion date. (1: The localized date components"), timeString)
                default:
                    caption?.text = timeString
                }

                accessibilityLabel = String(format: LocalizedString("Loop ran %@ ago", comment: "Accessbility format label describing the time interval since the last completion date. (1: The localized date components)"), timeString)

                var fullTimeStr: String = ""
                if ago >= timeAgoToIncludeDate {
                    fullTimeStr = String(format: LocalizedString("was at %1$@", comment: "Format string describing last completion. (1: the date"), timeDateFormatter.string(from: date))
                } else if ago >= timeAgoToIncludeTimeStamp {
                    fullTimeStr = String(format: LocalizedString("%1$@ ago at %2$@", comment: "Format string describing last completion. (1: time ago, (2: the date"), timeAgoFormatter.string(from: ago)!, timeFormatter.string(from: date))
                } else if ago < .minutes(1) {
                    fullTimeStr = String(format: LocalizedString("<1 min ago", comment: "Format string describing last completion"))
                } else {
                    fullTimeStr = String(format: LocalizedString("%1$@ ago", comment: "Format string describing last completion. (1: time ago"), timeAgoFormatter.string(from: ago)!)
                }
                lastLoopMessage = String(format: LocalizedString("Last completed loop %1$@.", comment: "Last loop time completed message (1: last loop time string)"), fullTimeStr)
            } else {
                caption?.text = "–"
                accessibilityLabel = nil
            }
        } else {
            caption?.text = "–"
            accessibilityLabel = LocalizedString("Waiting for first run", comment: "Accessibility label describing completion HUD waiting for first run")
        }

        if loopIconClosed {
            accessibilityHint = LocalizedString("Closed loop", comment: "Accessibility hint describing completion HUD for a closed loop")
        } else {
            accessibilityHint = LocalizedString("Open loop", comment: "Accessbility hint describing completion HUD for an open loop")
        }

        updateStatusLabel()
    }

    override public func didMoveToWindow() {
        super.didMoveToWindow()

        assertTimer()
    }
}

extension LoopCompletionHUDView {
    public var loopCompletionMessage: (title: String, message: String) {
        switch freshness {
        case .fresh:
            if loopStateView.open {
                let reason = closedLoopDisallowedLocalizedDescription ?? LocalizedString("Tap Settings to toggle Closed Loop ON if you wish for the app to automate your insulin.", comment: "Instructions for user to close loop if it is allowed.")
                return (title: LocalizedString("Closed Loop OFF", comment: "Title of green open loop OFF message"),
                        message: String(format: LocalizedString("\n%1$@ is operating with Closed Loop in the OFF position. Your pump and CGM will continue operating, but the app will not adjust dosing automatically.\n\n%2$@", comment: "Green closed loop OFF message (1: app name)(2: reason for open loop)"), Bundle.main.bundleDisplayName, reason))
            } else {
                return (title: LocalizedString("Closed Loop ON", comment: "Title of green closed loop ON message"),
                        message: String(format: LocalizedString("\n%1$@\n\n%2$@ is operating with Closed Loop in the ON position.", comment: "Green closed loop ON message (1: last loop string) (2: app name)"), lastLoopMessage, Bundle.main.bundleDisplayName))
            }
        case .aging:
            return (title: LocalizedString("Loop Warning", comment: "Title of yellow loop message"),
                    message: String(format: LocalizedString("\n%1$@\n\nTap your CGM and insulin pump status icons for more information. %2$@ will continue trying to complete a loop, but watch for potential communication issues with your pump and CGM.", comment: "Yellow loop message (1: last loop string) (2: app name)"), lastLoopMessage, Bundle.main.bundleDisplayName))
        case .stale:
            return (title: LocalizedString("Loop Failure", comment: "Title of red loop message"),
                    message: String(format: LocalizedString("\n%1$@\n\nTap your CGM and insulin pump status icons for more information. %2$@ will continue trying to complete a loop, but check for potential communication issues with your pump and CGM.", comment: "Red loop message (1: last loop  string) (2: app name)"), lastLoopMessage, Bundle.main.bundleDisplayName))
        }
    }
}

// MARK: - StatusHeroView

/// The hero view for the main status screen: a large loop completion ring with the current
/// glucose value, trend, unit, and delta inside it, and the eventual glucose below it.
///
/// The ring reuses `LoopCompletionHUDView`, so freshness and open/closed loop rendering are
/// unchanged; the glucose display reuses `CGMStatusHUDViewModel`, so value/trend/staleness
/// behavior matches the CGM status HUD.
public final class StatusHeroView: UIView {

    private enum LayoutConstants {
        static let ringDiameter: CGFloat = 192
        static let glucoseFontSize: CGFloat = 64
    }

    public let loopCompletionHUD = LoopCompletionHUDView(frame: CGRect(x: 0, y: 0, width: LayoutConstants.ringDiameter, height: LayoutConstants.ringDiameter))

    /// A preformatted eventual glucose string shown below the ring
    public var eventualGlucoseText: String? {
        didSet {
            eventualGlucoseLabel.text = eventualGlucoseText
        }
    }

    /// The current glucose range category, which drives `backgroundTintDidChange`.
    /// The tint is independent of the loop state: the background says how glucose is doing,
    /// the loop indicator says whether the loop is running.
    public var glucoseRangeCategory: GlucoseRangeCategory? {
        didSet {
            updateBackgroundTint()
            updateGlucoseDisplay()
            setNeedsLayout()
        }
    }

    private var isLowState: Bool {
        switch glucoseRangeCategory {
        case .low, .belowRange, .urgentLow:
            return true
        default:
            return false
        }
    }

    /// Notifies the host of the current background tint base color (nil for neutral).
    /// Fired when the glucose range category changes, when glucose goes stale, and when
    /// loop freshness changes — a stale loop always forces neutral so a red loop
    /// indicator is never shown on a red field.
    public var backgroundTintDidChange: ((UIColor?) -> Void)? {
        didSet {
            updateBackgroundTint()
        }
    }

    private lazy var viewModel = CGMStatusHUDViewModel(staleGlucoseValueHandler: { [weak self] in
        self?.glucoseRangeCategory = nil
        self?.updateGlucoseDisplay()
    })

    private let glucoseLabel: UILabel = {
        let label = UILabel()
        label.font = .monospacedDigitSystemFont(ofSize: LayoutConstants.glucoseFontSize, weight: .bold)
        label.textColor = .label
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
        return label
    }()

    private let infoLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let eventualGlucoseLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        return label
    }()

    private let headerTitleLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .label
        return label
    }()

    private let headerUnitLabel: UILabel = {
        let label = UILabel()
        label.font = .systemFont(ofSize: 15)
        label.textColor = .secondaryLabel
        return label
    }()

    private lazy var infoButton: UIButton = {
        let button = UIButton(type: .system)
        let configuration = UIImage.SymbolConfiguration(pointSize: 20, weight: .regular)
        button.setImage(UIImage(systemName: "info.circle", withConfiguration: configuration), for: .normal)
        button.tintColor = .secondaryLabel
        button.accessibilityLabel = LocalizedString("More Info", comment: "Accessibility label for the status hero card info button")
        button.addTarget(self, action: #selector(infoButtonWasTapped), for: .touchUpInside)
        return button
    }()

    /// The card header title shown in the top-left corner (e.g. "Glucose Now")
    public var headerTitle: String? {
        didSet {
            headerTitleLabel.text = headerTitle
        }
    }

    /// Called when the info button in the top-right corner is tapped
    public var infoButtonTapped: (() -> Void)?

    @objc private func infoButtonWasTapped() {
        infoButtonTapped?()
    }

    /// A ring around the glucose reading, colored by range: green in range, red low,
    /// yellow high, neutral when there is no current reading. Drawn as a filled
    /// annulus so its outer contour can flow smoothly into the trend bulge.
    private let rangeRingLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.fillRule = .evenOdd
        return layer
    }()

    /// The ring's stroke thickness and the trend bulge geometry
    private enum RingConstants {
        static let thickness: CGFloat = 16
        static let bulgeLength: CGFloat = 48
        /// Half-span of the bulge along the circle, in radians
        static let bulgeHalfSpan: CGFloat = 0.62
        /// Half-angle of the bulge's point, in radians
        static let tipHalfAngle: CGFloat = 0.42
        /// The ring-colored margin between the bulge contour and the arrow
        static let arrowMargin: CGFloat = 6.5
    }

    /// The solid slate triangle inside the trend bulge; its path is derived from the
    /// bulge geometry in layoutSubviews so the margin around it stays constant
    private let trendArrowLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.isHidden = true
        return layer
    }()

    /// The disc filling the ring's center, flooded with the state color when out of range
    private let centerDiscLayer = CAShapeLayer()

    /// The coin's base: fills the whole silhouette (including the bulge) and carries
    /// the drop shadow
    private let ringShadowLayer: CAShapeLayer = {
        let layer = CAShapeLayer()
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.11
        layer.shadowRadius = 7
        layer.shadowOffset = CGSize(width: 0, height: 4)
        return layer
    }()

    /// The ring's paint: a gradient masked to the annulus-plus-bulge shape
    private let ringGradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0.3, y: 0)
        layer.endPoint = CGPoint(x: 0.7, y: 1)
        return layer
    }()


    private var trendArrowAngle: CGFloat? {
        // Radians, 0 at 3 o'clock, positive rising
        switch viewModel.trend {
        case .flat:
            return 0
        case .up:
            return .pi / 4
        case .upUp, .upUpUp:
            return .pi / 2
        case .down:
            return -.pi / 4
        case .downDown, .downDownDown:
            return -.pi / 2
        case .none:
            return nil
        }
    }


    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // The large ring is not shown: the loop indicator in the status bar HUD covers
        // loop state visually. The (hidden) completion HUD still runs the freshness
        // timer that keeps the background tint honest.
        loopCompletionHUD.isHidden = true

        // Trend arrow and unit/delta sit together on a line below the glucose value
        // The trend is shown by the arrow riding the ring; the info line carries the unit
        let infoStack = UIStackView(arrangedSubviews: [infoLabel])
        infoStack.axis = .horizontal
        infoStack.alignment = .center
        infoStack.spacing = 4

        layer.addSublayer(ringShadowLayer)
        layer.addSublayer(centerDiscLayer)
        layer.addSublayer(ringGradientLayer)
        // The ring shape masks the gradient rather than painting directly
        ringGradientLayer.mask = rangeRingLayer
        layer.addSublayer(trendArrowLayer)

        loopCompletionHUD.translatesAutoresizingMaskIntoConstraints = false
        glucoseLabel.translatesAutoresizingMaskIntoConstraints = false
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        eventualGlucoseLabel.translatesAutoresizingMaskIntoConstraints = false
        headerTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        headerUnitLabel.translatesAutoresizingMaskIntoConstraints = false
        infoButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(loopCompletionHUD)
        addSubview(glucoseLabel)
        addSubview(infoStack)
        addSubview(eventualGlucoseLabel)
        addSubview(headerTitleLabel)
        addSubview(headerUnitLabel)
        addSubview(infoButton)

        // The bottom constraint yields (999) rather than conflicting with the temporary
        // UIView-Encapsulated-Layout-Height constraint during table view self-sizing;
        // everything else in the vertical chain stays required so the ring keeps its size.
        // Symmetric padding: the space above the ring equals the space below the
        // eventual glucose text.
        let bottomConstraint = bottomAnchor.constraint(equalTo: eventualGlucoseLabel.bottomAnchor, constant: 32)
        bottomConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            // Card header: title and unit in the top-left corner, info button in the top-right
            headerTitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headerTitleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            headerTitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: infoButton.leadingAnchor, constant: -8),
            headerUnitLabel.leadingAnchor.constraint(equalTo: headerTitleLabel.leadingAnchor),
            headerUnitLabel.topAnchor.constraint(equalTo: headerTitleLabel.bottomAnchor, constant: 2),
            infoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            infoButton.centerYAnchor.constraint(equalTo: headerTitleLabel.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 40),
            infoButton.heightAnchor.constraint(equalToConstant: 40),

            loopCompletionHUD.widthAnchor.constraint(equalToConstant: LayoutConstants.ringDiameter),
            loopCompletionHUD.heightAnchor.constraint(equalTo: loopCompletionHUD.widthAnchor),
            loopCompletionHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            // Clearance for the trend bulge pointing straight up
            loopCompletionHUD.topAnchor.constraint(equalTo: topAnchor, constant: 52),

            // The glucose value itself is centered in the ring; the trend/unit line
            // hangs below it so it doesn't drag the number off center
            glucoseLabel.centerXAnchor.constraint(equalTo: loopCompletionHUD.centerXAnchor),
            glucoseLabel.centerYAnchor.constraint(equalTo: loopCompletionHUD.centerYAnchor),
            glucoseLabel.widthAnchor.constraint(lessThanOrEqualTo: loopCompletionHUD.widthAnchor, constant: -36),

            infoStack.centerXAnchor.constraint(equalTo: loopCompletionHUD.centerXAnchor),
            infoStack.topAnchor.constraint(equalTo: glucoseLabel.bottomAnchor, constant: -11),
            infoStack.widthAnchor.constraint(lessThanOrEqualTo: loopCompletionHUD.widthAnchor, constant: -36),

            // Clearance for the trend bulge pointing straight down
            eventualGlucoseLabel.topAnchor.constraint(equalTo: loopCompletionHUD.bottomAnchor, constant: 52),
            eventualGlucoseLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            eventualGlucoseLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bottomConstraint,
        ])

        loopCompletionHUD.freshnessDidChange = { [weak self] in
            self?.updateBackgroundTint()
        }

        updateGlucoseDisplay()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let ringFrame = loopCompletionHUD.frame
        let center = CGPoint(x: ringFrame.midX, y: ringFrame.midY)
        let outerRadius = ringFrame.width / 2
        let innerRadius = outerRadius - RingConstants.thickness

        // Screen-coordinate angles (y down); trend angles are math convention (y up)
        func polar(_ angle: CGFloat, _ radius: CGFloat) -> CGPoint {
            CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }

        let ringPath = UIBezierPath()
        if let trendAngle = trendArrowAngle {
            // The outer contour follows the circle, then flows out to a point at the
            // trend angle and back. The curves leave the circle exactly along its
            // tangents and approach the tip symmetrically, so the blend is smooth.
            let bulgeAngle = -trendAngle
            let halfSpan = RingConstants.bulgeHalfSpan
            let tip = polar(bulgeAngle, outerRadius + RingConstants.bulgeLength)
            let bPoint = polar(bulgeAngle - halfSpan, outerRadius)
            let aPoint = polar(bulgeAngle + halfSpan, outerRadius)

            let outward = CGPoint(x: cos(bulgeAngle), y: sin(bulgeAngle))
            // Circle tangents at the junctions, pointing toward the bulge
            let tangentB = CGPoint(x: -sin(bulgeAngle - halfSpan), y: cos(bulgeAngle - halfSpan))
            let tangentA = CGPoint(x: sin(bulgeAngle + halfSpan), y: -cos(bulgeAngle + halfSpan))

            func rotated(_ v: CGPoint, by angle: CGFloat) -> CGPoint {
                CGPoint(x: v.x * cos(angle) - v.y * sin(angle), y: v.x * sin(angle) + v.y * cos(angle))
            }
            func offset(_ p: CGPoint, along v: CGPoint, by distance: CGFloat) -> CGPoint {
                CGPoint(x: p.x + v.x * distance, y: p.y + v.y * distance)
            }

            let tangentReach = outerRadius * halfSpan * 0.55
            let tipReach = RingConstants.bulgeLength * 0.5
            let tipHalfAngle = RingConstants.tipHalfAngle

            ringPath.addArc(withCenter: center, radius: outerRadius,
                            startAngle: bulgeAngle + halfSpan, endAngle: bulgeAngle - halfSpan,
                            clockwise: true)
            ringPath.addCurve(to: tip,
                              controlPoint1: offset(bPoint, along: tangentB, by: tangentReach),
                              controlPoint2: offset(tip, along: rotated(outward, by: tipHalfAngle), by: -tipReach))
            ringPath.addCurve(to: aPoint,
                              controlPoint1: offset(tip, along: rotated(outward, by: -tipHalfAngle), by: -tipReach),
                              controlPoint2: offset(aPoint, along: tangentA, by: tangentReach))
            ringPath.close()

            // Solid slate arrow with the same apex angle as the bulge walls, inset by a
            // constant perpendicular margin so the border around it is uniform; its
            // base is an arc concentric with the ring, so it contours with the circle.
            let apexX = RingConstants.bulgeLength - RingConstants.arrowMargin / sin(tipHalfAngle)
            let baseX: CGFloat = -2
            let halfHeight = (apexX - baseX) * tan(tipHalfAngle)
            // Local coordinates: origin on the ring's outer edge, +x outward;
            // the ring's center sits at (-outerRadius, 0)
            let ringCenterLocal = CGPoint(x: -outerRadius, y: 0)
            let baseRadius = outerRadius + baseX
            let baseHalfAngle = asin(min(1, halfHeight / baseRadius))
            let arrowPath = UIBezierPath()
            arrowPath.move(to: CGPoint(x: apexX, y: 0))
            arrowPath.addLine(to: CGPoint(x: ringCenterLocal.x + cos(baseHalfAngle) * baseRadius,
                                          y: sin(baseHalfAngle) * baseRadius))
            arrowPath.addArc(withCenter: ringCenterLocal, radius: baseRadius,
                             startAngle: baseHalfAngle, endAngle: -baseHalfAngle, clockwise: false)
            arrowPath.close()
            trendArrowLayer.path = arrowPath.cgPath
            trendArrowLayer.position = polar(bulgeAngle, outerRadius)
            trendArrowLayer.setAffineTransform(CGAffineTransform(rotationAngle: bulgeAngle))
            trendArrowLayer.fillColor = (UIColor(named: "primaryButton1") ?? .label).resolvedColor(with: traitCollection).cgColor
            trendArrowLayer.isHidden = false
        } else {
            ringPath.addArc(withCenter: center, radius: outerRadius,
                            startAngle: 0, endAngle: 2 * .pi, clockwise: true)
            trendArrowLayer.isHidden = true
        }
        // The coin's base fills the whole silhouette (including the bulge) and casts
        // the drop shadow
        ringShadowLayer.path = ringPath.cgPath
        ringShadowLayer.shadowPath = ringPath.cgPath
        ringShadowLayer.fillColor = UIColor.systemBackground.resolvedColor(with: traitCollection).cgColor

        // Inner edge of the annulus (even-odd fill leaves the middle clear)
        ringPath.move(to: polar(0, innerRadius))
        ringPath.addArc(withCenter: center, radius: innerRadius,
                        startAngle: 0, endAngle: 2 * .pi, clockwise: true)

        // The ring is painted by a gradient masked to the annulus-plus-bulge shape:
        // a soft grey with dimension while in range, the state color when out
        rangeRingLayer.path = ringPath.cgPath
        ringGradientLayer.frame = bounds

        let stateColor: UIColor
        switch glucoseRangeCategory {
        case .high, .aboveRange:
            stateColor = .warning
        case .low, .belowRange, .urgentLow:
            stateColor = .critical
        default:
            stateColor = .systemBackground
        }
        let resolvedState = stateColor.resolvedColor(with: traitCollection)

        // The grey ring is constant across states; only the center disc floods
        let light = UIColor.systemGray5.resolvedColor(with: traitCollection)
        let dark = UIColor.systemGray3.resolvedColor(with: traitCollection)
        ringGradientLayer.colors = [light.cgColor, dark.cgColor]

        // The center disc floods with the state color (white in range, yellow high,
        // red low), slightly overlapping the ring's inner edge to avoid a seam
        centerDiscLayer.path = UIBezierPath(arcCenter: center, radius: innerRadius + 1,
                                            startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        centerDiscLayer.fillColor = resolvedState.cgColor

        CATransaction.commit()
    }

    public override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        setNeedsLayout()
    }

    private func updateBackgroundTint() {
        // When the loop is stale, drop the tint to neutral so the red loop indicator is
        // the only red element on screen.
        let base: UIColor?
        if loopCompletionHUD.freshness == .stale {
            base = nil
        } else {
            base = glucoseRangeCategory?.backgroundGradientColor
        }

        backgroundTintDidChange?(base)
    }

    public func setGlucoseQuantity(_ glucoseQuantity: Double,
                                   at glucoseStartDate: Date,
                                   unit: HKUnit,
                                   staleGlucoseAge: TimeInterval,
                                   glucoseDisplay: GlucoseDisplayable?,
                                   wasUserEntered: Bool,
                                   isDisplayOnly: Bool)
    {
        viewModel.setGlucoseQuantity(glucoseQuantity,
                                     at: glucoseStartDate,
                                     unit: unit,
                                     staleGlucoseAge: staleGlucoseAge,
                                     glucoseDisplay: glucoseDisplay,
                                     wasUserEntered: wasUserEntered,
                                     isDisplayOnly: isDisplayOnly)
        updateGlucoseDisplay()
    }

    private func updateGlucoseDisplay() {
        if viewModel.glucoseValueString == CGMStatusHUDViewModel.staleGlucoseRepresentation {
            // No current reading: show a dimmed full-size placeholder so the layout keeps
            // its size perspective instead of collapsing around a row of dashes.
            glucoseLabel.text = "0.0"
            glucoseLabel.textColor = .tertiaryLabel
        } else {
            glucoseLabel.text = viewModel.glucoseValueString
            if isLowState {
                // On the red disc, the value and unit read in white
                glucoseLabel.textColor = .white
            } else if viewModel.glucoseValueTintColor == .label {
                // The value renders in the palette slate; sensor-limit tints from
                // the view model still take precedence
                glucoseLabel.textColor = UIColor(named: "primaryButton1") ?? .label
            } else {
                glucoseLabel.textColor = viewModel.glucoseValueTintColor
            }
        }
        infoLabel.text = viewModel.unitsString
        infoLabel.textColor = isLowState ? .white : .secondaryLabel
        // The header caption mirrors the display unit shown inside the disc
        headerUnitLabel.text = viewModel.unitsString

        // Reposition the ring's trend arrow for the new trend
        setNeedsLayout()

        accessibilityValue = viewModel.accessibilityString
    }
}

