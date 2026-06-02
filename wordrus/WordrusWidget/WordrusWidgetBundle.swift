//
//  WordrusWidgetBundle.swift
//  WordrusWidget
//
//  Created by Louis Currie on 20.05.26.
//

import WidgetKit
import SwiftUI

@main
struct WordrusWidgetBundle: WidgetBundle {
    init() {
        FontRegistrar.registerOnce()
    }

    var body: some Widget {
        DailyWordWidget()
    }
}
