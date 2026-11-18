# Slip match iteration log

Goal: the game's slips match the Fight Night Round 4 slip animation (reference clip `fightnight4-slip-dodge-short.mp4`)
at 9/10 from both graders (Haiku 5.5 high, Sonnet 5.5 medium) on the same version, then a fresh confirmation round.
Executor: Sonnet 5.5 (high). Orchestrator/reviewer: Opus 5.5.

## Setup (fixed every round)

- Worktree `knocknight-slip`, branch `fn2/slip-match`. Round 0 = uncommitted Blender-authored slip work (commit 2dac80a).
- Capture: `bash tools/slipmatch/capture_round.sh N` -> `_build/slipmatch/rN/`. Model meshy_anvil, 720x1280, 30 fps, `--fixed-fps 120`,
  deterministic input timeline (lean input from 0.20 s; release 1.05 s for A, 0.65 s for B, 0.33 s for C).
- Composites: reference left, current right, same real-time offset. `key.jpg` (8 instants), `dense.jpg` (15 fps), `sbs.gif` (30 fps).
  - A: front view, held slip, head to screen-left. Ref 22.85-24.25 s. Game `slip_r`, front camera (look_y 1.40, dist 2.15).
  - B: front view, quick slip, head to screen-right. Ref 24.40-25.40 s. Game `slip_l`.
  - C: rear 3/4 elevated view, slip under a punch. Ref 4.70-5.30 s. Game `slip_l` with opponent, yaw 100 side -1 elevation 38.
- Round score = lower of the two grader scores.

## Score history

| Round | Haiku | Sonnet | Round score | Best so far | Commit |
|---|---|---|---|---|---|
| 0 | 4 | 5 | 4 | 4 (r0) | 2dac80a |
| 1 | 4 | 4 | 4 | 4 (r0/r1) | b4f106b |
| 2 | 5 | 4 | 4 | 4 (r0-r2) | de04020 |
| 3 | 4 | 5 | 4 | 4 (r0-r3) | 94527d2 |
| 4 | 5 | 4 | 4 | 4 (r0-r4) | 64ce463 |
| 5 | 5 | 4 | 4 | 4 (r0-r5) | 848bba9 |
| 6 | 4 | 5 | 4 | 4 (r0-r6) | 380b70c |
| 7 | 4 | 5 | 4 | 4 (r0-r7) | a756d61 |
| 8 | 4 | 4 | 4 | 4 (r0-r8) | 307dee6 |
| 9 | 4 | 5 | 4 | 4 (r0-r9) | 1e481e1 |
| 10 | 4 | 5 | 4 | 4 (r0-r10) | 69f590f |
| 11 | 4 | 4 | 4 | 4 (r0-r11) | 68ce349 |

## Round 0 - baseline (Codex's Blender-authored slips + procedural lean)

- Change: none (baseline). Captures: `_build/slipmatch/r0/{A_front_slip,B_front_slip,C_rear_slip}/{key,dense}.jpg`.
- Orchestrator review: slip is a forward fold (lean_pose PITCH_SIDE 35 deg forward + DROP_SIDE 0.15 m + authored GLB hunch), lateral roll only 20 deg;
  entry reaches full depth in ~0.13 s (BASE_W 24) vs reference ~0.35-0.4 s; return ~0.18 s vs ~0.4 s; hold is a frozen plateau.
- Haiku (4) top 3, verbatim:
  1. "Trunk and neck (Clip A +0.20-+0.80, Clip C +0.27-+0.40, Clip B +0.30-+0.57): The CURRENT upper body bends forward as one rigid block (hunch) and the head drops mostly straight down. REFERENCE trunk leans laterally toward the slip direction with a visible shoulder drop on the slip side, and the head travels on a curved arc with the neck lagging the chest. Add lateral spine curvature and shoulder roll toward the slip direction, reduce forward pitch of the upper back, and let the head arrive ~0.05-0.1 s after the trunk. Worst in Clip C +0.27-+0.40 where the back reads as a bulging hump with no shoulder definition."
  2. "Hips and knees (all clips): CURRENT waistband/hip line stays nearly constant height through the slip... REFERENCE drops the hips and flexes the knees... Add ~15-20 deg knee flexion and a hip drop of around 10-15% of body height at peak, with the hips shifting opposite the head direction (for Clip A, hips move screen-right/back while head goes screen-left)."
  3. "Timing and hold (Clip A and B): In Clip A CURRENT reaches full depth by ~+0.27-+0.40 s while REFERENCE reaches it around +0.6-+0.8 s; from +0.40-+0.80 CURRENT is almost frozen while REFERENCE keeps drifting/settling. Delay the entry so peak depth lands near +0.6 s and keep a slow sinusoidal drift during the hold (a few degrees of trunk/head motion) rather than a flat plateau. In Clip B CURRENT bottoms out at +0.27-+0.40 s vs REFERENCE +0.43-+0.57 s and returns upright earlier (~+0.67 vs ~+0.8 s) - shift the bottom ~0.1-0.15 s later and extend the deepest hold by ~0.15 s."
- Sonnet (5) top 3, verbatim:
  1. "Replace the trunk-folded-over-sideways shape with the reference's lateral lean + rotation toward the slip side. In A and B, CURRENT collapses forward/sideways (~+0.20 to +0.80s) with head dropping below the shoulder line, chest tucked, head ending near hip level; REFERENCE keeps the head roughly at shoulder height, clearly above the belt, with the trunk shifting/leaning ~15-25 deg with a shoulder dip, neck staying upright against the trunk, and knees bending to lower the whole body ~10-15%. Concretely: cut spine/neck forward flexion by ~half and replace it with lateral flexion + lateral head translation; in B at +0.30-+0.57s CURRENT's head is nearly behind the lead glove and below shoulder - it's an overdone duck, not a slip. Cap head drop to about chin-to-shoulder height."
  2. "Fix timing/hold: In A, REFERENCE is mostly out of the slip by +1.0s and settled into guard by +1.2s, while CURRENT is still deep in the slip at +0.80-+1.0s and doesn't recover until ~+1.2-+1.4s; entry is also slower... In B, CURRENT hits its peak at +0.30-+0.57s, roughly aligned, but returns upright by ~+0.7s slightly before REFERENCE... stretch the return slightly (~0.1s later) so it reads as a flowing arc rather than a pop down/up."
  3. "Keep the guard/arms alive and give hips/knees an obvious role: In CURRENT the rear glove stays stuck at ear level and the lead arm sits in a fixed forward position; in REFERENCE the hands tuck and follow the body (lead glove drops in to guard chin, rear glove rides with the torso). In C (rear view), CURRENT shows a big rounded hunched-back blob at +0.27-+0.43s... Add a visible pelvis offset (~5-10cm toward the slip side), hip rotation, and 15-20 deg knee flexion; reduce the hunch/keep the scapular line flatter in C."
- Plan for round 1 (score < 6: structural rework): rebuild the lateral slip as lateral trunk flexion + shoulder dip with the head on an arc
  (neck follows the trunk with a short lag), forward pitch roughly halved, head drop capped near chin/shoulder height, knee flex + hip drop and
  hip shift opposite the head; slower eased entry/return (~0.35-0.45 s) and a breathing hold; fix the rear-view hunch.

## Round 1 - procedural lateral slip (score 4: Haiku 4, Sonnet 4; no gain)

- Change (from r0 feedback): authored GLB slip pose disabled (`APPLY_AUTHORED_POSE=false`); lean_pose lateral slip rebuilt: side-bend 28 deg,
  forward pitch 12 (was 35), pelvis shifts opposite the head (-0.075 m), hip drop 0.085 m, lagged loose neck (tau 0.075 s), separate side spring
  (W_SIDE 19 + 0.035 s pre-filter, 88% at once then 0.5 s creep), breathing hold. Captures `_build/slipmatch/r1/`.
- Orchestrator review: A reads lateral now and timing is close, but the head still bows (top of skull visible); C almost no motion (tap input,
  slow side spring).
- Haiku (4) top 3, verbatim:
  1. "Fix the slip shape in Clip A (and C held frames): Reference slip is a lateral side-bend (trunk banks toward screen-left, shoulder drops, neck tilts with the head, hips shift with it); CURRENT is mostly forward flexion with the head tucked down and forward (top of skull visible at +0.60-+0.87s). Shift spine bend from chest-forward flexion to lateral flexion toward the slip side and let the head lead the neck — target at A hold (+0.73-+0.80s) head-to-hip lateral offset roughly 2x current, with face still visible to camera."
  2. "Timing in Clip B and A return: In B, reference motion spans ~0.07s to ~0.80s, but CURRENT starts late (~+0.20s), peaks ~+0.33-+0.40s, and is already upright by ~+0.53-+0.60s — total slip ~0.4s vs reference ~0.7s. Move onset ~0.13s earlier and push the return ramp out to ~+0.6-+0.87s. In A, CURRENT starts ~0.07s early and returns to upright by ~+1.20s while reference is still lowered until ~+1.20s — slow the A return by ~0.1s and lengthen the held bottom by ~0.1-0.15s."
  3. "Hip/knee mechanics: In Clip C all 8 CURRENT frames show legs/hips essentially static, while reference drops hips/bends knees to dodge under the punch (deepest ~+0.33-+0.43s). CURRENT dip is shallow (~10% of standing height vs ~25% in reference) and over by ~+0.43s vs reference ~+0.50-+0.60s. Add knee flexion and hip drop of ~10-15 deg at the slip bottom, deepen the dip to match, and extend the return; the same hip drop should be present in A +0.60-+0.87s where the reference visibly sinks hips/knee."
- Sonnet (4) top 3, verbatim:
  1. "Make the whole body carry the slip, not just the upper trunk/head (all clips, worst in C): In the reference, the pelvis shifts laterally ~10–15% of body width, knees flex, weight transfers over one leg, and the trunk side-bends from the waist, so shoulders end well below/beside the hips. In CURRENT, the shorts/belt line and legs stay almost planted; only the chest/head fold. Add pelvis lateral translation + roll and a 10–20° knee bend with a 4–8 cm hip drop, starting at the same time as the trunk and peaking with the head. In Clip C the reference shows a clear crouch-and-lean from +0.17s to +0.50s; CURRENT is nearly static (only a small torso twist, legs/hips identical from +0.00s–+0.60s) — this needs a much larger amplitude, roughly 3x or more."
  2. "Neck and head: In CURRENT (A, +0.40s–+1.00s) the head is tucked down into the shoulder and chest folds around it — the shoulder shrugs and neck compresses, reading as hunched/rigid. In the reference the head stays upright and level-ish (neck counter-tilts ~15–25° against the trunk lean, eyes stay on the opponent). Remove the shrug, add neck counter-rotation so the head stays closer to vertical, and keep head lateral travel larger than chest travel — currently head sits too close to the sternum."
  3. "Guard hold + timing/return: In Clip B CURRENT, from +0.30s–+0.57s the lead arm sweeps out sideways and the rear arm flings away from the body; the reference keeps both gloves tight and high in front of the face, arms riding with the trunk. Pin hand IK/arm targets to the chest/head frame so the arms follow the lean but stay compact. For timing: Clip B CURRENT is fully back to guard by ~+0.70s while the reference is still recovering until ~+0.87–1.00s — slow the return and add ease-out into the guard with no overshoot..."
- Orchestrator reading of the references for round 2: the front view foreshortens forward pitch. In A/B the reference face stays fully
  visible and looking at the opponent while the shoulders tilt and the upper back shows (trunk pitched toward the camera); the rear view C
  shows the same slip as a big forward-down dip. So the target is trunk pitch ~20-30 deg + side-bend ~25 deg + yaw ~10 deg, with the NECK
  EXTENDING so the face stays toward the opponent (eyes roughly level), knees bending, pelvis dropping ~5-6 cm and shifting opposite.
  Timing: the front-view player eases the stick (~0.35 s entry); the rear clip is a flick (bottom in ~0.16 s).
- Capture setup fix for round 2 onward (one-time, logged): front clips A/B now ramp the stick like a thumb (`lean_ramp` 0.30 s for A,
  0.25 s for B, smoothstep in from start and out from release); clip C stays a step. A/B timing is not comparable with r0/r1.
- Plan for round 2 (score < 6, no gain: change technique): fast step response with an S-curve (bottom ~0.17 s, no pop), so the stick ramp
  provides the A/B flow and C gets a full deep slip; follow-through chain (pelvis -> lumbar -> thoracic -> neck -> head, each lagging) instead
  of one rigid rotation; neck extension to keep the face up; visible knee bend/pelvis drop and shift; compact gloves that ride with the head.

## Round 2 - follow-through chain + stick ramp (score 4: Haiku 5, Sonnet 4; no gain, 2nd round without gain)

- Change (from r1 feedback): pelvis -> lumbar -> thorax -> head follower chain (head = underdamped spring, ~0.055 s lag); fast side spring
  (W_SIDE 27, bottom ~0.14 s after a step); trunk pitch 27 / side-bend 25 / yaw 10 at full input; neck extension (head keeps ~none of the
  trunk pitch, 0.4 of the roll); pelvis 5.5 cm opposite + 7.5 cm sink; compact gloves. Front captures now ramp the stick (setup fix).
  Captures `_build/slipmatch/r2/`. Measured head displacement at peak: A 0.29 m, B 0.24 m, C 0.24 m (C mostly hidden by the rear camera).
- Haiku (5) top 3, verbatim:
  1. "Torso/hip mechanics (all clips): The reference shows lateral trunk lean toward the slip side with counter hip shift and knee flex, while CURRENT keeps legs nearly straight and bends forward into a hunch. Clip A: reference peaks ~+0.6–1.0s with a sideways lean (head to screen-left, low on the left) — current peaks at similar time but reads as forward hunch with head tucked behind gloves. Clip B: reference leans right at +0.30–0.43s, current stays more upright/tilts forward. Clip C: reference drops at hips/knees ~+0.17–0.33s, current keeps legs straight. Add lateral lean with counter-hip shift and knee flex, weighted toward the slip direction, and reduce the forward bend."
  2. "Neck/upper-body stiffness (Clips A and C, frames ~+0.6–1.0s in A, ~+0.27–0.6s in C): CURRENT's head moves as a rigid block sitting on the shoulders, and the back/shoulder mass reads as a rounded inflated hump in the rear-3/4 view. The reference shows the head leading with the neck flexing and the shoulders following with slight lag, plus visible chin tuck. Make the head lead the trunk by ~0.05–0.1s and add neck tilt, and reduce upper-back/trapezius deformation so shoulders stay flatter through the hold."
  3. "Recovery and punch timing (Clips B and C): In Clip C, the reference is already rising by +0.43–0.5s while CURRENT stays hunched through +0.6s — the return is late and holds too long. In Clip B, the reference dips to screen-left after the right slip (~+0.57–0.70s), but CURRENT dips center/forward, so the trough direction is wrong..."
- Sonnet (4) top 3, verbatim:
  1. "Add real lateral + vertical travel of the whole upper body (biggest gap, clips A, B, C). In REFERENCE the trunk side-bends and the head/chest shift ~25–35% of body width sideways (A: head drops ~15–20% of head-to-belt height; B: head and chest travel strongly to screen-right). In CURRENT the head mostly bows forward/sinks between the shoulders and moves only ~10–15% sideways; the torso stays an upright bulky block..."
  2. "Make the legs/hips participate, especially clip C where CURRENT barely moves. In REFERENCE rear view, from +0.17s to +0.43s the hips rotate and shift, knees bend, stance changes and torso folds; in CURRENT legs/feet/hips are essentially static... Add knee flexion ~15–25°, hip shift toward the slip side, weight transfer to the front foot, and pelvis yaw ~10–15° opposite the head slip..."
  3. "Let the guard/arms respond and shape the timing curve... In CURRENT the glove positions are almost frozen relative to the screen, which causes much of the rigid look. Add follow-through on shoulders/arms/gloves (2–3 frame lag), and neck counter-tilt so the head leads and the chest follows... add slight overshoot at the peak, micro-drift during the hold, and an ease-out return with slight overshoot past neutral."
- Orchestrator: reference guard/peak overlays put the clip A head ~2 head widths sideways at peak (ours ~1), clip B ~1.1 head widths sideways +
  ~0.9 head heights down, with the face looking up/out (chin lifted relative to a pitched trunk). The game's peak silhouette is the gap.
- Plan for round 3 (technique change after 2 rounds without gain): fit the PEAK POSES first, statically, to the reference peak frames in all
  three views (A +0.60, B +0.47, C +0.33) using per-bone authored target poses (pelvis, 4 spine bones, collars, neck, head, knees) blended by
  the eased stick, instead of global pitch/roll parameters; lateral head travel roughly doubled, shoulders depressed (no shrug), chin lifted,
  knees visibly bent; then keep the r2 chain timing.

## Round 3 - peak poses fitted to the reference silhouettes (score 4: Haiku 4, Sonnet 5; no gain, 3rd round without gain)

- Change (technique change): static fit of the peak poses to the reference peak frames; stabilised lagged head (world orientation from the
  head follower, 13 deg ear-to-shoulder roll, 7 deg chin lift) so the face stays up with a visible neck; collars depressed 14 deg (+6 slip
  side); trunk side-bend 22 / pitch 27 / yaw 10, slip-side shoulder dip 6; pelvis 5.5 cm TOWARD the slip side + 7 cm sink; gloves lower and
  framing the face. Captures `_build/slipmatch/r3/`. Commit 94527d2.
- Haiku (4) top 3, verbatim:
  1. "Add knee bend and hip drop to every slip (Clip C & A primary): In C, reference shows clear knee flex + hip lowering as the fighter goes under the punch (~+0.27–0.43s); CURRENT keeps both legs nearly straight through the entire bend. In A, reference drops hips/knees at +0.60–1.00s while CURRENT stance stays tall. Add ~15–25° knee flexion at slip peak with hip drop and slight hip shift opposite the head direction, keeping rear heel planted."
  2. "Make the spine/neck articulate progressively instead of bending as one rounded block: In C (+0.27–0.50s) and B (+0.43–0.57s), CURRENT forms a hump from upper back to shoulders with the head sunk into the shoulder mass (no visible neck). Reference keeps the back more erect and bends from the waist with the head tilting forward and leading the trunk. Drive the bend pelvis->lumbar->thoracic->neck, let the head lead the rotation, and reduce trapezius rounding so the shoulders stay roughly level."
  3. "Fix the return timing and B slip amplitude: In A, reference is already upright by +1.20s while CURRENT is still low/hunched at +1.20 and only recovers by ~+1.40s (return lags ~0.15–0.2s). In B, reference starts moving by +0.00–0.13s and peaks ~+0.43–0.57s with a much deeper head drop, while CURRENT holds upright until ~+0.2s and its dip is visibly smaller. Start B entry ~0.1s earlier, increase head/trunk displacement at peak, and use a faster ease-out on return."
- Sonnet (5) top 3, verbatim:
  1. "Fix lateral trunk/head travel and the lean direction (Clips A and B, entry through peak)... CURRENT moves the head only about half that far laterally and mostly hunches forward - the back rounds into a hump (visible at +0.8-1.0s) instead of the trunk side-bending. Add side-bend/lateral shift at the spine/chest (~25-30 deg) and pelvis translation (~1/3 shoulder width toward the slip side), and reduce the forward hunch/chest-down pitch by about half."
  2. "Lower the whole body into the slip (hips/knees)... CURRENT's belt line, hips and legs barely move in A, B and C - it reads as an upper-body animation on a fixed pedestal, which is the 'stiff/strong' look. Add a hip drop (~8-12% of leg length), knee flexion (~15-20 deg both legs), and a pelvis yaw/roll in the slip direction peaking with the head..."
  3. "Retime the curve and free the neck/head... In A the pose is nearly frozen from +0.6 to +1.0s (no settling/drift). In B CURRENT peaks later and returns slower (at +0.87s reference is already back in guard while CURRENT is still shifted)... Let the neck lag the trunk and counter-tilt so the eyes stay level and on the opponent..."
- Orchestrator review: A is the best clip yet (face visible, head well to the side, gloves tucked); the return is late. B swings the head far
  right with the lead glove over the face. C shows nothing useful: the rear capture camera sat behind the fighter, so every frame was a hump
  of back muscle.
- 3 rounds without gain: re-study of the references. The fundamental differences are:
  (1) The C camera was mis-framed. The reference camera sees the fighter's right flank in profile, with a chest sliver and the face in
  profile; ours (yaw 100) saw his back. Yaw 75 matches.
  (2) C in the reference is a forward-down slip under the punch: the waist folds about 40-45 deg, the head drops about 1 head height and
  the knees bend. The input was pure lateral, but the reference player clearly pushed diagonally.
  (3) The reference bends at the HIP (hip hinge, back fairly flat, shoulders level). We curl the thoracic spine, which turns meshy_anvil's
  big trapezius and back mass into a hump and buries the neck. This is the "strong"/rigid look every grader names.
  (4) The legs never visibly bend. The 7 cm sink is lost in the stance; the reference knees flex 15-25 deg with a clear belt drop.
  (5) Released thumbsticks spring back to centre; our 0.30 s release ramp made every return late.
- Capture setup fix for round 4 onward (logged, one-time, input and framing alignment only):
  - C camera yaw 100 -> 75.
  - C input is diagonal (x 0.85, forward 0.55), a flick as before.
  - A and B release the stick in 0.06 s (`release_ramp`); the entry ramps are unchanged.
  - B composite game-start 0.10 -> 0.18, to align the onset with the reference.
- Plan for round 4 (new angle): hip hinge instead of a spine curl. Most of the forward pitch goes into the pelvis/hip joint with the thorax
  nearly flat (chest flexion at most about 6 deg), and the side-bend goes into the lumbar plus a pelvis tilt. Deep, visible leg action:
  hip sink about 12-15 cm at full slip, with feet planted and knees bending 15-25 deg, and weight onto the slip-side leg. The forward-diagonal
  slip-under must produce reference C's fold and head drop. The return comes from the game's own release dynamics: reach upright about
  0.25-0.35 s after the stick snaps back, with no pop.

## Round 4 - hip hinge, visible legs, slip-under, snap-back release (score 4: Haiku 5, Sonnet 4; no gain, 4th round without gain)

- Change (new angle after the re-study):
  - Forward pitch is split 62% pelvis (hip hinge, feet re-planted so the knees flex), 25% lumbar and 13% thorax (capped at 6 deg).
  - Side-bend is moved low: pelvis roll 8, lumbar 15, thorax 3. Collars are depressed 12 deg.
  - Hip sink is 9 cm lateral plus 13 cm x forward; the pelvis goes 4.5 cm onto the slip leg and 5 cm back; pelvis yaw 8 deg.
  - Faster eased release, and a stronger settle/breath in the hold.
  - Capture alignment from the r3 re-study applies.
  - Captures `_build/slipmatch/r4/`, commit 64ce463.
- Haiku (5) top 3, verbatim:
  1. "Add hip drop and knee flex to the slip. In Clip C (rear 3/4, +0.17 to +0.50s) the reference drops the belt line and flexes both knees with feet planted; CURRENT bends only at the waist and keeps the legs nearly straight..."
  2. "Make the spine and neck follow through instead of moving as one rigid block. In Clip A at +0.40 to +0.60s the CURRENT head is fused to the shoulders and the trunk tilts as a unit. In Clip A and B the lateral amplitude is too small... Also fix the back 'hump' in Clip C at +0.27 to +0.60s, where a bulge over the shoulder blades reads as a mesh deformation..."
  3. "Correct timing and guard follow-through. Clip A entry is late... Clip B entry is also late... Clip C bottom arrives early... the rear glove in Clip A drops toward the chest/hip during the reference's peak (+0.40 to +0.80s) while CURRENT keeps it pinned near the chin. Let the guard hands travel with the trunk."
- Sonnet (4) top 3, verbatim:
  1. "Replace the rigid block-rotation of the upper body with a real spine and neck chain (biggest). In A (+0.40 to +1.00s) and C (+0.27 to +0.43s) CURRENT bends the whole torso as one lump. The shoulder/upper-back mass balloons into a huge rounded hump... Add a clearly delayed neck counter-tilt so the eyes stay level..."
  2. "Add lower-body involvement. In A and B the REFERENCE hips shift sideways and the knees bend... In C the REFERENCE legs bend and the feet re-plant. CURRENT's legs look straight and stiff."
  3. "Fix the timing and peak depth. A: ... the hold is nearly frozen (0.60 to 0.93 frames are almost identical)... B: CURRENT travels farther off the side with the whole upper body leaning out (head near the frame edge at +0.43s) and then snaps back by +0.70s. Reduce lateral displacement... add a longer ease-out return."
- Orchestrator review: C is framed correctly now and folds at the waist; A's return lands near the reference's. B over-travels sideways.
  A roster check (all 5 Meshy models, same C slip) shows the hump on every model at the slip bottom. So it is our pose, not the mesh: the
  stabilised head stays upright while the trunk pitches ~40 deg, so the neck hyperextends and drives the skull back into the trapezius. In the
  reference the head keeps most of the trunk pitch and leads forward past the shoulder line.
- 4 rounds without gain, so the technique changes: measurement-driven fitting. New tool `tools/slipmatch/posecurves.py` runs MediaPipe's
  pose landmarker on both sides of every composite and plots body-unit curves (`_build/slipmatch/rN/{A,B,C}_curves.png`). The graders still
  see only the composites. The hip landmark is unreliable on our model (the manifest says the A hip sinks 10 cm; the pose model reads more),
  so only the upper body and knees are used. Findings from r4:
  - **A:**
    - The reference trunk line keeps leaning through the "hold": -10 deg at +0.35, -20 at +0.5, -30 at +0.65, -38 at +0.9. Ours plateaus at -15 to -18 from +0.5.
    - The reference shoulder line stays at only -10 to -13 deg (ours -30): the upper body slides over with level shoulders and does not roll.
    - Eye line: reference -25, ours -35 to -40 (head over-rolled).
    - Head x from hip-mid: reference -0.85 TL at +0.85, ours -0.72 plateau.
    - Return: reference +1.0 to +1.4 smooth, ours +1.0 to +1.2 (too quick).
  - **B:**
    - Head lateral change: reference 0.54 TL, ours 0.70 (overshoot about 30%).
    - Trunk lean: reference 14.5 deg, ours 20.
    - Eye line: reference 15, ours 21.
    - Peak timing matches (+0.5 to +0.6).
    - Return: reference +0.65 to +0.95 gradual, ours +0.57 to +0.70 abrupt.
  - **C:**
    - The reference is a fast bob: the head drops 0.6 TL from +0.20 to +0.33 (0.13 s) and is back by +0.47 (0.15 s).
    - Ours has a similar depth but enters over about 0.23 s and returns over about 0.3 s.
    - Reference knees: about 125-130 deg at rest; the rear knee bends to about 92 deg at the bottom.
    - Ours: 157 deg at rest, and the visible knee STRAIGHTENS to about 175 deg at the bottom. This is the bug behind every "legs straight" note.
- Plan for round 5: match the measured curves.
  - A held lean keeps deepening (drift) through the hold, mostly as trunk lean with level shoulders (lumbar/pelvis lateral bend, thorax counter-roll).
  - B, released before the drift, is about 25% shallower than r4.
  - Less head roll.
  - The head keeps more trunk pitch and leads forward (no hyperextension, no hump).
  - Both knees flex during every slip (fix the straightening).
  - A flick (C) is a fast bob both ways; a held lean returns over about 0.3-0.4 s.
  - The gloves ride with the trunk, lagging.

## Round 5 - curve-fitted held-lean creep, level-shouldered lean, forward-leading head, tap vs held release (score 4: Haiku 5, Sonnet 4; no gain, 5th round without gain)

- Change (measurement-driven fitting):
  - A held stick "creeps" deeper over ~0.6 s, so A deepens through the hold while B, released early, stays shallower.
  - The lean lives in a pelvis roll of 30 deg plus 8 deg of lumbar; the thorax counter-rolls up to -22 deg so the shoulders stay level.
  - Head roll fades from 15 to 6 deg as the lean deepens.
  - The head keeps 65% of the trunk's forward pitch, with the neck protracted 16 deg (no hyperextension into the trapezius).
  - Release: a tap returns fast (REL_TAP); a held lean takes ~0.4 s (REL_HELD).
  - C's forward pitch is raised to 32 deg; the rear glove sits lower.
  - Captures `_build/slipmatch/r5/`, commit 848bba9.
- Haiku (5) top 3, verbatim:
  1. "Clip C (rear 3/4 slip under punch, dense frames +0.267s to +0.400s): the duck is too shallow and reads as a forward bow... In CURRENT the head only dips to about shoulder-chest level, the hips stay high, and the knees barely flex. Increase hip drop and knee flexion so the head travels noticeably lower (about 30 to 40 percent more vertical travel, judged by eye), and fold the trunk from the hips rather than from the upper back..."
  2. "Clip A (front, slip to screen-left, key +0.60s to +1.00s and dense +0.47s to +0.93s): CURRENT moves mainly forward and down (bowing, head ending low over the lead arm), while the reference side-bends... Change the peak pose so the spine bends laterally, not just forward, and the head travels left of the shoulders. Also, the head should lag the trunk by one to two frames on entry... and on exit..."
  3. "Clips A, B and C (guard arms): the gloves stay locked at chin or face height through every slip in CURRENT... In the reference the gloves drop, drift and counter-move with the torso. Make the gloves follow the head and torso with a small delay, and let the lead glove dip and move outward during the peak. Keep the head's lateral travel in clip B larger..."
- Sonnet (4) top 3, verbatim:
  1. "Add trunk lean/side-bend plus pelvis translation and knee flexion, mainly in clip A and C... CURRENT only tilts the torso about 10-15 degrees. The spine looks rigid and the head stays high..."
  2. "Fix the head and neck. In REFERENCE the head leads the move and ends up well off the centerline... In CURRENT the head only translates slightly, with little neck tilt and no counter-rotation, so the head and neck read as one stiff block with the shoulders..."
  3. "Match the timing and flow, and add the overall body travel... CURRENT's dense frames are nearly pose-to-pose, with a short pop and then a static hold... Add overlap so the shoulders and arms trail the trunk by 2-3 frames... In B (quick slip)... Raise the B amplitude by about 2x and add torso rotation."
- Orchestrator review: several grader claims contradict the measured curves. For example, our A head lateral offset matches the reference
  (-0.85 vs -0.86 TL), yet both graders call it small.
  - Cause found, framing: the reference front fighter fills the cell (shoulder width 0.25 of crop height) and sits right of centre. Ours
    stood at 2.15 m and looked about 35% smaller, so equal body motion read as much less in pixels.
  - Cause found, C angle: the flank camera still saw the back broadly (shoulder-width/torso 0.60 vs the reference 0.29). Yaw 50 gives 0.36.
- Measured (r5, wider measurement framing):
  - **Trailing glove, A and B:** the reference drops it to about 0.75 TL below shoulder-mid, near the belt (A by +0.4 s; B at the peak).
    Ours stays at 0.3-0.4. This is the "frozen guard" every grader has named since r0.
  - **A shoulder tilt:** -27 deg vs the reference's -10.
  - **B head drop:** 0.18 vs 0.33.
  - **C knees:** now bend at depth (ours 97-112 deg vs the reference's 92-150). Our rest stance is straighter (about 155 deg vs 110-130).
- Capture setup fix for round 6 onward (framing only, logged):
  - Front composites at dist 1.8, look_y 1.46; A shift_x -0.16, B -0.03 (reference figure scale and placement).
  - C yaw 75 -> 50.
  - Pose curves for A/B now come from extra measurement-only captures at the old wide framing (the pose model needs the full trunk).
- Plan for round 6 (fresh executor; the previous one's context is ~350k tokens):
  - The guard rides the body: the trailing glove drops to the belt line in held and quick slips; the gloves lag the trunk 2-3 frames.
  - A's shoulders stay level (about -10 deg).
  - B's head drops about 0.33 TL.
  - Overlap and settle (shoulders and arms trail; small overshoot) so it does not read pose-to-pose.
  - Slip-driven knee flex toward the reference's 110-130 deg.

## Round 6 - guard rides the body, level-shouldered right slips, overshoot + drift, slip knee flex (score 4: Haiku 4, Sonnet 5; no gain, 6th round without gain)

- Change (fresh executor, reference framing from this round):
  - Lagged glove goals: the fighter's left glove drops to a belt goal in both directions.
  - Right slips: thorax counter-roll held at -40 deg; the lean starts deeper and creeps faster.
  - Entry spring zeta 0.78 (a small overshoot); two-sine hold drift; 3.5 cm of slip-driven sink so the knees flex.
  - Captures `_build/slipmatch/r6/`, commit 380b70c.
- Haiku (4) top 3, verbatim:
  1. "Knee flex and hip drop (Clip C, +0.33s to +0.50s; also Clip A peak)... CURRENT keeps the legs nearly straight and bows at the waist. Add knee and hip compression so the pelvis lowers with the head, and bring the head to roughly hip height by about +0.43s."
  2. "Peak depth and return timing (Clip A, +0.80s to +1.40s). CURRENT sinks further than the reference: the head reaches the bottom edge of the frame at +0.80s to +1.00s, while the reference head is still mid-frame. CURRENT stays low through +1.40s, but the reference is already rising by +1.20s. Reduce the peak by roughly a third, shorten the hold by about 0.2s, and make the recovery finish by about +1.2s."
  3. "Lateral lean instead of vertical drop (Clip B, +0.30s to +0.43s, and Clip A entry, +0.20s to +0.40s). The reference tips the torso and head toward screen-right with the right shoulder dropping and the lead glove rising, so the motion reads as a side shear. CURRENT mostly drops straight down with a small lateral component..."
- Sonnet (5) top 3, verbatim:
  1. "Add a real trunk fold and lateral lean (biggest gap, all clips)... CURRENT only translates and tilts the head and upper chest slightly, so the torso reads as a rigid slab. Increase spine bend (lower and mid spine) by roughly 2x... Distribute it across 2-3 spine bones with a slight lag per bone..."
  2. "Add hips and knee involvement... In CURRENT the legs and feet look planted, with almost no hip shift or knee bend. Add about 10-15 cm of pelvis lateral shift, about 8-12 cm of pelvis drop, 15-25 degrees of extra knee flex on both legs, and a small foot weight-shift..."
  3. "Match the flow, not just the endpoints... Use ease-out on entry (about 70% of the displacement in the first 40% of the entry time). Add a slow 5-10% creep and breathing-style secondary motion during the hold. Have the return begin with the torso, with the head following about 2-3 frames later. Also add a small follow-through on the guard hands..."
- Orchestrator review:
  - The executor's "B: the fighter's left glove drops to the belt" rule came from a pose-model misread: the reference's screen-right glove is half off-frame in B. In the actual B frames both gloves stay up (one at the chest, one at the chin).
  - In A, the reference's logo glove does sink from the lower chest to the belt (confirmed on full frames).
  - A, my biggest visual gap: from +0.6 to +1.0 our head bows face-down (scalp showing). The reference's face stays visible toward the camera, with the head in line with a laterally leaning trunk.
  - The graders conflict on A's depth (Sonnet wants 2x more fold, Haiku a third less).
- New measurement: 3D trunk angles from the pose model's world landmarks (`t3_*` in the curves). They are clean on the reference and noisy on our model, so ours should be compared with exact bone angles from `sequence_manifest.json`.
  - **A, 3D deltas:** trunk roll toward the slip 0 / -11 (0.4) / -23 (0.6) / -33 (0.8) / -35 (0.9) / -27 (1.1) / -21 (1.2) / -12 (1.3) / -7 (1.4). Forward pitch -15 (0.5) / -21 (0.7) / -25 (0.9-1.1) / -16 (1.3) / -7 (1.4). Yaw toward the slip -6 (0.4) / -11 (0.6) / -17 (0.8-1.0) / -11 (1.2) / 0 (1.4). Neck nearly in line (165-171 deg).
  - **B:** roll +10 (0.3) / +18 (0.5-0.6) / +11 (0.8) / +5 (0.9) / -2 (1.0).
  - **C:** forward pitch -13 (0.3) / -18 (0.4) / -9 (0.5) / +3 (0.6). The neck flexes from 146 to 118 at +0.3 (head down and forward of the trunk) and is back to about 140 by +0.5.
- Plan for round 7:
  - A: the face stays visible (no bow) and the head stays in line with the leaning trunk. Match the 3D roll/pitch/yaw curves and finish the recovery by about +1.3.
  - B: the gloves stay up at chin/chest and ride the body (undo the belt drop), and B reads as a lateral shear, not a drop.
  - C: a clearer knee/hip compression with the neck flexing down and recovering.

## Round 7 - face up in side slips, 3D-curve trunk, B shear with guard up, C knee/hip duck (score 4: Haiku 4, Sonnet 5; no gain, 7th round)

- Change:
  - The head no longer keeps the trunk's side-lean pitch, so the face stays visible.
  - Right slips: trunk pitch 34; pelvis roll 23; thorax counter-roll eases from -40 to -17; earlier start and faster creep.
  - B: extra sink cut, more thorax roll, belt glove gated off (gloves up).
  - C: hip drop per forward input 0.32, hips back 0.12, 26 deg forward neck flex.
  - Bone-derived A roll matches the reference curve (-11 / -20 / -37 / -40 / -17 / -6 vs -11 / -23 / -33 / -34 / -21 / -7.5).
  - Captures `_build/slipmatch/r7/`, commit a756d61.
- Haiku (4) top 3, verbatim:
  1. "Clip B (quick slip to screen-right): add real lateral travel. In REFERENCE the head and trunk slide to the screen-right edge by about +0.30s, with the shoulder dropped and the trunk tilted; CURRENT mostly bobs down and stays near centre... Increase the sideways head and trunk offset roughly 2x, and cut the vertical drop so the motion reads as a side slip rather than a duck..."
  2. "Clip A (slip to screen-left, held): fix the descent timing and the nadir depth. REFERENCE starts leaning around +0.27s and holds a long lean from about +0.47 to +0.93s, with the head around chest-to-waist height. CURRENT starts dropping later (about +0.40s), descends faster, and reaches a hip-level nadir at +0.80 to +1.00s that is too deep and bowed. Start the lean about 0.1s earlier, spread the descent over roughly 0.5s, limit the nadir so the head stays above the belt line..."
  3. "Clip C (rear 3/4, slip under a punch): make the body move as one unit... CURRENT keeps the legs nearly straight and only folds at the waist with a rounded back and the head pushed forward, which is the stiff, hunched look. Add knee flexion and hip drop, a shoulder roll and a hip-led twist, and let the neck follow the trunk rather than lead it..."
- Sonnet (5) top 3, verbatim:
  1. "Add the lower-body weight shift and knee bend, and drive the slip from the hips... In C (+0.17s to +0.50s) the reference bends both knees, drops the hips 10-15% of body height, and shifts the pelvis sideways and back... Current keeps the legs and hips almost frozen... Add roughly 15-25 degrees of knee flexion on both legs at peak, lower the pelvis, and shift it laterally toward the slip side by about half the head's travel..."
  2. "Change the trunk shape to a lateral bend with a shoulder dip, and add more amplitude in B... In A... Current at +0.8 to +1.0s bends forward and down toward the camera... In B the reference head travels about half a shoulder-width right and drops, with shoulders rotating and the torso leaning. Current moves the head only about a third of that... Raise the lateral spine bend (about 2x in B), add shoulder-line roll toward the slip side, and reduce the forward pitch."
  3. "Fix the timing envelope in A and C, and keep the guard up... Current is nearly static until about +0.5s, then catches up, so entry is late by about 0.15-0.2s... Timing in C: the reference is still partly bent at +0.6s, while current is almost fully upright by +0.6s... Guard: in A at +0.6 to +1.0s the current gloves drop away from the face to the belly, with the lead glove going low and forward. The reference keeps both gloves tight to the chin and cheek."
- Orchestrator review:
  - A reads best so far: face visible, head at about the reference height.
  - The reference keeps its screen-left (cheek) glove at the cheek/shoulder while only the trailing logo glove sinks. Ours lets the cheek glove fall to the belly as well.
  - Both graders now agree that B is a bob (too much drop, too little slide) and that C's legs read straight with a hunched back. These are the consensus targets.
- Plan for round 8 (both graders' shared issues first):
  - **B:** about 2x lateral trunk and head translation, about half the vertical drop, and the slip-side shoulder drops (about 16-18 deg).
  - **A:** visible movement by +0.27; a gradual 0.5 s descent; less forward bow; the cheek glove stays at the cheek.
  - **C:** knee flex and pelvis drop/shift that read clearly from the flank, plus a hip-led twist. Experiment with collar/shoulder settings to flatten the upper-back hump at the bottom. The return is about 0.1 s later.

## Round 8 - C whole-body compression + opponent jab, B 2x shear / half drop, A earlier entry + cheek glove (score 4: Haiku 4, Sonnet 4; no gain, 9th round at 4)

- Change:
  - C:
    - A lagged lean drives the pelvis sink, sink-back and knee flex. Knees bottom at about 111/116 at +0.33 and are still about half bent at +0.6.
    - The hip hinge share is 0.80, the collars are drawn back, the spine twist opens the chest, and the neck flex is cut from 26 to 8.
    - Capture: the opponent throws an LJab (`opponent_tag`/`opponent_time`).
  - B: half the sink, side pitch 12, lumbar roll 11.
  - A: G0 0.62, pitch 34 -> 25, and the cheek glove is pulled to the cheek.
  - Commit 307dee6. Captures in `_build/slipmatch/r8/`.
- Haiku (4) top 3, verbatim:
  1. "Clip A entry timing and start pose (frames +0.00 to +0.40...). CURRENT starts already bent at +0.00 and is at near-full slip depth by +0.20 to +0.33. REFERENCE stays close to upright until about +0.40 and reaches peak lean around +0.80 to +1.00. Start CURRENT from a neutral upright stance and delay the slip onset by roughly 0.3 s, with an ease-in rather than a snap."
  2. "Clip A recovery (frames +1.20 to +1.40...). REFERENCE is rising and nearly upright by +1.40. CURRENT is still folded forward with the head low and hands near the floor level at +1.40... Shorten the hold and add a visible rise over roughly +1.20 to +1.40..."
  3. "Clip C reaction and evasion (frames +0.27 to +0.60...). In CURRENT the incoming glove reaches the top of the head at about +0.43 and overlaps the head through +0.60, so the slip does not clear the punch. REFERENCE drops the head and hips under the glove path by +0.33 to +0.43, with visible knee flex. Start the duck about 0.1 s earlier, drop the hips and bend the knees (not just the head), and lower the head to clear the glove path."
- Sonnet (4) top 3, verbatim:
  1. "Increase lateral trunk lean and head translation dramatically, and make it a spine bend... Clip B: the reference head travels about a full head-width to screen-right... It also drops about 10 to 15 percent of body height, with the shoulder line tilting hard. The current head moves only about a quarter of a head-width and stays at near-constant height... Clip C: ...The current figure stays upright and nearly static until about +0.43s..."
  2. "Fix the timing: fast entry, short hold, eased return. In clip C the reference is already near peak at +0.27s to +0.33s, but the current is still near neutral at +0.27s and barely peaks..."
  3. "Add knee, hip and neck counter-motion so the body loads instead of translating rigidly... The reference neck counter-tilts so the eyes stay level and on target... In clip A at +0.8s to +1.0s the reference has a clear neck bend with the chin tucked into the shoulder. The current head is almost in line with the trunk..."
  - Sonnet flag: "In clip A at +0.0s to +0.4s the current already looks sidelong-rotated, with the shoulder turned away. The reference starts square and then rotates..."
- Orchestrator review:
  - Captures are clean. In the A key frames, Haiku's A claims (bent at +0.00, near-floor hands at +1.40) do not match the frames.
  - The graders contradict each other on B: Sonnet says the head stays level, Haiku says it drops and holds low.
  - The measurement says the reference B head drops 0.33 TL and ours 0.20, so the r8 halving of the drop (taken from r7 grader wording) went the wrong way. From now on, amplitude follows the measurement whenever a grader's amplitude claim contradicts it.
  - Real gaps both graders point at:
    - C reads late (about 0.1 s).
    - C's jab lands on our head.
    - Our body never looks loaded.
- Anti-stall re-study (9 rounds at 4). Fundamental differences that no round has attacked:
  1. **Base stance.** The reference stands in a loaded, crouched stance in every frame: knees about 110-130, hips low, chest square to the camera. Ours stands tall (knee about 155) and bladed. Since r5 we have only added flex during the slip, so every frame before and after the slip still reads stiff and upright. This matches the owner's standing complaint that fighters "always look stiff".
  2. **C stimulus.** The punch must visibly miss: the reference glove passes beside the dropped head.
  3. **C onset alignment:** ours responds about 0.1 s after the reference.
- Plan for round 9 (new technique):
  - A loaded guard stance as the base under every slip: knees bent about 25 deg, pelvis about 6-8 cm lower, feet planted, a slightly squarer chest. The slip layers stay on top.
  - Match A's start orientation: compare the frame-0 shoulder-width/torso ratio and square up through the stance or the camera yaw.
  - B: restore the drop to the measured reference (0.33 TL) and keep the lateral travel.
  - C: the jab aims where the head was at the jab start, so it passes over/beside the slipped head. The C window shifts to align the onset.

## Round 9 - loaded guard stance as the base (new technique), B drop restored, C jab passes over + onset aligned (score 4: Haiku 4, Sonnet 5; no gain, 10th round at 4)

- Change (new technique after the re-study):
  - New layer `scripts/fighter/stance_pose.gd` before LeanPose: pelvis 6 cm lower, feet 3 cm wider, knees bent by leg IK. Active in boxing fight states only.
  - B side pitch 19 and full sink (drop restored to 0.30 TL, ref 0.33).
  - C: input 0.06 s earlier, jab thrown at 0.05 s so the glove passes above the dropped head.
  - Front composites use look_y 1.40.
  - Regression suite (stance/feet/punch tests) passes; test_lean, test_defence_family and test_pose_limits fail identically on the r8 baseline.
  - Commit 1e481e1. Captures in `_build/slipmatch/r9/`.
- Haiku (4) top 3, verbatim:
  1. "Clip A timing and return... CURRENT starts dropping about 0.1s earlier than REFERENCE and stays low far too long. At +1.200s the REFERENCE fighter is nearly upright while CURRENT is still hunched near the bottom of the frame... shorten the hold..."
  2. "Clips A and B: lateral lean, not a vertical bob... CURRENT mostly drops and pushes forward, and its lateral offset is maybe a third of the reference's. Drive the slip from the hips and lead-side knee... increase spine side-bend roughly 2x. In B, REFERENCE is back near center by about +0.67s, while CURRENT is still low until about +0.73s to +0.87s."
  3. "Clip C... REFERENCE folds the trunk forward at the waist with the head near hip height by +0.33s to +0.43s, with visible knee flex and the back foot changing. CURRENT keeps the trunk near vertical, the feet almost static, and the head barely lower. At +0.267s CURRENT's red glove still sits on the head... Across all three clips the torso and neck currently move as one rigid block..."
- Sonnet (5) top 3, verbatim:
  1. "Add a real trunk lean (side-bend) and lateral torso shift in the slip direction... CURRENT keeps the torso almost upright and only translates the head. It reads as a head-slide with a stiff barrel chest. Raise spine/chest side-bend and roll to roughly 25-35 degrees at peak..."
  2. "Fix the timing envelope. In A the REFERENCE has descended deep by +0.47-0.6s, holds low and bent through +1.0s, then rises smoothly. CURRENT is shallower and less sustained... the return at +1.2-1.4s looks like a snap back to the guard..."
  3. "Add neck and head decoupling plus knee and hip dip... CURRENT's head follows the torso rigidly, with a bald head sitting on a stiff column... In C the REFERENCE visibly sinks into a crouch with the hips tucked, and CURRENT stays tall with straight legs."
- Orchestrator review:
  - C now reads crouched and the jab clears the ducked head at +0.27-0.33 in the key frames. Both graders still say C has straight legs, and Haiku that the glove "sits on the head" at +0.27, which the frames do not show. The A/B legs are out of frame, so the stance change is invisible there.
  - New measurement, `tools/slipmatch/cellcurves.py`: head / shoulder-mid / hip-mid travel in composite-cell units, i.e. what the graders see. Torso-length units had hidden the real differences.
  - **B:**
    - The ref hips stay put (hip dx about 0.00 throughout) while the head goes +0.28 and the shoulders +0.15 at 0.5-0.6, so the trunk tilts over still hips.
    - Ours slides the whole body: hips +0.18 at 0.3, shoulders +0.23, head +0.335. The trunk stays upright, which is exactly "head-slide with a stiff barrel chest".
    - Our shoulder sink lingers: +0.106 / +0.057 at 0.9 / 1.0 vs the ref's +0.02 / -0.02.
  - **A:**
    - Ours enters about 0.12 s late, after a pre-move the wrong way (head +0.08, hips +0.05 at 0.1-0.2).
    - The ref head drops 0.16 while its shoulders drop only 0.09: the head goes down relative to the shoulders through trunk roll and neck tilt. Ours drop together (0.18 / 0.18), the rigid block.
    - The ref is still leaning at 1.4 (head -0.20, shoulders -0.19, hips -0.095). Ours snaps back (shoulders -0.015) and the hips swing to the wrong side (+0.125). This contradicts Haiku's "stays low too long" and matches Sonnet's "snap back".
- Plan for round 10 (measured cell-unit targets, the new technique):
  - **B:** the pelvis stays put and the lean comes from trunk roll; hit the ref head / shoulder dx and dy and the tail.
  - **A:** earlier entry with no wrong-way pre-move; the head drops relative to the shoulders with less body sink; a slow return with the hips held out.
  - **A framing:** our frame-0 shoulder width is 0.19 of the cell vs the ref's 0.37 (bladed, partly off-frame). Match the ref's view angle relative to the chest.

## Round 10 - cell-unit targets: A pre-move removed + earlier entry + held-out hips, B trunk tilts over still hips (score 4: Haiku 4, Sonnet 5; no gain, 11th round at 4)

- Change:
  - A:
    - The idle sway that caused the wrong-way pre-move is now cancelled: the lean layer holds the hip's lateral position at its slip-start value.
    - Input 0.15 s earlier, with a front-loaded stick response for right slips.
    - Shoulder sink halved (0.10 cell vs ref 0.09). Hips held out through the return (pelvis lag tau 0.75 s).
  - B: pelvis shift is now 1.5 cm (hip dx about +0.02 vs +0.18 in r9), so the trunk roll does the work; faster unfold.
  - Front camera yaw 0 -> 6 (framing, logged).
  - `A_cell.txt` / `B_cell.txt` are now written every round. Regression suite passes; test_lean has the same 11 checks failing as the r8 baseline.
  - Commit 69f590f. Captures in `_build/slipmatch/r10/`.
- Cell-unit result (ours / ref):
  - A head dx at 0.1 / 0.3 / 0.5 / 0.8 / 1.4: -.030/-.031, -.174/-.243, -.359/-.409, -.570/-.504, -.198/-.200.
  - A head dy peak .11 vs .16.
  - B head dx at peak .306 vs .275; B hip dx about .02 vs 0.
- Haiku (4) top 3, verbatim:
  1. "Add lateral trunk lean, hip drop and knee flex to the slip pose in all three clips... CURRENT stays close to frontal and mostly bobs forward at the waist. In Clip C... CURRENT keeps its legs nearly straight and only dips the upper body..."
  2. "Increase head displacement and make the head lead the trunk... CURRENT's head stays near the centerline in both clips. Roughly double the lateral head travel, start the head move first, and let the neck counter-rotate... Right now the head is locked to the torso pitch..."
  3. "Fix the timing of the peak and return. In Clip A the reference returns to upright by about +1.13 to +1.20 (dense), but CURRENT is still tucked at +1.33... In Clip B CURRENT stays tucked through +1.00 and re-dips..."
- Sonnet (5) top 3, verbatim:
  1. "Fix the trunk and neck, which still read as one rigid block... The shoulder line tilts about 25-30 degrees. The spine lateral-flexes and rotates. The head dips and angles toward the slip side. The neck bends separately from the trunk... Add 15-20 degrees of independent neck lateral flex and head tilt in the slip direction, with a lag of about 2-3 frames..."
  2. "Add vertical and knee motion, and fix the timing... Current hardly lowers, and its head stays at nearly the same height throughout B... Speed up entry: in A the ref reaches the held pose by about +0.5s, while current is still travelling at +0.6s..."
  3. "Fix the guard and arm response during the slip... Current's lead glove floats out in front of the face in A (+0.4 to +1.0s). In B at +0.43 to +0.57s both gloves splay wide and away from the head. In C the arms stay extended instead of tucking..."
- Orchestrator review:
  - The measured cell-unit motion now matches the reference closely in A (entry, peak, tail) and B (no hip slide, head travel).
  - Haiku's "head stays near the centerline... roughly double the lateral head travel" contradicts the measurement: ours travels slightly MORE than the ref in both clips.
  - Sonnet's "head stays at nearly the same height throughout B" contradicts the B head dy (.111 vs .123).
  - Diagnosis given to the user: the graders cannot see motion differences through the character-model and look gap. The 4-5 band is the rubric's "recognizable, with major differences" level for two visually different games. I proposed a calibration check (re-grade r0 cold, and a reference-vs-reference composite); awaiting the user's call.
  - Real gaps still standing:
    - A head dy is 30% short. The head does not drop or tilt relative to the shoulders, which is Sonnet's consistent neck point.
    - The lead glove floats in front of the face in A and the gloves flare in B (both visible in the key frames).
- Plan for round 11:
  - **Independent neck:** lateral flex and head tilt toward the slip, lagging the chest by 2-3 frames, so the head drops about 0.05 cell below the shoulder line in A.
  - **Gloves:** the A lead glove stays tight to the cheek; no B flare; the C lead arm tucks.
  - **B:** head about 10% less at the peak with a later return; shoulders less far over, with no lingering sink.

## Round 11 - neck lateral flex + head lag, gloves ride the chest (cheek glove tight, no B flare, C arm tucked), B/A tails (score 4: Haiku 4, Sonnet 4; 12th round at 4)

- Change:
  - Neck lateral flex A 9 / B 8 deg on top of a head follower lagging the chest by 0.06 s.
  - Hand targets follow a point 65% of the way from the head to the shoulder line. The A cheek glove is pulled to the cheek, B lateral glove offsets are 38% tighter, and the C lead arm tucks.
  - B and A tail trims.
  - Commit 68ce349. Captures in `_build/slipmatch/r11/`.
  - Regression: test_defence_family fails again ("recovered within 0.4 s") after the slower A return. This must be fixed before merging.
- Cell units (ours / ref):
  - B head dx peak .272 / .275.
  - A head dx at the hold -.56 / -.50.
  - A head dy .11-.125 / .16. Not closable without hiding the face: the neck is near horizontal at the hold.
- Haiku (4) top 3, verbatim:
  1. "Clip B (quick slip to screen-right): CURRENT has almost no lateral travel... CURRENT stays near centre and mostly drops straight down into a hunch..."
  2. "Clip A... CURRENT reaches full depth too early and then holds the head low through +1.33s..."
  3. "Clip C... CURRENT keeps the pelvis near vertical, the legs look straight, and the head sinks onto the shoulders..."
- Sonnet (4) top 3, verbatim:
  1. "Replace the stiff block lean with a real spine curve, mainly in clip A... The head moves only about half a head-width..."
  2. "Add knee and hip dip, and make the pelvis participate..."
  3. "Fix the timing and flow... CURRENT gets to a small displacement early (by +0.4s) and then barely changes..."
- Orchestrator review: Haiku's "almost no lateral travel" in B is measured at .272 vs the ref's .275. Sonnet's "half a head-width" in A is measured at -.56 vs -.50.

## Calibration (after r11) - can the graders see the slip at all?

Same prompt, same composites format, graded cold by fresh Haiku (high) and Sonnet (medium) graders.
- Negative control: the r11 build with amplitude=0, so the fighter never slips; same cameras and timeline. `_build/slipmatch/cal_noslip/`.
- Round 0 baseline (Codex's original slips) re-graded.

| Version | Haiku | Sonnet |
|---|---|---|
| No slip at all | 3 | 2 (saw "cal_noslip" in the path, so not blind) |
| r0 baseline | 4 | 5 |
| r11 current | 4 | 4 |

- Haiku on the no-slip control gave nearly the same feedback it gives our slips: "Overall amplitude is roughly a third of the reference in every clip", "the neck and head move as one block", "the head only bobs in place", "C... never gets under the punch path".
- Conclusions:
  1. The rubric's whole range for this pair of games sits in 2-5. "Not slipping at all" is 1 point below 11 rounds of measured matching, inside grader noise (±1 between graders on the same frames). With round score = min of the two, the loop cannot register motion changes, so the 9/10 exit is unreachable with this grading setup.
  2. The graders' complaint text is driven by the look of our model: a dark, low-detail Meshy mesh, a barrel trunk that shows no spine curvature, long dark shorts. They give the same "rigid block / stiff neck / straight legs" text whether or not the fighter moves.
  3. Cold, the graders do not rate r11 above r0. Whatever the measured motion gains are, they are not visible to them.
- Next step is the user's call (it changes the loop's grading rules):
  - (a) Grade motion on like-for-like figures: identical stick-figure skeleton panels from the pose model for both sides, plus the measured cell-unit curves as the acceptance numbers.
  - (b) Treat the model's deformation and look (spine and neck skinning, shorts) as its own job.
  - (c) Keep going as is.
