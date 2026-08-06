//
//  DocumentScannerView.swift
//  CastReader
//
//  系统文档扫描器（VisionKit）：自动找边 + 透视矫正 + 去阴影 + 多页连拍。
//
//  相机直拍出来的报纸是斜的、带梯形畸变的，而版面理解假设「栏是竖直的」。
//  这个系统组件把这件事在采集阶段就做掉，比事后补救可靠得多。
//  设备不支持时由调用方回退到 `CameraView`。
//

import SwiftUI
import UIKit
import VisionKit

struct DocumentScannerView: UIViewControllerRepresentable {
    var onScan: ([UIImage]) -> Void
    var onCancel: () -> Void
    /// 扫描失败时回调，调用方可回退到普通相机。
    var onFailure: ((Error) -> Void)?

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {
        context.coordinator.parent = self
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        var parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            var pages: [UIImage] = []
            for index in 0..<scan.pageCount {
                // 扫描器已经矫正过，这里只统一 EXIF 方向 —— OCR 的 bbox
                // 与显示几何都建立在 .up 之上。
                pages.append(scan.imageOfPage(at: index).fixedOrientation())
            }
            if pages.isEmpty {
                parent.onCancel()
            } else {
                parent.onScan(pages)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            if let onFailure = parent.onFailure {
                onFailure(error)
            } else {
                parent.onCancel()
            }
        }
    }
}
