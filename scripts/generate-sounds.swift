#!/usr/bin/env swift
// Renders Gitoken's arrival sounds into App/Resources/Sounds/ as 16-bit mono 44.1 kHz CAF.
// Pure synthesis, no external assets; the output is byte-for-byte deterministic.
//
// Usage: swift scripts/generate-sounds.swift [output-dir]

import Foundation

let sampleRate = 44_100.0
let targetPeakDB = -16.0

struct Partial {
    var frequency: Double
    var amplitude: Double
    /// Exponential decay time constant in seconds.
    var decay: Double
    var start: Double = 0
    /// Raised-cosine onset; every voice fades in so no onset clicks, including notes that start mid-file.
    var attack: Double = 0.006
    /// Pitch at onset relative to `frequency`; glides to 1 over `glide` seconds.
    var bendFrom: Double = 1
    var glide: Double = 0
}

struct Noise {
    var amplitude: Double
    var decay: Double
    var attack: Double = 0.005
}

func onset(_ t: Double, _ attack: Double) -> Double {
    t >= attack ? 1 : 0.5 - 0.5 * cos(.pi * t / attack)
}

func smoothstep(_ x: Double) -> Double { x * x * (3 - 2 * x) }

func render(_ partials: [Partial], noise: Noise? = nil, duration: Double) -> [Double] {
    let count = Int(duration * sampleRate)
    var out = [Double](repeating: 0, count: count)
    for p in partials {
        var phase = 0.0
        let first = Int(p.start * sampleRate)
        for i in first..<count {
            let t = Double(i - first) / sampleRate
            let bend = t < p.glide ? p.bendFrom + (1 - p.bendFrom) * smoothstep(t / p.glide) : 1
            phase += 2 * .pi * p.frequency * bend / sampleRate
            out[i] += p.amplitude * onset(t, p.attack) * exp(-t / p.decay) * sin(phase)
        }
    }
    if let noise {
        // Fixed-seed LCG so the file never changes between runs.
        var state: UInt32 = 0x6A09_E667
        for i in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let white = Double(state >> 8) / Double(1 << 23) - 1
            let t = Double(i) / sampleRate
            out[i] += noise.amplitude * onset(t, noise.attack) * exp(-t / noise.decay) * white
        }
    }
    return out
}

/// RBJ biquad low-pass (Butterworth Q), run twice for a gentle 24 dB/oct roll-off.
func lowPass(_ x: inout [Double], cutoff: Double) {
    let w = 2 * .pi * cutoff / sampleRate
    let alpha = sin(w) / (2 * 0.7071)
    let a0 = 1 + alpha
    let b0 = (1 - cos(w)) / 2 / a0, b1 = (1 - cos(w)) / a0, b2 = b0
    let a1 = -2 * cos(w) / a0, a2 = (1 - alpha) / a0
    for _ in 0..<2 {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let y = b0 * x[i] + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x[i]; y2 = y1; y1 = y
            x[i] = y
        }
    }
}

/// Raised-cosine fade to exactly zero over the last `release` seconds.
func fadeOut(_ x: inout [Double], release: Double) {
    let r = Int(release * sampleRate)
    for k in 0..<min(r, x.count) {
        x[x.count - 1 - k] *= 0.5 - 0.5 * cos(.pi * Double(k) / Double(r))
    }
}

func normalize(_ x: inout [Double], peakDB: Double) {
    let peak = x.map(abs).max() ?? 0
    guard peak > 0 else { return }
    let gain = pow(10, peakDB / 20) / peak
    for i in x.indices { x[i] *= gain }
}

func pcm16(_ x: [Double]) -> [Int16] {
    x.map { Int16(max(-32768, min(32767, ($0 * 32767).rounded()))) }
}

func dB(_ linear: Double) -> Double { 20 * log10(max(linear, 1e-12)) }

func cafData(_ samples: [Int16]) -> Data {
    var d = Data()
    func be<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.bigEndian) { d.append(contentsOf: $0) } }
    func fourCC(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
    fourCC("caff"); be(UInt16(1)); be(UInt16(0))
    fourCC("desc"); be(Int64(32))
    be(sampleRate.bitPattern)
    fourCC("lpcm")
    be(UInt32(0)) // format flags: big-endian signed integer
    be(UInt32(2)); be(UInt32(1)); be(UInt32(1)); be(UInt32(16)) // bytes/packet, frames/packet, channels, bits
    fourCC("data"); be(Int64(4 + samples.count * 2))
    be(UInt32(0)) // edit count
    for s in samples { be(s) }
    return d
}

/// Soft glass drop: a bell partial pair with a tiny upward pitch flick at the onset.
func drop() -> [Double] {
    let f = 1174.66 // D6
    var x = render([
        Partial(frequency: f, amplitude: 1.0, decay: 0.075, bendFrom: 0.9, glide: 0.022),
        Partial(frequency: f * 2.76, amplitude: 0.16, decay: 0.03, bendFrom: 0.9, glide: 0.022),
        Partial(frequency: f * 2.003, amplitude: 0.07, decay: 0.05),
    ], duration: 0.30)
    lowPass(&x, cutoff: 5_500)
    fadeOut(&x, release: 0.03)
    return x
}

/// Two quick ascending notes a perfect fifth apart (A5 → E6), the second slightly softer.
func chime() -> [Double] {
    let a = 880.0, e = 1318.51
    var x = render([
        Partial(frequency: a, amplitude: 1.0, decay: 0.07),
        Partial(frequency: a * 2, amplitude: 0.12, decay: 0.035),
        Partial(frequency: e, amplitude: 0.85, decay: 0.09, start: 0.085),
        Partial(frequency: e * 2, amplitude: 0.1, decay: 0.04, start: 0.085),
    ], duration: 0.34)
    lowPass(&x, cutoff: 5_000)
    fadeOut(&x, release: 0.04)
    return x
}

/// Muted wooden tick: two damped body modes plus a whisper of noise, darker low-pass.
func tap() -> [Double] {
    var x = render([
        Partial(frequency: 640, amplitude: 1.0, decay: 0.018, attack: 0.005),
        Partial(frequency: 1_730, amplitude: 0.45, decay: 0.009, attack: 0.005),
        Partial(frequency: 2_980, amplitude: 0.12, decay: 0.005, attack: 0.005),
    ], noise: Noise(amplitude: 0.18, decay: 0.006), duration: 0.12)
    lowPass(&x, cutoff: 3_800)
    fadeOut(&x, release: 0.03)
    return x
}

let outDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../App/Resources/Sounds").standardizedFileURL
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

for (name, rendered) in [("Drop", drop()), ("Chime", chime()), ("Tap", tap())] {
    var x = rendered
    normalize(&x, peakDB: targetPeakDB)
    let pcm = pcm16(x)
    try cafData(pcm).write(to: outDir.appendingPathComponent("\(name).caf"))
    let values = pcm.map { Double($0) / 32767 }
    let peak = values.map(abs).max() ?? 0
    let rms = (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot()
    print(String(
        format: "%@.caf  %.0f ms  peak %.1f dBFS  rms %.1f dBFS  first/last sample %d/%d",
        name, Double(pcm.count) / sampleRate * 1000, dB(peak), dB(rms), Int(pcm.first ?? 0), Int(pcm.last ?? 0)))
}
