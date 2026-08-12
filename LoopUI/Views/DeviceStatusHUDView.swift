//
//  DeviceStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

@objc open class DeviceStatusHUDView: BaseHUDView {
    
    var statusHighlightView: StatusHighlightHUDView! {
        didSet {
            statusHighlightView.isHidden = true
        }
    }
    
    @IBOutlet private var statusBadgeView: StatusBadgeHUDView! {
        didSet {
            statusBadgeView.isHidden = true
        }
    }
    
    @IBOutlet weak var progressView: UIProgressView! {
        didSet {
            progressView.isHidden = true
            progressView.tintColor = .systemGray
            // round the edges of the progress view
            progressView.layer.cornerRadius = 2
            progressView.clipsToBounds = true
            progressView.layer.sublayers!.last!.cornerRadius = 2
            progressView.subviews.last!.clipsToBounds = true
        }
    }
    
    /// The system separator heavily softened, matching the status screen's cards
    private var borderColor: CGColor {
        let resolved = UIColor.separator.resolvedColor(with: traitCollection)
        return resolved.withAlphaComponent(resolved.cgColor.alpha * 0.35).cgColor
    }

    /// Hides the pill's own background, for hosts that provide a shared card behind
    /// multiple HUDs
    public var showsBackground: Bool = true {
        didSet {
            backgroundView?.isHidden = !showsBackground
        }
    }

    @IBOutlet private weak var backgroundView: UIView! {
        didSet {
            // Translucent with a hairline border to match the status screen's cards
            backgroundView.backgroundColor = .systemBackground.withAlphaComponent(0.62)
            backgroundView.layer.cornerRadius = 23
            backgroundView.layer.borderWidth = 1
            backgroundView.layer.borderColor = borderColor
        }
    }

    open override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        // CGColors don't adapt automatically; re-resolve for the new appearance
        backgroundView?.layer.borderColor = borderColor
    }
    
    @IBOutlet weak var statusStackView: UIStackView!
    
    public var lifecycleProgress: DeviceLifecycleProgress? {
        didSet {
            guard let lifecycleProgress = lifecycleProgress else {
                resetProgress()
                return
            }
             
            progressView.isHidden = false
            progressView.progress = Float(lifecycleProgress.percentComplete.clamped(to: 0...1))
            progressView.tintColor = lifecycleProgress.progressState.color
        }
    }
    
    public var adjustViewsForNarrowDisplay: Bool = false {
        didSet {
            if adjustViewsForNarrowDisplay != oldValue {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 26),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 26),
                ])
            } else {
                NSLayoutConstraint.activate([
                    statusHighlightView.icon.widthAnchor.constraint(equalToConstant: 34),
                    statusHighlightView.icon.heightAnchor.constraint(equalToConstant: 34),
                ])
            }
        }
    }
    
    private func resetProgress() {
        progressView.isHidden = true
        progressView.progress = 0
    }
    
    func setup() {
        if statusHighlightView == nil {
            statusHighlightView = StatusHighlightHUDView(frame: self.frame)
        }
    }
    
    public func presentStatusHighlight(_ statusHighlight: DeviceStatusHighlight?) {
        guard let statusHighlight = statusHighlight else {
            dismissStatusHighlight()
            return
        }
        
        presentStatusHighlight(withMessage: statusHighlight.localizedMessage,
                               image: statusHighlight.image,
                               color: statusHighlight.state.color)
    }
    
    private func presentStatusHighlight(withMessage message: String,
                                       image: UIImage?,
                                       color: UIColor)
    {
        statusHighlightView.messageLabel.text = message
        statusHighlightView.messageLabel.tintColor = .label
        statusHighlightView.icon.image = image
        statusHighlightView.icon.tintColor = color
        presentStatusHighlight()
    }
    
    func presentStatusHighlight() {
        statusStackView?.addArrangedSubview(statusHighlightView)
        statusHighlightView.isHidden = false
    }
    
    func dismissStatusHighlight() {
        // need to also hide this view, since it will be added back to the stack at some point
        statusHighlightView.isHidden = true
        statusStackView?.removeArrangedSubview(statusHighlightView)
    }
    
    public func presentStatusBadge(_ statusBadge: DeviceStatusBadge?) {
        guard let statusBadge = statusBadge else {
            dismissStatusBadge()
            return
        }
        
        presentStatusBadge(withIcon: statusBadge.image,
                           color: statusBadge.state.color)
    }
    
    private func presentStatusBadge(withIcon badgeIcon: UIImage?,
                                    color: UIColor) {
        statusBadgeView.setBadgeIcon(badgeIcon)
        statusBadgeView.tintColor = color
        presentStatusBadge()
    }
    
    private func presentStatusBadge() {
        statusBadgeView.isHidden = false
    }
    
    private func dismissStatusBadge() {
        statusBadgeView.isHidden = true
    }
}
