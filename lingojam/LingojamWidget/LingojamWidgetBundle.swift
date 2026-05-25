//
//  LingojamWidgetBundle.swift
//  LingojamWidget
//
//  Created by Louis Currie on 20.05.26.
//

import WidgetKit
import SwiftUI

@main
struct LingojamWidgetBundle: WidgetBundle {
    init() {
        FontRegistrar.registerOnce()
    }

    var body: some Widget {
        DailyWordWidget()
    }
}
