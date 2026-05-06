//
//  WebRTCPreview.swift
//  金凤凰
//
//  Created by 陈源 on 10/3/25.
//
import SwiftUI
import WebRTC

struct WebRTCPreview: UIViewRepresentable {
    let view: RTCMTLVideoView
    func makeUIView(context: Context) -> RTCMTLVideoView {
            view.backgroundColor = .black
            view.videoContentMode = .scaleAspectFill
            return view
    }
    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {}
    
}

