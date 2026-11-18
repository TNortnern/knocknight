# Fight Night visual comparison

# Blender-authored left slip

The main fighter now blends authored left- and right-slip poses onto the combat skeleton using
live lean input. One modifier owns both poses and their procedural share, including the handoff
between directions. It fades into block, duck, diagonal lean, shell and backstep poses; a side
with an incompatible asset falls back to the procedural lean. Forward and backward leans remain
procedural. The actions are in `assets/animations/fightnight-slip-left.glb` and
`assets/animations/fightnight-slip-right.glb`.

The right action was built from a restrained existing right-slip pose while retaining the same
stance. A deeper first candidate hid the head in the rear view; the integrated revision is more
upright. In main-project Viper and Anvil captures of one right-slip counter, the incoming jab
missed and the marked counter hit, matching the earlier procedural fixture's recorded result.
A 120 Hz left-right-left capture showed smooth blending in that sequence. The source's exact
opposite-direction 3D motion is not established, so this is not proof of a right-slip 1:1 match.

Main-project Viper and Anvil captures recorded an incoming jab miss and a marked counter hit in
the reconstructed exchange. In a 120 Hz Viper capture, the slip-to-duck and slip-to-diagonal
handoffs reduced the sampled one-tick head displacement from 8.56 to 2.34 cm and 8.19 to 2.08 cm,
respectively. The captures use an approximate camera and reconstructed inputs, so they do not prove
exact source parity. The back remains rounded, the guard differs and the rear foot appears raised.
One measured capture also places the sampled fist close to the preceding rendered attachment,
which leaves contact timing uncertain. No code assertion tests were run.

Rapidly returning to the left slip while an earlier pose was fading previously jumped the animation
sample. The re-entry blend now follows the new sample smoothly. In the captured left-right-left
sequence, the head moved 4.56 cm at the switch instead of 12.27 cm; after a brief block, the
corresponding step was 1.02 cm instead of 11.73 cm. The primary Viper exchange retained its
sampled miss and marked counter.

The Blender action now includes a modest right-foot adjustment on the combat skeleton. In the
held-slip captures, the minimum height of the right-foot-weighted visual region above the base
canvas decreased from 2.20 to 1.53 cm for Viper and from 1.52 to 0.97 cm for Anvil. These are
broad vertex regions, not verified sole landmarks. The rear heel remains raised, and Anvil's
opposite foot showed existing penetration of about 0.83 cm in the sampled region. The motion
still needs work; the sole and reference match are not established.

A subsequent Blender adjustment raises the left ankle slightly through the held slip. In the
same posed-mesh measurement, the lowest left-foot-weighted Viper vertex moved from 0.18 cm below
the base canvas to 0.18 cm above it; Anvil moved from 0.83 cm below to 0.47 cm below. The right
foot's sampled minimum was unchanged. These are broad weighted regions rather than verified sole
landmarks, and the Anvil penetration remains. Main-project Viper and Anvil counter captures still
recorded the incoming jab missing and the marked counter hitting in the same reconstructed fixture.

# Contact classification correction

Later 120 Hz capture diagnostics identified that the earlier primary `.767 s` blocked-labelled
outcome was a **clash**, not a verified guard block. The incoming straight had already missed
and entered recovery; the clash logic could nevertheless rewrite both outcomes. The retained
change excludes missed or recovering attacks from clashes. Fresh primary Viper and Anvil captures
now report a missed incoming strike and a counter hit; one simultaneous active-straight capture
still reports a clash. The source contact is obscured, so neither outcome proves source parity.
The older blocked-labelled observations below describe their historical captures and should not
be interpreted as verified guard blocks. Assertion tests remain deferred.

The capture harness can show existing debug hull meshes (`debug_hulls=true`) and record passive
sampled fist/attachment/head-hull values (`trace_hitboxes=true`). A 120 fps Anvil capture shows
the forearm proxy entering the head region before the sampled fist sphere reaches a head/neck
hull. The hit remains pending through shallow contact and resolves afterward, consistent with
the existing glancing-contact gate but not proof of a sole cause. The overlay uses fitted
proxies, not mesh intersections; hitbox positions and the drawn pose are observed at different
stages. No code assertion tests were run.

An Anvil coverage exchange was rendered from three fixed angles after the high-guard update. The
incoming punch passes behind the head during contact; the fitted forearm/hull proxy also reports
overlap, though it is not a mesh intersection proof. The incoming strike is pending at .600 s
and recorded as a hit by .633 s. A faster recovery-only withdrawal was removed after its small
proxy reduction failed to yield a clear visual improvement. The active hand path and hit handling
need further work and later code-level verification; no exact parity is asserted.

For the deep lateral slip, the free high glove now blends closer to the head as lateral input
increases. The overhead source shows the high glove immediately beside the helmet; its earlier
game projection left a larger gap. The blend does not change the shallow, blocked or pure
backward-lean target. Viper and Anvil were compared at 30 fps and their primary counter guard
contacts remained at the same sampled .767 s. A DeepSeek visual reviewer found no obvious new
wrist/elbow pop, while noting partial Anvil cheek occlusion. Camera and model differences
prevent an exact 3D position claim; code-level contact tests remain deferred.

The overhead source peak projects the lower glove closer to the chest than the current game, but
the uncovered frontal source also shows a low glove. A deep-lateral-lean trial raised the fitted
hand target by up to 0.15 m, then was removed: it barely changed Viper's peak and moved the glove
more during recovery. Camera and body angles make 3D height uncertain. The source/game/trial
comparison retains the actual 30 fps frames without a time warp and includes both fighter models.

The source's 3.9–4.4 s counter shows a relative upper-body turn and face direction toward the foe,
but an uncalibrated camera and occlusion prevent an exact turn-angle measurement. Later tracking
shows nearly stationary source background features, not evidence of a source-camera orbit. An additional torso-yaw
candidate with counter-rotated neck and a separate reduced-roll candidate were visually compared
and removed. The former did not establish a clear improvement and delayed one Anvil contact sample;
the latter flattened projected shoulders late in recovery but changed the head's lateral position.
Evidence and the independent source review are retained with the delivery.

The latest chamber comparison stores the incoming hand in fighter space and blends into the head
straight across 5–65% of peak time. Marked head counters rise across 5–40% while retaining 40% of
their loaded lean; ordinary/body straight timing remains as before. This reduces the high initial
glove visit and delayed rise, with the primary Viper replay resolving blocked at .767 s again.
The comparison preserves literal input times, a fixed camera and raw clips. Whole-frame mirroring
is explicitly labeled. Source shoulder turn, head drive, stance and uncalibrated camera remain differences.
The initial slower chamber candidate delayed contact to .800 s and was superseded.

Unmarked and repeated-jab captures cover interaction with the normal straight. Capture tracking
now keys attack starts by serial rather than tag, so a jab-to-jab chain is counted twice. Per-frame
serial/time fields make that visible without inferring starts from a tag change. This audit fix has
no gameplay effect. Automated game assertion suites remain deferred.

`tools/compare_fn_reference.py` builds review evidence from a reference clip and a separately captured game frame directory. It selects the same normalized timestamps from both sources, shows the actual selected frames side by side, and records every timing offset. It does not measure poses from pixels and does not make an automatic 1:1 or pose-match claim.

## Usage

Run from the repository root:

```powershell
python tools/compare_fn_reference.py `
  --reference "C:\path\to\fightnight-reference.mp4" `
  --game "C:\path\to\game-frames" `
  --out "C:\absolute\evidence\fn-slip-compare" `
  --ref-start 4.7 `
  --ref-duration 1.8 `
  --fps 12 `
  --game-start 0.2 `
  --ref-crop 0,60,1080,1750 `
  --game-crop 260,80,1080,760
```

Use `--mirror-ref` to flip the whole reference frame when the source camera faces the opposite direction. Crop coordinates are pixels in the original source frame. The transform order is whole-frame crop, optional whole-reference flip, then one aspect-preserving contain scale for display. Bodies are never stretched, and the tool applies no pose edits or local warps.

`--reference` accepts a video or a directory of image frames. Video is decoded through ffmpeg only when video input is used; its comparison frames are written to `reference_frames/`. A frame directory is sampled without re-encoding. A game directory containing `sequence_manifest.json` uses the exact recorded frame paths and timestamps, excluding sheets and previews. Other directories assume `frame index / fps`, so pass the capture rate explicitly when it differs from 12.

The source window is deliberately split between the two produced inputs:

- Reference target time: `ref_start + normalized_time * ref_duration`.
- Game target time: `game_start + normalized_time * ref_duration`.

The six key phases are normalized at 0.02, 0.20, 0.40, 0.60, 0.80, and 0.98. They represent guard, entry, peak, hold, release, and returned guard. Choose `ref-start` and `ref-duration` around one continuous reference action. Camera cuts belong between comparison runs, not inside the window.
Use `--phase-times` with six increasing fractions to label measured events in a particular action. For the
current 4.7–5.3 s reference, `--phase-times 0.02,0.38,0.50,0.60,0.80,0.98` places entry at 4.928 s and
the actual peak at 5.000 s. This only selects labelled stills; the film retains every sampled timestamp.

## Output

The `--out` path must be absolute. The tool refuses a non-empty directory unless `--overwrite` is supplied; `--overwrite` replaces only its own known artifacts.

- `gallery.html` - static gallery with the matched-time GIF, six phase cards, timing tables, frame counts, warnings, and optional landmark results.
- `comparison.gif` - animated side-by-side pair for every sampled normalized time.
- `strips/*.png` - one high-resolution side-by-side still per key phase.
- `key_phases.png` - vertical contact sheet of the six stills.
- `manifest.json` - normalization formula, whole-frame transforms, source selection, target and selected source times, signed offsets in seconds and frames, animation samples, and frame counts.
- `summary.txt` and `summary.json` - concise run summary, frame counts, warnings, and the explicit no-claim statement.
- `landmark_measurements.json` - normalized displacement ratios when real annotated coordinates were supplied, otherwise an explicit `unavailable` result.

A signed offset means `selected_source_seconds - target_source_seconds`. A positive value means the nearest available frame occurs later than the requested normalized target. This matters around cuts, variable-rate capture, or short frame directories.

## Optional landmark coordinates

The optional landmark file contains six phase records for each source. Coordinates must be normalized `x,y` points in the post-crop source frame, with origin at top-left. With `--mirror-ref`, annotate the reference on the mirrored frame, matching what the reviewer sees. The coordinate values below show the JSON shape only; they are illustrative and must be replaced with real annotations.

```json
{
  "coordinate_space": "normalized_post_crop",
  "reference": {
    "guard_settle": {"head": [0.51, 0.20], "hip": [0.50, 0.55], "knee": [0.49, 0.77]},
    "entry":        {"head": [0.52, 0.21], "hip": [0.50, 0.55], "knee": [0.49, 0.77]},
    "peak":         {"head": [0.63, 0.24], "hip": [0.50, 0.56], "knee": [0.49, 0.78]},
    "hold":         {"head": [0.64, 0.24], "hip": [0.50, 0.56], "knee": [0.49, 0.78]},
    "release":      {"head": [0.58, 0.22], "hip": [0.50, 0.55], "knee": [0.49, 0.77]},
    "guard_return": {"head": [0.51, 0.20], "hip": [0.50, 0.55], "knee": [0.49, 0.77]}
  },
  "game": {
    "guard_settle": {"head": [0.50, 0.22], "hip": [0.50, 0.57], "knee": [0.50, 0.78]},
    "entry":        {"head": [0.51, 0.23], "hip": [0.50, 0.57], "knee": [0.50, 0.78]},
    "peak":         {"head": [0.61, 0.26], "hip": [0.50, 0.58], "knee": [0.50, 0.79]},
    "hold":         {"head": [0.62, 0.26], "hip": [0.50, 0.58], "knee": [0.50, 0.79]},
    "release":      {"head": [0.56, 0.24], "hip": [0.50, 0.57], "knee": [0.50, 0.78]},
    "guard_return": {"head": [0.50, 0.22], "hip": [0.50, 0.57], "knee": [0.50, 0.78]}
  }
}
```

Phase IDs can also be phase labels or phase numbers. `hips`/`knees` are accepted aliases, and points may be `{"x": 0.5, "y": 0.4}`. Individual joints or phases may be `null`; the report labels the corresponding measurements and phases as unavailable.

For each side, the tool sums consecutive joint-path distances in aspect-corrected normalized units and divides by that side's median head-to-hip body span. It reports the reference path, game path, and `game / reference` displacement ratio per joint. Missing coordinates, no usable head/hip baseline, a zero reference path, or an unsupported coordinate space make the affected value unavailable. The output is a motion-magnitude ratio, not a pose similarity score.

Visual parity still requires human review of the side-by-side stills and full-speed GIF. Static frames alone do not establish timing or continuity.

## Current reference alignment

The continuous source window at 4.7–5.3 seconds matches `slip_l`, viewed with `yaw=55 side=-1 elevation=35`.
Capture a short input pulse with `start=0.20 release=0.33 seconds=0.70 fps=30 width=540 height=960`.
Comparison uses `--ref-start 4.7 --ref-duration 0.6 --game-start 0 --fps 30`. This maps the source peak
at 5.000 seconds to the actual game frame at 0.300 seconds. Earlier comparisons using `slip_r` are
superseded. The source's head silhouette and the game's logical bone origin are different landmarks;
their displacement values must not be presented as a pose similarity score.

The task review contains actual rendered Viper/Anvil, both slip directions, pull, duck, analog circle,
slip-to-counter, queued counter-to-jab, blocked and half-amplitude sequences. Every input and rendered
tick is recorded in the capture manifests. The source/game films are shown at their captured rates.
No automated assertion suites were run, per the user's request. Neutral guard, stance, projection and
close opponent-arm overlap remain limits on any exact-match claim.

Current counter coverage also includes `counter_back` (pull into rear hook) and an Anvil counter.
The body-entry blend keeps the incoming hip/head posture through startup and releases towards contact,
while the live hand is saved before procedural lean. The free guard settles at boxing engagement range
and compacts as the lean deepens. `fitted_center_projections` records head/glove volume centres separately
from logical joints. Capture `ui_hidden` applies to the main HUD; world-space rocked/gassed labels stay
visible and can appear above a counter exchange.

The free-guard wrist pass uses the fitted glove axis and solves towards the forearm direction with an 8%
up-forward bias. Its maximum correction is 55 degrees, reducing to 45 for the lead hand as the slip
compacts. The fitted centre is held through a second arm solve. DeepSeek visual review preferred the
8% bias over the earlier 35% bias. A subsequent capture showed the initial 35-degree correction cap
was active throughout the pulse; relaxing it improves the remaining upright-glove silhouette. These
are corrections from the incoming animation, not anatomical wrist angles. Glove shape remains different
and source cuff occlusion limits wrist-roll inference.

## Backward pull review

The clean source hold at 7.767–8.100 seconds is a separate view from the lateral slip.
Its hip-to-shoulder/head arc and exposed jaw show a sustained backward lean and lifted chin.
The revised pull uses 36 degrees of trunk pitch and 12 degrees of extra chin lift, blended by
the backward input component. An open lead-hand target replaces the compact lateral guard
only as the input moves backward; the rear glove stays at the lower face/upper chest.
Blocking and the live striking hand keep their existing animation ownership.

Capture the front view with `scenario=back solo=true yaw=55 side=1 elevation=35 frame_offset=0`.
The source lead glove extends and retracts during the held body pose, so the fixed free-guard
target cannot reproduce the whole sequence. Source/model proportions, stance and view also
differ. The study compares sustained poses; it does not establish identical input timing or
an exact match. A separate lateral neck-extension candidate was rejected because the source
helmet/glove occlusion did not support that change.

## Additional Champion jab reference

User reference: https://www.youtube.com/shorts/K966_uJaa0A — “Three ways to use jabs!”,
Fight Night Champion. The useful continuous windows are 9.30–9.90 s and 10.17–10.70 s.
The fighter on the viewer's right uses a brief head/chin recoil followed by a straight, likely
lead-side counter. This is a guard/recoil/counter cue, not a sustained lateral-slip reference.
The foreground ropes, tracking camera, contact and motion blur leave foot travel and exact
lead/rear attribution uncertain. Do not substitute the instructional overlay for observed motion.

The Round 4 counter at 3.5–4.5 s also has a straighter visible arm path than the RHook used in
the original capture. `counter_tag=LJab` or `counter_tag=RJab` now selects literal jab/cross
captures, while the existing default RHook still covers the authored counter clips.

Those captures exposed a lean-layer defect: a normal head straight inherited the complete
trunk fold and drove down toward the body. Jabs/crosses now uncoil from full lean to 15% across
15–95% of their contact-peak time, reloading near recovery if the input remains held. The
striking hand's pre-lean transform supplies the IK target and global facing; ordinary straights
respect reachable arm length without translating a wrist bone. Body-jab targets retain their
own action height. Kicks and hook/uppercut lean behavior are outside this correction.

For the primary Round 4 counter, a marked counter retains 40% of the loaded lean through
extension; an ordinary straight retains 15%. The source keeps its head low through contact.
The current order fixture uses incoming `opponent_tag=RJab opponent_time=0.30`, loaded
`scenario=counter_l start=0.20`, return `counter_tag=LJab counter_time=0.55`, and `release=0.80`.
Source time maps to `3.5 + actual game time`, without retiming. The incoming strike misses
and the return straight reaches the guard around game 0.767 s / source 4.267 s. Earlier return
fixtures either got hit or resolved five frames late; those are documented as historical trials.
The source incoming anatomical hand remains unresolved, and its rotating camera differs from
the static game view. One matching contact frame does not establish full trajectory parity.

`opponent_tag` is optional; an empty value retains the earlier direction-specific coverage
pairing. Both actual action requests are recorded in the schedule and manifest. Capture scenes
use `capture_fn_main.gd` so focus loss cannot silently pause a background capture. Ordinary
gameplay retains its focus-loss pause. No test assertion suites are invoked by these utilities.

Four side-view captures show lead/rear straights, Anvil and pull-to-lead straight. They compare
implementation behavior and anatomy; their camera, opponent behavior and input timing are
not an exact reconstruction of the Champion exchange. Exact reference parity remains open.

## Uncovered front reference

The Round 4 short at 22.20–24.10 s supplies a near-frontal neutral/lean/recovery with the face
uncovered. The motion goes to image-left (the fighter's right), with a slight chin drop and
forward-readable gaze. The high rear glove stays beside the cheek/jaw while the other glove
sits lower. The free rear glove's lateral fitted-centre target is now -0.18 m rather than
-0.11 m, preserving the existing 85% blend, so it does not obscure as much of the face.

The two frontal coverage shots use `scenario=slip_r amplitude=0.5 solo=true yaw=10 side=1
elevation=8 fullbody=false frame_offset=0`, for Viper and Anvil. The source input amplitude
is unknown and its camera reframes, so this is a guard-visibility study rather than an exact
camera or timing reconstruction. The source hides knees and feet; it cannot validate stance.

A pre-lean elbow-pole candidate and extra lateral neck-extension candidates were rendered and
rejected because they showed no clear supported improvement. The existing lateral neck and
straight-counter elbow treatment are retained. The source does not resolve exact 3D joint
contributions, despite the clearer face view.

## Compact straight-counter reach

Consecutive source frames 4.133–4.400 s retain a visibly flexed counter elbow and a compact
forward/rising glove path. Foreshortening and opponent overlap prevent exact source joint angles.
Five existing jab/spacing trials were rendered before changing the reach: their timing and
outcomes differed, but the tested jab clips still approached full arm extension.

Near-range marked head jab/cross counters now limit shoulder-to-wrist reach along the existing
strike lane, blending from 99.2% of arm length at a current root gap of 0.95 m to 88% at 0.80 m.
The solve retains arm segment lengths and wrist facing; it does not translate the wrist bone.
Body jabs, ordinary unmarked straights and authored hook-counter clips retain their existing
paths. Actual glove geometry still determines whether contact is blocked, landed or missed.

A controlled 0.85 m starting-gap side-view comparison retains the existing sampled guard
contact at 0.767 s while the game elbow stays more flexed through extension. These measurements
describe game joints only; they are not source target angles. The primary Viper/Anvil replays,
body jab and farther starting-gap case are rendered separately. A far initial gap can close
into the near region during the lunge, so the cap follows the live gap rather than the initial
capture setting. The source still has a clearer chambered drive toward the head; a compact
guard contact and matching contact time do not establish exact source correspondence.

Capture manifests now include shoulder/elbow positions and `counter_reach_trim`; `gap` changes
only the initial capture spacing and is recorded in `input_options`. Default spacing stays 1 m.


## Sustained lateral slip guard

The Round 4 counter at 3.967–4.133 seconds shows a separated high and low glove as
the boxer remains loaded. A short pulse in the overhead reference has a higher low glove.
A held lateral input now lets the lead free glove settle up to 6 cm lower, starting only after
0.10 seconds in a deep lean and blending in by 0.22 seconds. The timer clears on a change
of side, drains on release, and resets outside standing states. The blocking guard and the
striking hand are still owned by their existing layers.

An approximate moving capture camera was chosen from multiple static views; it is not a
reconstruction of the source camera. In the Viper/Anvil primary fixtures the sampled
counter outcome remains blocked at 0.767 seconds for the smaller candidate. The larger
12 cm candidate altered Viper's sampled outcome and was removed. Short-slip overhead
samples and both slip directions, half amplitude, blocking and release were visually reviewed.
Different model proportions, stance, hand sides and source camera movement still prevent
a 1:1 claim. Close-range arm overlap remains open; gameplay code assertion tests are deferred.


## Primary acceptance and full-body stance check

The user delegated the choice of acceptance action. Use the Round 4 planted slip into a straight
counter at 3.5–4.5 s as the primary comparison, with Champion as a secondary recoil/straight cue.
The later 0.40 s slip-onset fixture is a closer onset hypothesis than the earlier 0.20 s replay;
source controls and exact camera remain unknown. Both are comparison fixtures, not gameplay presets.

Same-camera full-body captures show Viper and Anvil left-foot-forward at neutral, during the slip,
and after release. The logical left foot is approximately 0.58 m ahead of the right foot in the
neutral samples. Anvil's roster text calls it southpaw, but that text does not demonstrate a
right-lead pose. The source fighter's anatomical lead remains uncertain in the occluded moving view.
A whole-frame horizontal flip aligns screen-facing only; it does not swap the fighter's anatomical
sides. True stance support would need coherent animation, input and strike attachment/guard behavior;
a visual-only flip is not evidence of working southpaw combat. No stance code was changed here.
See the task's stance-fullbody-review.jpg and stance-fullbody-review.json for the rendered evidence.

A maximum-effort DeepSeek implementation audit found that Anvil's southpaw label is descriptive
text. The project defines stance actions, but fighter input/controller do not consume them; the
documented stance switch is absent, and GuardStyle and LeanPose assume the left hand is lead.
Both physical-side strike hitboxes exist. A real stance change requires animation and combat-side
coordination and later verification; this pass did not introduce a cosmetic-only mirror.


## Close-contact endpoint investigation

A capture-only 120 fps diagnostic samples the Meshy elbow/wrist joint line against fresh fitted head
and neck hulls. In the Anvil coverage fixture the deepest centre-line crossing at 0.575–0.650 s is
82.5–95% of the way from elbow to wrist; the wrist itself enters the fitted hull before the sampled
fist sphere resolves contact. This geometry limits an elbow-only correction when the hand stays
fixed. The impact outcome and hull samples are specific to this fixture, and joint lines and fitted
hulls are not a mesh intersection measurement. The corrected elbow-to-fist vector angle at 0.600 s
is about 36 degrees; that alone does not establish an unnatural wrist orientation.

An initial diagnostic mistakenly requested an uncached driver elbow and produced script errors;
those measurements were discarded. The corrected capture uses the Meshy joint, completes without
script errors and matches the earlier sampled outcomes. No gameplay adjustment was retained in this
investigation; a maximum-effort DeepSeek review identified possible bounded elbow work but confirmed
that it cannot clear an endpoint already inside the head proxy. See forearm-axis-contact-review.jpg
and .json in the task review. Code assertion tests remain deferred.


## Short-range strike-path trials

A same-camera Anvil coverage exchange was rendered with two experimental reductions of the wrist
path near a head hull. Both 0.16 m and 0.06 m caps bent the elbow sharply and advanced sampled hit
timing from .633 to .600 s at 30 fps. A separate candidate rotated the wrist around the fitted fist
centre, with a 25-degree or 12-degree limit. In this one replay the sampled fist centre and outcome
matched baseline and the forearm proxy improved briefly at .567 s, but the .600 s deepest crossing
was unchanged. These are sparse observed samples, not proof about all fist trajectories, and the
proxy is not a mesh intersection. Both candidates were removed, leaving the previous gameplay.
The matched frames and measurements are in the task visual review. No code assertion suites ran.


## Gradual analog entry comparison

A capture-only `counter_analog_ramp` option drives existing analog input from zero to `amplitude`
over the requested duration. Default digital counter captures are unchanged. In a 0.20–0.52 s ramp,
both fighters move earlier and more gradually than in the 0.40 s full-input fixture while both
sample a blocked counter at 0.767 s. The source shows an early head and upper-body lead; the
ramp also moves hips and does not independently reproduce that separation. Source input is unknown,
the camera orbit is approximate and the whole game frame is mirrored. The film retains actual sample
timing. Independent DeepSeek review of the phase sheet found gradual progression but did not
establish exact phase accuracy. Sampled outcomes are not code-level contact verification.

An experimental delayed counter rise (40–90% of peak time) kept the boxer more folded in startup
and delayed Anvil's sampled blocked counter from .767 to .800 s. It was removed; the game retains
the previous 5–40% rise. No automated assertion suites ran.


## Terra full-body phase prototype

At the user’s request, GPT-6.1 Terra agents worked at high effort on the motion and asset audit.
A prototype coordinated hip, torso, neck and foot phases and was rendered in the same analog-ramp
fixture for both fighters. Its deeper entry is visible, but the incoming punch hits at .567 s in
both captures. The requested return begins at .617 s as an unmarked attack rather than the .550 s
marked baseline counter; its first sampled hit is .867 s versus the baseline blocked counter at
.767 s. A second, earlier-unwind parameter set produced identical sampled poses because the
prototype only uses its drive phase for a marked counter, which was not present. Independent Terra
visual review found the prototype too hunched through counter/recovery. Both variants were removed
from gameplay, and the candidate source and captures remain in task scratch. The same-camera footage
is linked in the task review. No game assertion suites ran.


## Terra defensive clearance follow-up

Same-input 60 fps traces put the original prototype head 6–8 cm nearer the punch line than
the baseline before contact. Added lateral-hip candidates were rendered for both fighters:
4 cm still showed an Anvil incoming hit; 6 and 8 cm avoided the sampled hit, though Anvil’s
blocked counter sampled at .733 s instead of .767 s and the pose read more squat-like.
A torso-yaw candidate alone cleared Viper but not Anvil; a 3 cm lateral shift combined with
the yaw change preserved the sampled .767 s blocked counter and incoming miss for both.
Independent Terra review described only a modest entry improvement and no clear transition
improvement. A smaller coordinated change applied to the existing lean produced no clear
visual improvement. All candidates were removed; full-body comparisons, playback and sample
records are linked in the task review. Code assertion suites remain deferred.

## Fixed-camera follow-up

Source background features move only a few pixels over 3.500–4.500 s. A fixed-camera
Godot replay exposes substantial remaining fighter-turn and forward-lean differences; camera
angle, inputs, stance and proportions are still not matched. A 4 cm lead-glove experiment
did not visibly resolve the larger silhouette mismatch and was not adopted. The review package
contains the source/game video, phase sheet, background measurements and candidate capture.
An eight-second CPU exhibition showed an early backward lean and uppercut, then extended
close-range idle, so it does not establish natural lateral-slip frequency or overall fight quality.
No automated game assertion suites were run.

## Phased slip-to-counter turn

The marked left-slip lead-straight counter now adds a phased hip and spine turn. The turn
keeps the animated foot origins and orientations and pins the striking hand position and
orientation through the additive pose. A defensive input during the existing attack keeps
the same turn envelope, avoiding the snap seen when its input gate was cleared mid-attack.
In two specific Viper/Anvil visual captures, incoming strikes missed and counters hit at
the same sampled times as baseline; fitted pre-contact glove-center paths differed by at
most 0.28 cm. Viper paths diverged after contact, with up to roughly 16 cm sampled and 15 cm
for the drawn attachment; that remains a risk rather than a general equivalence claim.
An isolated 120 Hz block transition reduced one-frame head movement from 5.14 to 0.21 cm.
The review package includes source/old/new frames, gameplay-camera capture and limitations.
The source camera, stance, pose and timing are not matched 1:1. Code tests remain deferred.
