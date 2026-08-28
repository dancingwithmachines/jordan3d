// Builds a depth map for a photograph using Apple's Vision framework, entirely
// on this machine — nothing is uploaded.
//
// Vision gives us mattes, not depth, so depth is composed from two of them:
//
//   * the foreground-instance matte is the hero subject, placed near and
//     rounded slightly so it does not read as a flat card (a heavily blurred
//     copy of the matte stands in for a distance transform — the interior
//     stays near, silhouette edges fall back);
//   * the person-segmentation mask, minus the hero, picks up *other* people
//     further into the scene. It returns them mid-grey while background
//     clutter stays near-black, so a threshold window separates a second
//     figure from crowd speckle. Those go on a middle plane.
//   * everything else is a vertical ramp — far at the top, nearer at the
//     bottom, which is how a floor receding to a back wall behaves.
//
// This yields clean silhouettes, better than a monocular depth net manages at
// edges, but it only knows about people. Inanimate foreground objects land in
// the background ramp, and there is no true depth *within* a subject. For a
// full depth field, use a monocular depth model — see README.

import Foundation
import Vision
import CoreImage
import AppKit

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(("error: " + msg + "\n").data(using: .utf8)!)
  exit(1)
}

// ------------------------------------------------------------------- options

var input = "", output = "", matteOut = ""
var near: Float = 0.86         // subject depth
var bgTop: Float = 0.06        // background at the top of the frame
var bgBottom: Float = 0.42     // background at the bottom
var relief: Float = 0          // subject edge rounding; 0 keeps fine detail crisp
var feather: Float = 2.0       // matte edge softening, in pixels
var heroFill: Float = 70       // px reach for recovering thin bits Vision missed
var heroThresh: Float = 0.55   // person-mask value that counts as the hero
var tilt: Float = 0            // depth spread across the subject; 0 = flat cutout
var tiltDeg: Float = 135       // direction that gets *nearer*; y counts downward
var mid: Float = 0.55          // depth for secondary figures
var midLo: Float = 0.25        // person-mask value where a secondary figure starts
var midHi: Float = 0.60        // ...and where it counts fully. Below midLo = crowd.
var midSoft: Float = 0         // secondary blur radius in px; 0 = auto (long side / 60)
var usePersons = false         // secondary figures are opt-in; see --persons

var args = Array(CommandLine.arguments.dropFirst())
while let flag = args.first {
  args.removeFirst()
  func value() -> String {
    if args.isEmpty { fail("\(flag) needs a value") }
    return args.removeFirst()
  }
  switch flag {
  case "--in":       input = value()
  case "--out":      output = value()
  case "--matte":    matteOut = value()
  case "--near":     near = Float(value()) ?? near
  case "--bg-top":   bgTop = Float(value()) ?? bgTop
  case "--bg-bottom": bgBottom = Float(value()) ?? bgBottom
  case "--relief":   relief = Float(value()) ?? relief
  case "--hero-fill":   heroFill = Float(value()) ?? heroFill
  case "--hero-thresh": heroThresh = Float(value()) ?? heroThresh
  case "--tilt":     tilt = Float(value()) ?? tilt
  case "--tilt-deg": tiltDeg = Float(value()) ?? tiltDeg
  case "--feather":  feather = Float(value()) ?? feather
  case "--mid":      mid = Float(value()) ?? mid
  case "--mid-lo":   midLo = Float(value()) ?? midLo
  case "--mid-hi":   midHi = Float(value()) ?? midHi
  case "--mid-soft": midSoft = Float(value()) ?? midSoft
  case "--flat":     relief = 0
  case "--persons":  usePersons = true
  default: fail("unknown flag \(flag)")
  }
}
if input.isEmpty || output.isEmpty { fail("usage: --in <photo> --out <depth.png> [--matte <matte.png>]") }

// --------------------------------------------------------------------- input

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
      let cgImage = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
  fail("could not read \(input)")
}
let W = cgImage.width, H = cgImage.height

// ------------------------------------------------------------ subject matte

let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
let request = VNGenerateForegroundInstanceMaskRequest()
let persons = VNGeneratePersonSegmentationRequest()
persons.qualityLevel = .accurate
persons.outputPixelFormat = kCVPixelFormatType_OneComponent8

do {
  try handler.perform(usePersons || heroFill > 0 ? [request, persons] : [request])
} catch { fail("Vision failed: \(error)") }

guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
  fail("Vision found no foreground subject in \(input)")
}
FileHandle.standardError.write("found \(observation.allInstances.count) instance(s)\n".data(using: .utf8)!)

let maskBuffer: CVPixelBuffer
do {
  maskBuffer = try observation.generateScaledMaskForImage(
    forInstances: observation.allInstances, from: handler)
} catch { fail("mask generation failed: \(error)") }

// ------------------------------------------------------- matte -> grey bytes

let ciContext = CIContext(options: [.useSoftwareRenderer: false])
let grey = CGColorSpaceCreateDeviceGray()

/// Renders a CIImage to an 8-bit grey buffer, one byte per pixel, row 0 = top.
func greyBytes(_ image: CIImage) -> [UInt8] {
  var bytes = [UInt8](repeating: 0, count: W * H)
  guard let cg = ciContext.createCGImage(image, from: CGRect(x: 0, y: 0, width: W, height: H)) else {
    fail("could not rasterise mask")
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

/// Wraps an 8-bit grey buffer back up as a CIImage so it can be blurred.
func ciFromGrey(_ bytes: [UInt8]) -> CIImage {
  guard let provider = CGDataProvider(data: Data(bytes) as CFData),
        let cg = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                         bytesPerRow: W, space: grey,
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false,
                         intent: .defaultIntent) else { fail("could not wrap mask") }
  return CIImage(cgImage: cg)
}

let maskImage = CIImage(cvPixelBuffer: maskBuffer)
  .transformed(by: CGAffineTransform(
    scaleX: CGFloat(W) / CGFloat(CVPixelBufferGetWidth(maskBuffer)),
    y: CGFloat(H) / CGFloat(CVPixelBufferGetHeight(maskBuffer))))

func blurred(_ image: CIImage, _ radius: Float) -> CIImage {
  guard radius > 0 else { return image }
  let clamped = image.clampedToExtent()
  guard let f = CIFilter(name: "CIGaussianBlur",
                         parameters: [kCIInputImageKey: clamped,
                                      kCIInputRadiusKey: radius]),
        let out = f.outputImage else { fail("blur failed") }
  return out.cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
}

// The instance matte loses thin, low-contrast extremities: on the Jordan frame
// it drops his outstretched fingers entirely, which then sit at background
// depth and parallax *against* the arm they belong to.
//
// Person segmentation does resolve them, but it also lights up the crowd and
// the other player, so it cannot simply be unioned in. Instead it is accepted
// only within `heroFill` px of the instance matte: a gap adjacent to the hero
// gets filled, while a second figure a few hundred px away never qualifies.
let instanceRaw = greyBytes(maskImage)
var heroUnion = [UInt8](repeating: 0, count: W * H)

if heroFill > 0, let pObs = persons.results?.first {
  let pci = CIImage(cvPixelBuffer: pObs.pixelBuffer)
  let personRaw = greyBytes(pci.transformed(by: CGAffineTransform(
    scaleX: CGFloat(W) / pci.extent.width, y: CGFloat(H) / pci.extent.height)))

  // Blurring the matte and taking anything non-trivial approximates "within
  // heroFill px of the hero".
  let nearHero = greyBytes(blurred(maskImage, heroFill / 1.5))
  var recovered = 0
  for i in 0..<(W * H) {
    let isHero = instanceRaw[i] >= 128
    let adjacent = nearHero[i] >= 13 && Float(personRaw[i]) / 255.0 >= heroThresh
    heroUnion[i] = (isHero || adjacent) ? 255 : 0
    if !isHero && adjacent { recovered += 1 }
  }
  FileHandle.standardError.write(
    String(format: "hero fill recovered %.2f%% of frame\n",
           Double(recovered) / Double(W * H) * 100).data(using: .utf8)!)
} else {
  for i in 0..<(W * H) { heroUnion[i] = instanceRaw[i] >= 128 ? 255 : 0 }
}

let heroImage = ciFromGrey(heroUnion)
let matte = greyBytes(blurred(heroImage, feather))
// Stand-in for a distance transform: blur wide enough that only the interior
// stays saturated. Only consulted when relief > 0.
let mound = greyBytes(blurred(heroImage, Float(max(W, H)) / 40.0))

// Secondary figures — opt-in, and read the caveat below before using it.
//
// Vision resolves a further-away person only partially: on the Jordan frame the
// defender's head comes back at ~0.7, his arm at ~0.25 and his lower body not
// at all. Thresholding that directly turns the *variation within one body* into
// a depth gradient, and the parts then parallax away from each other — the arm
// visibly detaches from the shoulder.
//
// So the region is binarised at midLo and only then softened: the interior is
// uniformly `mid`, so everything it covers moves as one piece, and the blur
// applies to the boundary alone. That fixes the internal tearing but cannot
// invent the coverage Vision missed, so the seam moves to wherever the mask
// stops — mid-torso here. For a figure the mask only half-finds, leaving this
// off and letting them ride the background ramp reads cleaner.
var personMask: [UInt8]? = nil
if usePersons, let pObs = persons.results?.first {
  let pci = CIImage(cvPixelBuffer: pObs.pixelBuffer)
  let scaled = pci.transformed(by: CGAffineTransform(
    scaleX: CGFloat(W) / pci.extent.width, y: CGFloat(H) / pci.extent.height))
  let radius = midSoft > 0 ? midSoft : Float(max(W, H)) / 60.0
  let grown = greyBytes(blurred(scaled, radius))

  // Binarise, then soften the boundary only.
  var solid = [UInt8](repeating: 0, count: W * H)
  for i in 0..<(W * H) { solid[i] = Float(grown[i]) / 255.0 >= midLo ? 255 : 0 }

  personMask = greyBytes(blurred(ciFromGrey(solid), radius * 0.5))
}

// ------------------------------------------------------------- compose depth

// A matte carries no depth *within* the subject, so a flat cutout makes every
// part of a figure travel identically — an outstretched hand moves exactly like
// the chest behind it and the limb reads as stiff. `tilt` spreads depth linearly
// across the subject so a chosen direction sits nearer.
//
// This is an authored approximation, not measured depth: it says "this end of
// him is closer", which for a single limb reaching toward the lens is enough to
// sell the movement. It cannot know that a wrist bends. Off by default.
var tiltAxis = (x: Float(0), y: Float(0))
var tiltMin = Float.greatestFiniteMagnitude
var tiltMax = -Float.greatestFiniteMagnitude

if tilt != 0 {
  let rad = tiltDeg * Float.pi / 180
  tiltAxis = (x: cos(rad), y: sin(rad))
  for y in 0..<H {
    for x in 0..<W where heroUnion[y * W + x] > 127 {
      let p = Float(x) * tiltAxis.x + Float(y) * tiltAxis.y
      tiltMin = min(tiltMin, p)
      tiltMax = max(tiltMax, p)
    }
  }
}
let tiltSpan = max(tiltMax - tiltMin, 1)

func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
  guard b > a else { return x < a ? 0 : 1 }
  let t = max(0, min(1, (x - a) / (b - a)))
  return t * t * (3 - 2 * t)
}

var depth = [UInt8](repeating: 0, count: W * H)
var subjectPixels = 0, secondaryPixels = 0
var sumY = 0

for y in 0..<H {
  let v = Float(y) / Float(max(H - 1, 1))          // 0 at the top of the frame
  let bg = bgTop + (bgBottom - bgTop) * v
  for x in 0..<W {
    let i = y * W + x
    let m = Float(matte[i]) / 255.0
    let interior = Float(mound[i]) / 255.0
    var subject = near - relief * (1.0 - interior)
    if tilt != 0 {
      let p = Float(x) * tiltAxis.x + Float(y) * tiltAxis.y
      subject += tilt * ((p - tiltMin) / tiltSpan - 0.5)
    }

    var d = bg
    if let pm = personMask {
      // Already binarised and softened, so use it as-is. Masked outside the
      // hero, or his own soft edge would be dragged backward.
      let secondary = (Float(pm[i]) / 255.0) * (1.0 - m)
      d += (mid - d) * secondary
      if secondary > 0.5 { secondaryPixels += 1 }
    }
    d += (subject - d) * m

    depth[i] = UInt8(max(0, min(255, d * 255.0 + 0.5)))
    if m > 0.5 { subjectPixels += 1; sumY += y }
  }
}

// ---------------------------------------------------------------- write PNGs

func writePNG(_ bytes: [UInt8], to path: String) {
  var data = bytes
  guard let provider = CGDataProvider(data: Data(data) as CFData),
        let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 8,
                            bytesPerRow: W, space: grey,
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent) else { fail("could not build image") }
  let rep = NSBitmapImageRep(cgImage: image)
  guard let png = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed") }
  do { try png.write(to: URL(fileURLWithPath: path)) } catch { fail("write \(path): \(error)") }
  data.removeAll()
}

writePNG(depth, to: output)
if !matteOut.isEmpty { writePNG(matte, to: matteOut) }

let coverage = Double(subjectPixels) / Double(W * H) * 100
let secondary = Double(secondaryPixels) / Double(W * H) * 100
let centroid = subjectPixels > 0 ? Double(sumY) / Double(subjectPixels) / Double(H) : 0
print(String(format: "%dx%d  subject %.1f%% of frame (centroid %.2f down), secondary figures %.1f%%",
             W, H, coverage, centroid, secondary))
print(String(format: "near %.2f, tilt %.2f @ %.0f deg, relief %.2f, feather %.1f px",
             near, tilt, tiltDeg, relief, feather))
print("wrote \(output)" + (matteOut.isEmpty ? "" : " and \(matteOut)"))
