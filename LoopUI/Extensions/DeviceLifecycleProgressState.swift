//
//  DeviceLifecycleProgressState.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit
import SwiftUI

extension DeviceLifecycleProgressState {
    public var color: UIColor {
        switch self {
        case .critical:
            return .critical
        case .dimmed:
            return UIColor(Color.secondary)
        case .normalCGM:
            return .pumpStatusNormal
        case .normalPump:
            return .pumpStatusNormal
        case .warning:
            return .warning
        }
    }
}
