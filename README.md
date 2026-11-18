# KnockNight (Godot 4.7)

Native Godot build of KnockNight (Godot 4.7, GDScript only).

- Engine: Godot 4.7.2 mono (GDScript only), Jolt physics at 120 Hz.
- Run: open this folder in Godot and press F5 (main scene `scenes/main.tscn`).
- Fighters: `node tools/build_fighters.mjs` rebuilds `assets/fighters/{viper,anvil}.glb` (451 clips) and `data/clips.json` from `_source/`.
- Design: `docs/gameplay-spec.md` (rules and numbers distilled from the Rust sim).

## Tests
`godot --headless --path . --script res://tests/<name>.gd` for `test_fighter_import`, `test_combat_rules`,
`test_input_movement`, `test_fight_sim` (add `--fixed-fps 120` to run fast), `ui_flow_test`.
Windowed screenshot scripts: `tests/capture_real_fight.gd`, `tests/capture_jab.gd`, `tests/capture_shots.gd` (to `_build/shots/`).

## Movement controls: fighter-relative or camera-relative
Setup screen row "P1 MOVEMENT" (and "P2 MOVEMENT" for a local second player), saved in `user://settings.cfg` (`scripts/game_settings.gd`):
- **Toward foe (default, Fight Night style)**: W / up = toward the opponent, S = away, A / D = circle left / right around him, whatever the camera does.
  The analog lean (modifier + move keys) follows the same frame; Q / E and the right stick lean sideways relative to the fighter.
- **Camera relative**: W = away from the camera, A / D = screen left / right, using the camera's current yaw. Q / E and the stick's side lean are
  screen left / right too.
Match config keys: `p1_movement_mode` / `p2_movement_mode` (or `movement_mode` for both): `"fighter"` | `"camera"`. CPU and dummy input is unaffected.

## Defence family and analog lean (docs/gameplay-spec.md section 4)
The current slip/lean pose pass uses the supplied **Fight Night Round 4** short (`egmZEOilUR4`) as its visual reference.
Leans start from the normal guard, load the hips/knees, and preserve foot position and sole orientation. Input release goes
straight back through the lean spring; quick taps no longer force a 0.37-second full-depth hold. The free lead hand stays
lower than the rear guard, while blocked leans retain the protective hand bounds. Counter clips take over their embedded
lean continuously according to both action-slot weights.

The source-aligned pulse uses `scenario=slip_l start=0.20 release=0.33 seconds=0.70`. The source's
4.7–5.3 second action aligns with this direction; earlier `slip_r` comparisons are superseded. Guard IK
uses fitted visible glove/head centres and retains the glove's orientation while moving its elbow.
Final contact clearance bends elbows away from the opponent's final rendered hulls, retaining the live
striking hand transform; only recovery can add a bounded wrist withdrawal. Close-range overlap is still
under visual review. This is an implemented visual pass, with exact 1:1 parity still open.

At boxing engagement range, the free guard now keeps the same low lead glove through idle, slip and
release. Counter entry retains the incoming loaded hip/head posture through startup, then uncoils
towards contact instead of immediately straightening into the incoming jab. The hand is captured before
this layer's lean and restored after its body adjustment. `scenario=counter_back` captures the pull-to-hook
transition alongside left/right slip counters.

Free guard wrists follow the fitted cuff-to-knuckle axis and solved forearm with a bounded correction.
After rotation, the arm is re-solved to keep the visible glove centre on its original target. Blocked
hands and the active striking hand retain their animation orientation. Source cuff occlusion still
prevents an exact wrist-roll claim.

The uncovered frontal demonstration at 22.20–24.10 s keeps the face visible beside the rear glove.
The free rear-glove target now sits slightly farther to the side; this is a visibility refinement,
not an exact camera/stance reconstruction. The supplied Champion jab short (`K966_uJaa0A`) adds
brief recoil-to-straight cues. Jabs/crosses retain their target lane within reachable arm length
while the torso uncoils from a lean. `counter_tag=LJab` or `counter_tag=RJab` captures literal
straight counters alongside the default authored rear-hook counter. Marked straight counters
retain more of the loaded torso through contact (40%; ordinary straights 15%). `opponent_tag`
selects the incoming action independently. The primary timing fixture uses an incoming RJab at
0.30 s and return LJab at 0.55 s, with source time = game time + 3.5 s. Its guard contact near
0.767 s aligns with source 4.267 s; stance and camera orbit still differ, and the source's
glove overlap leaves its hit-versus-block outcome uncertain.
Near-range marked head straights retain a flexed elbow through a bounded shoulder-to-wrist reach
cap along the existing strike lane. Ordinary unmarked straights, body jabs and authored hook
counters retain their previous paths. The capture records actual shoulder/elbow landmarks,
`counter_reach_trim`, and an optional starting `gap` for review. Contact still uses glove geometry.

The lateral slip now loads the hips backward by up to 0.09 m, sinks them by up to 0.15 m, and folds the
torso forward by up to 35 degrees before the other pose layers. This brings the head ahead of the hips
without the former deeply folded front knee. Release follows the spring with a 0.90 speed multiplier;
it remains continuous with no minimum hold. `scenario=forward` separately captures the held forward
analog lean rather than using the authored duck as its proxy.

`tools/capture_fn_fight.gd` captures a CPU boxing exhibition through the normal gameplay camera/HUD,
with fixed render-frame sampling and a frame/state manifest. It is a visual capture utility and runs
no assertions. Pass `out=<absolute folder>` and optionally `fps=10 seconds=10` under `--fixed-fps 120`.
Both capture tools use a capture-only main script whose pause operation is disabled, so a hidden
background render cannot stall on focus loss. The normal game's pause behavior stays enabled.

Visual capture: `tools/capture_fn_match.gd` records real rendered frames plus input/bone/camera manifests. Parameters include
`scenario=all`, `model=meshy_viper`, `solo=true`, `fps=30`, `yaw=55`, `side=-1`, `elevation=35`, and `out=<absolute folder>`.
For the short source pulse use `scenario=slip_l start=0.20 release=0.33 seconds=0.7`. See `docs/reference/fn-visual-review.md`
for timestamped reference comparison. Visual evidence does not establish exact parity across all animations or rigs.

Head movement is an analog lean (Fight Night style). Hold the lean modifier and the move stick leans the upper body in any direction
(sideways = slip, back = pull / sway, forward = bob, diagonals), proportional to the stick, released = back to guard. The feet stay planted
while leaning. Lean speed is the per-fighter head-movement stat (`Roster.head_movement`, Viper 1.25 .. Oak 0.78), slower when tired or rocked.
You can punch from the lean: the lean is held through the throw (slip + hook, lean back + counter straight, duck + uppercut). Slipping a head
punch and countering inside ~0.4 s gives the counter bonus. A hit while leaning is layered on the held lean (stronger leaning into a hook or
back into the tip of a straight); heavy shots break the lean into the normal stumble.

| Move | P1 keys | P2 keys | Pad |
|---|---|---|---|
| Analog lean (any direction) | Tab + W A S D | ] + arrows | right stick |
| Quick side lean (full slip) | Q / E | Delete / PageDown | right stick L / R |
| Quick lean back (pull) | Y (or Q / E + move away) | [ | right stick up |
| Duck / bob forward | Ctrl or C or B | Numpad* | right stick down (partial = bob, full = duck) |
| Deep roll (beats hooks) | Ctrl + Q / E | Numpad* + Delete / PageDown | right stick down + L / R |
| High block | Space | Enter | RT |
| Shell / shoulder-roll | Space + Left Alt | Enter + Backslash | RT + LB |
| Small head tilt behind the guard (any lean while Block is held, 55 % depth) | Space + lean | Enter + lean | RT + right stick |
| Backstep (B Dodge) | G | End | D-pad right |

Footwork eases in (~0.17 s to full speed) and out (~0.12 s); no instant starts or direction snaps.
Code: `scripts/fighter/lean_pose.gd` (spring + pose + neck / glove guard), `defence_moves.gd`, `defence_pose.gd` (roll hinge), `scripts/ai/cpu_defence.gd`.
Tests: `tests/test_lean.gd`, `tests/test_defence_family.gd` (`--fixed-fps 120`). Sheet: `tests/capture_lean.gd` + `tools/make_lean_sheet.py`.

## Blocking, leaks and parry (guard pass)
- Two block heights (Block = head, Block + Body modifier = body): a body shot into a head guard and a head shot into a body guard land clean; the CPU switches level against a raised guard.
- A punch that touches the gloves is graded by `scripts/combat/guard_model.gd` (pure, tested in `tests/test_guard.gd`): lanes front (straights) / side (hooks, overhands) / gap (uppercuts) per block style (high = anvil, peek-a-boo = viper, shell, long / lead-low). Leak = 1 - cover + penalties (wide hook -0.32 side cover, tight +0.12, guard raised < 0.15 s ago up to +0.45, guard meter < 40 %, fatigue, loaded punch, guard knocked open, fist grazing the forearm).
  Leak < 0.30 full block (chip only); < 0.55 partial (30-60 % of the damage + head tilt); otherwise pierce (70-90 % damage, clean hit, rock gain x0.6, never floors anybody).
- Parry: a block press 0.03-0.15 s before a straight / ordinary hook lands (0.12 s window, x0.8 for hooks, narrower when tired; not vs uppercuts, body shots, kicks, loaded / wide punches). A press within 0.6 s of the previous press cannot parry (no mashing), costs 7 stamina, no damage and no guard loss. The glove swipes the punch off line, the attacker's arm is batted aside, his recovery is +0.30 s (he cannot block or walk out of it, combo cleared) and the parrier gets a 0.6 s counter window (the punish counts as a counter). HUD shows PARRY.
- Blocked loaded shots leave the hitter open ~0.12 s longer (earned counter). Only loaded power shots knock the guard open (+0.22 leak for 0.25 s).
- Glove knock (`scripts/fighter/guard_knock.gd`): blocked punches push the gloves 4-10 cm back toward the face / aside, springing back in ~0.3 s (< 1 cm by 0.4 s).
- The guard takes ~0.1 s to come up and 0.06 s to drop. The old "hands-down" idle variant (both gloves at the hips, picked at random whenever the foe was ~1.5 m away) was removed from the rotation; it remains only as a subtle post-knockdown / round-start relax, and low-hand variants are not picked for 2.5 s after an exchange.

## Body contact (chest to chest)
When the bodies touch (see the contact rules below) the fighters are in contact. Each pushes with `mass x drive x stamina`; the pair then moves as one body, so
the stronger man walks the other back (equal pushes stall, a passive fighter plants his feet but still gives ground to a heavier one) and the
ropes stop whoever is driven into them. Leaning costs stamina (the pressed fighter more, more again on the ropes or when tired). Masses:
`scripts/fighter/roster.gd` (Viper 0.90, Anvil 1.10, Oak 1.30). The torso reacts (`scripts/fighter/contact_pose.gd`): the presser leans in with his
head to the side, the pressed fighter braces, a spring-damper trunk overshoots and settles.

| Input | P1 | P2 | Pad | Result |
|---|---|---|---|---|
| Shove off | T | Backspace | D-pad left | two-hand shove in contact: opens 0.4-0.6 m (strength difference), costs stamina, you cannot punch for ~0.4 s; the shoved fighter is off balance (guard locked, no punch for ~0.28 s); into the ropes it opens less and rebounds |

- Smothered punches: at contact range straights and wide hooks lose damage (jab x0.58, std hook x0.75, wide hook x0.55); uppercuts and body shots keep it
  (`BodyContact.smother_factor`, applied as `ctx["smother"]` in `CombatRules.compute_damage`).
- Referee break: locked chest to chest (both pressing, or one pinned and leaned on) for 2.5 s without a punch -> "BREAK", the pair is walked apart to 1.2 m.
- CPU (`scripts/ai/cpu_contact.gd`): pressure fighters lean on the foe and work short punches, out-boxers shove off when leaned on / pinned.
- Bumps: fresh contact at speed (closing speed >= 1.0 m/s incl. entry steps, >= 0.5 m/s when the driver is mid-punch and has missed) is a collision, a 1-D
  momentum exchange by mass (restitution 0.3). The driver is stopped and stumbles (entry step cancelled, off balance ~0.4 s, no punch ~0.25 s); the other is
  bumped back >= 5 cm and his guard jolts. A driver who whiffed (overextended) is not stopped: he stumbles on into the foe, chest to chest, head on his shoulder.
- Inside fighting (chest to chest, "clinch but not clinch"): both bend sideways so the heads pass cheek to cheek (> 15 cm apart); a slow head-position battle
  (strength, drive, `head_push`) decides who holds the inside (bends further, short punches x0.88..x1.12, `smother_for`); gloves go tight to the chin; a guarding
  fighter (block input, or the CPU) puts his lead forearm on the foe's chest to frame: it holds the root gap at 0.775 m instead of 0.725 m and costs a little stamina;
  pressing fighters strain (trunk tremor) and lean harder, the weaker is walked back; orbiting each other at speed is damped in contact (`TURN_DAMP`).
- CPU (`scripts/ai/cpu_contact.gd`): chest to chest each brain picks a work for ~1 s by style (head position, frame, push, body / uppercuts); pressure fighters push and
  work the body, out-boxers frame and shove off when leaned on / pinned.

## Camera (Fight Night style, steady)
`scripts/camera/fight_camera.gd`: a broadcast side view at a fixed chest height (eye 1.5 m, look-at 1.15 m), no roll of its own. Distance = 5.0 m + 0.35 x separation
(5.0-6.8 m) through a slow spring. The view yaw is perpendicular to the fighters' line, but the line is low-passed (harder in a clinch) and the view only re-aims once
the line has turned past a ~29 degree dead-zone, then eases round with a ~0.8 s critically damped spring capped at ~10 deg/s (up to 26 deg/s when the view is badly
oblique). The look-at point has its own 0.35 m dead-zone. The camera side only flips when the pair is > 2.3 m on the far side. Keep-out of the ropes is continuous.
Routine hits do not shake the camera (light: none, medium ~0.3 deg, power / counter ~2 deg); rock and KO keep their image-space effects (fov push, roll, blur), which
never move the framing. `tests/test_camera_steady.gd` measures yaw rate / jumps over a 60 s CPU fight.
- Code: `scripts/fighter/body_contact.gd`, `contact_pose.gd`. Tests: `tests/test_body_contact.gd` (`--fixed-fps 120`), `tests/test_camera_steady.gd`.

## Stamina, fatigue and rocked pacing (fatigue pass)
- Stamina is a real resource: strikes cost x1.15 (power shots x1.3 more), a whiff costs +50 %, blocking / being hit drains it, regen is 26/s standing off,
  15/s moving, 10/s guarding, 2/s mid-strike; every round wears 10 off the pool and the rest minute refills 75 % of what was spent.
- `Fighter.fatigue` (0..1, under 42 % stamina) slows strikes up to x1.65, cuts outgoing damage 34 %, slows footwork, drops the gloves and adds heavy breathing
  (`scripts/fighter/fatigue_pose.gd`), forbids hooks / uppercuts / kicks under 20 %, flashes the HUD bar ("GASSED") and shows a GASSED tag (`status_tag.gd`).
  Numbers live in `scripts/combat/fatigue.gd`; CPU stamina behaviour in `scripts/ai/cpu_stamina.gd`.
- Rocked: a clean power hook rocks (`CombatRules.ROCK_TOTAL` 8.4, counters 7.0, meter 40), 14 s grace after a rock, ROCKED! tag + camera kick + stun sound.
  Knockdowns need a rocked or nearly finished head, 12 s grace after getting up, TKO = 3 in a round or 4 in the bout, damage scale 0.55.
- Diagnostics: `tools/fight_stats.gd -- diff=hard secs=180 rounds=3 seed=N [spam=1] [trace=1 every=10]`; tests `tests/test_fatigue.gd` (`--fixed-fps 120`);
  footage `tests/capture_fatigue.gd` (windowed, `_build/shots/fatigue_*.png`, `rocked_cam_*.png`).

## Punch commitment and punish windows (scripts/combat/commitment.gd)

- A punch cannot be cancelled into a block or a walk until its retraction is done (`CommitmentScript.lock_end`): jab ~0.38 s, cross ~0.55, hooks ~0.58, uppercuts ~0.62, body shots +10 %, loaded (power) versions ~x1.35. A scripted-literal test per punch lives in `tests/test_commitment.gd`.
- A miss overextends: +0.10 s (jab), +0.25 (hook), +0.30 (uppercut), +0.40 (loaded). A blocked punch adds +0.08 / +0.12 / +0.15. A whiffed loaded punch cannot be chained out of.
- While a whiffed punch is recovering the puncher is open: a punch that lands is a counter x1.35 damage, rock gain x1.8 (normal counter x1.25 / x1.5).
- An uppercut that lands on a head that is low or forward (`Fighter.head_low_or_forward()`: crouch, body shot in flight, whiff overextension, forward lean) is a punish: x1.5 damage, rock gain x2, knockdown check treats it as exposed.
- Hits on a punching / idle fighter flinch in proportion to damage (counters x1.25, lost trades x1.2), medium and heavy hits add a step back, a heavy counter knocks the victim's committed punch off line.
- CPU: no block until the lock ends, counters on whiffs (and, less often, on blocked punches) with an uppercut when the foe's head is low, loaded punches are rare unless the foe is hurt.

## Punch variety
Every jab / cross / hook / uppercut (and the body versions) has several variants (`data/punch_variants.json`, built by
`tools/gen_punch_variants.py`, layered on the strike table by `StrikeDB`; contact windows measured per variant with
`tools/measure_strikes.gd`, landing ranges with `tools/scan_variants.gd`). The variant is chosen by how you press:

| Input | P1 | P2 | Pad | Result |
|---|---|---|---|---|
| Tap | J K U I N M | Numpad 1-6 | X / Y (+ LB hooks, RB uppercuts) | the standard punch (a clip alternate each time) |
| Power modifier + punch | R + punch | / + punch | R3 (right stick click) + punch | loaded power punch: lunging step-in jab / cross, wide looping hook, rising uppercut, loaded body shot - slower, wind-up dip, more reach and damage, always lands heavy, overextends and is wide open on a miss |
| Quick re-tap (within about 1 s of the last punch) | same keys | same | same | flick: fast, short, light jab (double / triple jab by tapping again as each one starts); a re-tapped hook is a tight hook |
| Tap while moving towards the foe (gap > 0.9 m) | move + jab | | | step-in jab |
| Tap while moving away | move away + jab | | | pull-back jab (steps back as it lands) |

Per throw there is also +-6 % speed, a different torso rotation and a small aim correction towards where the foe's head was
when the punch was thrown. The CPU picks variants from range, the foe's guard, stamina and whether the foe is hurt (`scripts/ai/cpu_punch.gd`).
Code: `scripts/combat/punch_variants.gd` (choice, no repeated clip, steps, miss tail), `scripts/fighter/punch_pose.gd` (procedural
wind-up, torso turn, aim, overextension). Test: `tests/test_punch_variety.gd` (`--fixed-fps 120`). Footage: `tests/capture_punch_variants.gd`.

## Hit registration (contact only) and the F3 debug view
- Every fighter has hit / hurt / guard volumes fitted to the visible mesh of his model (`scripts/fighter/hit_fit.gd`, generated by `tools/measure_hits.gd`
  which bakes the skinned mesh in guard / slip / duck and fits head capsule + chest / abdomen rounded boxes + forearm / glove capsules + a 5-7 cm fist sphere
  per roster model). `tools/measure_hits.gd -- write=1` regenerates the table; the report compares old vs new volumes.
- A punch registers only when the fist sphere really intersects a target volume: the sphere is swept from its position last physics frame to now
  (`HitAreas.sweep`, exact distance fields, no tunnelling at any fist speed). No intersection, no hit. Quality = how centred the blow is x how squarely it
  travelled into the surface (speed along the normal). A touch shallower than 1 cm is held while the glove is still advancing and lands as a **glance**
  (12 % damage, no rock / knockdown, small flinch) if it never gets deeper.
- Body contact (clinch, bump, push, shove, smother) triggers only when the bodies touch (`HitAreas.contact_gap`: torso hulls, head and the arms / gloves
  of one fighter against the torso and head of the other, <= 1 cm; gloves against gloves do not count). The movement capsule is only 0.24 m wide now;
  how close two fighters get is decided by their visible bodies (eased apart when they overlap).
- **F3** toggles the overlay: hit spheres red, hurt hulls blue (torso orange), guard hulls green; every landed blow flashes its contact point on the
  foe's skin for 0.8 s (red hit, yellow glance, green block).
- Tests: `tests/test_hit_contact.gd` (`--fixed-fps 120`).

### Hits follow what you see; every touch has an outcome and a reaction (fn3/hits)
- **One source of truth.** For the Meshy roster the volumes above are re-mounted on the VISIBLE skeleton (`scripts/fighter/hit_fit_vis.gd`, generated by
  `tools/fit_visible.gd`; `FighterRig.rebind_visible`, `MeshySkin.mount`). The fist sphere sits on the bone of the glove you see, the head / torso hulls on
  the visible head and spine. Before, they rode the hidden M3DMale bones and only matched the skin in the guard pose it was fitted in.
- **No silent whiff.** A glove that touches the foe's glove / forearm while he is not blocking is a soft block (gloves in the stance still stop it:
  reduced chip, no guard-meter loss); a head punch that only reaches the chest of a slipping foe (or the reverse) is a glance on the zone it touched.
  Both are decided on the last frame of the strike window, so a punch still on its way to the head is not cut short. When the foe is slipping / ducking
  (`dm.evading()`) such a touch stays a MISS (miss penalty, his counter window, `whiffed` signal: the defence rules), but it is felt (a flinch, a glove knock).
- **Every outcome is felt** (`HitFlinch.impact`, called from `Fighter._react`): an impulse into critically damped head / neck / spine / hip springs at the
  contact point, scaled by the punch (jab .6 .. power hook 1.0) and the outcome, added on top of whatever the fighter is doing (a slip is never cancelled).
  Blocks drive the struck glove back to the face (`guard_knock.gd`, >= 7 cm), glances and clashes nod the head.
- **No glove through the head** (`scripts/fighter/impact_hold.gd`, the last pose layer on the attacker): the striking glove is stopped on the foe's skin, a
  landed blow holds it there for 40-95 ms (hit-stop) while the head snaps away, then it eases back. The hit sweeps use the path WITHOUT this correction
  (`Hitbox.clamp_delta`), so which blows land, when and how hard is unchanged.
- Tools: `tools/probe_hits.gd` + `tools/probe_hits_report.py` (`tools/run_probe.sh <tag>`): scripted jab / cross / hooks / uppercuts / body shots from out of
  reach to point blank against an idle, blocking and slipping foe on three Meshy pairs, plus a 90 s CPU fight; logs the visible skin-to-skin contact, the
  gameplay contact, the outcome, the deciding rule (`atk["why"]`) and the foe's reaction against a no-punch control. `tools/capture_hits.gd` +
  `tools/make_hits_sheet2.py` build the 30 fps contact sheets. Test: `tests/test_hit_registration.gd` (`--fixed-fps 120`).
