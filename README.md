# Jordan3D

A 2D photograph given parallax in the browser, using a depth map. Raw WebGL2,
no dependencies, no build step.

## How the technique works

The photo stays a flat quad. The illusion comes from *where each pixel samples
the plate*. Given a view offset `off` and a per-pixel depth `d`:

    uv = base + off * (d - focus)

Near pixels slide with the camera, far pixels lag, and anything sitting at
`focus` stays pinned. The catch is that the depth you need lives at the
*displaced* uv, not the original one.

Fixed-point iteration solves that in a few passes on smooth depth, but at a
silhouette the depth gradient is near-vertical and consecutive passes land on
opposite sides of the cliff — which reads as ragged, crawling edges around a
foreground subject. So instead we **search along the view ray**. Writing
`s = d - focus`, every candidate sits at `uv(s) = base + off * s`, and we want
the `s` where the surface actually is:

    depthAt(uv(s)) - focus == s

Marching near-to-far and taking the *first* crossing is what makes it stable:
the nearest surface wins, so a foreground edge cleanly occludes what is behind
it instead of the two fighting over the pixel. `refine` then bisects the
bracket so edge placement is not quantised to the step size.

At 7.5 megapixels this costs ~1.6 ms a frame — the step count is close to free,
being bandwidth-bound on a single-channel depth texture.

## Run it

```bash
./sync.sh
```

Then start the `jordan3d` preview server (port 4322). The sync step exists
because macOS TCC stops the preview server reading `~/Desktop` directly — it
serves a mirror from `/tmp/jordan3d-preview`. **Re-run `sync.sh` after every
edit** or you are looking at stale files.

Any plain static server works too, from the project root.

## Adding your image

Currently loaded: `assets/Jordan_Dunk.jpg` (1400x1680) with `assets/depth.png`
generated from it. Paths are set in `js/config.js`.

To use a different photo, drop two files into `assets/`:

| file               | what it is                                     |
|--------------------|------------------------------------------------|
| the photograph     | any aspect ratio                               |
| greyscale depth    | **white = near, black = far**                  |

You can also **drag both onto the page** — a filename containing `depth`,
`disp` or `dmap` loads as the depth map, anything else as the colour plate.
With a plate but no depth map, a luminance stand-in is synthesised so there is
something moving; that is brightness, not depth, and the readout labels it.

With no files at all it falls back to a synthetic test scene
(`python3 tools/make_test_scene.py`) whose layers sit at known depths.

## Making the depth map

```bash
./tools/make_depth.sh --in assets/Jordan_Dunk.jpg --out assets/depth.png \
  --matte grabs/matte.png --bg-top 0.26 --bg-bottom 0.34
```

This runs entirely on this machine — the image is never uploaded. It uses
Apple's Vision framework, which gives *mattes*, not depth, so depth is composed
from two of them:

- **Foreground instance matte** → the hero subject, placed at `--near` (0.86)
  and rounded slightly toward its silhouette so it does not read as a flat
  card. A heavily blurred copy of the matte stands in for a distance
  transform.
- **Everything else** → a vertical ramp from `--bg-top` to `--bg-bottom`. The
  tool defaults (0.06 → 0.42) suit a scene with a floor receding to a back
  wall. **This frame is not one** — it is a telephoto shot of a crowd *wall* at
  roughly constant distance, and a steep ramp there shears the background
  vertically, so a standing figure's head and feet ride different depths and
  the figure appears to stretch. Hence the near-flat `0.26 → 0.34` above.
  Match the ramp to what is actually behind the subject.
- **Person segmentation, minus the hero** → *other* people, further into the
  scene, on a middle plane at `--mid`. **Off by default**; enable with
  `--persons`, and read the caveat below first.

### Why secondary figures are opt-in

Vision resolves a further-away person only partially. On this frame it returns
the defender's head at ~0.7, his arm at ~0.25, and his lower body not at all.
Threshold that directly and the variation *within one body* becomes a depth
gradient, so his parts parallax away from each other — the arm visibly detaches
from the shoulder.

The tool now binarises the region before softening it, so the interior is
uniformly `mid` and everything it covers moves as one piece. That fixes the
internal tearing but cannot invent the coverage Vision missed: the seam just
moves to wherever the mask stops, mid-torso here. Measured on this frame, with
the layer off and a flat background, three points down the defender's body
(number, jersey, jersey again) all shift by exactly **33 px** — he translates
rigidly. So for a figure the mask only half-finds, leaving this off and letting
them ride the background plane reads cleaner. Turn it on when the second person
is matted properly.

Silhouettes come out cleaner than a monocular depth net manages. The cost is
that **Vision only knows about people**: on the Jordan frame the rim, net and
backboard sit in the top-left *in front of* everything, and they land in the
background ramp, so they drift with the crowd rather than leading it. There is
also no true depth *within* a subject — the ball is on the same plane as his
shoulders.

For a full depth field that places the rim correctly, use a monocular depth
model. Nothing on this machine can run one today: no `torch`, no
`transformers`, no `PIL`, and system Python is 3.9. Either

- set up a local venv with `torch` + Depth Anything V2 Small — a ~2.5 GB
  download, offline and repeatable afterwards; or
- run it through Depth Anything V2's Hugging Face Space or Immersity AI, which
  means **uploading the image to a third party** — worth a thought for
  unreleased concept art.

If a map comes out dark-near, set `invert` to 1 rather than re-exporting.

### Build note

`tools/make_depth.sh` pins the SDK:

    /Library/Developer/CommandLineTools/SDKs/MacOSX15.5.sdk

The CLT here ships a 26.2 SDK built with Swift 6.2 while `swiftc` is 6.1.2, and
the default pairing fails to build the `Swift` module at all. 15.5 is the
newest SDK this compiler accepts.

## Controls

Press **d** for the panel, **esc** to close, **r** to reset. `copy config`
prints the current values in `js/config.js` shape, ready to paste over
`params` to make a look permanent. `save png` writes the current frame out.

| param       | what it does                                                    |
|-------------|-----------------------------------------------------------------|
| `fit`       | `contain` shows the whole plate and letterboxes the slack; `cover` fills the canvas and crops. A portrait photo in a landscape window loses its top and bottom under `cover` — on the Jordan frame that means the ball, his head and the rim, so `contain` is the default. |
| `depthScale`| parallax strength, in uv units. The main dial.                   |
| `focus`     | depth that stays pinned, 0 far → 1 near. Put it on your subject. |
| `crop`      | zoom in so displacement never samples past the plate edge.       |
| `steps`     | ray-march steps. 24 is the default; below ~12 edges quantise.    |
| `refine`    | binary steps tightening the hit. 4 is plenty, and cheap.          |
| `smooth`    | depth blur in texels. 0 by default — the generated map is already pre-softened. Raise it for a map from elsewhere with JPEG steps along its edges. |
| `dilate`    | biases edges toward the nearer surface. 0 by default; the march handles occlusion properly now, so this is only a rescue for a bad map. |
| `stageHeight` | stage height in CSS px. Width follows the plate's aspect ratio, so the stage never letterboxes and never distorts. If it is taller than the window, the page scrolls. |
| `invert`    | set to 1 for dark-near maps.                                     |
| `amplitude` | multiplies whatever the input source gives.                      |
| `damping`   | per-frame approach, frame-rate normalised. Lower = heavier.      |
| `drift`     | speed and reach of the idle motion.                              |

Motion sources: `pointer`, `auto` drift, `both` (drift recedes while the
pointer is active), or `gyro`.

## Verified

On the synthetic scene, where layers are large and flat, displacement matches
theory exactly: the subject edge moves 80 px across a full view sweep against
80.6 predicted, 152 px against 151 with `focus` on the far ridge, and pinning
`focus` to the subject's own depth holds it at 0 px.

On the Jordan frame at a 1500 px stage, his torso silhouette moves **−84, −85
and −84 px** on three separate rows against −85 predicted. The consistency is
the point: the same measurement under fixed-point iteration gave −45 on two
rows and a spurious +98 on the third, because the edge was landing differently
row to row. That row-to-row disagreement *was* the visible glitching.

Silhouettes were then checked at 4–5x magnification at both extremes of travel
(`J3D.inspect`) — the defender translates rigidly, arm attached to shoulder,
and Jordan's outstretched hand and wristband hold together.

## Known limitation

A single depth map has no data *behind* anything. On the edge where the camera
should reveal what is hidden behind the subject, there are no pixels to reveal,
so the foreground stretches into the gap instead. Measured on the test scene:
the covering edge tracks the predicted displacement exactly, while the
revealing edge stalls, so the subject appears to widen rather than translate.

Keep `depthScale` modest (0.03–0.06 reads as convincing; past ~0.10 the stretch
becomes obvious) and use `dilate` to keep the smear on the background side.
Proper fixes are inpainting the hidden regions or splitting the plate into
layered sprites — worth doing only if a shot needs a big move.

## Scripting hook

`window.J3D` exposes `params`, `view`, `mode` and:

- `poke(x, y)` — render one frame synchronously at an explicit view offset,
  bypassing input and damping. The hook for driving this from a timeline later,
  and how the maths above was verified.
- `inspect(cx, cy, z)` — magnify a point on the plate (`cx`/`cy` in uv, y
  counting up; `z` below 1 zooms in) without touching the parallax maths, for
  examining a silhouette at the pixel level. `inspect(null)` clears it.

## Assets

`assets/Jordan_Dunk.jpg` is a third-party press photograph of the 1988 Slam
Dunk Contest, included here to prototype against. It is not ours to
redistribute — keep this repository private, and swap in licensed or original
photography before anything ships or goes public.

The depth maps and mattes in this repo are generated from it and carry the same
restriction. `assets/test-*.png` are synthetic and free of it.

## Layout

    index.html
    css/style.css
    js/config.js             tuned values + slider schema
    js/main.js               input, damping, render loop, UI
    js/gl.js                 WebGL2 helpers, cover-fit maths
    js/placeholder-depth.js  luminance stand-in
    shaders/quad.vert
    shaders/parallax.frag    the technique
    assets/                  your plate + depth map
    tools/make_test_scene.py synthetic scene generator
    grabs/                   screenshots
