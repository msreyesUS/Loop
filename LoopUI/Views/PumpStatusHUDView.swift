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

    /// Hides the basal rate dial, freeing the space for the expiration label
    public var showsBasalRate: Bool = true {
        didSet {
            basalRateHUD?.isHidden = !showsBasalRate
        }
    }

    /// A small label shown alongside the pump manager's HUD (e.g. pod expiration),
    /// styled to match the status highlight message
    public let expirationLabel: UILabel = {
        let label = UILabel()
        // Matches the status screen's card title font ("Glucose – Last 3 Hours")
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = .label
        label.numberOfLines = 2
        // The text hugs the pod icon, mirroring the sensor side's icon-hugging text
        label.textAlignment = .right
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.isHidden = true
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// Sets the expiration text; nil hides the label
    public func setExpiration(text: String?) {
        expirationLabel.text = text
        updateExpirationVisibility()
    }

    private func updateExpirationVisibility() {
        expirationLabel.isHidden = expirationLabel.text == nil || statusStackView.arrangedSubviews.contains(statusHighlightView)
    }

    override public func awakeFromNib() {
        super.awakeFromNib()

        // The expiration label sits where the basal dial was, before the pod view
        if let basalIndex = statusStackView.arrangedSubviews.firstIndex(of: basalRateHUD) {
            statusStackView.insertArrangedSubview(expirationLabel, at: basalIndex + 1)
        } else {
            statusStackView.addArrangedSubview(expirationLabel)
        }

        // Pull the pod (and the text hugging it) toward the outer edge so its
        // padding mirrors the sensor icon's on the far side
        for constraint in constraints where constraint.firstItem === statusStackView && constraint.firstAttribute == .trailing {
            constraint.constant = 0
        }
    }
    
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

        expirationLabel.isHidden = true
        statusStackView.removeArrangedSubview(expirationLabel)

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

        statusStackView.addArrangedSubview(expirationLabel)
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
    }
    
}
