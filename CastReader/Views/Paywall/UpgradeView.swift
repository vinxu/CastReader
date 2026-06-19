//
//  UpgradeView.swift
//  CastReader
//
//  从设置进入的 Pro 升级页（复用 ProUpsellContent）。
//

import SwiftUI

struct UpgradeView: View {
    var body: some View {
        ProUpsellContent()
            .navigationTitle("升级 Pro")
            .navigationBarTitleDisplayMode(.inline)
    }
}
