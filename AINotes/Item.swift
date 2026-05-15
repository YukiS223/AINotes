//
//  Item.swift
//  AINotes
//
//  Created by 落 on 2026-05-15.
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
