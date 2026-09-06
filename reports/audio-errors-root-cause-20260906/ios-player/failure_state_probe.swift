import Foundation
import AVFoundation
import Combine

// Narrow offline control-flow probe using a real failed AVPlayerItem.
// Mirrors only the relevant build-53 state assignments, not a compiled app test.
// No playback, installation, network, or production synthesis.
enum VMStatus: String { case streaming, ready, error }
var vmStatus = VMStatus.streaming
var terminalFailureCount = 0
var reportedItemID: ObjectIdentifier?
let dataURL = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("empty.mp3")
let item = AVPlayerItem(asset: AVURLAsset(url: dataURL))
let player = AVPlayer(playerItem: item)
// AudioPlayerService:1607-1676 -> reportPlaybackFailure:1892-1906 -> ReadVM:729-741.
let observer = item.publisher(for: \.status).receive(on: DispatchQueue.main).sink { status in
    guard status == .failed, reportedItemID != ObjectIdentifier(item) else { return }
    reportedItemID = ObjectIdentifier(item)
    player.pause()
    vmStatus = .error
    terminalFailureCount += 1
    print("failure_callback vm=\(vmStatus.rawValue) item=\(item.status.rawValue) readEndCount=\(terminalFailureCount)")
}
let deadline = Date().addingTimeInterval(5)
while Date() < deadline && terminalFailureCount == 0 {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
precondition(terminalFailureCount == 1)
// In production the existing TTS task is not cancelled and its epoch/session
// remain current. A subsequent segment takes ReadVM:3021; generation completion
// takes ReadVM:2854-2864. Perform these two permitted continuations here.
vmStatus = .streaming
print("next_producer_segment vm=\(vmStatus.rawValue) item=\(item.status.rawValue)")
vmStatus = .ready
print("producer_finished vm=\(vmStatus.rawValue) item=\(item.status.rawValue) readEndCount=\(terminalFailureCount)")
precondition(item.status == .failed && vmStatus == .ready)
print("retry_branch_selected=\(vmStatus == .error) (ReadVM:2124 checks only .error)")
observer.cancel()
