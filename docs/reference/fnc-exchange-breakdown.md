> **Source note:** the analysed clip (youtu.be/hFNapc7Gjto) is "Tale of the Tape - Gameplay Update #2", an indie Unreal boxing game, not Fight Night Champion. Use it as a fluid-feel reference; the owner's Fight Night Round 4 reference for leans/slips is the separate short (youtube.com/shorts/egmZEOilUR4).

# Exchange breakdown from the reference clip (https://youtu.be/hFNapc7Gjto)

## 0. Read this first: source caveats

- **The clip is NOT Fight Night Champion.** The video is titled "Tale of the Tape - Gameplay Update #2" (indie Unreal Engine boxing game, fighters "Brian Palaby" = bald, red gloves, white/red trunks, blue waistband; and "Nigel Slippy" = orange hair, white gloves, red/black checker trunks). It is still a good "fluid, physics-blended" reference, but do not quote these numbers as FNC numbers. Say so to the owner.
- 273 s long, 1142x720, 60 fps source. I sampled it at 10 fps (coarse) and 30 fps (precise, +-0.033 s) on 8 exchanges. Contact sheets are in this folder (`fnc_*.jpg`, each tile labelled with video time).
- The video is **edited with jump cuts** (the framing changes between adjacent 0.1 s samples in several places, e.g. 196.0->196.1, 202.17). Durations below are only taken inside continuous shots. Camera numbers are therefore approximate.
- No ground-truth scale. I use head width ~ 20 cm and shoulder width ~ 2 head-widths (HW) to give rough distances.
- Both fighters appear AI/replay driven in an exhibition. Fighter A = Palaby (bald), B = Slippy (orange hair).
- What I could NOT see clearly in this clip: clean uppercuts landing, deliberate lean-back slips, parry/deflection animations, power-charged punches. Those sections say "not observed" rather than inventing numbers. Slips/leans seen are listed in section 6.

Frame references: `fnc_jab_cycle_40s.jpg` (40.1-41.3 s), `fnc_cross_land_245s.jpg` (245.0-246.2), `fnc_block_jabs_262s.jpg` (262.2-263.4), `fnc_inside_hooks_88s.jpg` (88.4-89.6), `fnc_trade_175s.jpg` (174.7-175.9), `fnc_clinch_hook_102s.jpg` (101.6-102.8).

---

## 1. Punch commitment (measured at 30 fps)

Definitions: wind-up = first visible glove/shoulder move out of guard to the moment the glove moves forward with speed; extension = forward travel to the farthest point (hit frame); hold = frames glove stays near full extension; retract = glove leaving full extension to being back at guard; "guard back" = both gloves again at cheek/chin level and torso upright.

| Punch (clip time) | wind-up | extension | hold | retract | total commit | guard back after peak |
|---|---|---|---|---|---|---|
| Lead jab A, blocked, 40.17-40.43 | 0.07 s | 0.06 s (40.23 -> 40.30) | ~0.03 s | 0.13 s | ~0.27 s | ~0.13 s |
| Straight A (long jab/cross), 40.47-40.83, missed/stopped short by the guard | 0.07 s | 0.10 s (40.47 -> 40.57) | **0.07 s** (40.57-40.63, arm fully straight) | 0.17 s (40.63 -> 40.80) | ~0.35 s | ~0.20 s, guard settled ~40.90 |
| Cross A landing on head, 245.00-245.67 | 0.13 s (shoulders turn to camera 245.07-245.13, glove blurred) | 0.10 s (245.13 -> 245.23) | 0.07 s (245.23-245.30) | **0.37 s** (245.30 -> 245.67, slow ease-out) | ~0.65 s | ~0.4 s; fully quiet guard ~245.85 |
| Right hook A to guard, 101.80-102.13 | 0.10 s (glove swings wide 101.80-101.83, torso rotated ~90 deg so his back faces camera) | 0.07 s (101.83 -> 101.90) | 0.03 s | 0.20 s (101.97 -> 102.13) | ~0.4 s | ~0.25 s |
| Jab pump B, 262.60-263.0 (3 jabs in a row, all blocked) | 0.05-0.07 s | 0.07 s | ~0 | 0.10 s | **~0.22-0.27 s per jab cycle** (peaks at 262.67, 262.87, 263.0) | ~0.1 s |
| Body hook/uppercut B, 262.2-262.5 (white glove drops to hip, torso opens ~25 deg, lands on elbows/guard 262.43) | 0.20 s (long visible dip + rotation) | 0.10 s | 0.03 s | ~0.2 s | ~0.5 s | 0.25 s |
| Body shot B to ribs, 175.07-175.27 (glove at hip level, cyan hit flash at A's torso 175.20) | 0.10 s | 0.10 s | - | 0.15 s | ~0.35 s | - |
| Cross A over the top, 175.10-175.40 (trade) | 0.10 s (shoulder turn 175.10-175.17) | 0.07 s | 0.10 s (175.23-175.33) | 0.20 s | ~0.45 s | 0.25 s |

Takeaways:
- Jab total cycle ~0.25-0.35 s, cross ~0.55-0.65 s, hook ~0.4 s, body shot ~0.35-0.5 s. **The extension is fast (0.06-0.10 s) but retraction is 1.5-4x longer than extension and eased out.** Wind-up is short and shown mostly in the torso/shoulder, not the glove (the glove starts late, the shoulder/hips start first: telegraph is in the body, ~0.07-0.13 s before the glove moves).
- A short hold at full extension (0.03-0.10 s) is what makes the hit read. It is the "contact frame" plateau, then the arm eases back.
- Overextension on a miss/short punch: the 40.47-40.83 straight reaches ~1 arm length (about 5 HW from shoulder to glove) with the front shoulder driven forward ~0.5 HW and the torso leaning forward ~15-20 deg; the head follows the glove by ~0.3 HW. Recovery of the torso is slower than the arm (torso upright again ~0.3 s after the arm is back).
- Can the puncher block/move during recovery? Observed: during retraction, the free (non-punching) glove stays at the face the whole time (never drops). The punching hand is vulnerable until it is back at cheek level (~0.13-0.37 s). I never saw a fighter initiate a second punch from the same hand before the retract was ~70% done, but the other hand fires within 0.1-0.2 s (jab-cross 40.17 -> 40.47 = 0.30 s gap; 262.67/262.87 alternation 0.20 s). Footwork continues during the retract (small shuffle steps, see section 8).
- Hooks and body shots: visibly longer, because the torso must rotate and return (hips counter-rotate ~0.1 s after the glove returns).

## 2. Punish windows (observed)

| Missed/blocked | Punisher | delay | window | clip time |
|---|---|---|---|---|
| A's straight stops short against B's raised guard (retract 40.63-40.80) | nothing: B did not counter, he stayed in guard through the whole 0.35 s window | - | ~0.2 s from end of extension until guard back | 40.5-40.9 |
| A's wide right hook that hits B's guard (101.83-101.93) | B throws a jab/short punch at 102.00-102.10 as A retracts | **0.10-0.17 s after A's peak** | A is open ~0.2-0.25 s (right hand low, torso turned away from B) | 101.9-102.1 |
| B's slow body-hook/uppercut blocked on A's elbows (262.43) | A does not counter; A holds guard and B continues with jabs. A's guard stayed fused to head, so no punish | - | B's open window ~0.25 s | 262.4-262.7 |
| B's dropped lead hand during the body shot (175.07-175.27) | A's cross lands at 175.20-175.27 at the same instant (this is a trade, section 3) | ~0 s | B's face is exposed for the full 0.35 s body-shot commit | 175.1-175.3 |
| A's cross lands (245.20) then A retracts slowly to 245.67 | B did not counter although A's head/torso forward for 0.4 s; B stumbles back first | - | A open ~0.4 s | 245.3-245.7 |

Interpretation: the game never makes a punish look instantaneous. Counter punches begin **0.1-0.2 s after the opponent's peak extension**, i.e. while the opponent is still retracting (about 40-60% through his retract). A punish window is about the length of the retract plus torso recovery, 0.2-0.4 s. Counters are throw-and-land within ~0.15 s, which is why they read as "caught him coming back". This also shows B's counter-attempts get partly blocked because A's off hand was still up (a single punch recovering from a miss is not a free hit; only a cross or hook where the off-hand also moves is).

## 3. Trades (simultaneous punches)

Primary example `fnc_trade_175s.jpg`, 174.70-175.90:
- 174.77-174.87: B lands a straight into A's face (cyan edge-of-screen flash at 174.87, small teal spark at A's head 174.90, A's face tinted red). A's head pushed back ~0.3 HW, A's guard hand wobbles; A's left side rotates ~20 deg away.
- 175.07-175.13: A starts his cross while still being pushed back (A's shoulder turn begins ~0.2 s after the hit, so the reaction did not cancel his attack). B in the same 0.1 s drops the lead glove to the hip for a body hook.
- 175.20-175.27: both land at the same frame (A's cross hits B's head/guard while B's hook hits A's ribs; cyan flash at A's torso 175.20). B's head whips back ~15 deg and the torso bends back; A takes the body shot, his torso folds ~10 deg but his arm keeps extending.
- 175.30-175.47: A's extension holds 0.10 s, both bodies are now chest to chest (see section 7), B's right glove cups A's arm.
- 175.50-175.87: both retract with arms interlocked; bodies slide past each other ~0.5 HW.

Why it looks fluid:
1. The hit reaction does **not interrupt** the opponent's own attack animation. Each body plays its own attack layer; the hit adds a partial-body displacement (head/torso/arm) on top, so both punches complete.
2. Reaction magnitude depends on the *type* of hit and the victim's state: a punch that lands while the victim is also mid-punch only moves the head and torso a little (~10-15 deg), not a full flinch.
3. Both fighters' root positions continue translating (small forward lunges on both bodies) so the contact is shoulder-to-shoulder rather than a static pass-through.
4. Hit effect is a glove-level spark (small teal puff ~0.5 HW) + brief screen-edge cyan flash, not a freeze. No hit-stop is visible at 30 fps: I see no frame where either body freezes. (Hit-stop <= 0.03 s cannot be excluded.)

Timing differences observed: 0-0.05 s between contacts in this trade; a 0.1 s difference was enough to let the earlier puncher visibly "win" the exchange (the other fighter's head moved before his own glove reached the target in the 88.8 exchange).

## 4. Hit reactions

Observed reactions (30 fps unless noted):

| Hit | Victim state | Observed reaction | duration |
|---|---|---|---|
| Cross to head, 245.20 (B victim) | idle, guard up, stationary | Head rotates ~30-35 deg away (turns away from the punch, chin to shoulder), neck stretch, shoulders follow 0.05-0.07 s later (~15 deg torso twist), glove at the face drops ~0.5 HW, **one step back of ~0.5 HW** by 245.40, weight shifts to rear leg, then comes back upright | ~0.4 s to upright + guard raised by 245.60 |
| Jab-type hit, 40.30 | blocking | no head whip, gloves absorb: the white glove at B's face pushes ~0.2 HW toward the face and returns in ~0.1 s | 0.1-0.15 s |
| Right hand to head at 205.0 (B victim, near ropes) | in a corner, already stunned | knockdown: legs buckle, torso collapses to the rope side, slides down the corner post for ~0.75 s, ends flat on back, with a ragdoll-like roll and a limb overshoot (arms flop when hitting the floor) | 205.0-206.0 s (~1 s) to the floor |
| Straight hit at 174.83 (A victim) | moving forward / mid-throw | head push back ~0.3 HW with a ~10 deg rotation, face turns red (damage tint), the arm that was wound up keeps moving; torso leans away ~10 deg | 0.15-0.2 s |
| Body shot at 175.20 (A victim) | punching | ribs fold ~10 deg, no step, the cross still completes | 0.15 s |
| Hook around guard at 102.67-102.77 (B victim) | blocking, head still, gloves fused to face | glove wraps around side of head; head pitched ~10-15 deg and nudged sideways ~0.3 HW, gloves stay up | 0.15 s |
| Teal burst at B's head, 89.40-89.50 | clinch/close | head pushed forward-right ~0.5 HW and rolls ~10 deg, then returns; opposing glove slides | 0.2 s |

Physics-blending evidence: reaction onset is a few frames after glove contact and it is *proportional* (head whip bigger than torso twist, torso twist bigger than stance shift). Limbs overshoot and settle (the "soft-body/spring" look): the head overshoots by ~5 deg and returns, the hand holding the guard lags the shoulder by ~0.05 s. In every case I see motion from the *contact point outwards* (head first, then shoulders, then hips/feet) rather than a full-body canned flinch clip. Different hits produce different amplitude/direction (head turns with the punch direction). So I would conclude: **animation-driven attacks plus additive, spring/procedural hit layers driven by punch direction and strength**, with ragdoll only for the knockdown.

Recovery time to a playable guard after a hit: ~0.35-0.5 s for a clean head hit; ~0.1-0.2 s for a blocked hit.

## 5. Blocking

- `fnc_block_jabs_262s.jpg`: B throws 3 jabs at A, whose gloves are in front of the face, elbows tight to the ribs, chin tucked. The jab lands on the glove at 262.67/262.87/263.0: A's glove moves back ~0.2 HW (spring), A's head shows a ~3-5 deg pitch, nothing else moves. Return to rest 0.1 s. No stagger.
- Body shot/uppercut-like swing (262.2-262.5): A answers with elbows dropped inward; the punch is absorbed on the forearm/elbow at the torso, cyan/teal spark at the contact point at 262.43-262.5, A's torso rotates ~5 deg and rocks back ~0.2 HW; gloves stay on the face.
- A hook around the guard (101.83-101.93 and 102.67-102.77 in `fnc_clinch_hook_102s.jpg`): the hooking glove does *go around* the side of the head and touches the head/ear when the target's glove is near the front of the face. The target's reaction is a head tilt (10-15 deg) rather than a blocked animation. So blocks are positional (the guard is real geometry): hooks beat a frontal guard; straight punches get caught on the gloves.
- Guard is dynamic: guard drift between hands while the opponent is out of range is subtle, the guard tightens as the distance closes (fists at cheekbone/forehead).
- Parries/deflections: **not observed**.
- After a block: the blocker mostly stays in guard (~0.1-0.2 s) and does not counter at once. There is no "blocker immediately stunned/open" pattern here.

## 6. Head movement

- Observed leans/ducks: A bends forward at the waist with head dropped to B's shoulder at 88.50-88.70 (head dips ~1.2 HW forward and ~0.8 HW down in 0.15 s, torso pitch ~35-40 deg), while throwing a body shot (red glove low at 88.67); returns upright ~0.2 s after. This is the "duck/dip under + punch" with a counter from the dip.
- B leans back out of range at 175.10-175.17 (head moves back ~0.7 HW in 0.1 s, torso pitch back ~15 deg). He does it while the opponent's cross is already traveling and still takes the glove on the guard.
- B does a low-shoulder lean forward at 262.2-262.4 (head sinks ~0.5 HW) while swinging the body shot.
- A lowers his stance during hook wind-ups (head lowers ~0.3-0.5 HW, knees bend ~10-15 deg), e.g. 101.80.
- Slips (pure side-to-side head moves) and rolls: **not clearly observed** in the sampled windows. When defending against jabs, the fighters simply keep the guard and sway ~0.2-0.3 HW in 0.1 s.
- Counters from a lean: A's body shot from the dip (88.67-88.87) and B's counter-hook out of the clinch at 88.80-88.87 (cyan flash at 88.83). Counters start ~0.1-0.2 s after the lean's lowest point.

## 7. Close range

- Chest-to-chest/head-to-head behavior is common: from 88.4 to 89.6 both fighters are within 0.5-1 HW of each other with heads touching or almost touching (e.g. 102.23-102.33: A's cheek against B's cheek, gloves fused between faces).
- Smothered punches: punches thrown at this range have a shortened extension: elbows stay bent (~90-110 deg), glove travel ~1 HW (about 1/3 of an open-range punch), so duration is shorter (~0.2-0.25 s per punch) and reaction is smaller (head pitches ~5-10 deg).
- Pushing/leaning: bodies lean into each other with forehead/shoulder contact (88.60-88.70). The fighters do not pass through each other; the root positions get pushed apart ~0.3-0.5 HW in 0.2 s (see 175.5-175.9 where the pair slides past).
- Separation: no hard "break": fighters drift apart through small back steps (0.5 HW) 0.2-0.3 s after the last punch; the referee stays out of the frame.
- Arm interlocking/tie-ups: gloves occasionally overlap/tangle (175.40-175.50, 102.4) but the animation does not freeze; arms slide.

## 8. Movement and camera

Footwork (seen in wide shot 159.0-161.5 and the bounce in the mid shots):
- Fighters bounce/shuffle continuously; stride is short (0.5-1 foot-lengths); each step is ~0.25-0.3 s. Weight shifts to the rear leg right before a punch (hip back, ~0.1 s) and forward during extension.
- Approach from ~6-8 HW apart to punching range took ~1.5-2 s (159.0 -> 161.4 s) with ease-in (slow start) and ease-out (a short deceleration step before the first punch); no instant top speed.
- Retreat after a hit: one step back (~0.5 HW) plus a stagger, not a sprint.
- Both bodies keep rotating their torso toward the opponent (shoulders square within 0.2 s of a stance change).

Camera:
- Framing is dynamic and keyed to distance: apart (159.0-160.2 s) the fighters occupy ~14-18% of frame height with the referee between them, from a high (~35-40 deg downward) angle at the corner; when they engage (160.8-161.9) the camera pushes in over ~1.5-2 s so the fighters fill ~60-75% of the frame height; in a clinch/infight (88-89 s, 245-248 s) the heads fill ~25% of the frame height and the camera is at about head height, roughly 3-4 m away with a 25-30 deg lateral offset (3/4 view, behind one fighter's shoulder).
- It orbits around the pair (the ring posts and ropes sweep across the background), roughly 20-35 deg of azimuth change in ~1 s during exchanges (e.g. 175.2-175.6 where the referee slides to the frame edge). Pitch changes are small (~5-10 deg). No obvious shake on hits; there is a slight push in on big punches (the 245.2 cross: the frame zooms in ~5% over 0.2 s).
- Rope foreground occasionally crosses the frame (red rope across the bottom), meaning the camera stays low/near the ring edge and does not clip them out.
- Camera damping is soft (seconds, not frames): positions ease; when fighters move the framing lags ~0.2-0.3 s.

## 9. Top 12 things to copy (ranked)

1. **Asymmetric punch timing**: wind-up 0.05-0.13 s (starts in shoulders/torso), extension 0.06-0.10 s, hold 0.03-0.10 s at full extension, retract 0.13-0.37 s (1.5-4x the extension, eased out). Jab ~0.27-0.35 s, cross ~0.55-0.65 s, hook ~0.4 s, body shot ~0.35-0.5 s. Target for robotic -> fluid: never use symmetric (linear) extension/retract.
2. **Overlap actions, don't gate them**: other hand fires 0.20-0.30 s after the first (jab-cross 0.30 s, jab pump 0.20 s), and the off-hand stays at the chin during every punch. Allow chaining from ~65-70% of the previous retract, not from "idle".
3. **Hit reactions are additive, proportional layers**: contact-point outwards, head first (+0 s), shoulders (+0.05-0.07 s), hips/feet (+0.1 s), with overshoot ~5 deg and return. Head whip 30-35 deg (clean cross), 10-15 deg (hook around guard), 3-5 deg (blocked jab); torso twist ~15 deg; one back step of ~0.5 HW; recovery 0.35-0.5 s unblocked, 0.1-0.2 s blocked. Direction follows the punch.
4. **Attacking victims keep attacking**: a hit reaction must be a partial-body layer that does not cancel the victim's own punch (trades at 175.2). Only a clean hit on an idle/guard-dropped fighter plays the full stagger.
5. **Counter timing**: counters start 0.10-0.20 s after the opponent's peak extension, about halfway through his retract; punish window ~0.2-0.4 s (retract + torso recovery); only punches thrown when the off-hand is down/away are free hits.
6. **Positional blocking**: gloves/forearms are real geometry. Frontal jabs/crosses are absorbed with 0.2 HW glove recoil and 3-5 deg head pitch; hooks and body shots go around/under a guard that is not already on the side; blocked punches produce a small spark and 0.1-0.2 s recovery (no stagger).
7. **Body-first telegraph**: hip/shoulder rotation 0.07-0.13 s before the glove moves. Body shots show 0.2 s of drop (glove to hip + 15-25 deg torso open). Hook wind-up shows ~90 deg of torso turn (back to camera) on the long hook.
8. **Duck/dip counters**: forward torso pitch 35-40 deg and head down ~0.8 HW in 0.15 s with a body shot out of the dip; recovery 0.2 s. Lean back ~0.7 HW head travel and 15 deg pitch in 0.1 s.
9. **Close range shortens everything**: elbows bent 90-110 deg, glove travel ~1 HW, 0.2-0.25 s per punch, head pitch 5-10 deg; heads/shoulders touch at 0-1 HW; bodies push apart 0.3-0.5 HW per 0.2 s, no hard stop or pass-through; gloves overlap/tangle without freezing.
10. **Soft, damped footwork**: steps 0.25-0.3 s, ease in/out; weight to rear leg 0.1 s before a punch; approach 6-8 HW -> range over 1.5-2 s; one back step after a hit; torso re-squares within 0.2 s.
11. **Distance-driven camera with long damping**: wide/high (fighters 15% of frame height) when apart, push in to 60-75% over 1.5-2 s as they engage, then orbit 20-35 deg/s during exchanges at head height and 3-4 m; lag 0.2-0.3 s; ~5% punch-in on big hits, no shake. Keep a jump-cut-free damping.
12. **Hit feedback without hit-stop**: small glove-level spark (teal puff ~0.5 HW), a brief edge-of-screen cyan flash (~0.03-0.07 s, 1-2 frames at 30 fps), a red damage tint on the face, and the knockdown as a ~1 s ragdoll-like slide to the floor (0.75 s to collapse, limbs overshoot) with the standing fighter staying in guard.

## Caveats / uncertainty
- Timings from 30 fps tiles have +-0.033 s error, and the tile view makes the exact moment of contact a judgement call.
- Because of jump cuts and unknown camera FOV, the distances in HW are estimates (+-30%).
- I did not see uppercuts landing, slips, rolls, parries, power-punch charge-ups, or fighters being rocked with a standing stagger more than 1 step; those are gaps to fill from another source or by recording from FNC itself.
