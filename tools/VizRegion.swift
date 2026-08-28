// Side-by-side visualiser for a region of the layer stack: source photo, the
// mask that decides what is the subject, and the depth field that displaces it.
//
// Depth is contrast-stretched across the values actually present inside the
// mask in this crop — the subject occupies a narrow slice of 0..1, so the raw
// map looks like flat grey and tells you nothing by eye.

import Foundation
import CoreImage
import AppKit

func fail(_ m: String) -> Never {
  FileHandle.standardError.write(("error: " + m + "\n").data(using: .utf8)!); exit(1)
}

var photoPath = "", maskPath = "", depthPath = "", outPath = ""
var x0 = 0, y0 = 0, cw = 160, ch = 200, scale = 4

var args = Array(CommandLine.arguments.dropFirst())
while let f = args.first {
  args.removeFirst()
  func v() -> String {
    if args.isEmpty { fail("\(f) needs a value") }
    return args.removeFirst()
  }
  switch f {
  case "--photo": photoPath = v()
  case "--mask":  maskPath = v()
  case "--depth": depthPath = v()
  case "--out":   outPath = v()
  case "--x":     x0 = Int(v()) ?? 0
  case "--y":     y0 = Int(v()) ?? 0
  case "--w":     cw = Int(v()) ?? cw
  case "--h":     ch = Int(v()) ?? ch
  case "--scale": scale = Int(v()) ?? scale
  default: fail("unknown flag \(f)")
  }
}

func loadRGBA(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
  guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
        let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fail("read \(path)") }
  let w = cg.width, h = cg.height
  var bytes = [UInt8](repeating: 0, count: w * h * 4)
  bytes.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                              bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      fail("ctx")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
  }
  return (w, h, bytes)
}

let photo = loadRGBA(photoPath)
let mask = loadRGBA(maskPath)
let depth = loadRGBA(depthPath)

// stretch depth over the range present under the mask in this crop
var lo = 255, hi = 0
for y in y0..<(y0 + ch) {
  for x in x0..<(x0 + cw) {
    guard x < depth.w && y < depth.h else { continue }
    if mask.px[(y * mask.w + x) * 4] < 128 { continue }
    let d = Int(depth.px[(y * depth.w + x) * 4])
    lo = min(lo, d); hi = max(hi, d)
  }
}
let span = max(hi - lo, 1)
FileHandle.standardError.write("depth under mask in crop: \(lo)..\(hi) of 255\n".data(using: .utf8)!)

let gap = 10
let panelW = cw * scale, panelH = ch * scale
let outW = panelW * 3 + gap * 2, outH = panelH
var out = [UInt8](repeating: 24, count: outW * outH * 4)

for oy in 0..<outH {
  for ox in 0..<outW {
    var panel = -1, px = 0
    if ox < panelW { panel = 0; px = ox }
    else if ox >= panelW + gap && ox < panelW * 2 + gap { panel = 1; px = ox - panelW - gap }
    else if ox >= (panelW + gap) * 2 { panel = 2; px = ox - (panelW + gap) * 2 }
    guard panel >= 0 else { continue }

    let sx = x0 + px / scale, sy = y0 + oy / scale
    let o = (oy * outW + ox) * 4
    out[o + 3] = 255
    guard sx < photo.w && sy < photo.h else { continue }

    switch panel {
    case 0:
      let i = (sy * photo.w + sx) * 4
      out[o] = photo.px[i]; out[o+1] = photo.px[i+1]; out[o+2] = photo.px[i+2]
    case 1:
      // mask over a dimmed photo, so you can see what it is cutting around
      let i = (sy * photo.w + sx) * 4
      let inside = mask.px[(sy * mask.w + sx) * 4] > 127
      if inside {
        out[o] = photo.px[i]; out[o+1] = photo.px[i+1]; out[o+2] = photo.px[i+2]
      } else {
        out[o] = photo.px[i] / 4; out[o+1] = photo.px[i+1] / 4; out[o+2] = UInt8(min(255, Int(photo.px[i+2]) / 4 + 40))
      }
    default:
      let inside = mask.px[(sy * mask.w + sx) * 4] > 127
      let d = Int(depth.px[(sy * depth.w + sx) * 4])
      if inside {
        let t = UInt8(max(0, min(255, (d - lo) * 255 / span)))
        out[o] = t; out[o+1] = t; out[o+2] = t
      } else {
        out[o] = 12; out[o+1] = 12; out[o+2] = 28
      }
    }
  }
}

guard let provider = CGDataProvider(data: Data(out) as CFData),
      let image = CGImage(width: outW, height: outH, bitsPerComponent: 8, bitsPerPixel: 32,
                          bytesPerRow: outW * 4, space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                          provider: provider, decode: nil, shouldInterpolate: false,
                          intent: .defaultIntent),
      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
else { fail("encode") }
try! png.write(to: URL(fileURLWithPath: outPath))
print("wrote \(outPath)  (\(outW)x\(outH)) — photo | mask | depth(stretched \(lo)..\(hi))")
