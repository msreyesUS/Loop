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

    override public func awakeFromNib() {
        super.awakeFromNib()

        updateDisplay(nil)
    }

    public var loopIconClosed = false {
        didSet {
            loopStateView.open = !loopIconClosed
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
        static let ringDiameter: CGFloat = 200
        static let glucoseFontSize: CGFloat = 62
        static let trendIconPointSize: CGFloat = 28
    }

    public let loopCompletionHUD = LoopCompletionHUDView(frame: CGRect(x: 0, y: 0, width: LayoutConstants.ringDiameter, height: LayoutConstants.ringDiameter))

    /// A preformatted glucose delta/rate string shown beside the unit inside the ring
    public var deltaString: String? {
        didSet {
            updateInfoLabel()
        }
    }

    /// A preformatted eventual glucose string shown below the ring
    public var eventualGlucoseText: String? {
        didSet {
            eventualGlucoseLabel.text = eventualGlucoseText
        }
    }

    /// The current glucose range category, used to tint the view's background.
    /// The tint is independent of the ring color: the background says how glucose is doing,
    /// the ring says whether the loop is running.
    public var glucoseRangeCategory: GlucoseRangeCategory? {
        didSet {
            updateBackgroundTint()
        }
    }

    private lazy var viewModel = CGMStatusHUDViewModel(staleGlucoseValueHandler: { [weak self] in
        self?.deltaString = nil
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

    private let trendImageView: UIImageView = {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: LayoutConstants.trendIconPointSize, weight: .bold)
        imageView.tintColor = .glucoseTintColor
        return imageView
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

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        let valueStack = UIStackView(arrangedSubviews: [glucoseLabel, trendImageView])
        valueStack.axis = .horizontal
        valueStack.alignment = .center
        valueStack.spacing = 4

        let glucoseStack = UIStackView(arrangedSubviews: [valueStack, infoLabel])
        glucoseStack.axis = .vertical
        glucoseStack.alignment = .center
        glucoseStack.spacing = 0

        loopCompletionHUD.translatesAutoresizingMaskIntoConstraints = false
        glucoseStack.translatesAutoresizingMaskIntoConstraints = false
        eventualGlucoseLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(loopCompletionHUD)
        addSubview(glucoseStack)
        addSubview(eventualGlucoseLabel)

        // The bottom constraint yields (999) rather than conflicting with the temporary
        // UIView-Encapsulated-Layout-Height constraint during table view self-sizing;
        // everything else in the vertical chain stays required so the ring keeps its size.
        let bottomConstraint = eventualGlucoseLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16)
        bottomConstraint.priority = UILayoutPriority(999)

        NSLayoutConstraint.activate([
            loopCompletionHUD.widthAnchor.constraint(equalToConstant: LayoutConstants.ringDiameter),
            loopCompletionHUD.heightAnchor.constraint(equalTo: loopCompletionHUD.widthAnchor),
            loopCompletionHUD.centerXAnchor.constraint(equalTo: centerXAnchor),
            loopCompletionHUD.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            glucoseStack.centerXAnchor.constraint(equalTo: loopCompletionHUD.centerXAnchor),
            glucoseStack.centerYAnchor.constraint(equalTo: loopCompletionHUD.centerYAnchor),
            glucoseStack.widthAnchor.constraint(lessThanOrEqualTo: loopCompletionHUD.widthAnchor, constant: -32),

            eventualGlucoseLabel.topAnchor.constraint(equalTo: loopCompletionHUD.bottomAnchor, constant: 12),
            eventualGlucoseLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            eventualGlucoseLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            bottomConstraint,
        ])

        loopCompletionHUD.freshnessDidChange = { [weak self] in
            self?.updateBackgroundTint()
        }

        updateGlucoseDisplay()
    }

    private func updateBackgroundTint() {
        // When the loop is stale, drop the tint to neutral so the red ring is the only
        // red element on screen: a red ring on a red field must never happen.
        if loopCompletionHUD.freshness == .stale {
            backgroundColor = nil
        } else {
            backgroundColor = glucoseRangeCategory?.backgroundTintColor
        }
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
            glucoseLabel.textColor = viewModel.glucoseValueTintColor
        }
        trendImageView.image = viewModel.glucoseTrendIcon
        trendImageView.isHidden = viewModel.glucoseTrendIcon == nil
        trendImageView.tintColor = viewModel.glucoseTrendTintColor
        updateInfoLabel()

        accessibilityValue = viewModel.accessibilityString
    }

    private func updateInfoLabel() {
        infoLabel.text = [viewModel.unitsString, deltaString].compactMap { $0 }.joined(separator: " · ")
    }
}
