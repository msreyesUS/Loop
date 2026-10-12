//
//  GlucoseRangeCategory.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit

extension GlucoseRangeCategory {
    public var glucoseColor: UIColor {
        switch self {
        case .normal, .high, .low:
            return .label
        case .urgentLow, .belowRange:
            return .critical
        case .aboveRange:
            return .warning
        }
    }
    
    public var trendColor: UIColor {
        switch self {
        case .normal:
            return .glucose
        case .urgentLow, .belowRange:
            return .critical
        case .low, .high, .aboveRange:
            return .warning
        }
    }

    /// A muted background tint following the same severity mapping as `glucoseColor`:
    /// urgentLow and belowRange are critical, aboveRange is warning, the rest are neutral.
    public var backgroundTintColor: UIColor? {
        switch self {
        case .normal, .high, .low:
            return nil
        case .urgentLow, .belowRange:
            return .criticalBackground
        case .aboveRange:
            return .warningBackground
        }
    }

    /// A vivid base color for subtle background gradients:
    /// greenish in range, yellowish high, reddish low.
    public var backgroundGradientColor: UIColor {
        switch self {
        case .normal:
            return .fresh
        case .low, .belowRange, .urgentLow:
            return .critical
        case .high, .aboveRange:
            return .warning
        }
    }
}
