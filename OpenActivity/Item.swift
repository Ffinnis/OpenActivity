//
//  Item.swift
//  OpenActivity
//
//  Created by Roman on 24.09.2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
