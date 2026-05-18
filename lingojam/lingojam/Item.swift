//
//  Item.swift
//  lingojam
//
//  Created by Louis Currie on 18.05.26.
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
