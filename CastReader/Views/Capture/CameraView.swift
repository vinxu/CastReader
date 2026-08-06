//
//  CameraView.swift
//  CastReader
//
//  相机拍照（模拟器无相机时回退到相册），返回 UIImage。
//

import SwiftUI
import UIKit

struct CameraView: UIViewControllerRepresentable {
    var sourceType: UIImagePickerController.SourceType = .camera
    var onImage: (UIImage) -> Void
    var onCancel: () -> Void

    private var resolvedSourceType: UIImagePickerController.SourceType {
        if sourceType == .camera && !UIImagePickerController.isSourceTypeAvailable(.camera) {
            return .photoLibrary
        }
        return sourceType
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // 用指定来源；要相机但不可用（如模拟器）时回退相册
        picker.sourceType = resolvedSourceType
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        context.coordinator.parent = self
        let nextSourceType = resolvedSourceType
        if uiViewController.sourceType != nextSourceType {
            uiViewController.sourceType = nextSourceType
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImage(image.fixedOrientation())
            } else {
                parent.onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onCancel()
        }
    }
}

extension UIImage {
    /// 顺时针旋转 n 个 90°，像素级归正（结果 orientation 为 .up）。
    /// 用于把横着拍的页面转正 —— OCR 与显示必须用同一张图，否则 bbox 对不上画面。
    func rotatedClockwise(quarterTurns: Int) -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0, let cgImage = cgImage else { return self }
        let orientation: UIImage.Orientation
        switch turns {
        case 1: orientation = .right
        case 2: orientation = .down
        default: orientation = .left
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: orientation).fixedOrientation()
    }

    /// 归正 EXIF 方向，保证 OCR 的 bbox 与显示一致（统一为 .up）。
    func fixedOrientation() -> UIImage {
        guard imageOrientation != .up else { return self }
        UIGraphicsBeginImageContextWithOptions(size, false, scale)
        defer { UIGraphicsEndImageContext() }
        draw(in: CGRect(origin: .zero, size: size))
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
}
