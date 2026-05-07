//
//  WidgetExtensionBundle.swift
//  WidgetExtension
//
//  Created by nwlsrb on 5/3/26.
//

import WidgetKit
import SwiftUI

@main
struct WidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        WidgetExtension()
        WidgetExtensionControl()
        WidgetExtensionLiveActivity()
    }
}
