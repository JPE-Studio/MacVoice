// Standalone check of the C bindings against the real engine:
// reads a 16 kHz mono WAV, transcribes it, then runs cactus_complete with pcm + NULL input.
// Run: swiftc engine_test.swift macos-arm64/libcactus.a -o /tmp/engine_test && /tmp/engine_test /tmp/test.wav
import AVFoundation
import Ccactus
import Foundation

let args = CommandLine.arguments
guard args.count > 1 else { print("usage: engine_test <16k-mono-wav>"); exit(1) }

for name in ["needle3.cact", "whistle.cact"] {
    let path = NSHomeDirectory() + "/" + name
    guard let data = FileManager.default.contents(atPath: path) else { print("missing \(path)"); exit(1) }
    let ok = data.withUnsafeBytes { raw -> Int32 in
        guard let base = raw.baseAddress else { return 0 }
        return cactus_load(base.assumingMemoryBound(to: UInt8.self), UInt64(data.count))
    }
    print("load \(name): \(ok)")
}

let tools = (try! String(contentsOfFile: "tools.json", encoding: .utf8))
print("init: \(cactus_init(nil, tools, nil))")

let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
try file.read(into: buf)
var pcm: [Float] = []
if let ch = buf.floatChannelData?[0] {
    pcm = Array(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength)))
}
print("samples: \(pcm.count)")

var out = [CChar](repeating: 0, count: 1 << 18)
let n = pcm.withUnsafeBufferPointer { b in
    cactus_transcribe(b.baseAddress, Int32(pcm.count), nil, nil, 0, &out, Int32(out.count))
}
print("transcribe n=\(n): \(n > 0 ? String(cString: out) : "FAILED")")

var out2 = [CChar](repeating: 0, count: 1 << 18)
let n2 = pcm.withUnsafeBufferPointer { b in
    cactus_complete(nil, b.baseAddress, Int32(pcm.count), 320, &out2, Int32(out2.count))
}
print("complete(pcm, nil input) n=\(n2): \(n2 > 0 ? String(cString: out2) : "FAILED")")

var out3 = [CChar](repeating: 0, count: 1 << 18)
let n3 = "take a screenshot".withCString { inC in
    cactus_complete(inC, nil, 0, 320, &out3, Int32(out3.count))
}
print("complete(text only) n=\(n3): \(n3 > 0 ? String(cString: out3) : "FAILED")")
