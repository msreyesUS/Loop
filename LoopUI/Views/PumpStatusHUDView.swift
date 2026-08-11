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
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textColor = .label
        label.numberOfLines = 2
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.8
        label.isHidden = true
        return label
    }()

    /// Keeps the pump manager's HUD pinned to the trailing edge while the expiration
    /// label floats centered over the whole pill
    private let expirationSpacer = UIView()

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

        // The spacer takes the space the basal dial occupied, keeping the pump HUD at
        // the trailing edge; the label overlays the pill, centered on the whole card
        expirationSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        if let basalIndex = statusStackView.arrangedSubviews.firstIndex(of: basalRateHUD) {
            statusStackView.insertArrangedSubview(expirationSpacer, at: basalIndex + 1)
        } else {
            statusStackView.addArrangedSubview(expirationSpacer)
        }

        expirationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(expirationLabel)
        NSLayoutConstraint.activate([
            expirationLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            expirationLabel.centerYAnchor.constraint(equalTo: statusStackView.centerYAnchor),
            expirationLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.6),
        ])
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
        expirationSpacer.isHidden = true
        statusStackView.removeArrangedSubview(expirationSpacer)

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

        statusStackView.addArrangedSubview(expirationSpacer)
        expirationSpacer.isHidden = false
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
