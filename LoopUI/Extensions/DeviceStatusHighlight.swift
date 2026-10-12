//
//  DeviceStatusHighlight.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit

extension DeviceStatusHighlight {
    public var image: UIImage? {
        if let image = UIImage(named: imageName) {
            return image
        } else {
            return UIImage(systemName: imageName)
        }
    }
}

extension DeviceStatusElementState {
    public var color: UIColor {
        switch self {
        case .normalCGM:
            return .pumpStatusNormal
        case .normalPump:
            return .pumpStatusNormal
        case .warning:
            return .warning
        case .critical:
            return .critical
        }
    }
}
