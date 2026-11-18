# Fight Night Round 4 head movement: visual implementation plan

Goal: match the supplied Fight Night slip/lean reference in silhouette, head path, lower-body loading, timing, and transitions into counters. User requested visual review now and deferred assertion/code tests.

Source: `fightnight4-slip-dodge-short.mp4`, the high-resolution local copy of `https://www.youtube.com/shorts/egmZEOilUR4` (title: How To Slip And Dodge in Fight Night Round 4). Earlier Champion labeling was incorrect. Useful continuous sections: 4.7–6.5 seconds (white shorts, yellow gloves, lateral/forward defence), 6.7–8.1 seconds (black shorts, red gloves, backward lean). Edits and camera changes are boundaries, not animation timing samples.

## Design

Keep the existing two-dimensional analog input and actual bone-driven hurt volumes. Calibrate the procedural lean over the normal guard (the old authored hold plus additive lean doubled the bend). Keep feet planted during stationary leans. Fit the visible glove and head centres, including each model's mesh offsets, rather than treating wrist/head joint origins as silhouette centres. Preserve held defence through the start of a counter and blend continuously back to the requested lean or neutral guard.

The reference uses different models, proportions, camera, and lighting. A literal pixel identity of the entire scene is not a valid criterion for this port. Compare motion after a fixed camera/crop/scale alignment, show source timestamps, and report visible residual differences. Never stretch bodies, retime evidence secretly, or assert exact parity without evidence.

## Work and ownership

- [x] Locate local high-resolution source and confirm video identity.
- [x] Extract and inspect overview and dense 6 fps reference contact sheets.
- [x] Render the existing game baseline before gameplay edits; preserve original gameplay files in task scratch.
- [x] Capture worker: new `tools/capture_fn_match.gd`, with deterministic input timeline, rendered images, timestamps, and projected bone positions.
- [x] Comparison worker: new `tools/compare_fn_reference.py`, transparent source-time mapping, equal-aspect crops, contact sheets and playable comparison.
- [x] Transition worker: `scripts/fighter/fighter.gd` and `fighter_anim.gd`, direct analog response and continuous lean/action transitions.
- [x] Lead: tune `scripts/fighter/lean_pose.gd` from rendered evidence; inspect both directions, backwards lean, duck, direction changes, counters, and actual roster skins.
- [x] Review the actual patches, render integrated scenarios, inspect images, and iterate on observed mismatches.
- [x] Save review evidence in this chat's `outputs/fightnight-match/`, include unresolved mismatches and exact capture commands.
- [ ] Establish literal 1:1 parity. This remains open: the base guard, rear-foot stance, forward compression/head tuck and close opponent-arm overlap still differ. The independent visual reviewer did not approve an exact match.

## Continuation evidence

The source 4.7–5.3 s action corresponds visually to the captured `slip_l`, not the earlier `slip_r` comparison. At a common 405 px comparison width, the annotated source head moves approximately (-10,+110) px and hip (-15,+75) px. The corrected-direction capture records projected logical head (-7.5,+127.7) px and hip (-15.9,+77.2) px. Source annotations and logical joints are different measurement primitives; this is evidence of improved direction/scale, not an exact pose score. Reference camera/stance can confound single-view comparisons.

No skin foot warp was justified: a dedicated review found driver ankle/toe articulation is already preserved and the reference rear foot is also raised. Forearm recovery clearance is reviewed separately from active strike contact; a live attack must not be silently re-aimed merely to improve screenshots.

The integrated capture set is `latest-game/` (now nine sequences), with `latest-chain/`, `latest-anvil/`,
`latest-blocked/` and `latest-half/` for the additional cases. Live forearm clearance now adjusts only the
elbow pole and restores the complete striking hand transform. Recovery can withdraw a trapped wrist by
a spring-smoothed offset capped at 0.10 m. The before/after visual strip still shows close-counter
neck/shoulder overlap; the correction is not a complete collision solution. Retaining the glove path
limits how much a nearly straight arm can move around the opponent. This remains open alongside the
source guard/stance differences. No exact-match acceptance was recorded.

The next visual iteration traced early straightening to the counter clip's shallower body pose. Counter
entry now carries the previous hip/head posture through startup and releases it relative to the counter's
contact peak, while preserving the striking hand transform captured before this layer's lean. The source
counter at 3.9–4.4 s stays low until the incoming glove clears, and remains turned through counter contact.
Independent DeepSeek review supports that ordering; it does not certify exact timing or pose parity.
The boxing free guard also settles into the low lead-hand silhouette at engagement range and keeps it
through slip release. Fitted visible head/glove centres are now recorded separately from logical bone
origins. `counter_back` adds explicit sway-to-counter coverage. All affected captures are regenerated.

The wrist pass aligns each free glove's measured axis toward the solved forearm, with a small upward
guard bias and a 55-degree limit (45 on the lead hand in the compact slip). A second wrist solve retains the visible glove-centre goal after the
rotation. Blocked and live striking hands retain their authored orientation. Source cuffs are partly
occluded, so image-plane direction provides a useful visual check while palm roll remains uncertain.

The final wrist pulse was independently reviewed across frames 000–020 with no obvious cuff separation,
hyperflexion or entry/release discontinuity. Exact parity remains open. The next pose discrepancy to
investigate is the hip/head relationship: the reference appears to keep its hips farther behind the
head and its front knee less folded than the current deep slip. This is a single-view hypothesis; compare
backward hip loading with compensating trunk pitch under the same camera before changing the stance
or skin. Do not treat source-camera projection or different limb proportions as proof of a retargeting bug.

That hip-loading experiment now favours candidate B over both A and the prior forward-hip pose:
`PITCH_SIDE_DEG=35`, `HIP_SIDE_FWD=-0.09`, `DROP_SIDE=0.15`. Feet and camera remain fixed. The head-ahead-
of-hips projection and less-folded front-knee silhouette are closer to the source, while the visible belt
still appears somewhat tucked up under the chest. These source points are helmet/belt/knee silhouettes,
not anatomical landmarks; their ratios are not a match score. Release multiplier `0.90` retains a smoother
return in the source-length input pulse without adding a hold. All nine scenarios, including an explicit
forward analog lean, plus the roster and input variations are regenerated for the integrated review.

A lateral neck-only counter-pitch experiment was rejected. The source helmet/glove hide the brow, nose, chin
and neck contour; the baseline's low crown-dominant silhouette is closer than the more upright candidate.
No additional lateral neck-pitch direction is justified from this view.

The separately reviewed backward pull uses the clean hold at 7.767–8.100 s. It supports a stronger
backward trunk arc and lifted chin: the pull now uses 36-degree trunk pitch, a 12-degree chin-lift
contribution and an open lead guard, all blended by backward input. DeepSeek review found improved
source cues and no obvious new geometry defect in the sampled Viper sequence. Fresh front-view Viper
and Anvil clips cover entry/hold/return, and the nine scenarios include the revised pull-to-counter.
The source far glove changes during the hold, and stance/proportions/view still differ. Exact 1:1
acceptance remains open; the source short cannot resolve the occluded joints and every transition.

The user's additional Champion reference, `https://www.youtube.com/shorts/K966_uJaa0A`, supports
brief recoil followed by a straight counter at 9.30–9.90 s and 10.17–10.70 s. It does not establish
a sustained lateral lean or a readable large side step. Source action review also distinguishes
the Round 4 straight counter from the default RHook coverage action. Capture now accepts an explicit
`counter_tag`, recording the actual literal action in its schedule and manifest.

New straight captures reproduced the lean layer rotating an ordinary head jab down toward the body.
Jab/cross hands now retain their pre-lean target lane via reachable-length IK, and the trunk uncoils
as extension proceeds, reloading near recovery when input remains held. Authored counter hooks keep
their previous body-entry treatment. Five additional side-view cases include lead/rear straights,
Anvil, pull-to-jab and a body straight. Independent review confirms the head-target improvement;
shoulder crowding, wrist occlusion at contact and the rear-foot pivot still need continuous visual
assessment. Coverage footage is not an exact reconstruction of either source exchange.

The uncovered near-frontal source interval at 22.20–24.10 s supports keeping the rear glove
beside the cheek/jaw with the face readable. A small free-guard target change (-0.11 m to -0.18 m
laterally for the rear glove, existing 85% blend) reduces face occlusion in the game front view.
Additional pre-lean elbow and neck-extension experiments were rejected; their visible benefit
was not clear. Viper/Anvil frontal half-lean captures are added. Source camera reframing, unknown
input amplitude and absent knees/feet prevent this upper-body study from establishing exact
stance, camera or timing parity. The game chin/gaze and model proportions remain different.

The primary Round 4 counter is now a lead-straight fixture with independent incoming-action
selection (`opponent_tag`). Marked jab/cross counters retain 40% of their loaded lean through
extension, rather than 15%, keeping the head lower at contact. Ordinary straights keep the 15%
setting. In the current replay, the incoming RJab at .30 s misses, and a return LJab at .55 s
reaches the guard around .767 s, mapping to source 4.267 s without retiming. DeepSeek review
accepts the coarse glove-clear/head-rise/drive/contact ordering for this bounded replay. Earlier
fixtures got hit or contacted five frames late; that history is explicitly distinguished.
The source incoming hand and hit-versus-block outcome remain uncertain; the uncalibrated camera and opposite
lead stance remain differences. Source background features are nearly stationary in this window;
the earlier source-orbit hypothesis is not supported. Source/game comparison may mirror the entire game frame for screen-facing;
the raw clips are retained. No pose warping or exact trajectory acceptance is claimed.

The capture-only main script suppresses focus-loss auto-pause. The prior harness was observed
paused with its HUD hidden after another capture gained focus; it resumed via Escape. A new
capture completed with the harness subclass, and the refreshed run advances in the background.
The gameplay main script and its normal focus pause are unchanged.

The compactness pass compared five jab/spacing variants and three side-view clips before
adding a near-range marked head-straight reach cap. All tested jab variants approached full
extension; source review instead supports a persistent flexed-elbow chamber/drive/return cue.
The cap follows the current gap (.95–.80 m), keeping shoulder-to-wrist span within 99.2–88%
of segment length along the existing lane. No wrist bone translation or synthetic hit outcome
is applied. Controlled same-gap captures retain contact timing and a more flexed elbow;
DeepSeek found no new visible artifact in the bounded contact/recovery samples. Primary
Viper/Anvil, near/far starting spacing, body-jab and straight-counter captures were refreshed.
The source's clearer chambered head drive, model proportions and camera still differ. This
visual refinement changes the glove path; code-level contact checks remain deferred.

The chamber pass retains the prior actual hand pose in fighter space for marked head-straight startup.
It blends into the authored lane across 5–65% of contact-peak time, while the marked head counter's
body rises across 5–40%, retaining its existing 40% loaded lean. The initial 30–92% hand blend delayed
sampled primary contact one frame; the retained version restores the .767 s Viper guard resolution.
Source shoulder turn, forward head drive, stance and camera motion remain different. The controlled
before/current comparison is `counter-chamber-source-before-after.jpg`; the prior reach-only study
is historical. Repeated-jab capture exposed same-tag attack undercounting: the capture audit now uses
attack serials and records serial/time in frames. This does not alter gameplay.

## Close-contact overlap

The capture harness now accepts `debug_hulls=true trace_hitboxes=true` for a visual collision
overlay and passive sampled-fist/attachment/head-hull trace. A 120 fps Anvil exchange shows the
forearm proxy entering the head region before the sampled fist sphere reaches a head/neck hull;
the hit remains pending during shallow contact and then resolves. This is consistent with the
glancing-contact gate but is not sufficient to prove a sole cause. Tracked hitboxes are attached
to the logical skeleton, while the Meshy model has a separate retargeted display skeleton. A
visual-only clamp could hide a gameplay/display disagreement. The game needs a coherent active
strike trajectory and later contact verification; code assertion tests remain deferred.

The Anvil rear-straight coverage fixture has an incoming Viper jab that reaches behind Anvil's
head while the attacker is still in the contact phase. Three fixed-camera renders and a fitted
forearm/hull diagnostic show the concern; the diagnostic is a collision proxy, not proof of mesh
intersection. The incoming punch is pending at 0.600 s and recorded as a hit by 0.633 s. A
recovery-only increase in withdrawal speed and cap gave a small proxy reduction, with no clear
visual improvement, and was removed. Both runs reach zero reported proxy depth by 0.700 s.
The remaining active-strike path is held by design and may require contact/hit verification before
changing it. Code assertion tests remain deferred at the user's request.

## Planted slip high guard

The overhead reference keeps the high glove close to the helmet at the deep slip peak. In the
prior game capture the high glove projected farther forward. The free rear-glove forward target
now blends toward 0.03 m as the lateral lean deepens; shallow input, block and pure backward
lean retain their existing targets. Viper and Anvil showed a closer peak silhouette; consecutive
frame review found no obvious new wrist or elbow discontinuity. The primary counter fixtures
continued to resolve against the guard at the same sampled .767 s. The models, camera and glove
sizes differ, and the glove partly overlaps Anvil's cheek; exact placement remains unproven.
Physical contact assertions are deferred. Full updated coverage is regenerated after integration.

## Planted slip glove trial

At the overhead peak, the source's lower glove appears closer to the chest than in the game. A
trial raised the low hand target by up to 0.15 m only during deep lateral lean. Viper's peak
changed little while recovery moved more, and the separate uncovered frontal source shows a
low glove. The 3D target remains uncertain, so the trial was removed; the 30 fps comparison
and both-fighter phase sheet are preserved with the visual review. Code tests remain deferred.

## Shoulder-turn experiments

The source shows a relative upper-body turn while the face remains directed toward the opponent.
The camera is uncalibrated and occlusion makes the exact anatomical turn and angle uncertain.
Later source-background tracking shows nearly stationary composition rather than evidence of an orbit. An additional 12-degree
torso turn with neck counter-rotation did not produce a clear source-matching improvement in the
Viper A/B and delayed sampled blocked contact by one frame (.833 to .867 s) in the matched Anvil
opposite-side fixture. A separate reduced-side-roll candidate flattened the projected shoulders in
late recovery, but changed the head's lateral position and lacked a reliable source-angle target.
Both experimental changes were removed. Source/game and Anvil comparison sheets are retained in
the visual review; these observations do not replace deferred code-level contact verification.

## Visual acceptance

Evaluate neutral, entry, peak, held pose, counter startup/contact, release, and returned guard. Check head displacement relative to head height, hip sink relative to leg length, trunk pitch/roll, knees, stationary foot positions, guard-hand relation, and temporal continuity. Full-speed clips supplement contact sheets; static screenshots alone cannot establish motion quality. Parsing/import failures encountered during rendering must be fixed so the visual check can run; automated assertion suites remain deferred.
