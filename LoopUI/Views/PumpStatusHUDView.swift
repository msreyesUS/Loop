//
//  PumpStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-09.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class PumpStatusHUDView: DeviceStatusHUDView, NibLoadable {

    @IBOutlet public weak var basalRateHUD: BasalRateHUDView!

    @IBOutlet public weak var pumpManagerProvidedHUD: BaseHUDView!

    override public var orderPriority: HUDViewOrderPriority {
        return 3
    }

    /// Hides the basal rate dial, freeing the space for the expiration text
    public var showsBasalRate: Bool = true {
        didSet {
            basalRateHUD?.isHidden = !showsBasalRate
        }
    }

    /// The device caption also heads the expiration text ("Pod" / "1 day" / "5 hrs left")
    override public var deviceCaption: String? {
        didSet {
            expirationView.captionLabel.text = deviceCaption
            expirationView.captionLabel.isHidden = deviceCaption?.isEmpty ?? true
        }
    }

    /// Time remaining shown alongside the pump manager's HUD (e.g. pod expiration),
    /// right-aligned so the text hugs the pod icon on its trailing side
    public let expirationView: DeviceDetailTextView = {
        let view = DeviceDetailTextView()
        view.textAlignment = .right
        view.isHidden = true
        return view
    }()

    private var hasExpiration = false

    /// Sets the expiration headline ("1 day") and detail ("5 hrs 31 min left");
    /// a nil headline hides the text
    public func setExpiration(headline: String?, detail: String?) {
        hasExpiration = headline != nil
        expirationView.configure(caption: deviceCaption, headline: headline, detail: detail)
        updateExpirationVisibility()
    }

    private func updateExpirationVisibility() {
        expirationView.isHidden = !hasExpiration || statusStackView.arrangedSubviews.contains(statusHighlightView)
    }

    override public func awakeFromNib() {
        super.awakeFromNib()

        // The expiration text sits where the basal dial was, before the pod view
        if let basalIndex = statusStackView.arrangedSubviews.firstIndex(of: basalRateHUD) {
            statusStackView.insertArrangedSubview(expirationView, at: basalIndex + 1)
        } else {
            statusStackView.addArrangedSubview(expirationView)
        }

        // Let the content stack run to the pill's trailing edge (the nib insets it by 8
        // via the background view) so the expiration text has the full width; the pod
        // itself is nudged back by `podOutwardShift`
        for constraint in constraints where constraint.firstItem === statusStackView && constraint.firstAttribute == .trailing {
            constraint.constant = 8
        }

        // The pod graphic is drawn centered within a wider view; shift the text into
        // that empty margin so it hugs the visible pod like the sensor text hugs its icon
        expirationView.transform = CGAffineTransform(translationX: Self.podOutwardShift + 18, y: 0)
    }

    /// Horizontal nudge of the pod graphic (and its text) so the pod sits as far inside
    /// the card's edge as the sensor icon does on the opposite side
    private static let podOutwardShift: CGFloat = -8

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }

    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.left)
        deviceCaption = LocalizedString("Pump", comment: "Default caption naming the pump in the status bar pill")
    }

    public override func tintColorDidChange() {
        super.tintColorDidChange()

        basalRateHUD.tintColor = tintColor
    }

    override public func presentStatusHighlight() {
        guard !statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }

        // need to also hide these view, since they will be added back to the stack at some point
        basalRateHUD.isHidden = true
        statusStackView.removeArrangedSubview(basalRateHUD)

        expirationView.isHidden = true
        statusStackView.removeArrangedSubview(expirationView)

        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            pumpManagerProvidedHUD.isHidden = true
            statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        }

        super.presentStatusHighlight()
    }

    override public func dismissStatusHighlight() {
        guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }

        super.dismissStatusHighlight()

        statusStackView.addArrangedSubview(basalRateHUD)
        basalRateHUD.isHidden = !showsBasalRate

        statusStackView.addArrangedSubview(expirationView)
        updateExpirationVisibility()

        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            statusStackView.addArrangedSubview(pumpManagerProvidedHUD)
            pumpManagerProvidedHUD.isHidden = false
        }
    }

    public func removePumpManagerProvidedHUD() {
        guard let pumpManagerProvidedHUD = pumpManagerProvidedHUD else {
            return
        }

        statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        pumpManagerProvidedHUD.removeFromSuperview()
    }

    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        self.pumpManagerProvidedHUD = pumpManagerProvidedHUD
        statusStackView.addArrangedSubview(self.pumpManagerProvidedHUD)
        self.pumpManagerProvidedHUD.transform = CGAffineTransform(translationX: Self.podOutwardShift, y: 0)
    }

}
