// Splits a photograph into two textures for layered ("2.5D") parallax:
//
//   background — the photo with the subject's silhouette filled in, so there
//                are plausible pixels where he currently blocks the view
//   sprite     — the subject, cut out with alpha
//
// Why this exists: with a single plate, the renderer has nothing to reveal when
// the background slides out from behind the subject, so it repeats edge pixels
// and they streak. And a thin near feature cannot displace further than it is
// wide, because the ray march loses the feature and finds background instead.
// Two layers remove both problems — the sprite translates rigidly, and the
// background it uncovers is real.
//
// This deliberately computes its own subject mask rather than sharing the depth
// tool's, so nothing here can alter the existing depth pipeline.

import Foundation
import Vision
import CoreImage
import AppKit

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
  exit(1)
}

// ------------------------------------------------------------------- options

var input = "", bgOut = "", spriteOut = "", maskOut = "", depthOut = ""
var depthIn = "", bgDepthOut = "", provOut = ""
var subjThresh: Float = 0.45   // model depth below this, inside the mask, is
                               // treated as a hole and filled from neighbours
var depthSmooth: Float = 4     // px blur on the subject depth field
var subjClamp: Float = 0.05    // depth this far below the local level is a hole
var subjClampRadius: Float = 40 // px defining "local" for that comparison
var bgDepthSmooth: Float = 10  // px blur on the background depth field
var fillSmooth = 2             // box-blur passes over filled pixels only
var base: Float = 0.86     // the subject's overall depth
var bulge: Float = 0.12    // how much rounder the core reads than the edges
var tilt: Float = 0.14     // linear spread across the subject
var tiltDeg: Float = 135   // direction that gets nearer; y counts downward
var grow: Float = 4        // blur radius used to dilate the hole
var holeThresh: Float = 0.25   // level taken as "inside the hole" after that blur
var erode: Float = 1       // px to pull the sprite edge in, against crowd fringing
var feather: Float = 1.2   // sprite alpha softening
var patchSmooth: Float = 2.5   // spatial smoothing of a patch's colour gate
var patchGrow = 22             // max px a patch may grow out from the mask
var extend: Float = 90     // px of mirrored, texture-preserving fill before the
                           // pyramid takes over; this is the band that shows
var heroFill: Float = 70   // px reach for recovering thin bits Vision drops
var heroThresh: Float = 0.55
var patches: [(cx: Float, cy: Float, rx: Float, ry: Float, skin: Bool)] = []

var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
  args.removeFirst()
  func value() -> String {
    if args.isEmpty { fail("\(flag) needs a value") }
    return args.removeFirst()
  }
  switch flag {
  case "--in":      input = value()
  case "--bg":      bgOut = value()
  case "--sprite":  spriteOut = value()
  case "--mask":    maskOut = value()
  case "--provenance": provOut = value()   // debug: R=instance G=hero-fill B=patch
  case "--depth":   depthOut = value()
  case "--depth-in":  depthIn = value()     // real depth from the monocular model
  case "--bg-depth":  bgDepthOut = value()
  case "--subj-thresh": subjThresh = Float(value()) ?? subjThresh
  case "--depth-smooth":    depthSmooth = Float(value()) ?? depthSmooth
  case "--subj-clamp":      subjClamp = Float(value()) ?? subjClamp
  case "--subj-clamp-radius": subjClampRadius = Float(value()) ?? subjClampRadius
  case "--bg-depth-smooth": bgDepthSmooth = Float(value()) ?? bgDepthSmooth
  case "--fill-smooth":     fillSmooth = Int(value()) ?? fillSmooth
  case "--base":    base = Float(value()) ?? base
  case "--bulge":   bulge = Float(value()) ?? bulge
  case "--tilt":    tilt = Float(value()) ?? tilt
  case "--tilt-deg": tiltDeg = Float(value()) ?? tiltDeg
  case "--grow":    grow = Float(value()) ?? grow
  case "--hole-thresh": holeThresh = Float(value()) ?? holeThresh
  case "--erode":   erode = Float(value()) ?? erode
  case "--feather": feather = Float(value()) ?? feather
  case "--extend":  extend = Float(value()) ?? extend
  case "--patch-smooth": patchSmooth = Float(value()) ?? patchSmooth
  case "--patch-grow":   patchGrow = Int(value()) ?? patchGrow
  case "--hero-fill":   heroFill = Float(value()) ?? heroFill
  case "--hero-thresh": heroThresh = Float(value()) ?? heroThresh
  case "--patch":
    let f = value().split(separator: ",").compactMap { Float($0) }
    if f.count != 4 && f.count != 5 { fail("--patch wants cx,cy,rx,ry[,skin]") }
    patches.append((cx: f[0], cy: f[1], rx: f[2], ry: f[3], skin: f.count == 5 ? f[4] != 0 : true))
  default: fail("unknown flag \(flag)")
  }
}
if input.isEmpty || bgOut.isEmpty || spriteOut.isEmpty {
  fail("usage: --in <photo> --bg <bg.png> --sprite <sprite.png> [--mask <mask.png>]")
}

// --------------------------------------------------------------------- input

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
  fail("could not read \(input)")
}
let W = cgImage.width, H = cgImage.height
let grey = CGColorSpaceCreateDeviceGray()
let ciContext = CIContext(options: [.useSoftwareRenderer: false])

func rgbaBytes(_ image: CGImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: W * H * 4)
  bytes.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                              bitsPerComponent: 8, bytesPerRow: W * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
      fail("could not create rgb context")
    }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
  }
  return bytes
}

func greyBytes(_ image: CIImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: W * H)
  guard let cg = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: W, height: H)) else {
    fail("could not rasterise")
  }
  bytes.withUnsafeMutableBytes { raw in
    guard let ctx = CGContext(data: raw.baseAddress, width: W, height: H,
                              bitsPerComponent: 8, bytesPerRow: W, space: grey,
                              bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
      fail("could not create grey context")
    }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: W, height: H))
  }
  return bytes
}

func ciFromGrey(_ bytes: [UInt8]) -> CIImage {
  guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                         bytesPerRow: W, space: grey,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent) else { fail("could not wrap mask") }
  return CIImage(cgImage: cg)
}

func blurred(_ image: CIImage, _ radius: Float) -> CIImage {
  guard radius > 0 else { return image }
  guard let f = CIFilter(name: "CIGaussianBlur",
                         parameters: [kCIInputImageKey: image.clampedToExtent(),
                                      kCIInputRadiusKey: radius]),
        let out = f.outputImage else { fail("blur failed") }
  return out.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

// ------------------------------------------------------------- subject mask

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
let instance = VNGenerateForegroundInstanceMaskRequest()
let persons = VNGeneratePersonSegmentationRequest()
persons.qualityLevel = .accurate
persons.outputPixelFormat = kCVPixelFormatType_OneComponent8
do { try handler.perform([instance, persons]) } catch { fail("Vision failed: \(error)") }

guard let obs = instance.results?.first, !obs.allInstances.isEmpty else {
  fail("Vision found no foreground subject")
}
let maskBuffer: CVPixelBuffer
do {
  maskBuffer = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
} catch { fail("mask generation failed: \(error)") }

let maskImage = CIImage(cvPixelBuffer: maskBuffer).transformed(by: CGAffineTransform(
  scaleX: CGFloat(W) / CGFloat(CVPixelBufferGetWidth(maskBuffer)),
  y: CGFloat(H) / CGFloat(CVPixelBufferGetHeight(maskBuffer))))

// Loaded before the mask is assembled: real depth is the best available check
// on whether a pixel we are about to *add* to the subject really belongs to it.
var predicted: [UInt8] = []
if !depthIn.isEmpty {
  guard let dSrc = CGImageSourceCreateWithURL(URL(fileURLWithPath: depthIn) as CFURL, nil),
        let dCG = CGImageSourceCreateImageAtIndex(dSrc, 0, nil) else {
    fail("could not read \(depthIn)")
  }
  predicted = greyBytes(CIImage(cgImage: dCG).transformed(by: CGAffineTransform(
    scaleX: CGFloat(W) / CGFloat(dCG.width), y: CGFloat(H) / CGFloat(dCG.height))))
}

let instanceRaw = greyBytes(maskImage)
var subject = [UInt8](repeating: 0, count: W * H)
var fromInstance = [UInt8](repeating: 0, count: W * H)
var fromHeroFill = [UInt8](repeating: 0, count: W * H)
var fromPatch = [UInt8](repeating: 0, count: W * H)
for i in 0..<(W * H) {
  subject[i] = instanceRaw[i] >= 128 ? 255 : 0
  fromInstance[i] = subject[i]
}

// Thin extremities Vision drops, accepted only near the existing mask.
if heroFill > 0, let pObs = persons.results?.first {
  let pci = CIImage(cvPixelBuffer: pObs.pixelBuffer)
  let personRaw = greyBytes(pci.transformed(by: CGAffineTransform(
    scaleX: CGFloat(W) / pci.extent.width, y: CGFloat(H) / pci.extent.height)))
  let nearHero = greyBytes(blurred(maskImage, heroFill / 1.5))
  // Person segmentation lights up the crowd as well as the hero, and near his
  // legs and feet there are spectators close enough to the mask to qualify. On
  // this frame that pulled in a patch of crowd that then travelled with his
  // sneaker. Real depth settles it: a genuine part of him reads at subject
  // depth, a spectator behind him does not.
  var vetoed = 0
  for i in 0..<(W * H) where subject[i] < 128 {
    guard nearHero[i] >= 13 && Float(personRaw[i]) / 255.0 >= heroThresh else { continue }
    if !predicted.isEmpty && Float(predicted[i]) / 255.0 < subjThresh { vetoed += 1; continue }
    subject[i] = 255; fromHeroFill[i] = 255
  }
  if vetoed > 0 {
    FileHandle.standardError.write(
      String(format: "hero-fill: %.2f%% of frame vetoed by depth\n",
             Double(vetoed) / Double(W * H) * 100).data(using: .utf8)!)
  }
}

// Manual patches for parts Vision misses outright (his thumb and index tips).
if !patches.isEmpty {
  let photo = rgbaBytes(cgImage)
  for patch in patches {
    var inPatch = [Bool](repeating: false, count: W * H)
    // Candidates start as a copy of the mask so the smoothing below sees the
    // solid silhouette next door and grows coherently out of it.
    var cand = subject
    let cx = patch.cx * Float(W), cy = patch.cy * Float(H)
    let rx = max(patch.rx * Float(W), 1), ry = max(patch.ry * Float(H), 1)
    for y in max(0, Int(cy - ry))...min(H - 1, Int(cy + ry)) {
      for x in max(0, Int(cx - rx))...min(W - 1, Int(cx + rx)) {
        let nx = (Float(x) - cx) / rx, ny = (Float(y) - cy) / ry
        if nx * nx + ny * ny > 1 { continue }
        let i = y * W + x
        inPatch[i] = true
        if subject[i] > 127 { continue }
        let r = Int(photo[i*4]), g = Int(photo[i*4+1]), b = Int(photo[i*4+2])
        // Warmth alone, deliberately. Requiring r >= g >= b only ever admits
        // orange-dominant skin, and skin in shadow picks up blue from the
        // crowd around it, so blue overtakes green: 124,72,83 and 133,86,105
        // are plainly his hand and were both rejected. Those pixels then sat in
        // the background layer and drifted away from the hand as a brown blob
        // that read as a stray finger. Measured here, hand pixels run r-b 24..113
        // while the pale crowd runs 6 or negative, so warmth separates them on
        // its own.
        _ = (r, g, b)
      }
    }

    // Region growing, not area filling.
    //
    // Filling every gated pixel inside the ellipse makes the *ellipse* the
    // boundary: measured, the mask's edge traced this arc to within a pixel for
    // 11 of 14 rows, which is the hard geometric shape around the thumb. It
    // also cuts skin off where the digit continues past the arc, and admits
    // crowd where the arc reaches past the skin.
    //
    // Instead grow outward from the hand a ring at a time, taking a pixel only
    // if it touches what we have already and is warm. The region then stops
    // where the skin stops, so the boundary is anatomy. The ellipse survives
    // only as a bound on where growing may happen, and because growth halts on
    // its own, that bound is never what you see. Connectivity is what makes it
    // safe: warm crowd beyond the pale gap next to his thumb is never reached.
    let warm: (Int) -> Bool = { i in
      let r = Int(photo[i*4]), g = Int(photo[i*4+1]), b = Int(photo[i*4+2])
      return r > 80 && r >= g && (r - b) > 14
    }
    if patch.skin {
      for _ in 0..<patchGrow {
        var add: [Int] = []
        for y in 1..<(H - 1) {
          for x in 1..<(W - 1) {
            let i = y * W + x
            guard inPatch[i] && cand[i] < 128 && warm(i) else { continue }
            var touches = false
            for dy in -1...1 where !touches {
              for dx in -1...1 {
                if cand[(y + dy) * W + (x + dx)] > 127 { touches = true; break }
              }
            }
            if touches { add.append(i) }
          }
        }
        if add.isEmpty { break }
        for i in add { cand[i] = 255 }
      }
    } else {
      for y in 0..<H {
        for x in 0..<W where inPatch[y * W + x] { cand[y * W + x] = 255 }
      }
    }

    // A per-pixel colour test on grainy film admits and rejects neighbouring
    // pixels almost at random, which leaves a dithered mask edge — visible as
    // ragged, crawling artefacts along the fingers, worse than the problem the
    // gate was widened to fix. Blurring the candidate map and re-thresholding
    // turns that speckle into a coherent boundary: isolated hits fall below the
    // threshold and disappear, solid regions survive with a smooth edge.
    if patchSmooth > 0 {
      let soft = greyBytes(blurred(ciFromGrey(cand), patchSmooth))
      for i in 0..<(W * H) where inPatch[i] {
        cand[i] = soft[i] >= 128 ? 255 : 0
      }
    }
    for i in 0..<(W * H) where inPatch[i] && cand[i] > 127 && subject[i] < 128 {
      subject[i] = 255; fromPatch[i] = 255
    }

    // Close interior holes only. A gated patch skips a lit highlight on the
    // digit because the specular reads as washed out, leaving pinholes; taking
    // any pixel whose neighbours are nearly all inside fills those without
    // growing the region outward into the crowd, which is what an ungated
    // ellipse did — it travelled with the hand as a hard-edged blob.
    for _ in 0..<3 {
      var add: [Int] = []
      for y in 1..<(H - 1) {
        for x in 1..<(W - 1) {
          let i = y * W + x
          guard inPatch[i] && subject[i] < 128 else { continue }
          var n = 0
          for dy in -1...1 {
            for dx in -1...1 where !(dx == 0 && dy == 0) {
              if subject[(y + dy) * W + (x + dx)] > 127 { n += 1 }
            }
          }
          if n >= 6 { add.append(i) }
        }
      }
      if add.isEmpty { break }
      for i in add { subject[i] = 255; fromPatch[i] = 255 }
    }
  }
}

let coverage = Double(subject.reduce(0) { $0 + ($1 > 127 ? 1 : 0) }) / Double(W * H) * 100
FileHandle.standardError.write(String(format: "subject mask %.1f%% of frame\n", coverage).data(using: .utf8)!)

// ------------------------------------------------------------- pyramid fill
//
// "Pull-push" inpainting. Pull: repeatedly halve the image, averaging only
// pixels that are known, so colour information spreads coarsely across the
// hole. Push: walk back up, filling unknown pixels from the coarser level.
//
// The result is smooth rather than detailed, which is exactly right here — the
// background behind him is defocused crowd, and only a ~40 px band just inside
// his silhouette is ever actually revealed. The interior never gets seen.
// Crucially the fill is *static*, so nothing shimmers as the view moves; the
// per-frame invention is what makes the single-plate smear so objectionable.

struct Level {
  var w: Int, h: Int
  var colour: [Float]   // rgb, w*h*3
  var weight: [Float]   // 0 = unknown, 1 = known
}

func downsample(_ l: Level) -> Level {
  let w2 = max(1, (l.w + 1) / 2), h2 = max(1, (l.h + 1) / 2)
  var c = [Float](repeating: 0, count: w2 * h2 * 3)
  var wt = [Float](repeating: 0, count: w2 * h2)
  for y in 0..<h2 {
    for x in 0..<w2 {
      var sr: Float = 0, sg: Float = 0, sb: Float = 0, sw: Float = 0
      for dy in 0..<2 {
        for dx in 0..<2 {
          let sx = x * 2 + dx, sy = y * 2 + dy
          if sx >= l.w || sy >= l.h { continue }
          let i = sy * l.w + sx
          let ww = l.weight[i]
          if ww <= 0 { continue }
          sr += l.colour[i*3] * ww; sg += l.colour[i*3+1] * ww; sb += l.colour[i*3+2] * ww
          sw += ww
        }
      }
      let o = y * w2 + x
      if sw > 0 {
        c[o*3] = sr / sw; c[o*3+1] = sg / sw; c[o*3+2] = sb / sw
        wt[o] = min(1, sw / 4)
      }
    }
  }
  return Level(w: w2, h: h2, colour: c, weight: wt)
}

/// Mirror fill for the boundary band.
///
/// Ring-by-ring colour dilation propagates along diagonals and lays down a
/// visible 45-degree cross-hatch. Instead, find each unknown pixel's nearest
/// known pixel and *reflect* through it: sample the photo at 2b - p. That
/// carries real crowd texture and its film grain into the hole rather than
/// inventing a smooth wash, and the extension direction follows the silhouette
/// normal instead of the pixel grid.
///
/// This band is what gets revealed when the background slides out from behind
/// the subject, so it is the only part of the fill that has to convince. Beyond
/// `maxDist` the pyramid takes over — nobody ever sees that far in.
func mirrorFill(colour: inout [Float], weight: inout [Float], photo: [UInt8], maxDist: Float) {
  var srcX = [Int32](repeating: -1, count: W * H)
  var srcY = [Int32](repeating: -1, count: W * H)
  for i in 0..<(W * H) where weight[i] >= 1 {
    srcX[i] = Int32(i % W); srcY[i] = Int32(i / W)
  }

  func consider(_ i: Int, _ j: Int, _ x: Int, _ y: Int) {
    guard srcX[j] >= 0 else { return }
    let cx = Int(srcX[j]) - x, cy = Int(srcY[j]) - y
    let cand = cx * cx + cy * cy
    if srcX[i] < 0 {
      srcX[i] = srcX[j]; srcY[i] = srcY[j]; return
    }
    let hx = Int(srcX[i]) - x, hy = Int(srcY[i]) - y
    if cand < hx * hx + hy * hy { srcX[i] = srcX[j]; srcY[i] = srcY[j] }
  }

  // two sweeps propagate an approximate nearest-known-pixel field
  for y in 0..<H {
    for x in 0..<W {
      let i = y * W + x
      if x > 0 { consider(i, i - 1, x, y) }
      if y > 0 { consider(i, i - W, x, y) }
      if x > 0 && y > 0 { consider(i, i - W - 1, x, y) }
      if x + 1 < W && y > 0 { consider(i, i - W + 1, x, y) }
    }
  }
  for y in stride(from: H - 1, through: 0, by: -1) {
    for x in stride(from: W - 1, through: 0, by: -1) {
      let i = y * W + x
      if x + 1 < W { consider(i, i + 1, x, y) }
      if y + 1 < H { consider(i, i + W, x, y) }
      if x + 1 < W && y + 1 < H { consider(i, i + W + 1, x, y) }
      if x > 0 && y + 1 < H { consider(i, i + W - 1, x, y) }
    }
  }

  var filled = 0
  for y in 0..<H {
    for x in 0..<W {
      let i = y * W + x
      if weight[i] >= 1 { continue }
      guard srcX[i] >= 0 else { continue }
      let bx = Int(srcX[i]), by = Int(srcY[i])
      let dx = Float(bx - x), dy = Float(by - y)
      if (dx * dx + dy * dy).squareRoot() > maxDist { continue }

      // reflect through the boundary point; fall back to it when the mirrored
      // sample lands in the hole as well
      let mx = 2 * bx - x, my = 2 * by - y
      var sx = bx, sy = by
      if mx >= 0 && my >= 0 && mx < W && my < H && weight[my * W + mx] >= 1 {
        sx = mx; sy = my
      }
      let j = sy * W + sx
      colour[i*3] = Float(photo[j*4]) / 255
      colour[i*3+1] = Float(photo[j*4+1]) / 255
      colour[i*3+2] = Float(photo[j*4+2]) / 255
      weight[i] = 1
      filled += 1
    }
  }
  FileHandle.standardError.write(
    String(format: "mirror fill covered %.1f%% of frame\n",
           Double(filled) / Double(W * H) * 100).data(using: .utf8)!)
}

/// Fills every pixel whose weight is below 1, using colour pulled from coarser
/// levels. Returns rgb for the full resolution.
func pyramidFill(colour: [Float], weight: [Float]) -> [Float] {
  var levels = [Level(w: W, h: H, colour: colour, weight: weight)]
  while levels[levels.count - 1].w > 2 && levels[levels.count - 1].h > 2 {
    levels.append(downsample(levels[levels.count - 1]))
  }

  for li in stride(from: levels.count - 2, through: 0, by: -1) {
    let coarse = levels[li + 1]
    var fine = levels[li]
    for y in 0..<fine.h {
      for x in 0..<fine.w {
        let i = y * fine.w + x
        if fine.weight[i] >= 1 { continue }

        // bilinear sample of the coarser level
        let fx = (Float(x) + 0.5) / 2 - 0.5, fy = (Float(y) + 0.5) / 2 - 0.5
        let x0 = max(0, min(coarse.w - 1, Int(floor(fx))))
        let y0 = max(0, min(coarse.h - 1, Int(floor(fy))))
        let x1 = max(0, min(coarse.w - 1, x0 + 1))
        let y1 = max(0, min(coarse.h - 1, y0 + 1))
        let tx = max(0, min(1, fx - Float(x0))), ty = max(0, min(1, fy - Float(y0)))
        var acc: [Float] = [0, 0, 0], accW: Float = 0
        for (px, py, wgt) in [(x0, y0, (1-tx)*(1-ty)), (x1, y0, tx*(1-ty)),
                              (x0, y1, (1-tx)*ty), (x1, y1, tx*ty)] {
          let ci = py * coarse.w + px
          let cw = coarse.weight[ci] * wgt
          if cw <= 0 { continue }
          acc[0] += coarse.colour[ci*3] * cw
          acc[1] += coarse.colour[ci*3+1] * cw
          acc[2] += coarse.colour[ci*3+2] * cw
          accW += cw
        }
        guard accW > 0 else { continue }
        let a = fine.weight[i]                    // may be partially known
        for k in 0..<3 {
          let filled = acc[k] / accW
          fine.colour[i*3+k] = a * fine.colour[i*3+k] + (1 - a) * filled
        }
        fine.weight[i] = 1
      }
    }
    levels[li] = fine
  }
  return levels[0].colour
}

/// Softens filled pixels only, leaving real photography untouched.
///
/// The nearest-known-pixel field comes from a two-sweep approximation, so
/// neighbouring hole pixels can reflect through different boundary points and
/// copy from unrelated places. Magnified, that reads as a blocky staircase in
/// the revealed band. A couple of box-blur passes restricted to the filled
/// region knock the steps down while keeping enough grain to pass as crowd.
func smoothFilled(_ colour: inout [Float], filledMask: [Bool], passes: Int) {
  guard passes > 0 else { return }
  for _ in 0..<passes {
    var next = colour
    for y in 1..<(H - 1) {
      for x in 1..<(W - 1) {
        let i = y * W + x
        guard filledMask[i] else { continue }
        for k in 0..<3 {
          var sum: Float = 0
          for dy in -1...1 {
            for dx in -1...1 { sum += colour[((y + dy) * W + (x + dx)) * 3 + k] }
          }
          next[i*3+k] = sum / 9
        }
      }
    }
    colour = next
  }
}

// ------------------------------------------------------------------- outputs

let photo = rgbaBytes(cgImage)

// The hole is the subject, dilated slightly so no sliver of him is left behind
// in the plate.
//
// How far it dilates matters more than it looks. Thresholding a blurred mask at
// a very low level pushes the boundary out a long way, which closes narrow
// *enclosed* background gaps — the dark slots between his fingers. Those are
// genuine background: the sprite does not draw them, so erasing them from the
// plate too means they render as fill mush, the fingers lose their separation
// and read as missing. Take a level near the middle instead, so the dilation is
// a couple of px: enough to bury the matte's soft edge, not enough to swallow a
// gap.
let hole = greyBytes(blurred(ciFromGrey(subject), grow))
var bgColour = [Float](repeating: 0, count: W * H * 3)
var bgWeight = [Float](repeating: 0, count: W * H)
for i in 0..<(W * H) {
  bgColour[i*3] = Float(photo[i*4]) / 255
  bgColour[i*3+1] = Float(photo[i*4+1]) / 255
  bgColour[i*3+2] = Float(photo[i*4+2]) / 255
  // anything the dilated mask touches at all is treated as unknown
  bgWeight[i] = Float(hole[i]) / 255 > holeThresh ? 0 : 1
}
let unknownPct = Double(bgWeight.reduce(0) { $0 + ($1 < 1 ? 1 : 0) }) / Double(W * H) * 100
FileHandle.standardError.write(String(format: "filling %.1f%% of the plate\n", unknownPct).data(using: .utf8)!)
let wasFilled = bgWeight.map { $0 < 1 }
mirrorFill(colour: &bgColour, weight: &bgWeight, photo: photo, maxDist: extend)
let stillUnknown = Double(bgWeight.reduce(0) { $0 + ($1 < 1 ? 1 : 0) }) / Double(W * H) * 100
FileHandle.standardError.write(String(format: "%.1f%% left for the pyramid (never revealed)\n",
                                      stillUnknown).data(using: .utf8)!)
var bgFilled = pyramidFill(colour: bgColour, weight: bgWeight)
smoothFilled(&bgFilled, filledMask: wasFilled, passes: fillSmooth)

// Sprite alpha: erode a touch so crowd pixels caught by the mask edge do not
// ride along, then feather.
var spriteAlpha = subject
if erode > 0 {
  let soft = greyBytes(blurred(ciFromGrey(subject), erode))
  for i in 0..<(W * H) { spriteAlpha[i] = Float(soft[i]) / 255 >= 0.72 ? 255 : 0 }
}
let alphaSoft = greyBytes(blurred(ciFromGrey(spriteAlpha), feather))

// Sprite rgb: extend subject colour outward past the edge, so bilinear
// filtering never mixes in a transparent black and leaves a dark fringe.
var spColour = [Float](repeating: 0, count: W * H * 3)
var spWeight = [Float](repeating: 0, count: W * H)
for i in 0..<(W * H) {
  spColour[i*3] = Float(photo[i*4]) / 255
  spColour[i*3+1] = Float(photo[i*4+1]) / 255
  spColour[i*3+2] = Float(photo[i*4+2]) / 255
  spWeight[i] = spriteAlpha[i] > 127 ? 1 : 0
}
let spriteRGB = pyramidFill(colour: spColour, weight: spWeight)

func writeRGB(_ rgb: [Float], to path: String) {
  var bytes = [UInt8](repeating: 0, count: W * H * 4)
  for i in 0..<(W * H) {
    for k in 0..<3 { bytes[i*4+k] = UInt8(max(0, min(255, rgb[i*3+k] * 255 + 0.5))) }
    bytes[i*4+3] = 255
  }
  writeRGBA(bytes, to: path)
}

func writeRGBA(_ bytes: [UInt8], to path: String) {
  guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32,
                            bytesPerRow: W * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent) else { fail("could not build image") }
  // JPEG for the opaque background plate — it is a photograph and PNG triples
  // the size for nothing. Anything with alpha has to stay PNG.
  let rep = NSBitmapImageRep(cgImage: image)
  let isJpeg = path.lowercased().hasSuffix(".jpg") || path.lowercased().hasSuffix(".jpeg")
  let data = isJpeg
    ? rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
    : rep.representation(using: .png, properties: [:])
  guard let out = data else { fail("image encode failed") }
  do { try out.write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path): \(error)") }
}

writeRGB(bgFilled, to: bgOut)

var spriteBytes = [UInt8](repeating: 0, count: W * H * 4)
for i in 0..<(W * H) {
  for k in 0..<3 { spriteBytes[i*4+k] = UInt8(max(0, min(255, spriteRGB[i*3+k] * 255 + 0.5))) }
  spriteBytes[i*4+3] = alphaSoft[i]
}
writeRGBA(spriteBytes, to: spriteOut)

// ------------------------------------------- real depth, split across layers
//
// With a monocular model's depth map we no longer have to author anything. The
// same map serves both layers, but each needs its own copy:
//
//   subject depth — the map as predicted, extended outward past the sprite's
//                   alpha so bilinear filtering at the edge has real values.
//   background depth — the subject's depth carved out and filled, because
//                   behind him the background is at *background* depth, not his.
//
// Both use the fills already built for colour.
if !depthIn.isEmpty {
  // the fill helpers work on rgb, so carry depth in all three channels
  /// `requireForeground` additionally rejects model depth that reads as
  /// background *inside* the subject mask. The model loses thin, low-contrast
  /// extremities just as Vision does — on this frame it puts the thumb tip at
  /// 0.165, solid crowd depth — and a sprite pixel carrying background depth
  /// parallaxes away from the hand it belongs to, which is the very artefact
  /// this whole exercise is chasing. Treat those as holes and fill them from
  /// neighbouring subject depth instead.
  func fillDepth(keepWhere known: [UInt8], invert: Bool, requireForeground: Bool = false) -> [UInt8] {
    var colour = [Float](repeating: 0, count: W * H * 3)
    var weight = [Float](repeating: 0, count: W * H)
    var rejected = 0
    for i in 0..<(W * H) {
      let v = Float(predicted[i]) / 255
      colour[i*3] = v; colour[i*3+1] = v; colour[i*3+2] = v
      let inside = known[i] > 127
      var ok = (invert ? !inside : inside)
      if ok && requireForeground && v < subjThresh { ok = false; rejected += 1 }
      weight[i] = ok ? 1 : 0
    }
    if requireForeground {
      FileHandle.standardError.write(
        String(format: "subject depth: %.2f%% of frame rejected as background-inside-mask\n",
               Double(rejected) / Double(W * H) * 100).data(using: .utf8)!)
    }
    var photoLike = [UInt8](repeating: 0, count: W * H * 4)
    for i in 0..<(W * H) {
      for k in 0..<3 { photoLike[i*4+k] = predicted[i] }
      photoLike[i*4+3] = 255
    }
    mirrorFill(colour: &colour, weight: &weight, photo: photoLike, maxDist: extend)
    let out = pyramidFill(colour: colour, weight: weight)
    var bytes = [UInt8](repeating: 0, count: W * H)
    for i in 0..<(W * H) { bytes[i] = UInt8(max(0, min(255, out[i*3] * 255 + 0.5))) }
    return bytes
  }

  // A model's depth steps hard at a silhouette. Inside a sprite that detail is
  // wasted — alpha already draws the edge — but it is actively harmful: the
  // per-pixel offset then jumps between neighbouring pixels and tears the alpha
  // edge into a zigzag. Blurring the field costs nothing visible and fixes it.
  /// Removes valleys in the subject's depth field.
  ///
  /// A fixed threshold only catches the floor of a dip. On this frame the
  /// model's depth across the thumb runs 158, 153, 128, 91, 91, 125 while the
  /// rest of the hand sits at ~155: the deepest pixels get rejected and filled,
  /// but the shoulders at 125-147 read as plausible, survive, and smoothing then
  /// blends the hole back in. Those pixels are inside the sprite yet displace
  /// like crowd, which tears the hand.
  ///
  /// Comparing each pixel against a wide local average instead catches the whole
  /// valley, whatever its depth, while leaving genuine large-scale gradients
  /// alone — the local average follows those.
  func clampValleys(_ d: [UInt8], mask: [UInt8], tol: Float, radius: Float) -> [UInt8] {
    guard tol > 0 else { return d }
    var cur = d
    for _ in 0..<2 {                                  // twice: the valley drags the average down
      let wide = greyBytes(blurred(ciFromGrey(cur), radius))
      for i in 0..<(W * H) where mask[i] > 127 {
        let dv = Float(cur[i]) / 255, wv = Float(wide[i]) / 255
        if dv < wv - tol { cur[i] = UInt8(max(0, min(255, wv * 255 + 0.5))) }
      }
    }
    return cur
  }

  func smoothed(_ bytes: [UInt8], _ radius: Float) -> [UInt8] {
    guard radius > 0 else { return bytes }
    return greyBytes(blurred(ciFromGrey(bytes), radius))
  }

  if !depthOut.isEmpty {
    // keep the subject's own depth, extend it outward
    let filled = fillDepth(keepWhere: subject, invert: false, requireForeground: true)
    let levelled = clampValleys(filled, mask: subject, tol: subjClamp, radius: subjClampRadius)
    let sd = smoothed(levelled, depthSmooth)
    var m = [UInt8](repeating: 0, count: W * H * 4)
    for i in 0..<(W * H) { for k in 0..<3 { m[i*4+k] = sd[i] }; m[i*4+3] = 255 }
    writeRGBA(m, to: depthOut)
    FileHandle.standardError.write("wrote subject depth from the model\n".data(using: .utf8)!)
  }
  if !bgDepthOut.isEmpty {
    // carve the subject out and fill, so the plate carries background depth
    let bd = smoothed(fillDepth(keepWhere: hole, invert: true), bgDepthSmooth)
    var m = [UInt8](repeating: 0, count: W * H * 4)
    for i in 0..<(W * H) { for k in 0..<3 { m[i*4+k] = bd[i] }; m[i*4+3] = 255 }
    writeRGBA(m, to: bgDepthOut)
    FileHandle.standardError.write("wrote background depth from the model\n".data(using: .utf8)!)
  }
}

// ------------------------------------------------- depth *within* the subject
//
// Layered compositing hands the subject-to-background cliff to alpha, so the
// depth field inside the sprite is smooth — no cliff, therefore no ray march,
// therefore none of the width clamping that punished thin features on a single
// plate. That means the subject can carry real volume again while a fingertip
// still travels with the palm.
//
// Two smooth cues, both authored:
//
//   bulge — a wide blur of the mask stands in for thickness, so the core reads
//           nearer than the edges and he is round rather than a cutout.
//   tilt  — a linear gradient, so a limb reaching toward the lens leads.
//
// Defined everywhere, not just under the mask: outside the silhouette thickness
// falls to zero and the tilt still evaluates, so the field stays continuous and
// bilinear filtering at the sprite edge has nothing to catch on.
if !depthOut.isEmpty && depthIn.isEmpty {
  let thickness = greyBytes(blurred(ciFromGrey(subject), Float(max(W, H)) / 26.0))

  var tMin = Float.greatestFiniteMagnitude, tMax = -Float.greatestFiniteMagnitude
  let rad = tiltDeg * Float.pi / 180
  let ax = cos(rad), ay = sin(rad)
  if tilt != 0 {
    for y in 0..<H {
      for x in 0..<W where subject[y * W + x] > 127 {
        let p = Float(x) * ax + Float(y) * ay
        tMin = min(tMin, p); tMax = max(tMax, p)
      }
    }
  }
  let span = max(tMax - tMin, 1)

  var d = [UInt8](repeating: 0, count: W * H)
  var lo: Float = 1, hi: Float = 0
  for y in 0..<H {
    for x in 0..<W {
      let i = y * W + x
      var v = base + bulge * (Float(thickness[i]) / 255.0)
      if tilt != 0 {
        let p = Float(x) * ax + Float(y) * ay
        v += tilt * ((p - tMin) / span - 0.5)
      }
      if subject[i] > 127 { lo = min(lo, v); hi = max(hi, v) }
      d[i] = UInt8(max(0, min(255, v * 255 + 0.5)))
    }
  }
  var m = [UInt8](repeating: 0, count: W * H * 4)
  for i in 0..<(W * H) { for k in 0..<3 { m[i*4+k] = d[i] }; m[i*4+3] = 255 }
  writeRGBA(m, to: depthOut)
  FileHandle.standardError.write(
    String(format: "subject depth spans %.3f..%.3f (base %.2f, bulge %.2f, tilt %.2f)\n",
           lo, hi, base, bulge, tilt).data(using: .utf8)!)
}

if !maskOut.isEmpty {
  var m = [UInt8](repeating: 0, count: W * H * 4)
  for i in 0..<(W * H) { for k in 0..<3 { m[i*4+k] = alphaSoft[i] }; m[i*4+3] = 255 }
  writeRGBA(m, to: maskOut)
}

if !provOut.isEmpty {
  var m = [UInt8](repeating: 0, count: W * H * 4)
  var counts = [0, 0, 0]
  for i in 0..<(W * H) {
    m[i*4] = fromInstance[i]; m[i*4+1] = fromHeroFill[i]; m[i*4+2] = fromPatch[i]
    m[i*4+3] = 255
    if fromInstance[i] > 0 { counts[0] += 1 }
    if fromHeroFill[i] > 0 { counts[1] += 1 }
    if fromPatch[i] > 0 { counts[2] += 1 }
  }
  writeRGBA(m, to: provOut)
  let pc = counts.map { String(format: "%.2f%%", Double($0) / Double(W * H) * 100) }
  FileHandle.standardError.write(
    "provenance — instance \(pc[0]), hero-fill \(pc[1]), patch \(pc[2])\n".data(using: .utf8)!)
}

print("wrote \(bgOut) and \(spriteOut)" + (maskOut.isEmpty ? "" : " and \(maskOut)"))
