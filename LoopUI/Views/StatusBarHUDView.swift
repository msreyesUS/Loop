//
//  StatusBarHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKitUI

public class StatusBarHUDView: UIView, NibLoadable {
    
    @IBOutlet public weak var cgmStatusHUD: CGMStatusHUDView!
    
    @IBOutlet public weak var loopCompletionHUD: LoopCompletionHUDView!
    
    @IBOutlet public weak var pumpStatusHUD: PumpStatusHUDView!
        
    public var containerView: UIStackView!
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                cgmStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                pumpStatusHUD.adjustViewsForNarrowDisplay = adjustViewsForNarrowDisplay
                containerView.spacing = adjustViewsForNarrowDisplay ? Self.narrowSectionSpacing : Self.sectionSpacing
            }
        }
    }

    override public var bounds: CGRect {
        didSet {
            // need to adjust for narrow display. The labels in the status bar need more space when the bounds width is less than 350 points.
            adjustViewsForNarrowDisplay = bounds.width < 350
        }
    }
    
    override public init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    func setup() {
        containerView = (StatusBarHUDView.nib().instantiate(withOwner: self, options: nil)[0] as! UIStackView)
        containerView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(containerView)

        // Hairline dividers separate the sensor, loop, and pump sections of the shared card.
        // Spacing is tight so the two device pills keep room for their three-line text.
        containerView.spacing = Self.sectionSpacing
        containerView.insertArrangedSubview(makeDivider(), at: 1)
        containerView.insertArrangedSubview(makeDivider(), at: 3)

        // Use AutoLayout to have the stack view fill its entire container.
        NSLayoutConstraint.activate([
            containerView.centerXAnchor.constraint(equalTo: centerXAnchor),
            containerView.centerYAnchor.constraint(equalTo: centerYAnchor),
            containerView.widthAnchor.constraint(equalTo: widthAnchor),
            containerView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        
        self.backgroundColor = UIColor.secondarySystemBackground
    }
        
    private static let sectionSpacing: CGFloat = 8
    private static let narrowSectionSpacing: CGFloat = 6

    /// A one-point vertical line, shorter than the card so it reads as a soft separator
    private func makeDivider() -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.setContentHuggingPriority(.required, for: .horizontal)
        container.setContentCompressionResistancePriority(.required, for: .horizontal)

        let line = UIView()
        line.backgroundColor = UIColor.separator.withAlphaComponent(0.6)
        line.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(line)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 1),
            line.widthAnchor.constraint(equalToConstant: 1),
            line.heightAnchor.constraint(equalTo: container.heightAnchor, multiplier: 0.6),
            line.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            line.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    public func removePumpManagerProvidedView() {
        pumpStatusHUD.removePumpManagerProvidedHUD()
    }
    
    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        pumpStatusHUD.addPumpManagerProvidedHUDView(pumpManagerProvidedHUD)
    }
}
