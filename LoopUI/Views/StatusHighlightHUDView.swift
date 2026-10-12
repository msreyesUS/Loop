//
//  StatusHighlightHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-05.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import LoopKit

/// Three stacked lines describing a device: a muted caption naming it ("Sensor", "Pod"),
/// a prominent headline ("6 days"), and a muted detail line ("4 hrs 31 min left").
/// Lines with no text collapse, so problem states can use the headline alone.
public final class DeviceDetailTextView: UIView {

    public let captionLabel = UILabel()
    public let headlineLabel = UILabel()
    public let detailLabel = UILabel()

    private let stack = UIStackView()

    /// Aligns all three lines; `.right` is used when the device icon sits on the trailing side
    public var textAlignment: NSTextAlignment = .left {
        didSet {
            for label in [captionLabel, headlineLabel, detailLabel] {
                label.textAlignment = textAlignment
            }
            stack.alignment = textAlignment == .right ? .trailing : .leading
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
        captionLabel.font = .systemFont(ofSize: 12)
        captionLabel.textColor = .secondaryLabel

        headlineLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        headlineLabel.textColor = .label
        headlineLabel.numberOfLines = 2
        headlineLabel.adjustsFontSizeToFitWidth = true
        headlineLabel.minimumScaleFactor = 0.75

        // Fixed size (no shrink-to-fit) so the sensor and pod detail lines always match
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabel

        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        for label in [captionLabel, headlineLabel, detailLabel] {
            stack.addArrangedSubview(label)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // The text yields horizontal space to the fixed-size icon beside it
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    public func configure(caption: String?, headline: String?, detail: String?, headlineColor: UIColor = .label) {
        captionLabel.text = caption
        captionLabel.isHidden = caption?.isEmpty ?? true
        headlineLabel.text = headline
        headlineLabel.textColor = headlineColor
        headlineLabel.isHidden = headline?.isEmpty ?? true
        detailLabel.text = detail
        detailLabel.isHidden = detail?.isEmpty ?? true
    }
}

public class StatusHighlightHUDView: UIView, NibLoadable {

    private var stackView: UIStackView!

    /// The nib's single-label message; replaced at runtime by `detailTextView`
    @IBOutlet public weak var messageLabel: UILabel!

    @IBOutlet public weak var icon: UIImageView! {
        didSet {
            icon.tintColor = tintColor
        }
    }

    /// The three-line device description shown beside the icon
    public let detailTextView = DeviceDetailTextView()

    /// Names the device ("Sensor", "Pod"); shown as the caption line above the message
    public var caption: String? {
        didSet {
            if caption != oldValue, let message = currentMessage {
                setMessage(message, state: currentState)
            }
        }
    }

    private var currentMessage: String?
    private var currentState: DeviceStatusElementState = .normalCGM

    public enum IconPosition {
        case left
        case right
    }

    private var iconPosition: IconPosition = .right {
        didSet {
            stackView.removeArrangedSubview(detailTextView)
            stackView.removeArrangedSubview(icon)
            switch iconPosition {
            case .left:
                stackView.addArrangedSubview(icon)
                stackView.addArrangedSubview(detailTextView)
                // The message hugs its icon so both device pills mirror each other
                detailTextView.textAlignment = .left
            case .right:
                stackView.addArrangedSubview(detailTextView)
                stackView.addArrangedSubview(icon)
                detailTextView.textAlignment = .right
            }
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

    func setup() {
        stackView = (StatusHighlightHUDView.nib().instantiate(withOwner: self, options: nil)[0] as! UIStackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(stackView)

        // The nib's label gives way to the caption/headline/detail block
        messageLabel.removeFromSuperview()
        stackView.insertArrangedSubview(detailTextView, at: 0)
        stackView.spacing = 6
        detailTextView.textAlignment = .right

        // The stack fills the container; the text block stretches to occupy the
        // space beside the icon
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.widthAnchor.constraint(equalTo: widthAnchor),
            stackView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
    }

    public func setIconPosition(_ iconPosition: IconPosition) {
        if self.iconPosition != iconPosition {
            self.iconPosition = iconPosition
        }
    }

    /// Lays a device message out as caption / headline / detail.
    ///
    /// Normal messages are "<headline>\n<detail>", e.g. "6 days\n4 hrs 31 min left". A
    /// headline that merely repeats the caption ("Sensor\nActive") is dropped so the device
    /// name isn't shown twice. Problem states read as a single headline in the state
    /// color ("Signal Loss", "Pod Expired").
    public func setMessage(_ message: String, state: DeviceStatusElementState) {
        currentMessage = message
        currentState = state

        let lines = message
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        switch state {
        case .normalCGM, .normalPump:
            if lines.count >= 2 {
                let headline = lines[0]
                let detail = lines.dropFirst().joined(separator: " ")
                if let caption = caption, headline.caseInsensitiveCompare(caption) == .orderedSame {
                    detailTextView.configure(caption: caption, headline: detail, detail: nil)
                } else {
                    detailTextView.configure(caption: caption, headline: headline, detail: detail)
                }
            } else {
                detailTextView.configure(caption: caption, headline: lines.first, detail: nil)
            }
        case .warning, .critical:
            detailTextView.configure(caption: caption,
                                     headline: lines.joined(separator: " "),
                                     detail: nil,
                                     headlineColor: state.color)
        }
    }
}
