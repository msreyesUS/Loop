//
//  StatusTableViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 9/6/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import UIKit
import HealthKit
import SwiftUI
import Intents
import LoopCore
import LoopKit
import LoopKitUI
import LoopTestingKit
import LoopUI
import SwiftCharts
import os.log
import Combine
import WidgetKit


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.status, .glucose, .insulin, .carbs, .targets]
}

/// A full-screen, static soft gradient behind the status table — a slight cool wash
/// rather than flat white — giving the Liquid Glass controls content to refract.
private final class GradientBackgroundView: UIView {

    private static let topColor = UIColor(named: "statusBackgroundTop") ?? .secondarySystemBackground
    private static let bottomColor = UIColor(named: "statusBackgroundBottom") ?? .secondarySystemBackground

    private let gradientLayer: CAGradientLayer = {
        let layer = CAGradientLayer()
        layer.startPoint = CGPoint(x: 0.5, y: 0)
        layer.endPoint = CGPoint(x: 0.5, y: 1)
        return layer
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .secondarySystemBackground
        layer.addSublayer(gradientLayer)
        updateColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.frame = bounds
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // CGColors don't adapt automatically; re-resolve for the new appearance
        updateColors()
    }

    private func updateColors() {
        gradientLayer.colors = [
            Self.topColor.resolvedColor(with: traitCollection).cgColor,
            Self.bottomColor.resolvedColor(with: traitCollection).cgColor,
        ]
    }
}

final class StatusTableViewController: LoopChartsTableViewController {

    private let log = OSLog(category: "StatusTableViewController")

    lazy var carbFormatter: QuantityFormatter = QuantityFormatter(for: .gram())

    lazy var insulinFormatter: QuantityFormatter = QuantityFormatter(for: .internationalUnit())

    var onboardingManager: OnboardingManager!

    var testingScenariosManager: TestingScenariosManager!

    var automaticDosingStatus: AutomaticDosingStatus!
    
    var alertPermissionsChecker: AlertPermissionsChecker!

    var alertMuter: AlertMuter!

    var supportManager: SupportManager!

    lazy private var cancellables = Set<AnyCancellable>()

    override func viewDidLoad() {

        super.viewDidLoad()

        // Buttons in the table respond to touch-down immediately instead of after
        // the scroll view's ~150ms touch delay
        tableView.delaysContentTouches = false

        tableView.register(HeroStatusTableViewCell.self, forCellReuseIdentifier: HeroStatusTableViewCell.className)
        tableView.register(PrimaryActionsTableViewCell.self, forCellReuseIdentifier: PrimaryActionsTableViewCell.className)
        tableView.register(GlucoseChartTableViewCell.self, forCellReuseIdentifier: GlucoseChartTableViewCell.className)
        tableView.register(StatsTableViewCell.self, forCellReuseIdentifier: StatsTableViewCell.className)
        tableView.register(BolusProgressTableViewCell.nib(), forCellReuseIdentifier: BolusProgressTableViewCell.className)
        tableView.register(AlertPermissionsDisabledWarningCell.self, forCellReuseIdentifier: AlertPermissionsDisabledWarningCell.className)
        tableView.register(MuteAlertsWarningCell.self, forCellReuseIdentifier: MuteAlertsWarningCell.className)

        registerPumpManager()
        registerCGMManager()

        let notificationCenter = NotificationCenter.default

        notificationObservers += [
            notificationCenter.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let rawContext = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                let context = LoopDataManager.LoopUpdateContext(rawValue: rawContext)
                DispatchQueue.main.async {
                    switch context {
                    case .none, .insulin?:
                        self?.refreshContext.formUnion([.status, .insulin])
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .carbs?:
                        self?.refreshContext.update(with: .carbs)
                    case .glucose?:
                        self?.refreshContext.formUnion([.glucose, .carbs])
                    case .loopFinished?:
                        self?.refreshContext.update(with: .insulin)
                    }

                    self?.hudView?.loopCompletionHUD.loopInProgress = false
                    self?.heroStatusView?.loopCompletionHUD.loopInProgress = false
                    self?.log.debug("[reloadData] from notification with context %{public}@", String(describing: context))
                    self?.reloadData(animated: true)
                }
                
                WidgetCenter.shared.reloadAllTimelines()
            },
            notificationCenter.addObserver(forName: .LoopRunning, object: deviceManager.loopManager, queue: nil) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.hudView?.loopCompletionHUD.loopInProgress = true
                    self?.heroStatusView?.loopCompletionHUD.loopInProgress = true
                }
            },
            notificationCenter.addObserver(forName: .PumpManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerPumpManager()
                    self?.configurePumpManagerHUDViews()
                    self?.updateActionButtons()
                }
            },
            notificationCenter.addObserver(forName: .CGMManagerChanged, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.registerCGMManager()
                    self?.configureCGMManagerHUDViews()
                    self?.updateActionButtons()
                }
            },
            notificationCenter.addObserver(forName: .PumpEventsAdded, object: deviceManager, queue: nil) { [weak self] (notification: Notification) in
                DispatchQueue.main.async {
                    self?.refreshContext.update(with: .insulin)
                    self?.reloadData(animated: true)
                }
            },
        ]

        automaticDosingStatus.$automaticDosingEnabled
            .receive(on: DispatchQueue.main)
            .sink { self.automaticDosingStatusChanged($0) }
            .store(in: &cancellables)

        alertMuter.$configuration
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .dropFirst()
            .sink { _ in
                self.refreshContext.update(with: .status)
                self.reloadData(animated: true)
            }
            .store(in: &cancellables)

        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 74

        // Estimate an initial value
        landscapeMode = UIScreen.main.bounds.size.width > UIScreen.main.bounds.size.height

        addScenarioStepGestureRecognizers()

        tableView.backgroundColor = .secondarySystemBackground
        tableView.backgroundView = gradientBackgroundView
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext.formUnion(RefreshContext.all)
        }
    }

    private var appearedOnce = false

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        navigationController?.setNavigationBarHidden(true, animated: animated)
        navigationController?.setToolbarHidden(true, animated: animated)

        updateActionButtons()

        alertPermissionsChecker.checkNow()

        updateBolusProgress()

        onboardingManager.$isComplete
            .merge(with: onboardingManager.$isSuspended)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshContext.update(with: .status)
                self?.reloadData(animated: true)
                self?.updateActionButtons()
            }
            .store(in: &cancellables)
    }

    override func viewDidAppear(_ animated: Bool) {

        super.viewDidAppear(animated)

        if !appearedOnce {
            appearedOnce = true
            DispatchQueue.main.async {
                self.log.debug("[reloadData] after HealthKit authorization")
                self.reloadData()
            }
        }

        onscreen = true

        deviceManager.analyticsServicesManager.didDisplayStatusScreen()

        deviceManager.checkDeliveryUncertaintyState()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        onscreen = false

        if presentedViewController == nil {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        maybeOpenDebugMenu()

        super.viewWillTransition(to: size, with: coordinator)
    }

    // MARK: - State

    // This reflects whether the application is active 
    override var active: Bool {
        didSet {
            hudView?.loopCompletionHUD.assertTimer(active)
            heroStatusView?.loopCompletionHUD.assertTimer(active)
            updateHUDActive()
        }
    }

    // This is similar to the visible property, but is set later, on viewDidAppear, to be
    // suitable for animations that should be seen in their entirety.
    var onscreen: Bool = false {
        didSet {
            updateHUDActive()
        }
    }

    private var bolusState: PumpManagerStatus.BolusState = .noBolus {
        didSet {
            if oldValue != bolusState {
                switch bolusState {
                case .inProgress(let dose):
                    guard case .inProgress = oldValue else {
                        // Bolus starting
                        bolusProgressReporter = deviceManager.pumpManager?.createBolusProgressReporter(reportingOn: DispatchQueue.main)
                        // If there is an existing bolus progressCell, update its dose values now in case the app is currently in the
                        // background as otherwise these values won't get initialized and can contain stale data from some earlier bolus.
                        if let progressCell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
                            progressCell.totalUnits = dose.programmedUnits
                            progressCell.deliveredUnits = 0
                        }
                        break
                    }
                default:
                    break
                }
                refreshContext.update(with: .status)
                reloadData(animated: true)
            }
        }
    }

    private var bolusProgressReporter: DoseProgressReporter?

    private func updateBolusProgress() {
        if let cell = tableView.cellForRow(at: IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)) as? BolusProgressTableViewCell {
            cell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
        }
    }

    private func updateHUDActive() {
        deviceManager.pumpManagerHUDProvider?.visible = active && onscreen
    }

    private func configurePrimaryActionsCell(_ cell: PrimaryActionsTableViewCell) {
        let isPumpOnboarded = onboardingManager.isComplete || deviceManager.pumpManager?.isOnboarded == true

        cell.onBolus = { [weak self] in self?.presentBolusScreen() }
        cell.onCarbs = { [weak self] in self?.userTappedAddCarbs() }
        cell.onMore = { [weak self] in self?.presentMoreActions() }
        cell.onSettings = { [weak self] in self?.presentSettings() }

        cell.bolusButton.isEnabled = isPumpOnboarded
        cell.carbsButton.isEnabled = isPumpOnboarded
    }

    /// Blends two colors, resolving dynamic colors for the current appearance
    private static func blend(_ color: UIColor, with other: UIColor, fraction: CGFloat) -> UIColor {
        UIColor { traits in
            var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
            var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
            other.resolvedColor(with: traits).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
            return UIColor(red: r1 + (r2 - r1) * fraction,
                           green: g1 + (g2 - g1) * fraction,
                           blue: b1 + (b2 - b1) * fraction,
                           alpha: 1)
        }
    }

    /// The sheet presented by the MORE button, holding the pre-meal, suspend, and
    /// preset actions that no longer live on the main screen
    private weak var moreActionsViewController: MoreActionsViewController?

    private func configureMoreActions(_ vc: MoreActionsViewController) {
        let isPumpOnboarded = onboardingManager.isComplete || deviceManager.pumpManager?.isOnboarded == true

        vc.setPreMeal(selected: preMealMode == true && preMealModeAllowed, enabled: preMealModeAllowed)
        vc.setPreset(active: workoutMode == true, enabled: workoutModeAllowed)
        vc.suspendButton.isEnabled = isPumpOnboarded && !(basalDeliveryState?.isSuspended ?? true)
    }

    private func presentMoreActions() {
        let vc = MoreActionsViewController()

        // Each action dismisses the sheet first so any follow-up alert or screen
        // can be presented from this view controller
        vc.onPreMeal = { [weak self] in self?.dismissMoreActions { self?.togglePreMealMode(confirm: false) } }
        vc.onSuspend = { [weak self] in self?.dismissMoreActions { self?.presentSuspendInsulinConfirmation() } }
        vc.onPreset = { [weak self] in self?.dismissMoreActions { self?.presentCustomPresets(confirm: false) } }

        configureMoreActions(vc)

        vc.modalPresentationStyle = .pageSheet
        if let sheet = vc.sheetPresentationController {
            if #available(iOS 16.0, *) {
                sheet.detents = [.custom { _ in 260 }]
            } else {
                sheet.detents = [.medium()]
            }
            sheet.prefersGrabberVisible = true
        }

        moreActionsViewController = vc
        present(vc, animated: true)
    }

    private func dismissMoreActions(then action: @escaping () -> Void) {
        if let vc = moreActionsViewController, vc.presentingViewController != nil {
            vc.dismiss(animated: true, completion: action)
        } else {
            action()
        }
    }

    private func updateActionButtons() {
        if let cell = tableView.cellForRow(at: IndexPath(row: ActionsRow.primary.rawValue, section: Section.actions.rawValue)) as? PrimaryActionsTableViewCell {
            configurePrimaryActionsCell(cell)
        }
        if let vc = moreActionsViewController {
            configureMoreActions(vc)
        }
    }

    private func presentSuspendInsulinConfirmation() {
        let alert = UIAlertController(
            title: NSLocalizedString("Suspend Insulin Delivery?", comment: "The alert title for suspend insulin confirmation"),
            message: NSLocalizedString("The pump will stop delivering insulin until you resume. Loop will not adjust your dosing while delivery is suspended.", comment: "The alert body for suspend insulin confirmation"),
            preferredStyle: .alert
        )
        alert.addCancelAction()
        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Suspend", comment: "The title of the action used to suspend insulin delivery"),
            style: .destructive
        ) { [weak self] _ in
            self?.deviceManager.pumpManager?.suspendDelivery { (error) in
                DispatchQueue.main.async {
                    if let error = error {
                        let alert = UIAlertController(with: error, title: NSLocalizedString("Failed to Suspend Insulin Delivery", comment: "The alert title for a suspend error"))
                        self?.present(alert, animated: true, completion: nil)
                    }
                }
            }
        })
        present(alert, animated: true)
    }

    public var basalDeliveryState: PumpManagerStatus.BasalDeliveryState? = nil {
        didSet {
            if oldValue != basalDeliveryState {
                log.debug("New basalDeliveryState: %@", String(describing: basalDeliveryState))
                refreshContext.update(with: .status)
                reloadData(animated: true)
                updateActionButtons()
            }
        }
    }

    // Toggles the display mode based on the screen aspect ratio. Should not be updated outside of reloadData().
    private var landscapeMode = false

    private var lastLoopError: Error?

    private var reloading = false

    private var refreshContext = RefreshContext.all

    private var shouldShowHUD: Bool {
        return !landscapeMode
    }


    override func glucoseUnitDidChange() {
        log.debug("[reloadData] for HealthKit unit preference change")
        refreshContext = RefreshContext.all
    }
    
    /// A benign status highlight shown in the CGM pill when the CGM has nothing to
    /// report; the big glucose number already covers the reading, so the pill carries
    /// sensor state instead. Real highlights (searching, warmup, signal loss) take
    /// precedence via the existing mechanism.
    private struct SensorOKStatusHighlight: DeviceStatusHighlight {
        var localizedMessage: String {
            NSLocalizedString("Sensor\nActive", comment: "Sensor status shown when the CGM has nothing to report")
        }
        var imageName: String {
            "sensor.tag.radiowaves.forward"
        }
        var state: DeviceStatusHighlightState {
            .normalCGM
        }
    }

    private func registerCGMManager() {
        deviceManager.cgmManager?.removeStatusObserver(self)
        deviceManager.cgmManager?.addStatusObserver(self, queue: .main)
    }

    private func registerPumpManager() {
        basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState
        bolusState = deviceManager.pumpManager?.status.bolusState ?? .noBolus
        deviceManager.pumpManager?.removeStatusObserver(self)
        deviceManager.pumpManager?.addStatusObserver(self, queue: .main)
    }
    
    override func createChartsManager() -> ChartsManager {
        // Charts have been removed from this screen; provide an empty manager to satisfy the base class.
        return ChartsManager(colors: .primary, settings: .default, charts: [], traitCollection: traitCollection)
    }

    override func reloadData(animated: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))

        guard view.window != nil else {
            return
        }

        // This should be kept up to date immediately
        hudView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted
        heroStatusView?.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

        guard !reloading && !deviceManager.authorizationRequired else {
            return
        }

        if case .bolusing = statusRowMode, bolusProgressReporter?.progress.isComplete == true {
            refreshContext.update(with: .status)
        }

        if visible && active {
            bolusProgressReporter?.addObserver(self)
        } else {
            bolusProgressReporter?.removeObserver(self)
        }

        guard active && visible && !refreshContext.isEmpty else {
            updateBannerRow(animated: animated)
            return
        }

        log.debug("Reloading data with context: %@", String(describing: refreshContext))

        let currentContext = refreshContext
        var retryContext: Set<RefreshContext> = []
        refreshContext = []
        reloading = true

        let reloadGroup = DispatchGroup()
        var glucoseSamples: [StoredGlucoseSample]?
        var predictedGlucoseValues: [GlucoseValue]?
        var iobValues: [InsulinValue]?
        var cobValues: [CarbValue]?
        var carbsOnBoard: HKQuantity?
        var newLastManualBolus: DoseEntry?
        var lastManualBolusUpdated = false
        var newLastCarbEntryDate: Date?
        var lastCarbEntryUpdated = false
        let startDate = Date(timeIntervalSinceNow: -LoopConstants.statusChartMinimumHistoryDisplay)
        let basalDeliveryState = self.basalDeliveryState
        let automaticDosingEnabled = automaticDosingStatus.automaticDosingEnabled

        // TODO: Don't always assume currentContext.contains(.status)
        reloadGroup.enter()
        deviceManager.loopManager.getLoopState { (manager, state) -> Void in
            predictedGlucoseValues = state.predictedGlucoseIncludingPendingInsulin ?? []

            // Retry this refresh again if predicted glucose isn't available
            if state.predictedGlucose == nil {
                retryContext.update(with: .status)
            }

            /// Update the status HUDs immediately
            let lastLoopError = state.error

            // Net basal rate HUD
            let netBasal: NetBasal?
            if let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory {
                netBasal = basalDeliveryState?.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            } else {
                netBasal = nil
            }
            self.log.debug("Update net basal to %{public}@", String(describing: netBasal))

            DispatchQueue.main.async {
                self.lastLoopError = lastLoopError

                if let netBasal = netBasal {
                    self.hudView?.pumpStatusHUD.basalRateHUD.setNetBasalRate(netBasal.rate, percent: netBasal.percent, at: netBasal.start)

                    if let rateString = self.netBasalFormatter.string(from: netBasal.rate) {
                        self.netBasalDescription = String(format: NSLocalizedString("%@ U", comment: "The format string describing the net basal rate. (1: localized basal rate value)"), rateString)
                    } else {
                        self.netBasalDescription = nil
                    }
                    self.netBasalStart = netBasal.start
                }
            }

            if currentContext.contains(.carbs) {
                reloadGroup.enter()
                self.deviceManager.carbStore.getCarbsOnBoardValues(start: startDate, end: nil, effectVelocities: state.insulinCounteractionEffects) { (result) in
                    switch result {
                    case .failure(let error):
                        self.log.error("CarbStore failed to get carbs on board values: %{public}@", String(describing: error))
                        retryContext.update(with: .carbs)
                        cobValues = []
                    case .success(let values):
                        cobValues = values
                    }
                    reloadGroup.leave()
                }
            }
            // always check for cob
            carbsOnBoard = state.carbsOnBoard?.quantity

            reloadGroup.leave()
        }

        if currentContext.contains(.glucose) {
            reloadGroup.enter()
            deviceManager.glucoseStore.getGlucoseSamples(start: Date(timeIntervalSinceNow: -Self.chartHistoryInterval), end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("Failure getting glucose samples: %{public}@", String(describing: error))
                    glucoseSamples = nil
                case .success(let samples):
                    glucoseSamples = samples
                }
                reloadGroup.leave()
            }
        }

        if currentContext.contains(.carbs) {
            reloadGroup.enter()
            deviceManager.carbStore.getCarbEntries(start: Date(timeIntervalSinceNow: -Self.lastManualBolusLookback), end: nil) { (result) in
                switch result {
                case .failure(let error):
                    self.log.error("CarbStore failed to get carb entries: %{public}@", String(describing: error))
                case .success(let entries):
                    newLastCarbEntryDate = entries.map(\.startDate).max()
                    lastCarbEntryUpdated = true
                }
                reloadGroup.leave()
            }
        }

        if currentContext.contains(.insulin) {
            reloadGroup.enter()
            deviceManager.doseStore.getInsulinOnBoardValues(start: startDate, end: nil, basalDosingEnd: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get insulin on board values: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                    iobValues = []
                case .success(let values):
                    iobValues = values
                }
                reloadGroup.leave()
            }

            reloadGroup.enter()
            deviceManager.doseStore.getNormalizedDoseEntries(start: Date(timeIntervalSinceNow: -Self.lastManualBolusLookback), end: nil) { (result) -> Void in
                switch result {
                case .failure(let error):
                    self.log.error("DoseStore failed to get dose entries for last bolus: %{public}@", String(describing: error))
                    retryContext.update(with: .insulin)
                case .success(let doses):
                    newLastManualBolus = doses
                        .filter { $0.type == .bolus && $0.automatic != true && !$0.isMutable }
                        .max(by: { $0.startDate < $1.startDate })
                    lastManualBolusUpdated = true
                }
                reloadGroup.leave()
            }
        }

        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)

        if deviceManager.loopManager.settings.preMealTargetRange == nil {
            preMealMode = nil
        } else {
            preMealMode = deviceManager.loopManager.settings.preMealTargetEnabled()
        }

        if !FeatureFlags.sensitivityOverridesEnabled, deviceManager.loopManager.settings.legacyWorkoutTargetRange == nil {
            workoutMode = nil
        } else {
            workoutMode = deviceManager.loopManager.settings.nonPreMealOverrideEnabled()
        }

        reloadGroup.notify(queue: .main) {
            // Eventual Glucose
            if (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled),
                let eventualGlucose = predictedGlucoseValues?.last
            {
                self.eventualGlucoseDescription = self.deviceManager.displayGlucosePreference.format(eventualGlucose.quantity)
            } else {
                self.eventualGlucoseDescription = nil
            }

            // Active Insulin
            // Show the larger of the value either before or after the current date
            if let iobValues = iobValues {
                if let currentIOB = iobValues.allElementsAdjacent(to: Date()).max(by: { $0.value < $1.value }) {
                    self.currentIOBDescription = self.insulinFormatter.string(from: HKQuantity(unit: .internationalUnit(), doubleValue: currentIOB.value))
                } else {
                    self.currentIOBDescription = nil
                }
            }

            // Active Carbohydrates
            if let currentCOB = cobValues?.closestPrior(to: Date()) {
                self.currentCOBDescription = self.carbFormatter.string(from: currentCOB.quantity)
            } else if let carbsOnBoard = carbsOnBoard {
                self.currentCOBDescription = self.carbFormatter.string(from: carbsOnBoard)
            } else {
                self.currentCOBDescription = nil
            }

            // Last Bolus
            if lastManualBolusUpdated {
                self.lastManualBolus = newLastManualBolus
            }
            if lastCarbEntryUpdated {
                self.lastCarbEntryDate = newLastCarbEntryDate
            }

            self.updateStatsCell()

            self.tableView.beginUpdates()
            if let hudView = self.hudView {
                // CGM Status
                if let glucose = self.deviceManager.glucoseStore.latestGlucose {
                    let unit = self.deviceManager.displayGlucosePreference.unit
                    hudView.cgmStatusHUD.setGlucoseQuantity(glucose.quantity.doubleValue(for: unit),
                                                            at: glucose.startDate,
                                                            unit: unit,
                                                            staleGlucoseAge: LoopCoreConstants.inputDataRecencyInterval,
                                                            glucoseDisplay: self.deviceManager.glucoseDisplay(for: glucose),
                                                            wasUserEntered: glucose.wasUserEntered,
                                                            isDisplayOnly: glucose.isDisplayOnly)
                }
                hudView.cgmStatusHUD.presentStatusHighlight(self.deviceManager.cgmStatusHighlight ?? SensorOKStatusHighlight())
                hudView.cgmStatusHUD.presentStatusBadge(self.deviceManager.cgmStatusBadge)
                hudView.cgmStatusHUD.lifecycleProgress = self.deviceManager.cgmLifecycleProgress

                // Pump Status
                hudView.pumpStatusHUD.presentStatusHighlight(self.deviceManager.pumpStatusHighlight)
                hudView.pumpStatusHUD.presentStatusBadge(self.deviceManager.pumpStatusBadge)
                hudView.pumpStatusHUD.lifecycleProgress = self.deviceManager.pumpLifecycleProgress
                self.updatePodExpiration(on: hudView)
            }

            // Hero glucose display
            if let heroStatusView = self.heroStatusView {
                if let glucose = self.deviceManager.glucoseStore.latestGlucose {
                    let unit = self.deviceManager.displayGlucosePreference.unit
                    let glucoseDisplay = self.deviceManager.glucoseDisplay(for: glucose)
                    heroStatusView.setGlucoseQuantity(glucose.quantity.doubleValue(for: unit),
                                                      at: glucose.startDate,
                                                      unit: unit,
                                                      staleGlucoseAge: LoopCoreConstants.inputDataRecencyInterval,
                                                      glucoseDisplay: glucoseDisplay,
                                                      wasUserEntered: glucose.wasUserEntered,
                                                      isDisplayOnly: glucose.isDisplayOnly)
                    // Color the ring against the same in-range band the chart shows.
                    // CGM-reported categories (sensor-limit LOW/HIGH) take precedence;
                    // most CGMs don't report one, so fall back to comparing the reading
                    // to the band: low is red, in range green, high yellow.
                    if let cgmCategory = glucoseDisplay?.glucoseRangeCategory {
                        heroStatusView.glucoseRangeCategory = cgmCategory
                    } else {
                        let mgdl = glucose.quantity.doubleValue(for: .milligramsPerDeciliter)
                        if mgdl < Self.chartInRangeBand.lowerBound.doubleValue(for: .milligramsPerDeciliter) {
                            heroStatusView.glucoseRangeCategory = .low
                        } else if mgdl > Self.chartInRangeBand.upperBound.doubleValue(for: .milligramsPerDeciliter) {
                            heroStatusView.glucoseRangeCategory = .high
                        } else {
                            heroStatusView.glucoseRangeCategory = .normal
                        }
                    }
                } else {
                    heroStatusView.glucoseRangeCategory = nil
                }

                if let eventualGlucose = self.eventualGlucoseDescription {
                    heroStatusView.eventualGlucoseText = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
                } else {
                    heroStatusView.eventualGlucoseText = nil
                }
            }

            // Chart card: only refresh when this reload actually fetched glucose history.
            // Only real CGM history is charted — no predicted values.
            if let glucoseSamples = glucoseSamples {
                let unit = self.deviceManager.displayGlucosePreference.unit
                self.chartHistoricalGlucose = glucoseSamples.map { ($0.startDate, $0.quantity.doubleValue(for: unit)) }
                self.chartTargetRange = Self.chartInRangeBand.lowerBound.doubleValue(for: unit)...Self.chartInRangeBand.upperBound.doubleValue(for: unit)
                let displayBound = Self.chartDisplayBand
                self.chartDisplayRange = displayBound.lowerBound.doubleValue(for: unit)...displayBound.upperBound.doubleValue(for: unit)
                self.chartGridValues = Self.chartGridValues(for: unit)
                self.updateChartCell()
            }

            self.tableView.endUpdates()

            // Show/hide the table view rows. This must stay OUTSIDE the batch above:
            // nested beginUpdates defer the row changes to the outer endUpdates, which
            // commits them with the default slide animation — bouncing the action
            // buttons — and prevents the in-place fade from finding its cells.
            let statusRowMode = self.determineStatusRowMode()

            self.updateBannerAndHUDandStatusRows(statusRowMode: statusRowMode, newSize: currentContext.newSize, animated: animated)

            self.reloading = false
            let reloadNow = !self.refreshContext.isEmpty
            self.refreshContext.formUnion(retryContext)

            // Trigger a reload if new context exists.
            if reloadNow {
                self.log.debug("[reloadData] due to context change during previous reload")
                self.reloadData()
            }
        }
    }

    private enum Section: Int, CaseIterable {
        case alertWarning
        case hud
        case hero
        case chart
        case stats
        case status
        case actions
    }

    // MARK: - Actions Section Data

    private enum ActionsRow: Int, CaseIterable {
        case primary = 0
    }

    // MARK: - Status Metrics Data

    private var eventualGlucoseDescription: String?

    private var currentIOBDescription: String?

    private var currentCOBDescription: String?

    private var netBasalDescription: String?

    /// The most recent non-automatic bolus, cached and refreshed under the insulin refresh context.
    /// Automatic boluses (from the Automatic Bolus dosing strategy) are excluded so this doesn't
    /// churn every five minutes.
    private var lastManualBolus: DoseEntry?

    /// When the most recent carb entry was made, cached under the carbs refresh context
    private var lastCarbEntryDate: Date?

    /// When the current net basal took effect (updates as the loop adjusts the temp basal)
    private var netBasalStart: Date?

    private static let lastManualBolusLookback = TimeInterval(hours: 24)

    /// How much glucose history the chart card shows
    private static let chartHistoryInterval = TimeInterval(hours: 3)

    /// The conventional time-in-range band (70–180 mg/dL, i.e. 3.9–10.0 mmol/L),
    /// matching how CGM apps display "in range"
    private static let chartInRangeBand =
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 70)...HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 180)

    /// The chart's fixed vertical domain, 2.0–22.2 mmol/L, so the in-range band sits
    /// well clear of the bottom edge and readings up to sensor limits stay on-chart
    private static let chartDisplayBand =
        HKQuantity(unit: .millimolesPerLiter, doubleValue: 2.0)...HKQuantity(unit: .millimolesPerLiter, doubleValue: 22.2)

    /// Values (in the display unit) marked by faint dotted gridlines with labels along
    /// the chart's left edge
    private static func chartGridValues(for unit: HKUnit) -> [Double] {
        if unit == .millimolesPerLiter {
            return Array(stride(from: 2.0, through: 22.0, by: 4.0))
        } else {
            return Array(stride(from: 50.0, through: 400.0, by: 50.0))
        }
    }

    private var chartHistoricalGlucose: [(date: Date, value: Double)] = []
    private var chartTargetRange: ClosedRange<Double>?
    private var chartDisplayRange: ClosedRange<Double>?
    private var chartGridValues: [Double] = []

    private lazy var bolusTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// Shows the time remaining until pod expiration in the pump pill, derived from the
    /// lifecycle progress. The pod's progress reports the REMAINING fraction of its
    /// 72-hour nominal life. Units zero out rather than drop as time drains, e.g.
    /// headline "0 days" with detail "0 hrs 52 min left".
    private func updatePodExpiration(on hudView: StatusBarHUDView) {
        if let progress = deviceManager.pumpLifecycleProgress, progress.percentComplete > 0 {
            let nominalPodLife = TimeInterval(hours: 72)
            let remaining = progress.percentComplete * nominalPodLife
            let totalMinutes = Int(remaining / 60)
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            let dayUnit = days == 1 ? "day" : "days"
            let hourUnit = hours == 1 ? "hr" : "hrs"
            hudView.pumpStatusHUD.setExpiration(headline: "\(days) \(dayUnit)", detail: "\(hours) \(hourUnit) \(minutes) min left")
        } else {
            hudView.pumpStatusHUD.setExpiration(headline: nil, detail: nil)
        }
    }

    /// The pump pill's caption: "Pod" for Omnipod systems, otherwise the generic "Pump"
    private var pumpDeviceCaption: String {
        if deviceManager.pumpManager?.pluginIdentifier.hasPrefix("Omni") == true {
            return NSLocalizedString("Pod", comment: "Caption naming an Omnipod in the status bar pill")
        }
        return NSLocalizedString("Pump", comment: "Caption naming a generic pump in the status bar pill")
    }

    private lazy var netBasalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.minimumIntegerDigits = 1
        formatter.positiveFormat = "+0.0##"
        formatter.negativeFormat = "-0.0##"

        return formatter
    }()

    // MARK: - Loop Status Section Data

    private enum StatusRow: Int, CaseIterable {
        case status = 0
    }

    private enum StatusRowMode {
        case hidden
        case scheduleOverrideEnabled(TemporaryScheduleOverride)
        case enactingBolus
        case bolusing(dose: DoseEntry)
        case cancelingBolus
        case pumpSuspended(resuming: Bool)
        case onboardingSuspended
        case recommendManualGlucoseEntry

        var hasRow: Bool {
            switch self {
            case .hidden:
                return false
            default:
                return true
            }
        }
    }

    private var statusRowMode = StatusRowMode.hidden

    /// A secondary status row surfacing an active override/pre-meal when the primary row
    /// is occupied by something else (e.g. No Recent Glucose)
    private var overrideStatusRowMode = StatusRowMode.hidden

    private func determineOverrideStatusRowMode(primaryMode: StatusRowMode) -> StatusRowMode {
        // When the primary row already shows the override, don't repeat it
        if case .scheduleOverrideEnabled = primaryMode {
            return .hidden
        }

        if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride,
            !scheduleOverride.hasFinished()
        {
            return .scheduleOverrideEnabled(scheduleOverride)
        }

        if let premealOverride = deviceManager.loopManager.settings.preMealOverride,
            !premealOverride.hasFinished()
        {
            return .scheduleOverrideEnabled(premealOverride)
        }

        return .hidden
    }

    /// The status row mode backing a given row of the status section.
    /// Row 0 is always the primary slot (possibly .hidden); row 1 is the override row.
    private func statusRowMode(forRow row: Int) -> StatusRowMode {
        if row == 0 {
            return statusRowMode
        }
        return overrideStatusRowMode
    }

    private func determineStatusRowMode() -> StatusRowMode {
        let statusRowMode: StatusRowMode

        if case .initiating = bolusState {
            statusRowMode = .enactingBolus
        } else if case .canceling = bolusState {
            statusRowMode = .cancelingBolus
        } else if case .suspended = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: false)
        } else if case .resuming = basalDeliveryState {
            statusRowMode = .pumpSuspended(resuming: true)
        } else if case .inProgress(let dose) = bolusState, dose.endDate.timeIntervalSinceNow > 0 {
            statusRowMode = .bolusing(dose: dose)
        } else if !onboardingManager.isComplete, deviceManager.pumpManager?.isOnboarded == true {
            statusRowMode = .onboardingSuspended
        } else if onboardingManager.isComplete, deviceManager.isGlucoseValueStale {
            statusRowMode = .recommendManualGlucoseEntry
        } else if let scheduleOverride = deviceManager.loopManager.settings.scheduleOverride,
            !scheduleOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(scheduleOverride)
        } else if let premealOverride = deviceManager.loopManager.settings.preMealOverride,
            !premealOverride.hasFinished()
        {
            statusRowMode = .scheduleOverrideEnabled(premealOverride)
        } else {
            statusRowMode = .hidden
        }

        return statusRowMode
    }

    /// Applies the translucent rounded card background used across the status screen
    private func applyCardBackground(to cell: UITableViewCell, cornerRadius: CGFloat = 14) {
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = UIColor.systemBackground.withAlphaComponent(0.62)
        background.cornerRadius = cornerRadius
        background.backgroundInsets = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        background.strokeColor = Self.cardBorderColor
        background.strokeWidth = 1
        cell.backgroundConfiguration = background
    }

    private func configureStatsCell(_ cell: StatsTableViewCell) {
        let placeholder = "—"
        cell.iobValueLabel.text = currentIOBDescription ?? placeholder
        cell.cobValueLabel.text = currentCOBDescription ?? placeholder
        cell.basalValueLabel.text = netBasalDescription ?? placeholder

        // The last bolus belongs with active insulin
        if let bolus = lastManualBolus,
           let volumeString = insulinFormatter.string(from: HKQuantity(unit: .internationalUnit(), doubleValue: bolus.deliveredUnits ?? bolus.programmedUnits))
        {
            cell.iobCaptionLabel.text = String(format: NSLocalizedString("%1$@ · %2$@", comment: "The caption describing the last bolus below active insulin. (1: localized insulin amount)(2: localized time)"), volumeString, bolusTimeFormatter.string(from: bolus.startDate))
        } else {
            cell.iobCaptionLabel.text = " "
        }

        // When the most recent carbs were entered
        if let lastCarbEntryDate = lastCarbEntryDate {
            cell.cobCaptionLabel.text = bolusTimeFormatter.string(from: lastCarbEntryDate)
        } else {
            cell.cobCaptionLabel.text = " "
        }

        // When the current net basal took effect
        if let netBasalStart = netBasalStart {
            cell.basalCaptionLabel.text = bolusTimeFormatter.string(from: netBasalStart)
        } else {
            cell.basalCaptionLabel.text = " "
        }
    }

    private func configureChartCell(_ cell: GlucoseChartTableViewCell) {
        cell.titleLabel.text = NSLocalizedString("Glucose – Last 3 Hours", comment: "The title of the status screen glucose chart card")
        cell.unitLabel.text = deviceManager.displayGlucosePreference.unit.localizedShortUnitString
        cell.chartView.setData(historical: chartHistoricalGlucose, predicted: [], targetRange: chartTargetRange, displayRange: chartDisplayRange, gridValues: chartGridValues)
    }

    private func updateChartCell() {
        if let cell = tableView.cellForRow(at: IndexPath(row: 0, section: Section.chart.rawValue)) as? GlucoseChartTableViewCell {
            configureChartCell(cell)
        }
    }

    private func updateStatsCell() {
        if let cell = tableView.cellForRow(at: IndexPath(row: 0, section: Section.stats.rawValue)) as? StatsTableViewCell {
            configureStatsCell(cell)
        }
    }

    private var shouldShowBannerWarning: Bool {
        alertPermissionsChecker.showWarning || alertMuter.configuration.shouldMute
    }

    private func updateBannerRow(animated: Bool) {
        let warningWasVisible = tableView.numberOfRows(inSection: Section.alertWarning.rawValue) != 0
        if !shouldShowBannerWarning && warningWasVisible {
            tableView.deleteRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else if shouldShowBannerWarning && !warningWasVisible {
            tableView.insertRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: animated ? .top : .none)
        } else {
            tableView.reloadRows(at: [IndexPath(row: 0, section: Section.alertWarning.rawValue)], with: .none)
        }
    }

    private func updateBannerAndHUDandStatusRows(statusRowMode: StatusRowMode, newSize: CGSize?, animated: Bool) {
        let hudWasVisible = self.shouldShowHUD
        // The primary status row is a permanent slot in portrait; only rotation
        // inserts or deletes it
        let statusWasVisible = !landscapeMode
        let overrideWasVisible = !landscapeMode && self.overrideStatusRowMode.hasRow
        let oldOverrideRow = statusWasVisible ? 1 : 0

        let oldStatusRowMode = self.statusRowMode

        self.statusRowMode = statusRowMode
        self.overrideStatusRowMode = determineOverrideStatusRowMode(primaryMode: statusRowMode)

        if let newSize = newSize {
            landscapeMode = newSize.width > newSize.height
        }

        let hudIsVisible = self.shouldShowHUD
        let statusIsVisible = !landscapeMode
        let overrideIsVisible = !landscapeMode && self.overrideStatusRowMode.hasRow
        let newOverrideRow = statusIsVisible ? 1 : 0

        hudView?.cgmStatusHUD?.isVisible = hudIsVisible

        // Status rows fade in and out strictly in place: all row changes are applied
        // without movement (the spacer above the actions absorbs the height change
        // within the same frame, so the buttons never shift), outgoing rows fade away
        // via a snapshot left at their old position, and incoming rows fade in.
        var fadeOutSnapshots: [UIView] = []
        var fadeInRows: [IndexPath] = []

        func snapshotRowForFadeOut(at indexPath: IndexPath) {
            guard animated,
                  let cell = tableView.cellForRow(at: indexPath),
                  let snapshot = cell.snapshotView(afterScreenUpdates: false) else {
                return
            }
            snapshot.frame = cell.frame
            fadeOutSnapshots.append(snapshot)
        }

        let statusIndexPath = IndexPath(row: StatusRow.status.rawValue, section: Section.status.rawValue)
        let oldOverrideIndexPath = IndexPath(row: oldOverrideRow, section: Section.status.rawValue)
        let newOverrideIndexPath = IndexPath(row: newOverrideRow, section: Section.status.rawValue)

        let statusNeedsReload: Bool
        switch (oldStatusRowMode, self.statusRowMode) {
        case (.hidden, .hidden):
            statusNeedsReload = false
        case (.enactingBolus, .enactingBolus):
            statusNeedsReload = false
        case (.bolusing(let oldDose), .bolusing(let newDose)):
            statusNeedsReload = oldDose.syncIdentifier != newDose.syncIdentifier
        case (.pumpSuspended(resuming: let wasResuming), .pumpSuspended(resuming: let isResuming)):
            statusNeedsReload = isResuming != wasResuming
        default:
            statusNeedsReload = true
        }

        // Snapshots must be taken while the outgoing cells are still on screen
        if statusWasVisible && (!statusIsVisible || statusNeedsReload) {
            snapshotRowForFadeOut(at: statusIndexPath)
        }
        if overrideWasVisible && !overrideIsVisible {
            snapshotRowForFadeOut(at: oldOverrideIndexPath)
        }

        UIView.performWithoutAnimation {
            tableView.beginUpdates()

            updateBannerRow(animated: false)

            switch (hudWasVisible, hudIsVisible) {
            case (false, true):
                tableView.insertRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: .none)
            case (true, false):
                tableView.deleteRows(at: [IndexPath(row: 0, section: Section.hud.rawValue)], with: .none)
            default:
                break
            }

            switch (statusWasVisible, statusIsVisible) {
            case (true, true):
                if statusNeedsReload {
                    tableView.reloadRows(at: [statusIndexPath], with: .none)
                    fadeInRows.append(statusIndexPath)
                }
            case (false, true):
                tableView.insertRows(at: [statusIndexPath], with: .none)
                fadeInRows.append(statusIndexPath)
            case (true, false):
                tableView.deleteRows(at: [statusIndexPath], with: .none)
            default:
                break
            }

            // Secondary override row (deletes address the old index space, inserts the new)
            switch (overrideWasVisible, overrideIsVisible) {
            case (true, true):
                tableView.deleteRows(at: [oldOverrideIndexPath], with: .none)
                tableView.insertRows(at: [newOverrideIndexPath], with: .none)
            case (false, true):
                tableView.insertRows(at: [newOverrideIndexPath], with: .none)
                fadeInRows.append(newOverrideIndexPath)
            case (true, false):
                tableView.deleteRows(at: [oldOverrideIndexPath], with: .none)
            case (false, false):
                break
            }

            tableView.endUpdates()

            // Settle the new row heights and re-balance the bottom spacer within the
            // same frame so the action buttons hold their position
            tableView.layoutIfNeeded()
            updateActionsBottomSpacer()
            tableView.layoutIfNeeded()
        }

        guard animated else { return }

        for indexPath in fadeInRows {
            guard let cell = tableView.cellForRow(at: indexPath) else { continue }
            cell.alpha = 0
            UIView.animate(withDuration: 0.3) {
                cell.alpha = 1
            }
        }

        for snapshot in fadeOutSnapshots {
            tableView.addSubview(snapshot)
            UIView.animate(withDuration: 0.25, animations: {
                snapshot.alpha = 0
            }, completion: { _ in
                snapshot.removeFromSuperview()
            })
        }
    }

    // MARK: - Toolbar data

    private var preMealMode: Bool? = nil {
        didSet {
            guard oldValue != preMealMode else {
                return
            }
            updatePresetModeAvailability(automaticDosingEnabled: automaticDosingStatus.automaticDosingEnabled)
        }
    }
    private lazy var preMealModeAllowed: Bool = {
        onboardingManager.isComplete &&
                (automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
    }()

    private func updatePresetModeAvailability(automaticDosingEnabled: Bool) {
        preMealModeAllowed = onboardingManager.isComplete &&
                (automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled)
                && deviceManager.loopManager.settings.preMealTargetRange != nil
        workoutModeAllowed = onboardingManager.isComplete && workoutMode != nil
        updateActionButtons()
    }

    private var workoutMode: Bool? = nil {
        didSet {
            guard oldValue != workoutMode else {
                return
            }
            workoutModeAllowed = workoutMode != nil && onboardingManager.isComplete
            updateActionButtons()
        }
    }
    private lazy var workoutModeAllowed: Bool = {
        workoutMode != nil && onboardingManager.isComplete
    }()

    // MARK: - Table view data source

    override func numberOfSections(in tableView: UITableView) -> Int {
        return Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .alertWarning:
            return shouldShowBannerWarning ? 1 : 0
        case .hero:
            return 1
        case .chart:
            return 1
        case .stats:
            return 1
        case .hud:
            return shouldShowHUD ? 1 : 0
        case .status:
            guard !landscapeMode else {
                return 0
            }
            // The primary status row is a permanent fixed-height slot (invisible when
            // .hidden) so cards fade in and out of it without reflowing the layout —
            // the action buttons below never move
            return 1 + (overrideStatusRowMode.hasRow ? 1 : 0)
        case .actions:
            return ActionsRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        // Status cards swap between cell types of different natural heights (e.g. the
        // 44pt bolus progress nib vs 58pt title/subtitle cards); a fixed height keeps
        // the slot — and the action buttons below it — from shifting between modes
        if Section(rawValue: indexPath.section) == .status {
            return 58
        }
        return UITableView.automaticDimension
    }

    /// The card border color: the system separator, heavily softened
    static let cardBorderColor = UIColor { traits in
        let resolved = UIColor.separator.resolvedColor(with: traits)
        return resolved.withAlphaComponent(resolved.cgColor.alpha * 0.35)
    }

    /// A rounded, translucent card with a hairline border so it reads against the
    /// equally subtle background gradient
    private final class CardView: UIView {
        init(cornerRadius: CGFloat) {
            super.init(frame: .zero)
            backgroundColor = .systemBackground.withAlphaComponent(0.62)
            layer.cornerRadius = cornerRadius
            layer.cornerCurve = .continuous
            layer.borderWidth = 1
            // A whisper of depth in place of the heavier border
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.05
            layer.shadowRadius = 5
            layer.shadowOffset = CGSize(width: 0, height: 2)
            translatesAutoresizingMaskIntoConstraints = false
            updateBorderColor()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            updateBorderColor()
        }

        private func updateBorderColor() {
            layer.borderColor = StatusTableViewController.cardBorderColor.resolvedColor(with: traitCollection).cgColor
        }
    }

    /// A rounded, translucent card container used by the redesigned status cells;
    /// partially transparent so the background gradient shows through
    private static func makeCardView(cornerRadius: CGFloat = 20) -> UIView {
        return CardView(cornerRadius: cornerRadius)
    }

    private class HeroStatusTableViewCell: UITableViewCell {
        let heroView = StatusHeroView()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

            selectionStyle = .none
            backgroundColor = .clear

            let cardView = StatusTableViewController.makeCardView()
            heroView.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview(heroView)
            contentView.addSubview(cardView)

            let bottomConstraint = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
            bottomConstraint.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                heroView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
                heroView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
                heroView.topAnchor.constraint(equalTo: cardView.topAnchor),
                heroView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

                cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
                bottomConstraint,
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    /// A lightweight glucose chart: target-range band, history line with endpoint dot,
    /// dashed prediction tail, and hourly time labels. No interaction; tap the card to
    /// open the prediction screen.
    private final class SimpleGlucoseChartView: UIView {
        private var historical: [(date: Date, value: Double)] = []
        private var predicted: [(date: Date, value: Double)] = []
        private var targetRange: ClosedRange<Double>?
        private var displayRange: ClosedRange<Double>?
        private var gridValues: [Double] = []

        private lazy var axisTimeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }()

        private lazy var axisValueFormatter: NumberFormatter = {
            let formatter = NumberFormatter()
            formatter.maximumFractionDigits = 1
            formatter.minimumFractionDigits = 0
            return formatter
        }()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isOpaque = false
            backgroundColor = .clear
            contentMode = .redraw
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func setData(historical: [(date: Date, value: Double)], predicted: [(date: Date, value: Double)], targetRange: ClosedRange<Double>?, displayRange: ClosedRange<Double>?, gridValues: [Double] = []) {
            self.historical = historical.sorted { $0.date < $1.date }
            self.predicted = predicted.sorted { $0.date < $1.date }
            self.targetRange = targetRange
            self.displayRange = displayRange
            self.gridValues = gridValues
            setNeedsDisplay()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            setNeedsDisplay()
        }

        override func draw(_ rect: CGRect) {
            let axisHeight: CGFloat = 14
            // Reserve a right-hand gutter for the range value labels and a left-hand
            // gutter for the gridline labels
            let valueAxisWidth: CGFloat = 30
            let leftAxisWidth: CGFloat = gridValues.isEmpty ? 0 : 24
            let drawRect = CGRect(x: bounds.minX + leftAxisWidth + 2, y: bounds.minY + 4, width: bounds.width - leftAxisWidth - valueAxisWidth - 6, height: bounds.height - axisHeight - 8)

            let all = historical + predicted
            let minDate = all.map(\.date).min() ?? Date(timeIntervalSinceNow: -TimeInterval(hours: 3))
            let maxDate = all.map(\.date).max() ?? Date()
            guard maxDate > minDate else { return }
            let dateSpan = maxDate.timeIntervalSince(minDate)

            // A fixed display range keeps the line calm (like the CGM app's chart)
            // instead of amplifying small wiggles by auto-scaling to the data;
            // the domain only expands when data or the target band falls outside it.
            var valueMin = displayRange?.lowerBound ?? all.map(\.value).min() ?? targetRange?.lowerBound ?? 0
            var valueMax = displayRange?.upperBound ?? all.map(\.value).max() ?? targetRange?.upperBound ?? 1
            if let dataMin = all.map(\.value).min(), let dataMax = all.map(\.value).max() {
                valueMin = min(valueMin, dataMin)
                valueMax = max(valueMax, dataMax)
            }
            if let targetRange = targetRange {
                valueMin = min(valueMin, targetRange.lowerBound)
                valueMax = max(valueMax, targetRange.upperBound)
            }
            // Keep the padding tight so the fixed domain edges (2.0 and 22.2) stay
            // close to the chart edges and the outermost gridlines remain visible
            let padding = max((valueMax - valueMin) * 0.02, 0.1)
            valueMin -= padding
            valueMax += padding
            let valueSpan = valueMax - valueMin

            func x(for date: Date) -> CGFloat {
                drawRect.minX + CGFloat(date.timeIntervalSince(minDate) / dateSpan) * drawRect.width
            }
            func y(for value: Double) -> CGFloat {
                drawRect.maxY - CGFloat((value - valueMin) / valueSpan) * drawRect.height
            }
            func point(for sample: (date: Date, value: Double)) -> CGPoint {
                CGPoint(x: x(for: sample.date), y: y(for: sample.value))
            }

            // Faint dotted horizontal gridlines with their values along the left edge
            let gridColor = UIColor.tertiaryLabel.resolvedColor(with: traitCollection)
            let gridLabelAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
                .foregroundColor: gridColor,
            ]
            for value in gridValues where value >= valueMin && value <= valueMax {
                let lineY = y(for: value)
                let linePath = UIBezierPath()
                linePath.move(to: CGPoint(x: drawRect.minX, y: lineY))
                linePath.addLine(to: CGPoint(x: drawRect.maxX, y: lineY))
                linePath.lineWidth = 0.5
                linePath.setLineDash([2, 3], count: 2, phase: 0)
                gridColor.withAlphaComponent(0.6).setStroke()
                linePath.stroke()

                guard let text = axisValueFormatter.string(from: NSNumber(value: value)) else { continue }
                let label = text as NSString
                let size = label.size(withAttributes: gridLabelAttributes)
                let labelY = min(max(lineY - size.height / 2, bounds.minY), bounds.maxY - size.height)
                label.draw(at: CGPoint(x: drawRect.minX - size.width - 4, y: labelY), withAttributes: gridLabelAttributes)
            }

            // Target range band
            if let targetRange = targetRange {
                let bandRect = CGRect(x: drawRect.minX,
                                      y: y(for: targetRange.upperBound),
                                      width: drawRect.width,
                                      height: y(for: targetRange.lowerBound) - y(for: targetRange.upperBound))
                let bandPath = UIBezierPath(roundedRect: bandRect, cornerRadius: 3)
                UIColor.freshColor.withAlphaComponent(0.15).resolvedColor(with: traitCollection).setFill()
                bandPath.fill()

                let caption = NSLocalizedString("Target Range", comment: "Caption on the glucose chart target range band") as NSString
                let captionAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 8, weight: .medium),
                    .foregroundColor: UIColor.freshColor.resolvedColor(with: traitCollection),
                ]
                let captionSize = caption.size(withAttributes: captionAttributes)
                caption.draw(at: CGPoint(x: bandRect.maxX - captionSize.width - 4, y: bandRect.maxY - captionSize.height - 2), withAttributes: captionAttributes)

                // Range values in the right-hand gutter, aligned with the band edges
                let rangeValueAttributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: UIColor.freshColor.resolvedColor(with: traitCollection),
                ]
                for bound in [targetRange.upperBound, targetRange.lowerBound] {
                    guard let text = axisValueFormatter.string(from: NSNumber(value: bound)) else {
                        continue
                    }
                    let label = text as NSString
                    let size = label.size(withAttributes: rangeValueAttributes)
                    let labelY = min(max(y(for: bound) - size.height / 2, bounds.minY), bounds.maxY - size.height)
                    label.draw(at: CGPoint(x: bounds.maxX - size.width - 2, y: labelY), withAttributes: rangeValueAttributes)
                }
            }

            func path(for samples: [(date: Date, value: Double)]) -> UIBezierPath {
                let path = UIBezierPath()
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                for (index, sample) in samples.enumerated() {
                    if index == 0 {
                        path.move(to: point(for: sample))
                    } else {
                        path.addLine(to: point(for: sample))
                    }
                }
                return path
            }

            // History line and endpoint dot, in the palette's info accent
            let lineColor = (UIColor(named: "infoAccent") ?? .systemBlue).resolvedColor(with: traitCollection)

            // Soft gradient shading under the history line, fading downward. The fill's
            // floor is the target band's top edge, so shading only appears where the
            // line rises above the green section.
            if historical.count > 1, let context = UIGraphicsGetCurrentContext() {
                let shadeFloor = targetRange.map { y(for: $0.upperBound) } ?? drawRect.maxY
                let areaPath = path(for: historical)
                areaPath.addLine(to: CGPoint(x: point(for: historical[historical.count - 1]).x, y: shadeFloor))
                areaPath.addLine(to: CGPoint(x: point(for: historical[0]).x, y: shadeFloor))
                areaPath.close()

                context.saveGState()
                // Constrain to above the floor so stretches where the line dips into
                // the band contribute no fill
                context.clip(to: CGRect(x: drawRect.minX, y: drawRect.minY, width: drawRect.width, height: max(0, shadeFloor - drawRect.minY)))
                areaPath.addClip()
                let shadeTop = historical.map { y(for: $0.value) }.min() ?? drawRect.minY
                let shadeColors = [lineColor.withAlphaComponent(0.22).cgColor,
                                   lineColor.withAlphaComponent(0.0).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shadeColors, locations: [0, 1]) {
                    context.drawLinearGradient(gradient,
                                               start: CGPoint(x: 0, y: shadeTop),
                                               end: CGPoint(x: 0, y: shadeFloor),
                                               options: [])
                }
                context.restoreGState()
            }

            if historical.count > 1 {
                let historyPath = path(for: historical)
                historyPath.lineWidth = 2
                lineColor.setStroke()
                historyPath.stroke()
            }
            if let last = historical.last {
                let dotRect = CGRect(x: point(for: last).x - 3, y: point(for: last).y - 3, width: 6, height: 6)
                lineColor.setFill()
                UIBezierPath(ovalIn: dotRect).fill()
            }

            // Dashed prediction tail, connected to the last real reading
            var predictionSamples = predicted
            if let lastHistorical = historical.last {
                predictionSamples.insert(lastHistorical, at: 0)
            }
            if predictionSamples.count > 1 {
                let predictionPath = path(for: predictionSamples)
                predictionPath.lineWidth = 1.5
                predictionPath.setLineDash([3, 3], count: 2, phase: 0)
                lineColor.withAlphaComponent(0.6).setStroke()
                predictionPath.stroke()
            }

            // Hourly time labels along the bottom
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 9),
                .foregroundColor: UIColor.tertiaryLabel.resolvedColor(with: traitCollection),
            ]
            var tick = Calendar.current.nextDate(after: minDate, matching: DateComponents(minute: 0), matchingPolicy: .strict, direction: .forward) ?? minDate
            while tick <= maxDate {
                let text = axisTimeFormatter.string(from: tick) as NSString
                let size = text.size(withAttributes: labelAttributes)
                let centeredX = min(max(x(for: tick) - size.width / 2, bounds.minX), bounds.maxX - size.width)
                text.draw(at: CGPoint(x: centeredX, y: bounds.maxY - size.height - 1), withAttributes: labelAttributes)
                tick = tick.addingTimeInterval(.hours(1))
            }
        }
    }

    private class GlucoseChartTableViewCell: UITableViewCell {
        let titleLabel: UILabel = {
            let label = UILabel()
            label.font = .systemFont(ofSize: 13, weight: .semibold)
            label.textColor = .label
            return label
        }()

        let unitLabel: UILabel = {
            let label = UILabel()
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabel
            return label
        }()

        let chartView = SimpleGlucoseChartView()

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

            selectionStyle = .none
            backgroundColor = .clear

            let cardView = StatusTableViewController.makeCardView(cornerRadius: 16)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            unitLabel.translatesAutoresizingMaskIntoConstraints = false
            chartView.translatesAutoresizingMaskIntoConstraints = false
            cardView.addSubview(titleLabel)
            cardView.addSubview(unitLabel)
            cardView.addSubview(chartView)
            contentView.addSubview(cardView)

            let bottomConstraint = cardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
            bottomConstraint.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                titleLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
                titleLabel.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 12),
                unitLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
                unitLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),

                chartView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 14),
                chartView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -14),
                chartView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
                chartView.heightAnchor.constraint(equalToConstant: 150),
                chartView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -10),

                cardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                cardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                cardView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
                bottomConstraint,
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
    }

    private class StatsTableViewCell: UITableViewCell {
        let iobValueLabel = UILabel()
        let cobValueLabel = UILabel()
        let basalValueLabel = UILabel()
        let iobCaptionLabel = UILabel()
        let cobCaptionLabel = UILabel()
        let basalCaptionLabel = UILabel()

        // Each card is a tap target for its detail screen
        var onActiveInsulinTapped: (() -> Void)?
        var onActiveCarbsTapped: (() -> Void)?
        var onBasalTapped: (() -> Void)?

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            super.init(style: style, reuseIdentifier: reuseIdentifier)

            selectionStyle = .none
            backgroundColor = .clear

            // Three separate small cards, one per metric, each with an optional caption
            // line (e.g. the last bolus under Active Insulin)
            let cards = [
                (NSLocalizedString("Active Insulin", comment: "The title of the active insulin stats column"), iobValueLabel, iobCaptionLabel),
                (NSLocalizedString("Active Carbs", comment: "The title of the active carbs stats column"), cobValueLabel, cobCaptionLabel),
                (NSLocalizedString("Basal", comment: "The title of the basal stats column"), basalValueLabel, basalCaptionLabel),
            ].map { (title, valueLabel, captionLabel) -> UIView in
                let titleLabel = UILabel()
                titleLabel.font = .systemFont(ofSize: 12)
                titleLabel.textColor = .secondaryLabel
                titleLabel.text = title
                titleLabel.adjustsFontSizeToFitWidth = true

                valueLabel.font = .monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
                valueLabel.textColor = .label

                captionLabel.font = .systemFont(ofSize: 10)
                captionLabel.textColor = .secondaryLabel
                captionLabel.adjustsFontSizeToFitWidth = true
                captionLabel.minimumScaleFactor = 0.7
                captionLabel.text = " "

                let column = UIStackView(arrangedSubviews: [titleLabel, valueLabel, captionLabel])
                column.axis = .vertical
                column.alignment = .center
                column.spacing = 3
                column.translatesAutoresizingMaskIntoConstraints = false

                let card = StatusTableViewController.makeCardView(cornerRadius: 14)
                card.addSubview(column)
                NSLayoutConstraint.activate([
                    column.centerXAnchor.constraint(equalTo: card.centerXAnchor),
                    column.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 6),
                    column.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
                    column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -10),
                ])
                return card
            }

            let tapActions: [Selector] = [#selector(activeInsulinTapped), #selector(activeCarbsTapped), #selector(basalTapped)]
            for (card, action) in zip(cards, tapActions) {
                card.isUserInteractionEnabled = true
                card.addGestureRecognizer(UITapGestureRecognizer(target: self, action: action))
            }

            let stack = UIStackView(arrangedSubviews: cards)
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(stack)

            let bottomConstraint = stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4)
            bottomConstraint.priority = UILayoutPriority(999)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
                stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
                bottomConstraint,
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func activeInsulinTapped() {
            onActiveInsulinTapped?()
        }

        @objc private func activeCarbsTapped() {
            onActiveCarbsTapped?()
        }

        @objc private func basalTapped() {
            onBasalTapped?()
        }
    }

    /// The prominent filled style shared by the bottom action row and the MORE sheet
    private static func makeActionButton(title: String, image: UIImage?, color: UIColor, fontSize: CGFloat = 15, imagePlacement: NSDirectionalRectEdge = .top) -> UIButton {
        // Flat filled style everywhere — no Liquid Glass: its gradient sheen and
        // springy press animation read as lag and gradient on the buttons
        var config: UIButton.Configuration = .filled()
        config.cornerStyle = .large
        config.baseForegroundColor = .white
        config.baseBackgroundColor = color
        config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 4, bottom: 8, trailing: 4)

        if imagePlacement == .top {
            // UIButton's own image-above-title layout pixel-floors the image's x origin,
            // leaving the icon a hair left of center at fractional button widths. Bypass
            // it: content is our own stack pinned to the button's exact center.
            let button = UIButton(configuration: config)
            button.tintColor = color
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true

            let iconView = UIImageView(image: image?.withRenderingMode(.alwaysTemplate))
            iconView.tintColor = .white
            iconView.contentMode = .center
            if image?.isSymbolImage == false {
                // Asset-catalog icons (bolus, carbs) render at their native PDF size,
                // which is much larger than the SF Symbols beside them; scale them down
                // to match so the labels sit at the same height on every button
                iconView.contentMode = .scaleAspectFit
                iconView.heightAnchor.constraint(equalToConstant: 22).isActive = true
            }

            let label = UILabel()
            label.text = title
            label.font = UIFont.systemFont(ofSize: fontSize, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center

            let content = UIStackView(arrangedSubviews: [iconView, label])
            content.axis = .vertical
            content.alignment = .center
            content.spacing = 5
            content.isUserInteractionEnabled = false
            content.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                content.widthAnchor.constraint(lessThanOrEqualTo: button.widthAnchor, constant: -16),
            ])

            // Custom subviews don't follow the configuration's disabled dimming
            button.configurationUpdateHandler = { button in
                content.alpha = button.isEnabled ? 1.0 : 0.4
            }
            return button
        }

        // With an attributed title, the button derives its title alignment from the string's
        // paragraph style (default: leading), overriding titleAlignment — center it explicitly
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        config.attributedTitle = AttributedString(NSAttributedString(string: title, attributes: [
            .font: UIFont.systemFont(ofSize: fontSize, weight: .semibold),
            .paragraphStyle: paragraphStyle,
        ]))
        config.image = image?.withRenderingMode(.alwaysTemplate)
        config.imagePlacement = imagePlacement
        config.imagePadding = 8
        config.titleAlignment = .center
        let button = UIButton(configuration: config)
        button.tintColor = color
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        return button
    }

    /// Restyles an action button between its normal filled look and a pressed-in
    /// "active" look: a border in the button's color around a lighter fill, with
    /// the content in the color
    private static func setActionButton(_ button: UIButton, color: UIColor, active: Bool) {
        guard var config = button.configuration else { return }
        if active {
            config.baseBackgroundColor = blend(color, with: .systemBackground, fraction: 0.75)
            config.baseForegroundColor = color
            config.background.strokeColor = color
            config.background.strokeWidth = 2.5
        } else {
            config.baseBackgroundColor = color
            config.baseForegroundColor = .white
            config.background.strokeColor = nil
            config.background.strokeWidth = 0
        }
        button.configuration = config
        button.tintColor = color
    }

    private class PrimaryActionsTableViewCell: UITableViewCell {
        var onBolus: (() -> Void)?
        var onCarbs: (() -> Void)?
        var onMore: (() -> Void)?
        var onSettings: (() -> Void)?

        let bolusButton: UIButton
        let carbsButton: UIButton
        let moreButton: UIButton
        let settingsButton: UIButton

        override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
            // Distinct palette colors: slate for the primary action, success green for
            // carbs, info blue for more, lighter slate for settings
            bolusButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Bolus", comment: "The label of the bolus action button"),
                                                                     image: UIImage(named: "bolus"),
                                                                     color: UIColor(named: "primaryButton1") ?? .systemTeal)
            carbsButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Carbs", comment: "The label of the carb entry action button"),
                                                                     image: UIImage(named: "carbs"),
                                                                     color: .freshColor)
            moreButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("More", comment: "The label of the more actions button"),
                                                                    image: UIImage(systemName: "ellipsis.circle"),
                                                                    color: UIColor(named: "infoAccent") ?? .systemBlue)
            settingsButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Settings", comment: "The label of the settings action button"),
                                                                        image: UIImage(systemName: "gearshape"),
                                                                        color: UIColor(named: "primaryButton3") ?? .systemGray)

            super.init(style: style, reuseIdentifier: reuseIdentifier)

            selectionStyle = .none
            backgroundColor = .clear

            bolusButton.addTarget(self, action: #selector(bolusTapped), for: .touchUpInside)
            carbsButton.addTarget(self, action: #selector(carbsTapped), for: .touchUpInside)
            moreButton.addTarget(self, action: #selector(moreTapped), for: .touchUpInside)
            settingsButton.addTarget(self, action: #selector(settingsTapped), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [bolusButton, carbsButton, moreButton, settingsButton])
            stack.axis = .horizontal
            stack.distribution = .fillEqually
            stack.spacing = 10
            stack.translatesAutoresizingMaskIntoConstraints = false

            contentView.addSubview(stack)
            let bottomConstraint = stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
            bottomConstraint.priority = UILayoutPriority(999)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
                bottomConstraint,
            ])
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func bolusTapped() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onBolus?()
        }
        @objc private func carbsTapped() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onCarbs?()
        }
        @objc private func moreTapped() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onMore?()
        }
        @objc private func settingsTapped() {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onSettings?()
        }
    }

    /// The sheet behind the MORE button: full-width pre-meal, suspend, and preset
    /// buttons in the same prominent style as the bottom action row
    private final class MoreActionsViewController: UIViewController {
        var onPreMeal: (() -> Void)?
        var onSuspend: (() -> Void)?
        var onPreset: (() -> Void)?

        static let preMealColor: UIColor = .freshColor
        static let suspendColor: UIColor = UIColor(named: "primaryButton2") ?? .systemGray
        static let presetColor = UIColor(named: "infoAccent") ?? .systemBlue

        let preMealButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Pre-Meal", comment: "The label of the pre-meal action button"),
                                                                       image: UIImage.preMealImage(selected: false),
                                                                       color: preMealColor,
                                                                       fontSize: 17,
                                                                       imagePlacement: .leading)
        let suspendButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Suspend", comment: "The label of the suspend insulin delivery action button"),
                                                                       image: UIImage(systemName: "pause.circle"),
                                                                       color: suspendColor,
                                                                       fontSize: 17,
                                                                       imagePlacement: .leading)
        let presetButton = StatusTableViewController.makeActionButton(title: NSLocalizedString("Preset", comment: "The label of the preset action button"),
                                                                      image: UIImage.workoutImage(selected: false),
                                                                      color: presetColor,
                                                                      fontSize: 17,
                                                                      imagePlacement: .leading)

        override func viewDidLoad() {
            super.viewDidLoad()

            view.backgroundColor = .systemBackground

            preMealButton.addTarget(self, action: #selector(preMealTapped), for: .touchUpInside)
            suspendButton.addTarget(self, action: #selector(suspendTapped), for: .touchUpInside)
            presetButton.addTarget(self, action: #selector(presetTapped), for: .touchUpInside)

            let stack = UIStackView(arrangedSubviews: [preMealButton, suspendButton, presetButton])
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
                stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 28),
            ])
        }

        func setPreMeal(selected: Bool, enabled: Bool) {
            StatusTableViewController.setActionButton(preMealButton, color: Self.preMealColor, active: selected)
            preMealButton.isEnabled = enabled
            if selected {
                preMealButton.accessibilityTraits.insert(.selected)
                preMealButton.accessibilityHint = NSLocalizedString("Disables", comment: "The action hint of the workout mode toggle button when enabled")
            } else {
                preMealButton.accessibilityTraits.remove(.selected)
                preMealButton.accessibilityHint = NSLocalizedString("Enables", comment: "The action hint of the workout mode toggle button when disabled")
            }
        }

        func setPreset(active: Bool, enabled: Bool) {
            StatusTableViewController.setActionButton(presetButton, color: Self.presetColor, active: active)
            presetButton.isEnabled = enabled
        }

        @objc private func preMealTapped() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPreMeal?()
        }
        @objc private func suspendTapped() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSuspend?()
        }
        @objc private func presetTapped() {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onPreset?()
        }
    }

    private class AlertPermissionsDisabledWarningCell: UITableViewCell {
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let titleImageAttachment = NSTextAttachment()
            titleImageAttachment.image = UIImage(systemName: "exclamationmark.triangle.fill")?.withTintColor(.white)
            let title = NSMutableAttributedString(string: NSLocalizedString(" Safety Notifications are OFF", comment: "Warning text for when Notifications or Critical Alerts Permissions is disabled"))
            let titleWithImage = NSMutableAttributedString(attachment: titleImageAttachment)
            titleWithImage.append(title)
            contentConfig.attributedText = titleWithImage
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .bold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = NSLocalizedString("Fix now by turning Notifications, Critical Alerts and Time Sensitive Notifications ON.", comment: "Secondary text for alerts disabled warning, which appears on the main status screen.")
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.backgroundColor = .critical
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 5, trailing: 10)
            backgroundConfiguration?.cornerRadius = 10

            let disclosureIndicator = UIImage(systemName: "chevron.right")?.withTintColor(.white)
            let imageView = UIImageView(image: disclosureIndicator)
            imageView.tintColor = .white
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }

    private class MuteAlertsWarningCell: UITableViewCell {
        var formattedAlertMuteEndTime: String = NSLocalizedString("Unknown", comment: "label for when the alert mute end time is unknown")

        fileprivate class GradientView: UIView {
            override static var layerClass: AnyClass { CAGradientLayer.self }
        }
        
        override func updateConfiguration(using state: UICellConfigurationState) {
            super.updateConfiguration(using: state)

            let adjustViewForNarrowDisplay = bounds.width < 350

            var contentConfig = defaultContentConfiguration().updated(for: state)
            let title = NSMutableAttributedString(string: NSLocalizedString("All Alerts Muted", comment: "Warning text for when alerts are muted"))
            let image = UIImage(systemName: "speaker.slash.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .thin, scale: .large))
            contentConfig.image = image
            contentConfig.imageProperties.tintColor = .white
            contentConfig.attributedText = title
            contentConfig.textProperties.color = .white
            contentConfig.textProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 16 : 18, weight: .semibold)
            contentConfig.textProperties.adjustsFontSizeToFitWidth = true
            contentConfig.secondaryText = String(format: NSLocalizedString("Until %1$@", comment: "indication of when alerts will be unmuted (1: time when alerts unmute)"), formattedAlertMuteEndTime)
            contentConfig.secondaryTextProperties.color = .white
            contentConfig.secondaryTextProperties.font = .systemFont(ofSize: adjustViewForNarrowDisplay ? 13 : 15)
            contentConfiguration = contentConfig

            let backgroundGradient = GradientView()
            (backgroundGradient.layer as? CAGradientLayer)?.colors = [UIColor.warning.cgColor, UIColor.warning.withAlphaComponent(0.9).cgColor]
            
            var backgroundConfig = backgroundConfiguration?.updated(for: state)
            backgroundConfig?.customView = backgroundGradient
            backgroundConfiguration = backgroundConfig
            backgroundConfiguration?.backgroundInsets = NSDirectionalEdgeInsets(top: 0, leading: 5, bottom: 5, trailing: 5)
            backgroundConfiguration?.cornerRadius = 10

            let unmuteIndicator = UIImage(systemName: "stop.circle")?.withTintColor(.white)
            let imageView = UIImageView(image: unmuteIndicator)
            imageView.tintColor = .white
            imageView.frame.size = CGSize(width: 30, height: 30)
            accessoryView = imageView

            contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 0, bottom: 13, trailing: 0)
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                let cell = tableView.dequeueReusableCell(withIdentifier: AlertPermissionsDisabledWarningCell.className, for: indexPath) as! AlertPermissionsDisabledWarningCell
                return cell
            } else {
                let cell = tableView.dequeueReusableCell(withIdentifier: MuteAlertsWarningCell.className, for: indexPath) as! MuteAlertsWarningCell
                cell.formattedAlertMuteEndTime = alertMuter.formattedEndTime
                cell.selectionStyle = .none
                return cell
            }
        case .hero:
            let cell = tableView.dequeueReusableCell(withIdentifier: HeroStatusTableViewCell.className, for: indexPath) as! HeroStatusTableViewCell
            heroStatusView = cell.heroView

            return cell
        case .chart:
            let cell = tableView.dequeueReusableCell(withIdentifier: GlucoseChartTableViewCell.className, for: indexPath) as! GlucoseChartTableViewCell
            configureChartCell(cell)

            return cell
        case .stats:
            let cell = tableView.dequeueReusableCell(withIdentifier: StatsTableViewCell.className, for: indexPath) as! StatsTableViewCell
            configureStatsCell(cell)
            cell.onActiveInsulinTapped = { [weak self] in
                self?.performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: nil)
            }
            cell.onActiveCarbsTapped = { [weak self] in
                self?.performSegue(withIdentifier: CarbAbsorptionViewController.className, sender: nil)
            }
            cell.onBasalTapped = { [weak self] in
                guard let self = self else { return }
                if self.automaticDosingStatus.automaticDosingEnabled || !FeatureFlags.simpleBolusCalculatorEnabled {
                    self.performSegue(withIdentifier: PredictionTableViewController.className, sender: nil)
                }
            }

            return cell
        case .hud:
            let cell = tableView.dequeueReusableCell(withIdentifier: HUDViewTableViewCell.className, for: indexPath) as! HUDViewTableViewCell
            cell.backgroundColor = .clear
            cell.hudView.backgroundColor = .clear
            // One shared card behind sensor, loop ring, and pump, mirroring the
            // bottom action bar; the pills drop their individual backgrounds
            cell.hudView.cgmStatusHUD.showsBackground = false
            cell.hudView.pumpStatusHUD.showsBackground = false
            applyCardBackground(to: cell, cornerRadius: 20)
            hudView = cell.hudView

            return cell
        case .status:

            func getTitleSubtitleCell() -> TitleSubtitleTableViewCell {
                let cell = tableView.dequeueReusableCell(withIdentifier: TitleSubtitleTableViewCell.className, for: indexPath) as! TitleSubtitleTableViewCell
                cell.selectionStyle = .none
                cell.backgroundColor = .clear
                cell.titleLabel.text = nil
                cell.subtitleLabel.text = nil
                cell.accessoryView = nil
                applyCardBackground(to: cell)
                return cell
            }

            switch statusRowMode(forRow: indexPath.row) {
                case .hidden:
                    // The permanent slot's idle state: fully invisible placeholder
                    let cell = getTitleSubtitleCell()
                    cell.backgroundConfiguration = UIBackgroundConfiguration.clear()
                    return cell
                case .scheduleOverrideEnabled(let override):
                    let cell = getTitleSubtitleCell()
                    switch override.context {
                    case .preMeal:
                        let symbolAttachment = NSTextAttachment()
                        symbolAttachment.image = UIImage(named: "Pre-Meal-symbol")?.withTintColor(.carbTintColor)

                        let attributedString = NSMutableAttributedString(attachment: symbolAttachment)
                        attributedString.append(NSAttributedString(string: NSLocalizedString(" Pre-meal Preset", comment: "Status row title for premeal override enabled (leading space is to separate from symbol)")))
                        cell.titleLabel.attributedText = attributedString
                    case .legacyWorkout:
                        let symbolAttachment = NSTextAttachment()
                        symbolAttachment.image = UIImage(named: "workout-symbol")?.withTintColor(.glucoseTintColor)

                        let attributedString = NSMutableAttributedString(attachment: symbolAttachment)
                        attributedString.append(NSAttributedString(string: NSLocalizedString(" Workout Preset", comment: "Status row title for workout override enabled (leading space is to separate from symbol)")))
                        cell.titleLabel.attributedText = attributedString
                    case .preset(let preset):
                        cell.titleLabel.text = String(format: NSLocalizedString("%@ %@", comment: "The format for an active custom preset. (1: preset symbol)(2: preset name)"), preset.symbol, preset.name)
                    case .custom:
                        cell.titleLabel.text = NSLocalizedString("Custom Preset", comment: "The title of the cell indicating a generic custom preset is enabled")
                    }

                    if override.isActive() {
                        switch override.duration {
                        case .finite:
                            let endTimeText = DateFormatter.localizedString(from: override.activeInterval.end, dateStyle: .none, timeStyle: .short)
                            cell.subtitleLabel.text = String(format: NSLocalizedString("until %@", comment: "The format for the description of a custom preset end date"), endTimeText)
                        case .indefinite:
                            cell.subtitleLabel.text = nil
                        }
                    } else {
                        let startTimeText = DateFormatter.localizedString(from: override.startDate, dateStyle: .none, timeStyle: .short)
                        cell.subtitleLabel.text = String(format: NSLocalizedString("starting at %@", comment: "The format for the description of a custom preset start date"), startTimeText)
                    }

                    return cell
                case .enactingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Starting Bolus", comment: "The title of the cell indicating a bolus is being sent")

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .bolusing(let dose):
                    let progressCell = tableView.dequeueReusableCell(withIdentifier: BolusProgressTableViewCell.className, for: indexPath) as! BolusProgressTableViewCell
                    progressCell.selectionStyle = .none
                    progressCell.totalUnits = dose.programmedUnits
                    progressCell.tintColor = .insulinTintColor
                    progressCell.deliveredUnits = bolusProgressReporter?.progress.deliveredUnits
                    progressCell.backgroundColor = .clear
                    applyCardBackground(to: progressCell)
                    // Inset the nib content so it clears the rounded card edges
                    progressCell.contentView.preservesSuperviewLayoutMargins = false
                    progressCell.contentView.layoutMargins = UIEdgeInsets(top: 8, left: 44, bottom: 8, right: 40)
                    return progressCell
                case .cancelingBolus:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Canceling Bolus", comment: "The title of the cell indicating a bolus is being canceled")

                    let indicatorView = UIActivityIndicatorView(style: .default)
                    indicatorView.startAnimating()
                    cell.accessoryView = indicatorView
                    return cell
                case .pumpSuspended(let resuming):
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("Insulin Suspended", comment: "The title of the cell indicating the pump is suspended")

                    if resuming {
                        let indicatorView = UIActivityIndicatorView(style: .default)
                        indicatorView.startAnimating()
                        cell.accessoryView = indicatorView
                    } else {
                        cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume insulin delivery")
                    }
                    cell.selectionStyle = .default
                    return cell
                case .onboardingSuspended:
                    let cell = tableView.dequeueReusableCell(withIdentifier: IconTitleSubtitleTableViewCell.className, for: indexPath) as! IconTitleSubtitleTableViewCell
                    cell.selectionStyle = .default
                    cell.backgroundColor = .clear
                    applyCardBackground(to: cell)
                    cell.iconImageView.image = UIImage(systemName: "exclamationmark.circle.fill")
                    cell.iconImageView.tintColor = .warning
                    cell.iconImageView.contentMode = .scaleAspectFit
                    cell.iconImageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 28)
                    cell.titleLabel.text = NSLocalizedString("Setup Incomplete", comment: "The title of the cell indicating that onboarding is suspended")
                    cell.subtitleLabel.text = NSLocalizedString("Tap to Resume", comment: "The subtitle of the cell displaying an action to resume onboarding")
                    cell.accessoryView = nil
                    return cell
                case .recommendManualGlucoseEntry:
                    let cell = getTitleSubtitleCell()
                    cell.titleLabel.text = NSLocalizedString("No Recent Glucose", comment: "The title of the cell indicating that there is no recent glucose")
                    cell.subtitleLabel.text = NSLocalizedString("Tap to Add", comment: "The subtitle of the cell displaying an action to add a manually measurement glucose value")
                    cell.selectionStyle = .default
                    let imageView = UIImageView(image: UIImage(named: "drop.circle"))
                    imageView.tintColor = .glucoseTintColor
                    cell.accessoryView = imageView
                    return cell
            }
        case .actions:
            switch ActionsRow(rawValue: indexPath.row)! {
            case .primary:
                let cell = tableView.dequeueReusableCell(withIdentifier: PrimaryActionsTableViewCell.className, for: indexPath) as! PrimaryActionsTableViewCell
                configurePrimaryActionsCell(cell)

                return cell
            }
        }
    }

    // MARK: - Bottom-aligned actions

    /// Height of an invisible footer placed before the actions section so the action buttons
    /// sit along the bottom of the screen when the content is shorter than the table.
    private var actionsBottomSpacerHeight: CGFloat = 0

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        updateActionsBottomSpacer()
    }

    private func updateActionsBottomSpacer() {
        let contentHeight = tableView.contentSize.height - actionsBottomSpacerHeight
        let availableHeight = tableView.bounds.height - tableView.adjustedContentInset.top - tableView.adjustedContentInset.bottom
        let newHeight = max(0, availableHeight - contentHeight)

        if abs(newHeight - actionsBottomSpacerHeight) > 1 {
            actionsBottomSpacerHeight = newHeight
            UIView.performWithoutAnimation {
                tableView.beginUpdates()
                tableView.endUpdates()
            }
        }
    }

    override func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        guard Section(rawValue: section) == .status else {
            return 0
        }
        return actionsBottomSpacerHeight
    }

    override func tableView(_ tableView: UITableView, viewForFooterInSection section: Int) -> UIView? {
        guard Section(rawValue: section) == .status else {
            return nil
        }
        let spacer = UIView()
        spacer.backgroundColor = .clear
        return spacer
    }

    // MARK: - UITableViewDelegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Section(rawValue: indexPath.section)! {
        case .alertWarning:
            if alertPermissionsChecker.showWarning {
                tableView.deselectRow(at: indexPath, animated: true)
                AlertPermissionsChecker.gotoSettings()
            } else {
                tableView.deselectRow(at: indexPath, animated: true)
                presentUnmuteAlertConfirmation()
            }
        case .chart:
            // The glucose history chart is display-only; the prediction screen is
            // reached from the Basal stat card instead
            tableView.deselectRow(at: indexPath, animated: true)
        case .hero, .stats, .hud, .actions:
            break
        case .status:
                tableView.deselectRow(at: indexPath, animated: true)

                switch statusRowMode(forRow: indexPath.row) {
                case .pumpSuspended(let resuming) where !resuming:
                    updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: true) , newSize: nil, animated: true)
                    deviceManager.pumpManager?.resumeDelivery() { (error) in
                        DispatchQueue.main.async {
                            if let error = error {
                                let alert = UIAlertController(with: error, title: NSLocalizedString("Failed to Resume Insulin Delivery", comment: "The alert title for a resume error"))
                                self.present(alert, animated: true, completion: nil)
                                if case .suspended = self.basalDeliveryState {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .pumpSuspended(resuming: false), newSize: nil, animated: true)
                                }
                            } else {
                                self.updateBannerAndHUDandStatusRows(statusRowMode: self.determineStatusRowMode(), newSize: nil, animated: true)
                                self.refreshContext.update(with: .insulin)
                                self.log.debug("[reloadData] after manually resuming suspend")
                                self.reloadData()
                            }
                        }
                    }
                case .scheduleOverrideEnabled(let override):
                    switch override.context {
                    case .preMeal, .legacyWorkout:
                        break
                    default:
                        let vc = AddEditOverrideTableViewController(glucoseUnit: deviceManager.displayGlucosePreference.unit)
                        vc.inputMode = .editOverride(override)
                        vc.delegate = self
                        show(vc, sender: tableView.cellForRow(at: indexPath))
                    }
                case .bolusing:
                    updateBannerAndHUDandStatusRows(statusRowMode: .cancelingBolus, newSize: nil, animated: true)
                    deviceManager.pumpManager?.cancelBolus() { (result) in
                        DispatchQueue.main.async {
                            switch result {
                            case .success:
                                // show user confirmation and actual delivery amount?
                                break
                            case .failure(let error):
                                self.presentErrorCancelingBolus(error)
                                if case .inProgress(let dose) = self.bolusState {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .bolusing(dose: dose), newSize: nil, animated: true)
                                } else {
                                    self.updateBannerAndHUDandStatusRows(statusRowMode: .hidden, newSize: nil, animated: true)
                                }
                            }
                        }
                    }
                case .onboardingSuspended:
                    onboardingManager.resume()
                case .recommendManualGlucoseEntry:
                    presentBolusEntryView(enableManualGlucoseEntry: true)
                default:
                    break
                }
        }
    }

    private func presentUnmuteAlertConfirmation() {
        let title = NSLocalizedString("Unmute Alerts?", comment: "The alert title for unmute alert confirmation")
        let body = NSLocalizedString("Tap Unmute to resume sound for your alerts and alarms.", comment: "The alert body for unmute alert confirmation")
        let action = UIAlertAction(
            title: NSLocalizedString("Unmute", comment: "The title of the action used to unmute alerts"),
            style: .default) { _ in
                self.alertMuter.unmuteAlerts()
            }
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        alert.addCancelAction { _ in }
        present(alert, animated: true, completion: nil)
    }

    private func presentErrorCancelingBolus(_ error: (Error)) {
        log.error("Error Canceling Bolus: %@", error.localizedDescription)
        let title = NSLocalizedString("Error Canceling Bolus", comment: "The alert title for an error while canceling a bolus")
        let body = NSLocalizedString("Unable to stop the bolus in progress. Move your iPhone closer to the pump and try again. Check your insulin delivery history for details, and monitor your glucose closely.", comment: "The alert body for an error while canceling a bolus")
        let action = UIAlertAction(
            title: NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert"), style: .default)
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(action)
        present(alert, animated: true, completion: nil)
    }

    // MARK: - Actions

    override func restoreUserActivityState(_ activity: NSUserActivity) {
        switch activity.activityType {
        case NSUserActivity.newCarbEntryActivityType:
            presentCarbEntryScreen(activity)
        default:
            break
        }
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        super.prepare(for: segue, sender: sender)

        var targetViewController = segue.destination

        if let navVC = targetViewController as? UINavigationController, let topViewController = navVC.topViewController {
            targetViewController = topViewController
        }

        switch targetViewController {
        case let vc as CarbAbsorptionViewController:
            vc.isOnboardingComplete = onboardingManager.isComplete
            vc.automaticDosingStatus = automaticDosingStatus
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
        case let vc as InsulinDeliveryTableViewController:
            vc.deviceManager = deviceManager
            vc.hidesBottomBarWhenPushed = true
            vc.enableEntryDeletion = FeatureFlags.entryDeletionEnabled
            vc.headerValueLabelColor = .insulinTintColor
        case let vc as OverrideSelectionViewController:
            if deviceManager.loopManager.settings.futureOverrideEnabled() {
                vc.scheduledOverride = deviceManager.loopManager.settings.scheduleOverride
            }
            vc.presets = deviceManager.loopManager.settings.overridePresets
            vc.glucoseUnit = deviceManager.displayGlucosePreference.unit
            vc.overrideHistory = deviceManager.loopManager.overrideHistory.getEvents()
            vc.delegate = self
        case let vc as PredictionTableViewController:
            vc.deviceManager = deviceManager
        default:
            break
        }
    }

    @IBAction func unwindFromEditing(_ segue: UIStoryboardSegue) {}

    @IBAction func unwindFromSettings(_ segue: UIStoryboardSegue) {}

    @IBAction func userTappedAddCarbs() {
        presentCarbEntryScreen(nil)
    }

    func presentCarbEntryScreen(_ activity: NSUserActivity?) {
        let navigationWrapper: UINavigationController
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            let viewModel = SimpleBolusViewModel(delegate: deviceManager, displayMealEntry: true)
            if let activity = activity {
                viewModel.restoreUserActivityState(activity)
            }
            let bolusEntryView = SimpleBolusView(viewModel: viewModel).environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: bolusEntryView, isModalInPresentation: false)
            navigationWrapper = UINavigationController(rootViewController: hostingController)
            // A titled item renders as the word "Cancel"; the system .cancel item draws as an X on iOS 26+
            hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Cancel", comment: "Button label for cancel"), style: .plain, target: navigationWrapper, action: #selector(dismissWithAnimation))
            present(navigationWrapper, animated: true)
        } else {
            let viewModel = CarbEntryViewModel(delegate: deviceManager)
            if let activity {
                viewModel.restoreUserActivityState(activity)
            }
            let carbEntryView = CarbEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
            let hostingController = DismissibleHostingController(rootView: carbEntryView, isModalInPresentation: false)
            present(hostingController, animated: true)
        }
        deviceManager.analyticsServicesManager.didDisplayCarbEntryScreen()
    }

    @IBAction func presentBolusScreen() {
        presentBolusEntryView()
    }
    
    @ViewBuilder
    func bolusEntryView(enableManualGlucoseEntry: Bool = false) -> some View {
        if FeatureFlags.simpleBolusCalculatorEnabled && !automaticDosingStatus.automaticDosingEnabled {
            SimpleBolusView(
                viewModel: SimpleBolusViewModel(
                    delegate: deviceManager,
                    displayMealEntry: false
                )
            )
            .environmentObject(deviceManager.displayGlucosePreference)
        } else {
            let viewModel: BolusEntryViewModel = {
                let viewModel = BolusEntryViewModel(
                    delegate: deviceManager,
                    screenWidth: UIScreen.main.bounds.width,
                    isManualGlucoseEntryEnabled: enableManualGlucoseEntry
                )
                
                Task { @MainActor in
                    await viewModel.generateRecommendationAndStartObserving()
                }
                
                viewModel.analyticsServicesManager = deviceManager.analyticsServicesManager
                
                return viewModel
            }()
            
            BolusEntryView(viewModel: viewModel)
                .environmentObject(deviceManager.displayGlucosePreference)
        }
    }

    func presentBolusEntryView(enableManualGlucoseEntry: Bool = false) {
        let hostingController = DismissibleHostingController(
            content: bolusEntryView(
                enableManualGlucoseEntry: enableManualGlucoseEntry
            )
        )
        
        let navigationWrapper = UINavigationController(rootViewController: hostingController)
        // A titled item renders as the word "Cancel"; the system .cancel item draws as an X on iOS 26+
        hostingController.navigationItem.leftBarButtonItem = UIBarButtonItem(title: NSLocalizedString("Cancel", comment: "Button label for cancel"), style: .plain, target: navigationWrapper, action: #selector(dismissWithAnimation))
        present(navigationWrapper, animated: true)
        deviceManager.analyticsServicesManager.didDisplayBolusScreen()
    }

    @IBAction func premealButtonTapped(_ sender: UIBarButtonItem) {
        togglePreMealMode(confirm: false)
    }
    
    func togglePreMealMode(confirm: Bool = true) {
        if preMealMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Pre-Meal Preset?", message: "This will remove any currently applied pre-meal preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride(matching: .preMeal)
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
            }
        } else {
            presentPreMealModeAlertController()
        }
    }
    
    func presentPreMealModeAlertController() {
        let vc = UIAlertController(premealDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.workoutMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enablePreMealOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enablePreMealOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    func presentCustomPresets(confirm: Bool = true) {
        if workoutMode == true {
            if confirm {
                let alert = UIAlertController(title: "Disable Preset?", message: "This will remove any currently applied preset.", preferredStyle: .alert)
                alert.addCancelAction()
                alert.addAction(UIAlertAction(title: "Disable", style: .destructive, handler: { [weak self] _ in
                    self?.deviceManager.loopManager.mutateSettings { settings in
                        settings.clearOverride()
                    }
                }))
                present(alert, animated: true)
            } else {
                deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride()
                }
            }
        } else {
            if FeatureFlags.sensitivityOverridesEnabled {
                performSegue(withIdentifier: OverrideSelectionViewController.className, sender: nil)
            } else {
                presentWorkoutModeAlertController()
            }
        }
    }
    
    func presentWorkoutModeAlertController() {
        let vc = UIAlertController(workoutDurationSelectionHandler: { duration in
            let startDate = Date()

            guard self.preMealMode != true else {
                // allow cell animation when switching between presets
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.clearOverride(matching: .preMeal)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    self.deviceManager.loopManager.mutateSettings { settings in
                        settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
                    }
                }
                return
            }

            self.deviceManager.loopManager.mutateSettings { settings in
                settings.enableLegacyWorkoutOverride(at: startDate, for: duration)
            }
        })

        present(vc, animated: true, completion: nil)
    }

    @IBAction func toggleWorkoutMode(_ sender: UIBarButtonItem) {
        presentCustomPresets(confirm: false)
    }
    
    @IBAction func onSettingsTapped(_ sender: UIBarButtonItem) {
        presentSettings()
    }

    private func presentSettings() {
        let deletePumpDataFunc: () -> PumpManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.pumpManager is TestingPumpManager) ? {
                [weak self] in self?.deviceManager.deleteTestingPumpData()
                } : nil
        }
        let deleteCGMDataFunc: () -> CGMManagerViewModel.DeleteTestingDataFunc? = { [weak self] in
            (self?.deviceManager.cgmManager is TestingCGMManager) ? {
                [weak self] in self?.deviceManager.deleteTestingCGMData()
                } : nil
        }
        let pumpViewModel = PumpManagerViewModel(
            image: { [weak self] in self?.deviceManager.pumpManager?.smallImage },
            name: { [weak self] in self?.deviceManager.pumpManager?.localizedTitle ?? "" },
            isSetUp: { [weak self] in self?.deviceManager.pumpManager?.isOnboarded == true },
            availableDevices: deviceManager.availablePumpManagers,
            deleteTestingDataFunc: deletePumpDataFunc,
            onTapped: { [weak self] in
                self?.onPumpTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addPumpManager(withIdentifier: $0.identifier)
        })

        let cgmViewModel = CGMManagerViewModel(
            image: {[weak self] in (self?.deviceManager.cgmManager as? DeviceManagerUI)?.smallImage },
            name: {[weak self] in self?.deviceManager.cgmManager?.localizedTitle ?? "" },
            isSetUp: {[weak self] in self?.deviceManager.cgmManager?.isOnboarded == true },
            availableDevices: deviceManager.availableCGMManagers,
            deleteTestingDataFunc: deleteCGMDataFunc,
            onTapped: { [weak self] in
                self?.onCGMTapped()
            },
            didTapAddDevice: { [weak self] in
                self?.addCGMManager(withIdentifier: $0.identifier)
        })
        let servicesViewModel = ServicesViewModel(showServices: FeatureFlags.includeServicesInSettingsEnabled,
                                                  availableServices: { [weak self] in self?.deviceManager.servicesManager.availableServices ?? [] },
                                                  activeServices: { [weak self] in self?.deviceManager.servicesManager.activeServices ?? [] },
                                                  delegate: self)
        let versionUpdateViewModel = VersionUpdateViewModel(supportManager: supportManager, guidanceColors: .default)
        let viewModel = SettingsViewModel(alertPermissionsChecker: alertPermissionsChecker,
                                          alertMuter: alertMuter,
                                          versionUpdateViewModel: versionUpdateViewModel,
                                          pumpManagerSettingsViewModel: pumpViewModel,
                                          cgmManagerSettingsViewModel: cgmViewModel,
                                          servicesViewModel: servicesViewModel,
                                          criticalEventLogExportViewModel: CriticalEventLogExportViewModel(exporterFactory: deviceManager.criticalEventLogExportManager),
                                          therapySettings: { [weak self] in self?.deviceManager.loopManager.therapySettings ?? TherapySettings() },
                                          sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                                          initialDosingEnabled: deviceManager.loopManager.settings.dosingEnabled,
                                          isClosedLoopAllowed: automaticDosingStatus.$isAutomaticDosingAllowed,
                                          automaticDosingStrategy: deviceManager.loopManager.settings.automaticDosingStrategy,
                                          availableSupports: supportManager.availableSupports,
                                          isOnboardingComplete: onboardingManager.isComplete,
                                          therapySettingsViewModelDelegate: deviceManager,
                                          delegate: self)
        let hostingController = DismissibleHostingController(
            rootView: SettingsView(viewModel: viewModel, localizedAppNameAndVersion: supportManager.localizedAppNameAndVersion)
                .environmentObject(deviceManager.displayGlucosePreference)
                .environment(\.appName, Bundle.main.bundleDisplayName),
            isModalInPresentation: false)
        present(hostingController, animated: true)
    }

    private func onPumpTapped() {
        guard var settingsViewController = deviceManager.pumpManager?.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures, allowedInsulinTypes: deviceManager.allowedInsulinTypes) else {
            // assert?
            return
        }
        settingsViewController.pumpManagerOnboardingDelegate = deviceManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }

    private func onCGMTapped() {
        guard let cgmManager = deviceManager.cgmManager as? CGMManagerUI else {
            // assert?
            return
        }

        var settings = cgmManager.settingsViewController(bluetoothProvider: deviceManager.bluetoothProvider, displayGlucosePreference: deviceManager.displayGlucosePreference, colorPalette: .default, allowDebugFeatures: FeatureFlags.allowDebugFeatures)
        settings.cgmManagerOnboardingDelegate = deviceManager
        settings.completionDelegate = self
        show(settings, sender: self)
    }

    private func automaticDosingStatusChanged(_ automaticDosingEnabled: Bool) {
        updatePresetModeAvailability(automaticDosingEnabled: automaticDosingEnabled)
        hudView?.loopCompletionHUD.loopIconClosed = automaticDosingEnabled
        hudView?.loopCompletionHUD.closedLoopDisallowedLocalizedDescription = deviceManager.closedLoopDisallowedLocalizedDescription
        heroStatusView?.loopCompletionHUD.loopIconClosed = automaticDosingEnabled
        heroStatusView?.loopCompletionHUD.closedLoopDisallowedLocalizedDescription = deviceManager.closedLoopDisallowedLocalizedDescription
    }

    // MARK: - HUDs

    private let gradientBackgroundView = GradientBackgroundView()

    private var heroStatusView: StatusHeroView? {
        didSet {
            guard let heroStatusView = heroStatusView, heroStatusView != oldValue else {
                return
            }

            heroStatusView.loopCompletionHUD.stateColors = .loopStatus
            heroStatusView.loopCompletionHUD.loopIconClosed = automaticDosingStatus.automaticDosingEnabled
            heroStatusView.loopCompletionHUD.closedLoopDisallowedLocalizedDescription = deviceManager.closedLoopDisallowedLocalizedDescription
            heroStatusView.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

            heroStatusView.headerTitle = NSLocalizedString("Glucose Now", comment: "The title of the status screen glucose hero card")
            heroStatusView.infoButtonTapped = { [weak self] in
                // Opens the insulin delivery history (all boluses and doses)
                self?.performSegue(withIdentifier: InsulinDeliveryTableViewController.className, sender: nil)
            }

            refreshContext.update(with: .status)
            log.debug("[reloadData] after heroStatusView loaded")
            reloadData()
        }
    }

    @IBOutlet var hudView: StatusBarHUDView? {
        didSet {
            guard let hudView = hudView, hudView != oldValue else {
                return
            }

            let statusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(showLoopCompletionMessage(_:)))
            hudView.loopCompletionHUD.addGestureRecognizer(statusTapGestureRecognizer)
            hudView.loopCompletionHUD.accessibilityHint = NSLocalizedString("Shows last loop error", comment: "Loop Completion HUD accessibility hint")

            let pumpStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(pumpStatusTapped(_:)))
            hudView.pumpStatusHUD.addGestureRecognizer(pumpStatusTapGestureRecognizer)

            let cgmStatusTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(cgmStatusTapped(_:)))
            hudView.cgmStatusHUD.addGestureRecognizer(cgmStatusTapGestureRecognizer)

            configurePumpManagerHUDViews()
            configureCGMManagerHUDViews()

            // when HUD view is initialized, update loop completion HUD (e.g., icon and last loop completed)
            // Equal halves for the sensor and pump sides, so their lifecycle bars and
            // text zones match in width
            hudView.cgmStatusHUD.widthAnchor.constraint(equalTo: hudView.pumpStatusHUD.widthAnchor).isActive = true

            hudView.loopCompletionHUD.stateColors = .loopStatus
            hudView.loopCompletionHUD.loopIconClosed = automaticDosingStatus.automaticDosingEnabled
            hudView.loopCompletionHUD.lastLoopCompleted = deviceManager.loopManager.lastLoopCompleted

            hudView.cgmStatusHUD.stateColors = .cgmStatus
            hudView.cgmStatusHUD.tintColor = .label
            hudView.pumpStatusHUD.stateColors = .pumpStatus
            hudView.pumpStatusHUD.tintColor = .pumpStatusNormal
            // The pod pill shows expiration instead of the basal dial; net basal
            // lives in the stats card
            hudView.pumpStatusHUD.showsBasalRate = false

            refreshContext.update(with: .status)
            log.debug("[reloadData] after hudView loaded")
            reloadData()
        }
    }

    private func configurePumpManagerHUDViews() {
        if let hudView = hudView {
            hudView.removePumpManagerProvidedView()
            if let pumpManagerHUDProvider = deviceManager.pumpManagerHUDProvider {
                if let view = pumpManagerHUDProvider.createHUDView() {
                    addPumpManagerViewToHUD(view)
                }
                pumpManagerHUDProvider.visible = active && onscreen
            }
            hudView.pumpStatusHUD.deviceCaption = pumpDeviceCaption
            hudView.pumpStatusHUD.presentStatusHighlight(deviceManager.pumpStatusHighlight)
            hudView.pumpStatusHUD.lifecycleProgress = deviceManager.pumpLifecycleProgress
            updatePodExpiration(on: hudView)
        }
    }

    private func configureCGMManagerHUDViews() {
        if let hudView = hudView {
            hudView.cgmStatusHUD.presentStatusHighlight(deviceManager.cgmStatusHighlight ?? SensorOKStatusHighlight())
            hudView.cgmStatusHUD.lifecycleProgress = deviceManager.cgmLifecycleProgress
        }
    }

    private func addPumpManagerViewToHUD(_ view: BaseHUDView) {
        if let hudView = hudView {
            view.stateColors = .pumpStatus
            hudView.addPumpManagerProvidedHUDView(view)
        }
    }

    @objc private func showLoopCompletionMessage(_: Any) {
        guard let loopCompletionMessage = hudView?.loopCompletionHUD.loopCompletionMessage else { return }
        presentLoopCompletionMessage(title: loopCompletionMessage.title, message: loopCompletionMessage.message)
    }

    private func presentLoopCompletionMessage(title: String, message: String) {
        let action = UIAlertAction(title: NSLocalizedString("Dismiss", comment: "The button label of the action used to dismiss an error alert"),
                                   style: .default)
        let alertController = UIAlertController(title: title,
                                                message: message,
                                                preferredStyle: .alert)
        alertController.addAction(action)
        present(alertController, animated: true)
    }

    @objc private func showLastError(_: Any) {
        let error: Error?
        // First, check whether we have a device error after the most recent completion date
        if let deviceError = deviceManager.lastError,
            deviceError.date > (hudView?.loopCompletionHUD.lastLoopCompleted ?? .distantPast)
        {
            error = deviceError.error
        } else if let lastLoopError = lastLoopError {
            error = lastLoopError
        } else {
            error = nil
        }
        if let error = error {
            let alertController = UIAlertController(with: error)
            let manualLoopAction = UIAlertAction(title: NSLocalizedString("Retry", comment: "The button text for attempting a manual loop"), style: .default, handler: { _ in
                self.deviceManager.refreshDeviceData()
            })
            alertController.addAction(manualLoopAction)
            present(alertController, animated: true)
        }
    }

    @objc private func pumpStatusTapped(_ sender: UIGestureRecognizer) {
        if let pumpStatusView = sender.view as? PumpStatusHUDView {
            executeHUDTapAction(deviceManager.didTapOnPumpStatus(pumpStatusView.pumpManagerProvidedHUD))
        }
    }

    @objc private func cgmStatusTapped( _ sender: UIGestureRecognizer) {
        executeHUDTapAction(deviceManager.didTapOnCGMStatus())
    }

    private func executeHUDTapAction(_ action: HUDTapAction?) {
        guard let action = action else {
            return
        }

        switch action {
        case .presentViewController(let vc):
            var completionNotifyingVC = vc
            completionNotifyingVC.completionDelegate = self
            present(completionNotifyingVC, animated: true, completion: nil)
        case .openAppURL(let url):
            UIApplication.shared.open(url)
        case .setupNewCGM:
            addNewCGMManager()
        case .setupNewPump:
            addNewPumpManager()
        default:
            return
        }
    }

    private func addNewPumpManager() {
        let availablePumpManagers = deviceManager.availablePumpManagers

        switch availablePumpManagers.count {
        case 1:
            if let availablePumpManager = availablePumpManagers.first {
                addPumpManager(withIdentifier: availablePumpManager.identifier)
            }
        default:
            let alert = UIAlertController(availablePumpManagers: availablePumpManagers) { [weak self] (identifier) in
                self?.addPumpManager(withIdentifier: identifier)
            }
            alert.addCancelAction { _ in }
            present(alert, animated: true, completion: nil)
        }
    }

    private func addNewCGMManager() {
        let availableCGMManagers = deviceManager.availableCGMManagers

        switch availableCGMManagers.count {
        case 1:
            if let availableCGMManager = availableCGMManagers.first {
                addCGMManager(withIdentifier: availableCGMManager.identifier)
            }
        default:
            let alert = UIAlertController(availableCGMManagers: availableCGMManagers) { [weak self] identifier in
                self?.addCGMManager(withIdentifier: identifier)
            }
            alert.addCancelAction { _ in }
            present(alert, animated: true, completion: nil)
        }
    }


    // MARK: - Debug Scenarios and Simulated Core Data

    var lastOrientation: UIDeviceOrientation?
    var rotateCount = 0
    let maxRotationsToTrigger = 6
    var rotateTimer: Timer?
    let rotateTimerTimeout = TimeInterval.seconds(2)
    private func maybeOpenDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }
        // Opens the debug menu if you rotate the phone 6 times (or back & forth 3 times), each rotation within 2 secs.
        if lastOrientation != UIDevice.current.orientation {
            if UIDevice.current.orientation == .portrait && rotateCount >= maxRotationsToTrigger-1 {
                presentDebugMenu()
                rotateCount = 0
                rotateTimer?.invalidate()
                rotateTimer = nil
            } else {
                rotateTimer?.invalidate()
                rotateTimer = Timer.scheduledTimer(withTimeInterval: rotateTimerTimeout, repeats: false) { [weak self] _ in
                    self?.rotateCount = 0
                    self?.rotateTimer?.invalidate()
                    self?.rotateTimer = nil
                }
                rotateCount += 1
            }
        }
        lastOrientation = UIDevice.current.orientation
    }

    private func presentDebugMenu() {
        guard FeatureFlags.allowDebugFeatures else {
            return
        }

        let actionSheet = UIAlertController(title: "Debug", message: nil, preferredStyle: .actionSheet)
        if FeatureFlags.scenariosEnabled {
            actionSheet.addAction(UIAlertAction(title: "Scenarios", style: .default) { _ in
                DispatchQueue.main.async {
                    self.presentScenarioSelector()
                }
            })
        }
        if FeatureFlags.simulatedCoreDataEnabled {
            actionSheet.addAction(UIAlertAction(title: "Simulated Core Data", style: .default) { _ in
                self.presentSimulatedCoreDataMenu()
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Remove Exports Directory", style: .default) { _ in
            if let error = self.deviceManager.removeExportsDirectory() {
                self.presentError(error)
            }
        })
        if FeatureFlags.mockTherapySettingsEnabled {
            actionSheet.addAction(UIAlertAction(title: "Mock Therapy Settings", style: .default) { _ in
                let therapySettings = TherapySettings.mockTherapySettings
                self.deviceManager.loopManager.mutateSettings { settings in
                    settings.glucoseTargetRangeSchedule = therapySettings.glucoseTargetRangeSchedule
                    settings.preMealTargetRange = therapySettings.correctionRangeOverrides?.preMeal
                    settings.legacyWorkoutTargetRange = therapySettings.correctionRangeOverrides?.workout
                    settings.suspendThreshold = therapySettings.suspendThreshold
                    settings.maximumBolus = therapySettings.maximumBolus
                    settings.maximumBasalRatePerHour = therapySettings.maximumBasalRatePerHour
                    settings.insulinSensitivitySchedule = therapySettings.insulinSensitivitySchedule
                    settings.carbRatioSchedule = therapySettings.carbRatioSchedule
                    settings.basalRateSchedule = therapySettings.basalRateSchedule
                    settings.defaultRapidActingModel = therapySettings.defaultRapidActingModel
                }
            })
        }
        actionSheet.addAction(UIAlertAction(title: "Crash the App", style: .destructive) { _ in
            fatalError("Test Crash")
        })
        actionSheet.addAction(UIAlertAction(title: "Delete CGM Manager", style: .destructive) { _ in
            self.deviceManager.cgmManager?.delete() { }
        })

        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentScenarioSelector() {
        guard FeatureFlags.scenariosEnabled else {
            fatalError("\(#function) should be invoked only when scenarios are enabled")
        }

        let vc = TestingScenariosTableViewController(scenariosManager: testingScenariosManager)
        present(UINavigationController(rootViewController: vc), animated: true)
    }

    private func addScenarioStepGestureRecognizers() {
        if FeatureFlags.scenariosEnabled {
            let leftSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioForward))
            leftSwipe.direction = .left
            let rightSwipe = UISwipeGestureRecognizer(target: self, action: #selector(stepActiveScenarioBackward))
            rightSwipe.direction = .right

            tableView.addGestureRecognizer(leftSwipe)
            tableView.addGestureRecognizer(rightSwipe)
        }
    }

    private func presentSimulatedCoreDataMenu() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        let actionSheet = UIAlertController(title: "Simulated Core Data", message: nil, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: "Generate Simulated Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged before generating new simulated historical Core Data. Are you sure?", actionTitle: "Generate Simulated Historical") {
                self.generateSimulatedHistoricalCoreData()
            }
        })
        actionSheet.addAction(UIAlertAction(title: "Purge Historical", style: .default) { _ in
            self.presentConfirmation(actionSheetMessage: "All existing Core Data older than 24 hours will be purged. Are you sure?", actionTitle: "Purge Historical") {
                self.purgeHistoricalCoreData()
            }
        })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func generateSimulatedHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Generating simulated historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    if let error = error {
                        dismissActivityIndicator()
                        self.presentError(error)
                        return
                    }

                    self.deviceManager.generateSimulatedHistoricalCoreData() { error in
                        DispatchQueue.main.async {
                            dismissActivityIndicator()
                            if let error = error {
                                self.presentError(error)
                            }
                        }
                    }
                }
            }
        }
    }

    private func purgeHistoricalCoreData() {
        guard FeatureFlags.simulatedCoreDataEnabled else {
            fatalError("\(#function) should be invoked only when simulated core data is enabled")
        }

        presentActivityIndicator(title: "Simulated Core Data", message: "Purging historical...") { dismissActivityIndicator in
            self.deviceManager.purgeHistoricalCoreData() { error in
                DispatchQueue.main.async {
                    dismissActivityIndicator()
                    if let error = error {
                        self.presentError(error)
                    }
                }
            }
        }
    }

    private func presentConfirmation(actionSheetMessage: String, actionTitle: String, handler: @escaping () -> Void) {
        let actionSheet = UIAlertController(title: nil, message: actionSheetMessage, preferredStyle: .actionSheet)
        actionSheet.addAction(UIAlertAction(title: actionTitle, style: .destructive) { _ in handler() })
        actionSheet.addCancelAction()
        present(actionSheet, animated: true)
    }

    private func presentError(_ error: Error, handler: (() -> Void)? = nil) {
        let alert = UIAlertController(title: "Error", message: "An error occurred: \(String(describing: error))", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in handler?() })
        present(alert, animated: true)
    }

    private func presentActivityIndicator(title: String, message: String, completion: @escaping (@escaping () -> Void) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addActivityIndicator()
        present(alert, animated: true) { completion { alert.dismiss(animated: true) } }
    }

    @objc private func stepActiveScenarioForward() {
        testingScenariosManager.stepActiveScenarioForward { _ in }
    }

    @objc private func stepActiveScenarioBackward() {
        testingScenariosManager.stepActiveScenarioBackward { _ in }
    }
}

extension UIAlertController {
    func addActivityIndicator() {
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let activityIndicator = UIActivityIndicatorView(frame: frame)
        activityIndicator.style = .default
        activityIndicator.startAnimating()
        let viewController = UIViewController()
        viewController.preferredContentSize = frame.size
        viewController.view.addSubview(activityIndicator)
        setValue(viewController, forKey: "contentViewController")
    }
}

extension StatusTableViewController: CompletionDelegate {
    func completionNotifyingDidComplete(_ object: CompletionNotifying) {
        if let vc = object as? UIViewController {
            if presentedViewController === vc {
                dismiss(animated: true, completion: nil)
            } else {
                vc.dismiss(animated: true, completion: nil)
            }
        }
    }
}

extension StatusTableViewController: PumpManagerStatusObserver {
    func pumpManager(_ pumpManager: PumpManager, didUpdate status: PumpManagerStatus, oldStatus: PumpManagerStatus) {
        dispatchPrecondition(condition: .onQueue(.main))
        log.default("PumpManager:%{public}@ did update status", String(describing: type(of: pumpManager)))

        basalDeliveryState = status.basalDeliveryState
        bolusState = status.bolusState

        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: CGMManagerStatusObserver {
    func cgmManager(_ manager: CGMManager, didUpdate status: CGMManagerStatus) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

extension StatusTableViewController: DoseProgressObserver {
    func doseProgressReporterDidUpdate(_ doseProgressReporter: DoseProgressReporter) {

        updateBolusProgress()

        if doseProgressReporter.progress.isComplete {
            // Bolus ended
            self.bolusProgressReporter = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: {
                self.bolusState = .noBolus
                self.reloadData(animated: true)
            })
        }
    }
}

extension StatusTableViewController: OverrideSelectionViewControllerDelegate {
    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didUpdatePresets presets: [TemporaryScheduleOverridePreset]) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.overridePresets = presets
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didConfirmPreset preset: TemporaryScheduleOverridePreset) {
        let intent = EnableOverridePresetIntent()
        intent.overrideName = preset.name

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.identifier = preset.id.uuidString
        interaction.groupIdentifier = preset.name
        interaction.donate { (error) in
            if let error = error {
                os_log(.error, "Failed to donate intent: %{public}@", String(describing: error))
            }
        }
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = preset.createOverride(enactTrigger: .local)
        }
    }

    func overrideSelectionViewController(_ vc: OverrideSelectionViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController: AddEditOverrideTableViewControllerDelegate {
    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didSaveOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = override
        }
    }

    func addEditOverrideTableViewController(_ vc: AddEditOverrideTableViewController, didCancelOverride override: TemporaryScheduleOverride) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.scheduleOverride = nil
        }
    }
}

extension StatusTableViewController {
    fileprivate func addCGMManager(withIdentifier identifier: String) {
        switch deviceManager.setupCGMManager(withIdentifier: identifier) {
        case .failure(let error):
            log.error("Failure to setup CGM manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.cgmManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("CGM manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController {
    fileprivate func addPumpManager(withIdentifier identifier: String) {
        guard let maximumBasalRate = deviceManager.loopManager.settings.maximumBasalRatePerHour,
              let maxBolus = deviceManager.loopManager.settings.maximumBolus,
              let basalSchedule = deviceManager.loopManager.settings.basalRateSchedule else
        {
            log.error("Failure to setup pump manager: incomplete settings")
            return
        }
        
        let settings = PumpManagerSetupSettings(maxBasalRateUnitsPerHour: maximumBasalRate,
                                                maxBolusUnits: maxBolus,
                                                basalSchedule: basalSchedule)
        switch deviceManager.setupPumpManagerUI(withIdentifier: identifier, initialSettings: settings) {
        case .failure(let error):
            log.error("Failure to setup pump manager with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.pumpManagerOnboardingDelegate = deviceManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Pump manager with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }
}

extension StatusTableViewController: BluetoothObserver {
    func bluetoothDidUpdateState(_ state: BluetoothState) {
        refreshContext.update(with: .status)
        reloadData(animated: true)
    }
}

// MARK: - SettingsViewModel delegation
extension StatusTableViewController: SettingsViewModelDelegate {
    var closedLoopDescriptiveText: String? {
        return deviceManager.closedLoopDisallowedLocalizedDescription
    }

    func dosingEnabledChanged(_ value: Bool) {
        deviceManager.loopManager.mutateSettings { settings in
            settings.dosingEnabled = value
        }
    }
    
    func dosingStrategyChanged(_ strategy: AutomaticDosingStrategy) {
        self.deviceManager.loopManager.mutateSettings { settings in
            settings.automaticDosingStrategy = strategy
        }
    }

    func didTapIssueReport() {
        // TODO: this dismiss here is temporary, until we know exactly where
        // we want this screen to belong in the navigation flow
        dismiss(animated: true) {
            let vc = CommandResponseViewController.generateDiagnosticReport(deviceManager: self.deviceManager)
            vc.title = NSLocalizedString("Issue Report", comment: "The view controller title for the issue report screen")
            self.show(vc, sender: nil)
        }
    }
}

// MARK: - Services delegation

extension StatusTableViewController: ServicesViewModelDelegate {
    func addService(withIdentifier identifier: String) {
        switch deviceManager.servicesManager.setupService(withIdentifier: identifier) {
        case .failure(let error):
            log.default("Failure to setup service with identifier '%{public}@': %{public}@", identifier, String(describing: error))
        case .success(let success):
            switch success {
            case .userInteractionRequired(var setupViewController):
                setupViewController.serviceOnboardingDelegate = deviceManager.servicesManager
                setupViewController.completionDelegate = self
                show(setupViewController, sender: self)
            case .createdAndOnboarded:
                log.default("Service with identifier '%{public}@' created and onboarded", identifier)
            }
        }
    }

    func gotoService(withIdentifier identifier: String) {
        guard let serviceUI = deviceManager.servicesManager.activeServices.first(where: { $0.pluginIdentifier == identifier }) as? ServiceUI else {
            return
        }
        showServiceSettings(serviceUI)
    }

    fileprivate func showServiceSettings(_ serviceUI: ServiceUI) {
        var settingsViewController = serviceUI.settingsViewController(colorPalette: .default)
        settingsViewController.serviceOnboardingDelegate = deviceManager.servicesManager
        settingsViewController.completionDelegate = self
        show(settingsViewController, sender: self)
    }
}
