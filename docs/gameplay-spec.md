# KnockNight Godot - Gameplay Spec

Source of truth: the 120 Hz fight model (Rust `src/*.rs`, three.js layer `web/js/*`, `strikes.json`, `sounds.json`). This is the behaviour spec for the native build. Numbers come from code unless marked **(?)** = uncertain / inferred / quirk worth a human decision. The `docs/combat*.md` files named in the README do not exist in the repo; README, `docs/claude-plan60/PLAN.md` and `handoff.md` were used instead.

Conventions: metres, seconds. P1 starts at x=-1.15, P2 at x=+1.15, z=0. "L"/"R" = left/right hand or foot (orthodox: L is lead). Sim timing is a **fixed 120 Hz step** (matches Godot `physics_ticks_per_second=120`); frame dt clamped to 50 ms.

---
## 0. Architecture facts that shape everything

| Fact | Consequence for Godot |
|---|---|
| Sim owns state, timers, damage, stamina; the renderer owns bones. Contact is decided by **animated limb capsule sweeps** (glove/foot vs head/body/leg) with evidence `quality 0..1` (centredness), `speed m/s`, `clearance m`, `kind` (target / guarding glove / glove-vs-glove clash). Clip timing windows are only a fallback. | Area3D hitboxes on hand/foot bones, swept each physics tick; compute quality and closing speed. |
| 10 collision groups: `LHTH RHTH LHTB RHTB LLTH RLTH LLTB RLTB LLTL RLTL` = (L/R)(H hand / L leg)(T)(H head / B body / L leg). Each strike names its group (`group` in strikes.json). | One hitbox layer per (limb, target zone). |
| One hit per strike (`hitdone`), evidence tied to a per-strike serial. | Strike instance id; ignore repeat overlaps. |
| Hit-stop is **0** on every hit (only camera/screen response). | No time freeze. |
| Slips are not invulnerability in the real path: a head strike is avoided only if the head geometrically leaves the glove path. Fallback (no masks) skips head hits while `dodge_t > 0.20`. | Slip/duck poses must move the head hurtbox. Optional 0.20 s fallback. |
| Fighters always face each other (`facing = sign(foe.x - self.x)`, renderer turns roots toward foe in XZ). `stands` = +1 orthodox / -1 southpaw (X key) mirrors animation and flips strike side. | Auto-face; mirror rig on stance switch. |
| No difficulty setting exists; CPU has one fixed profile. | Add knobs yourself (sec. 8). |
| Round/phase/HUD data cross a 512-float state buffer; irrelevant to Godot. | - |

---
## 1. Controls

Keyboard events are queued in key-down order (up to 8 pending per player), so same-frame J+K are two events.

### 1.1 Keyboard (local versus exists: Exhibition -> Opponent "LOCAL 2P")

| Action | P1 | P2 | Kind |
|---|---|---|---|
| Move left / right / depth-away (up) / depth-toward (down) | A / D / W / S (Z = down alt) | Arrows (PageUp = down alt) | held |
| Block (guard) | Space | Enter | held |
| Body modifier (body target / body guard) | Left Shift | Right Shift, Numpad9, Digit9 | held modifier |
| Duck | Left Ctrl, C, B | Right Ctrl, NumpadMultiply | held |
| Slip left / right | Q / E | Delete / PageDown | held (tap = short slip) |
| Backstep (B Dodge) | G | End, NumpadDecimal | edge |
| Left / right jab | J / K | Numpad1 / Numpad2 (Digit1/2) | edge |
| Left / right hook | U / I | Numpad3 / 4 (Digit3/4) | edge |
| Left / right uppercut | N / M | Numpad5 / 6 (Digit5/6) | edge |
| Left / right kick (head round) | O / P | Numpad7 / 8 (Digit7/8) | edge |
| Low kick L / R | Comma / Period | NumpadSubtract / NumpadDivide | edge |
| Alt-kick modifier ("SPEC": front kick) | F | Numpad0, Digit0 | held modifier |
| Selected catalog strike (any of 74) | V | NumpadAdd | edge |
| Taunt | H | Home | edge |
| Stance switch | X | Insert | edge |
| Pause / resume | Esc | (same) | global |
| Restart bout / toggle P2 CPU / toggle P1 CPU | R / T / Y | - | debug |
| Controls help | ? | - | global |

Modifier resolution: hand key + Body -> BodyJab / BodyHook / BodyUppercut. Kick key alone = `Round` (head); +SPEC = `Front` (head); +Body = `BodyRound`; +Body+SPEC = `BodyFront`; +Low = `LowKick` (Low wins over Body). Boxing: leg strikes are rejected in `begin_move`.
Selected strike (V / pad L3) throws any of the 74 moves; keep as training/debug.
**Feint**: no player feint input exists. Feints are CPU-only (sec. 4.4). Add one if wanted.

### 1.2 Gamepad (standard mapping; slot 0 = P1, slot 1 = P2; bindings are remappable)

| Control | Action |
|---|---|
| Left stick | Move |
| X (btn2) / Y (btn3) | Left jab / right jab |
| A (btn0) / B (btn1) | Left / right round kick |
| Hold LB (btn4) + X/Y | Hooks. LB + A/B = low kick |
| Hold RB (btn5) + X/Y | Uppercuts |
| Hold LT (btn6) | Body modifier (also body guard with RT; A/B become body kicks) |
| Hold RT (btn7) | Block |
| Right stick left / right | Slip L / R |
| Right stick up / down | Backstep / Duck |
| L3 (btn10) | Selected strike; D-pad left/right cycles it (skips ruleset-disabled strikes) |
| D-pad up / down | Taunt / Stance switch |
| Start (btn9) / Back (btn8) | Pause / menu back (menu: A accept, B back, LB/LT/RB/RT tabs) |

Stick deadzone: on 0.5, off 0.35 (hysteresis). Rumble on every hit taken: 70 ms, strong 0.18, weak 0.35. SPEC has no pad binding. Touch controls exist for phones (skip in v1).

### 1.3 Tap, double-tap and buffer rules
- **Double-tap a direction** (same key, <=0.28 s, not opposed, human only, stamina >= 8, 0.38 s cooldown, from Idle/Walk/Block/Slip/Crouch, not rocked): burst step, **0.42 m over 0.22 s** (quintic ease), costs 8 stamina, regen lock 0.38 s. Interrupted by punch entry or being hit.
- **Action buffer** (max 2): while attacking, in hitstun, slipping, ducking or rock-locked, fresh action presses queue. Lifetime = remaining action + recovery tail + 0.25 s (0.25 s when idle/hitstun). Same-hand repeat replaces the queued entry. Held guard, new movement, a new duck/slip press, or a hit clears the queue, except a counter queued from a held slip/duck or in hitstun ("protected").
- Held punch keys never auto-repeat.
- Cancels out of an attack: defence (Block held / queued defence) at action progress >= **55%** hands, **78%** kicks; movement at >= **85%**.

---
## 2. Fighter state machine

States (sim ids): IDLE 0, WALK 1, BLOCK 2, ATTACK 3, HIT 4, DOWN 5 (lost/KO'd, terminal), WIN 6, SLIP 7, TAUNT 8, STANCE 9, CROUCH 10, FALL 11, GETUP 12, COUNT (13).
Parallel layers (not states): **rock/stun flag**, **guard layer** (block_on / body_block_on, masks over locomotion), **duck_weight** and **slip_axis** (smoothed posture; duck rises at rate 32/s, falls 16/s; slip 32/s, 36/s on reversal, 28/s release), **feint overlay**.

| State | Enter | Duration / exit | While in it |
|---|---|---|---|
| IDLE / WALK | default / move input | velocity accel rate 14/s, brake 20/s (CPU 10 / 14) | everything allowed |
| BLOCK | Block held, guard meter > 0, not guard-locked, not ATTACK/HIT/TAUNT/STANCE | release Block; layer fade 0.10-0.12 s | walk 0.85 m/s; slip/duck compose with guard; no strikes (a fresh hand from held slip/duck opens guard) |
| ATTACK | `begin_move`: pays stamina, `mt=0`, sets play-rate so clip == action time | sec. 3. Ends at action end (+ recovery tail on miss/block), by chain gate into queued strike, or defence/move cancel | hands keep layered duck/slip and a weak walk; kicks do not |
| HIT | any non-absorbed hit | reaction length = clip length, then capped: jab 0.20, other hand 0.28, kick 0.34 s (x0.4 for glancing head hit). Break / Stun / PKO clips uncapped. -> IDLE | no move/guard/attack; posture + queued counter still live |
| SLIP | Q/E/G; stamina >= 3 (cost 3, regen lock 0.25 s) | directional: entry 0.09 s, held while key held and stamina > 0, release 0.14 s. Backstep: entry 0.16 s then release. `dodge_t = max(0.34 - elapsed, 0.18)`. Clip play-rate: directional 0.45 s, back 0.8 s | counter hand allowed from 0.08 s (directional: at once); Block/move cancels; Ctrl converts to CROUCH |
| CROUCH | Ctrl | "Crouch In" 0.24 s (play-rate 0.28 s), hold while key held (frozen at 84% of clip), "Crouch Out" 0.23 s | hand counters (uppercut flows out of duck); slip direction switch; walk x0.65 |
| TAUNT | H, not guarding | one of 17 random clips, full length | defenceless: +100% damage taken |
| STANCE | X, not guarding | `Switch Stands A/B` ~0.67 s (speed 1.5) | toggles `stands` |
| FALL | knockdown | 1.1 s -> COUNT | other fighter frozen |
| COUNT | after FALL | 2.9 s, anim paused, HUD `KNOCKDOWN / n` | - |
| GETUP | after COUNT | 2.0 s: `GetUpFace` if prone else `GetUpBack` -> IDLE, `guard_lock 0.3`, rock cleared | no input |
| DOWN / WIN | KO or decision | terminal | victory clip then `VictoryEnd` |

Rules
- While any fighter is in acute knockdown (FALL/COUNT/GETUP) the whole sim freezes: the other fighter is forced IDLE, queues cleared.
- Idle variation: in Neutral, every 2-5 s a random directional idle clip fades in (cosmetic).
- Fighters yield bodies at 0.60 m centre distance (pushed apart 50/50) so pocket work is possible; hit knockback adds a decaying velocity (0.016 m jab, 0.032 heavy, 0.045 kick, clamped 0.9 m/s, decay exp(-18 t)).

### 2.1 World phases
`PH_FIGHT` 0 -> `PH_END` 1 (round end or KO) -> `PH_MATCH` 2 (match over). Banner ids: 1 "ROUND n / FIGHT" (1.1 s), 2 K.O. (2.3 s), 3 winner/decision (2.7 s), 4 TIME UP (1.8 s), 5 DOUBLE K.O. draw, 6 knockdown.

---
## 3. Strikes

### 3.1 Rule sets
| | Boxing | Kickboxing (default) |
|---|---|---|
| Allowed | jab, hook, uppercut (head + body) | + front/round/low kicks, plus every catalog move via "selected strike" |
| Leg strikes | `begin_move` refuses; CPU substitutes RJab (head) / RBodyJab (body) | allowed |
| Targets | head, body | head, body, legs |
| UI metadata (not enforced by sim) **(?)** | `knockdownPolicy short-count, downSeconds 4, getupSeconds 2, scorecards` | same + legs |
The sim's actual knockdown timing is FALL 1.1 + COUNT 2.9 + GETUP 2.0 s regardless of ruleset.

### 3.2 Phases of a strike
Every strike has one **action duration** `A` (clip is time-scaled so clip length == `A`; rocked fighters use `A x 1.18`). Within `A`:
1. **Startup** - 0 -> contact start. Interruptible: a hit landing here is an "early interrupt" (counts as an earned counter for the hitter, x1.25 damage, if the victim is not yet `committed_hand`; hands become committed at `A x recoil x 0.35`).
2. **Active** - hit possible while the glove/foot hitbox touches a hurtbox inside the contact window `[c0,c1]` (below). Real contact is geometric; window is fallback and also bounds ghost hits (no hits after the clip ends).
3. **Recoil gate** - progress `recoil` (jab 0.34, hook 0.40, uppercut 0.42 of A; kicks per table). If nothing was hit by here, outcome = MISSED (with masks it stays provisional until clip end).
4. **Recovery** - to end of `A`. Chain gate = earliest follow-up (queued strike or CPU combo); defence gate (0.55 hands / 0.78 kicks) = earliest guard cancel; movement cancel at 0.85.
5. **Outcome tail** (extra committed time on the last pose; also the **counter window** for the opponent):

| Outcome | Light hand | Heavy hand | Light kick | Heavy kick |
|---|---|---|---|---|
| Clean | 0 | 0 | 0 | 0 |
| Blocked | tail 0.04 s, gate delay 0.025 | 0.07 / 0.04 | 0.04 / 0.03 | 0.06 / 0.035 |
| Missed | 0.06 / 0.04 | **0.24 / 0.15** | 0.05 / 0.04 | **0.24 / 0.06** |
Heavy = hooks, uppercuts, power ("P*"), OverHand, BackFist, any damage >= 20, all kicks. Tail ends early if the attacker chains or cancels into defence.

**Chain classes**: same-tag repeat or "paired" follow-up (e.g. LJab -> RJab/RHook/RUppercut/body variants; LHook -> RUppercut/RJab/RHook/LUppercut/LJab/LBodyHook; full list `combat_timing::paired`) uses the move's own chain gate; other hand->hand uses `max(chain, 0.82)`; hand<->leg uses 0.96 (to hand) / 0.88 (to leg). Chain gates in table are fractions already multiplied by A.
Footwork during a hand strike: held movement is allowed at 0.46x walk for jabs, fully planted for heavy hands until 78% of A; heavy hands release into movement during recovery. **Entry step**: punch auto-steps toward the foe if root gap in (0.80, 1.70) (1.75 for pressing lead jab): distance `min(gap-0.76, limit)` with limit jab 0.28 (lead jab while pushing forward 0.45), hook 0.42, rear uppercut 0.24, other 0.18, smoothstep over 0.24 s; cancelled if player moves away (dot < -0.3).
Reach: strike resolves only if the glove/foot touches; root-gap hard cap 1.45 m (fallback path). Measured: jabs/hooks connect at a 0.80 root gap, miss at 0.91 (arm reach is not stretched; footwork closes distance). CPU "striking reach" column below.

### 3.3 Strike table (all 74; generated from `moves.rs`, `combat_timing.rs`, `strike_cost.rs`)
Columns: `#` catalog index; **Clip** = exact animation clip name (clip length = action `A`); Dir = hit direction F/L/R/U(pper)/O(verhead) in attacker's orthodox frame (L/R swap for southpaw attacker and again for southpaw defender); Dmg/Blk = damage / damage-vs-guard before scaling; Stam = effective cost (strike_cost, replaces strikes.json `stamina`); Action = `A` seconds; Contact = window inside `A`; Recoil = miss gate; Chain = earliest follow-up; Reach = CPU commit reach (m). Limb = first letter of the tag (L/R hand or foot); tags ending in "Kick" are leg strikes (source=leg), everything else is a hand. **Keyboard-reachable** = LJab RJab LHook RHook LUppercut RUppercut, the six Body versions (LBodyJab ... RBodyUppercut), LRoundKick RRoundKick LFrontKick RFrontKick LBodyRoundKick RBodyRoundKick LBodyFrontKick RBodyFrontKick LLowKick RLowKick. Everything else (power/push "P" variants, OverHand, BackFists, BodyPush/Side kicks, spectacle kicks) is selected-strike only; the CPU combos additionally throw LFrontKick, RFrontKick, LBodySideKick, RBodySide1Kick, LLowKick, RLowKick.
Contact windows for **non-core** rows are the raw source-clip sample window / duration (unretimed); core rows use tuned values. Treat contact windows as **(?)** estimates; geometry decides.

| # | Tag | Clip | Zone | Dir | Dmg/Blk | Stam | Action | Contact | Recoil | Chain | Reach |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 | LBodyJab | L B J | body | F | 10/10 | 5 | 0.58 | 0.08-0.12 | 0.20 | 0.33 | 0.95 |
| 1 | LBodyHook | L B H | body | R | 20/20 | 10 | 0.74 | 0.18-0.21 | 0.30 | 0.50 | 0.98 |
| 2 | LBodyUppercut | L B U | body | F | 25/25 | 12 | 0.70 | 0.02-0.02 | 0.29 | 0.48 | 0.88 |
| 3 | LJab | L J | head | F | 5/5 | 5 | 0.58 | 0.28-0.44 | 0.20 | 0.32 | 0.95 |
| 4 | LHook | L H | head | R | 10/10 | 10 | 0.74 | 0.12-0.37 | 0.30 | 0.50 | 0.98 |
| 5 | LUppercut | L U | head | U | 15/15 | 12 | 0.70 | 0.12-0.70 | 0.29 | 0.49 | 0.88 |
| 6 | LPJab | L J P | head | F | 15/15 | 8 | 0.58 | 0.17-0.21 | 0.20 | 0.32 | 0.95 |
| 7 | LPHook | L H P | head | R | 20/20 | 12 | 0.74 | 0.40-0.49 | 0.30 | 0.50 | 0.98 |
| 8 | LPUppercut | L U P | head | U | 25/25 | 14 | 0.70 | 0.22-0.31 | 0.29 | 0.49 | 0.88 |
| 9 | LOverHand | L OverHand | head | O | 25/25 | 15 | 0.90 | 0.26-0.29 | 0.38 | 0.72 | 1.02 |
| 10 | LBackFist1 | L BackFist1 | head | L | 30/25 | 15 | 0.90 | 0.16-0.16 | 0.38 | 0.72 | 1.02 |
| 11 | LBackFist2 | L BackFist2 | head | L | 32/28 | 15 | 0.90 | 0.13-0.13 | 0.38 | 0.72 | 1.02 |
| 12 | LBodySideKick | L BodySideKick 306 | body | F | 30/30 | 17 | 1.35 | 0.34-0.37 | 0.57 | 1.30 | 1.35 |
| 13 | LBodyFrontKick | L BodyFront 307 | body | F | 33/32 | 13 | 0.86 | 0.28-0.39 | 0.44 | 0.52 | 1.35 |
| 14 | LBody1Kick | L Body1 301 | body | R | 35/33 | 17 | 1.35 | 0.23-0.29 | 0.57 | 1.30 | 1.35 |
| 15 | LBody2Kick | L Body2 302 | body | R | 35/35 | 17 | 1.35 | 0.47-0.63 | 0.63 | 1.30 | 1.35 |
| 16 | LBody3Kick | L Body3 303 | body | R | 36/33 | 17 | 1.35 | 0.23-0.31 | 0.57 | 1.30 | 1.35 |
| 17 | LBodyPushKick | L BodyPush 304 | body | F | 34/31 | 12 | 0.78 | 0.12-0.21 | 0.27 | 0.47 | 1.35 |
| 18 | LBodyRoundKick | L BodyRound 305 | body | R | 36/36 | 17 | 0.88 | 0.24-0.29 | 0.35 | 0.53 | 1.35 |
| 19 | LFrontKick | L Front 104 | head | F | 30/30 | 22 | 0.92 | 0.29-0.41 | 0.47 | 0.56 | 1.35 |
| 20 | LHeelKick | L Heel 103 | head | U | 35/35 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 21 | LFrontBounceKick | L Front 104 | head | F | 33/32 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 22 | LThrustKick | L Thrust 106 | head | F | 40/35 | 24 | 1.35 | 0.30-0.46 | 0.57 | 1.30 | 1.35 |
| 23 | LThrustSideKick | L ThrustBounce 107 | head | R | 32/33 | 24 | 1.35 | 0.40-0.53 | 0.57 | 1.30 | 1.35 |
| 24 | LRoundKick | L Round 101 | head | R | 42/35 | 24 | 0.96 | 0.23-0.28 | 0.34 | 0.58 | 1.35 |
| 25 | LFrontSideKick | L FrontSide 102 | head | F | 33/33 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 26 | LCrescentKick | L Crescent 108 | head | L | 31/31 | 32 | 1.35 | 0.43-0.63 | 0.63 | 1.30 | 1.35 |
| 27 | LArcKick | L Arc 110 | head | L | 36/36 | 32 | 1.75 | 0.48-0.65 | 0.73 | 1.68 | 1.35 |
| 28 | LDoubleKick | L Double 111 | head | F | 43/43 | 32 | 1.75 | 0.80-1.09 | 1.09 | 1.68 | 1.35 |
| 29 | LWheelKick | L Wheel 114 | head | L | 42/36 | 32 | 1.75 | 0.56-0.79 | 0.79 | 1.68 | 1.35 |
| 30 | LTwirlKick | L Twirl 115 | head | F | 40/44 | 32 | 1.75 | 1.08-1.20 | 1.20 | 1.68 | 1.35 |
| 31 | LDropKick | L Drop 116 | head | F | 51/51 | 32 | 1.75 | 0.82-1.57 | 1.57 | 1.68 | 1.35 |
| 32 | LJumpKick | L Jump 117 | head | F | 45/45 | 32 | 1.35 | 0.20-0.75 | 0.75 | 1.30 | 1.35 |
| 33 | LSpinKick | L SpinKick 119 | head | L | 49/45 | 32 | 1.75 | 0.37-1.33 | 1.33 | 1.68 | 1.35 |
| 34 | LLowKick | L LowKick | leg | R | 5/0 | 9 | 0.70 | 0.02-0.29 | 0.34 | 0.42 | 1.00 |
| 35 | RBodyJab | R B J | body | F | 15/15 | 5 | 0.58 | 0.06-0.13 | 0.20 | 0.33 | 0.95 |
| 36 | RBodyHook | R B H | body | L | 30/30 | 10 | 0.74 | 0.21-0.23 | 0.30 | 0.50 | 0.98 |
| 37 | RBodyUppercut | R B U | body | F | 35/35 | 12 | 0.70 | 0.19-0.23 | 0.29 | 0.48 | 0.88 |
| 38 | RJab | R J | head | F | 7/7 | 5 | 0.58 | 0.05-0.13 | 0.20 | 0.32 | 0.95 |
| 39 | RHook | R H | head | L | 15/15 | 10 | 0.74 | 0.10-0.26 | 0.30 | 0.50 | 0.98 |
| 40 | RUppercut | R U | head | U | 20/20 | 12 | 0.70 | 0.08-0.13 | 0.29 | 0.49 | 0.88 |
| 41 | RPJab | R J P | head | F | 25/25 | 8 | 0.58 | 0.17-0.21 | 0.20 | 0.32 | 0.95 |
| 42 | RPHook | R H P | head | L | 30/30 | 12 | 0.74 | 0.26-0.26 | 0.30 | 0.50 | 0.98 |
| 43 | RPUppercut | R U P | head | U | 35/35 | 14 | 0.70 | 0.19-0.25 | 0.29 | 0.49 | 0.88 |
| 44 | ROverHand | R OverHand | head | O | 30/30 | 15 | 0.90 | 0.21-0.52 | 0.38 | 0.72 | 1.02 |
| 45 | RBackFist1 | R BackFist1 | head | R | 35/30 | 15 | 0.90 | 0.16-0.18 | 0.38 | 0.72 | 1.02 |
| 46 | RBackFist2 | R BackFist2 | head | R | 37/33 | 15 | 0.90 | 0.20-0.51 | 0.38 | 0.72 | 1.02 |
| 47 | RBodySide1Kick | R BodySide1 413 | body | L | 40/40 | 17 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 48 | RBodySide2Kick | R BodySide2 415 | body | L | 43/42 | 17 | 1.35 | 0.56-0.82 | 0.82 | 1.30 | 1.35 |
| 49 | RBody1Kick | R Body1 401 | body | L | 45/43 | 17 | 1.35 | 0.24-0.42 | 0.57 | 1.30 | 1.35 |
| 50 | RBody2Kick | R Body2 402 | body | L | 45/45 | 17 | 1.35 | 0.28-0.32 | 0.57 | 1.30 | 1.35 |
| 51 | RBody3Kick | R Body3 403 | body | L | 45/40 | 17 | 1.35 | 0.24-0.42 | 0.57 | 1.30 | 1.35 |
| 52 | RBodyPush1Kick | R BodyPush1 404 | body | F | 42/42 | 13 | 0.80 | 0.13-0.18 | 0.27 | 0.48 | 1.35 |
| 53 | RBodyPush2Kick | R BodyPush2 405 | body | F | 48/42 | 13 | 1.35 | 0.19-0.28 | 0.57 | 1.30 | 1.35 |
| 54 | RBodyRoundKick | R BodyRound 407 | body | L | 48/45 | 17 | 0.82 | 0.15-0.23 | 0.28 | 0.49 | 1.35 |
| 55 | RBodyBackKick | R BodyBack 409 | body | F | 48/48 | 17 | 1.35 | 0.11-0.14 | 0.57 | 1.30 | 1.35 |
| 56 | RBodyFrontKick | R BodyFront1 410 | body | F | 41/41 | 14 | 0.90 | 0.29-0.41 | 0.46 | 0.55 | 1.35 |
| 57 | RBodyFrontSideKick | R BodyFrontSide 414 | body | F | 44/43 | 17 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 58 | RSlashKick | R Slash 210 | head | L | 44/40 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 59 | RWheelKick | R Wheel 219 | head | R | 46/43 | 32 | 1.35 | 0.41-0.57 | 0.57 | 1.30 | 1.35 |
| 60 | RHighKick | R High 201 | head | L | 44/44 | 24 | 1.35 | 0.25-0.31 | 0.57 | 1.30 | 1.35 |
| 61 | RFrontKick | R Front 203 | head | F | 45/45 | 22 | 0.88 | 0.15-0.21 | 0.45 | 0.54 | 1.35 |
| 62 | RThrustKick | R Thrust 204 | head | F | 48/44 | 24 | 1.35 | 0.16-0.51 | 0.57 | 1.30 | 1.35 |
| 63 | RRoundKick | R Round 205 | head | L | 52/35 | 24 | 1.00 | 0.18-0.27 | 0.34 | 0.60 | 1.35 |
| 64 | RFrontSideKick | R FrontSide 207 | head | F | 46/43 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 65 | RRoundHouseKick | R RoundHouse 209 | head | L | 48/43 | 24 | 1.35 | 0.46-0.59 | 0.59 | 1.30 | 1.35 |
| 66 | RSideKick | R Side 211 | head | L | 49/45 | 24 | 1.35 | 0.38-0.47 | 0.57 | 1.30 | 1.35 |
| 67 | RUpperKick | R Upper 212 | head | U | 48/40 | 24 | 1.35 | 0.43-0.61 | 0.61 | 1.30 | 1.35 |
| 68 | RAxeKick | R Axe 213 | head | O | 55/40 | 32 | 1.35 | 0.11-0.29 | 0.57 | 1.30 | 1.35 |
| 69 | RJumpKick | R Jump 214 | head | F | 50/48 | 32 | 1.35 | 0.20-0.73 | 0.73 | 1.30 | 1.35 |
| 70 | RFrontJumpKick | R FrontJump 215 | head | F | 48/48 | 32 | 1.35 | 0.53-0.64 | 0.64 | 1.30 | 1.35 |
| 71 | RHammerKick | R Hammer 216 | head | L | 43/41 | 32 | 1.35 | 0.58-0.70 | 0.70 | 1.30 | 1.35 |
| 72 | RWheelJumpKick | R WheelJump 217 | head | R | 54/52 | 32 | 1.35 | 0.54-0.56 | 0.57 | 1.30 | 1.35 |
| 73 | RLowKick | R LowKick | leg | L | 5/0 | 9 | 0.72 | 0.23-0.32 | 0.37 | 0.44 | 1.00 |

---
## 4. Defence

### 4.1 Block / guard meter
| Rule | Value |
|---|---|
| Guard types | High guard (Block) blocks **head** strikes; Body guard (Block + Body) blocks **body and leg** strikes. A head strike on a body guard (or vice versa) is not blocked. |
| Guard meter | 100 (`block_max`, rehab +30 between rounds, cap 100). Regens **18/s** while Block is NOT held and `guard_regen_lock` (1.1 s after a blocked hit) is 0. |
| Blocked hit (hand) | Only counts if a glove actually met the incoming fist first (`kind=guard`); otherwise held guard still absorbs for non-hand/native paths. Meter loss `clamp(blockDamage*1.5 + 7, 13, 32)`; health chip = `total x 0.12` to head or body; no reaction clip, block layer plays (sec. 6); outcome BLOCKED for attacker. |
| Guard break | meter <= 0 on a blocked head/body hit: meter = 0, `guard_lock 1.0 s` (cannot guard), full "Break" hit reaction (`... head punch Break` / `... body kick Break`), screen shake 0.18, no hitstop. |
| Blocked kick vs leg | Leg strikes with Body guard and meter > 10 are a "leg counter": defender takes a fixed small hit (L-direction strikes: leg value -5; R-direction: -damage x5 **(?)** source-port quirk) and leg *max* -damage x2, plays `L/R leg kick` reaction. Meter <= 10 -> normal leg hit. Recommend simplifying to "guarded leg kick = reduced leg damage + brief reaction". |
| Glove clash | Two near-simultaneous (<= 35 ms apart) jabs whose gloves meet: both deflect, outcome BLOCKED, no damage, shake 0.025, sound kind 4 flags 32. Later/looping fists meeting a glove count as a normal block. |
| Moving guard | Walk 0.85 m/s (layered with duck/slip: x0.68 more). Guard + slip/duck compose; Block alone cancels a slip/duck back to idle. |
| Feeling | Releasing Block is instant; guard layer fades in 0.10-0.12 s. Stamina regen is halved (11/s) while guarding. |

### 4.2 Slips, ducks, backstep
| Move | Input | Cost | Timing | What it does |
|---|---|---|---|---|
| Directional slip (L/R) | Q/E, RS left/right | 3 stamina (0.25 s regen lock); holding costs no more | entry 0.09 s (pose reaches peak), hold up to key release (needs stamina > 0), release 0.14 s. Defence anim authored lengths: slip 0.70 s (in 0.18 / out 0.53 / hold <= 0.4), sway (vs straights) 0.75 s (in 0.167 / out 0.583) | Head leaves the punch line (hips hinge, lean toward side, ankles planted, speed x0.90 when moving). **Intended** to beat straights and a late hook only partly (hooks tracked it in build 59) **(?)**; body and leg strikes still land |
| Duck | Ctrl/C, RS down | free | In 0.24 s, hold, out 0.23 s; authored duck 0.55 s (in 0.21 / out 0.34, hold <= 0.6) | Head drops under hooks/head kicks; moving duck 65% speed; body shots still land. Body punch from held duck is allowed and opens guard |
| Backstep | G, RS up | 3 stamina | entry 0.16 s, ~0.06 m root slide, release 0.14 s; clip `B Dodge` (0.82 s, phase 0.30 hold) | Pull-back vs straights (head back 0.2-0.4 m is the target, see PLAN) |
| Slip -> duck | hold Ctrl during slip | - | slip converts to CROUCH (crouch-in) and can return to the held slip | - |
| Burst step | double-tap direction | 8 | 0.42 m / 0.22 s | Evasive footwork, cannot be during strike/hit |
Slip/duck can be re-chosen instantly (L<->R) if stamina >= 3 without leaving the state. A hit during slip interrupts it (`slip_elapsed` reset); the reaction plays on top of the held lean.
`Reward timing` (earned counter): see 4.3.

### 4.3 Counters
| Source of counter bonus | Condition | Effect |
|---|---|---|
| **Slip/sway timing reward** | Slip held with *onset age* 0.04-0.22 s when the foe's committed **head** strike nominally overlaps the head but the real head clears it by **0 < clearance <= 0.12 m**, no touch/block on this strike, new strike serial, not already rewarded for this held slip. Duck counts as a held slip for the timer. | Opens a **0.30 s counter window**. The next fresh strike press inside it (rising edge, not auto-fire) *consumes* it: `counter_power = 1` -> counter damage x1.25, impact class COUNTER, finishing-power eligible. Cancelled if the slipper is touched. |
| **Whiff punish** | Defender is in outcome tail (`counter_window > 0`), or `miss_provisional`, or attack outcome MISSED | Hitter's strike is "earned counter": x1.25, `counter_power >= 0.25` |
| **Interrupt** | Defender is mid-attack but not yet committed (startup) | same as above |
| Other damage bonuses | see sec. 5.1 | - |
Counter from a held slip/duck: a hand queued from slip/duck launches as soon as Block is released / tap (>= 0.08 s into non-directional slip; instantly in directional). Uppercuts can leave duck/slip without visiting idle. CPU reads the same windows: a confirmed whiff with `recovery_left >= 0.08 s` and gap <= 1.02 m triggers a counter (Jab -> Cross; Cross -> Hook if gap <= 0.98; otherwise Hook/Cross) after a 0.04-0.10 s read delay, within `min(recovery+0.08, 0.55)` s.

### 4.4 Feints (CPU only)
`begin_feint`: non-damaging cue, 0.16 s, weight decays 1 -> 0, cooldown 1.45 s, costs 2.5 stamina, owns no clip/hit/serial (renderer layers a lean/arm cue; kind = Jab or Kick). CPU feints when gap 0.90-1.30, not foe-defending, noise > 0.45, then waits 1.45-2.0 s (feint cooldown) / 1.9-3.1 s (next probe). A feint is dropped when hit. Not player-accessible.

---
## 5. Damage, stamina, KO

### 5.1 Pools
Each fighter has **head, body, left leg, right leg** (current 0-100 and **max**, start 100), **guard** (100/100) and **stamina** (255/255). HUD health bar = head; sidebars = body/legs/guard.
Damage to an unblocked target (`total`):
```
num   = (blocked ? blockDamage : damage) x (attacker rocked ? 0.72 : 1)
bonus = 0.10 num                                 // base accumulation
        +0.20 num if defender sideways speed > 24 deg/s and strike direction L(R) matches  (-0.20 opposite)
        +0.20 num if attacker closes > 0.5 m/s with F/U/O strike (-0.20 if retreating < -0.5)
        +0.20 num if defender walking into it (-0.20 if backing away), threshold 0.5 m/s
        +0.30 num if defender is in an action state (not idle/walk/hit/block)
        +1.00 num if defender is taunting;  +0.15 num if defender is rocked and not guarding
        +0.50 num if defender throws a body strike and incoming is an uppercut
bonus = min(bonus, cap/2)
cap   = head hand 14 (power moves PJab/PHook/PUpper/OverHand/BackFist 20), head kick 18, body hand 14, body kick 18, leg 12
total = min(num+bonus, cap) x 0.7 (DAMAGE_SCALE) x (0.45 + 0.55 quality) [geometric contact]
        x 1.25 if earned counter  x (1 + 0.25 x (1 - defenderStamina/StaminaMax))
```
Application: head -> `head -= total`, `head_max -= bonus` (+0.25 num if already rocked; head_max min 1). Body -> `body -= total`, `body_max -= bonus`, `stamina_max -= 0.1 total` (min 10). Leg -> `leg -= total` AND `leg_max -= total`. Quality default 1 if no evidence. Typical clean values: LJab ~3.9, RHook ~9.8, RUppercut ~12.6, power moves up to 14.
**Any max <= 0 (head, body, lleg or rleg) = knocked out** (`is_down`). Max regen: none within a round; between rounds `max = min(current + 30, 100)`.
Health regen: 1.75/s per pool up to its max, locked 1.0 s after any hit and while rocked or within `regen_lock`.

### 5.2 Stamina
| Item | Value |
|---|---|
| Capacity | 255 (HUD shows `/255`; was 196); start full; practice/training: infinite optional |
| Strike cost | Stam column in sec. 3.3 (jab 5, hook 10, uppercut 12, power jab/hook/upper 8/12/14, OverHand/BackFist 15, low kick 9, body push 12-13, body front 13-14, body round 17, head front 22, head round 24, spectacle kicks 32). Need stamina >= 10 **and** >= cost to start. |
| Other costs | slip/backstep 3, burst step 8, CPU feint 2.5 |
| Regen | **22/s** idle/walk/hit; **11/s** while blocking, slipping, ducking, or Block held; locked 0.25 s after any spend (0.38 after burst step, 1.0 s after a body/leg hit taken) |
| Penalties | Damage taken x(1 + 0.25 x (1 - stamina ratio)); CPU resets/recovers at < 45% / < 30%; finishers need launch stamina >= 55% |
| Round break | stamina refilled to old max, new max `min(old+30, 255)` |

### 5.3 Knockdown (recoverable), flash KO, TKO
A **clean (unblocked) head hit** causes a knockdown when `finish.assess_damaged_head` passes: power strike (power/heavy/kick/earned counter) with contact speed >= 2.2 m/s (hands) / 3.0 (kicks), contact quality >= 0.80, attacker launch stamina >= 55%, defender head ratio (`head/100`) < 0.50, **and** defender is exposed (committed attack, balance <= 0.35, or stamina <= 30%). Also any head hit that takes head to 0 (non-practice). Defender balance: 0.2 whiffing/recovering, 0.35 attacking, 0.3 releasing slip, 0.5 moving, else 1.
Knockdown: head set to >= 1, `knockdowns += 1`, state FALL (1.1 s) -> COUNT (2.9 s) -> GETUP (2.0 s); total 6.0 s frozen sim; shake 0.35; clip `{dir} Fall`. Count shown as `KNOCKDOWN / knockdowns` (3-count UI means nothing "counts to 10"; KO is by number of knockdowns). Knockdowns persist for the bout (survive round rehab).
**Leg knockdown**: unblocked kick on a leg when the *opposite* foot is raised (> 0.7 m) -> same FALL (1.1 s) and +1 knockdown (practice: 2 s, no count).
**TKO**: third knockdown (a clean head hit that would knock down while `knockdowns >= 2`) -> head 0 -> KO.
**Flash KO**: unblocked power head hit, head ratio < 0.40, quality >= 0.80, speed >= 2.2, launch stamina >= 55%: chance `clamp(0.18 + 0.20(1 - ratio/0.4) + 0.12(1 - stamRatio) + 0.10(1 - balance), 0.05, 0.60)`. Also terminal: hit on a rocked fighter with head ratio < 0.5, power strike, quality >= 0.8.
KO states: loser DOWN (KO clip, sec. 6), winner WIN (random of 7 victory clips). Double KO (both is_down same tick) = draw, banner 5, both `F head KO`.
Practice modes (sparring, training): no knockdown/KO/flash, pools floored at 35-ish and regenerate 24/s, maxes reset to 100 each tick.

### 5.4 Rocked / stagger (separate from knockdown)
| Item | Value |
|---|---|
| Trigger | unblocked **head** hit, not already rocked, and (`total >= 12.5` or `rock_meter >= 34` or head/head_max <= 0.28). `rock_meter += total` (cap 100), decays 5/s when not rocked. |
| Onset | `stun_pending 0.12 s`, then `stunned`. Severity `clamp(total/45 + meter/100 + 0.25(1-ratio), 0.35, 1)`. Duration `3.2 + 2.8 x severity` s (3.6-6.0 s). Extra hit with total >= 18 while rocked: +0.4 s (cap 6 s). |
| Offence lock | no strikes during pending and the first **1.2 s** of rock (HIT state owns body, `... Stun`/hit clip). After 1.2 s state returns to IDLE: can walk (x0.68 speed), guard, slip, counter; strikes cost normal but do x0.72 damage and take x1.18 longer. Rock lasts until `stun_left` ends. |
| Vulnerability | +15% bonus on unblocked hits, head_max extra loss +0.25 num per hit, easier finish (see 5.3). |
| Feedback | shake 0.65, camera rock push-in (sec. 10), sound flag 1 (stagger layer). |
| Visual | torso/head sag, hands drop (renderer: `rocked-pose.js`); designed "daze" rework is planned, not built (`docs/handoff86/design-rocked.json`). |

### 5.5 Rounds, timer, decision
| Item | Value |
|---|---|
| Rounds | Exhibition 1 or 3 (limit clamped 1-5); sparring/training 1 |
| Round length | Exhibition 120 / **180** (default) / 300 s; sparring 180 / **300**; training timer OFF / 120 / 180. (README mentions the original game's 60 s; sim default constant 60 s is overridden by config.) |
| Start | Banner "ROUND n - FIGHT" 1.1 s, bell x1; fighters reset to x = -1.15 / +1.15, neutral, queues cleared, keep damage/knockdowns |
| Round end by time | `PH_END`, banner TIME UP; standing fighters released to idle; if round < limit: 7.1 s intermission then next round with rehab; if last round: 2.1 s then decision |
| KO | banner K.O. 2.3 s; replay armed (sec. 9); `finish_match` after **3.7 s** (winner victory clip, loser `Congrats`) |
| Decision | winner = higher sum of the four max pools (head_max + body_max + lleg_max + rleg_max); **tie -> P2/index 1** **(?)** (probable accident). No scorecards/judge rounds even though RULESETS lists `scorecards: true`. |
| KO on the final tick beats the timer. |
| Sparring/training | When timed, session ends in banner TIME UP -> HUD "SESSION COMPLETE" (no next round). Untimed training renews timer / restarts. |

---
## 6. Hit reactions (clip names are the animator-state names, also exact clip names)
Direction prefix `D` in {F, L, R, U, O}: the strike's `direction` (table) with L<->R swapped if attacker is southpaw, then again if defender is southpaw. Missing clip -> fallback below. Clip length in seconds in parentheses.

| Situation | Clip | Notes |
|---|---|---|
| Head, normal hit | `D head punch` (0.83) if hand and it is the strike's release/contact frame or defender already rocked; `D head kick` (F 1.5, L 1.03, R 1.0, U/O 1.2-1.5) for kicks / code != 0 moves; fallback `F head punch` | Reaction length then capped 0.20 (jab) / 0.28 (other hand) / 0.34 (kick). Non-capped if it contains Stun/Break/PKO |
| Head, power/"P" move or guard break | `D head punch Break` (1.0-1.03) | uncapped |
| Head to 0 (not previously rocked) | `D head Stun` (R 1.5, L 1.52, F 2.67, U 1.2, O 1.5) | |
| Head KO | `D head KO` (R 1.95, L 2.22, F 3.25, U 2.2, O 1.95) | triggered when head_max <= 0 |
| Body | none for ordinary body punches (renderer additive flinch + torso fold); `D body kick` (F 1.17 / L 0.93 / R 1.0) if hit by a kick or while defender is attacking | |
| Body weakened | body_max < 50 (kick) -> `D body kick Break` (1.5); body_max/100 < 0.25 -> `D body PKO` (1.5); body_max <= 0 -> `D body KO` (R 1.15, L 1.48, F 2.07) | body_max < 25 forces level-2 impact |
| Leg | leg_max < 75 and fresh contact -> `L/R leg kick` (1.0); < 50 -> `leg kick C` (1.0); < 25 -> `leg kick S` (1.5); <= 0 -> `leg kick KO` (R 0.75, L 0.27); fallback `R leg kick` | side = L/R only |
| Leg + opposite foot raised > 0.7 m | `L Fall` (2.03 s @ speed 0.7) / `R Fall` (1.93) then knockdown | |
| Guard break | `D body kick Break` / `D head kick` (code != 0) / `D head punch Break` | |
| Guarded hit visuals (layer on guard) | head hand: `H Block`; head kick: `LH Block` / `RH Block` / `FH Block` (2.28 / 2.87 / 1.6 s); body: `FBodyBlock` (hand) or `LBodyBlock` / `RBodyBlock` / `FBodyBlock` (kick, 0.98 s) | cross-fade 0.08 s |
| Knockdown fall | `D Fall` (`L Fall`/`R Fall`; D=R else) 1.1 s window, then held, then `GetUpFace` or `GetUpBack` (1.67 s) | prone/supine from pelvis facing |
| KO | `{D} head KO` / `{D} body KO` / `{D} leg kick KO`; fallbacks `F head KO`, `F body KO`, `R leg kick KO` | |
| Victory (loser = `Congrats` 5.67 s) | random of `Celebration_01`, `Celebration_02`, `Victory_Taunt`, `Yes`, `Bow`, `Cheer`, `Chest_Beat` -> `VictoryEnd` (6.48 s) at exit-time 0.8 / 0.7 / 0.94 of the clip | |
Reaction cross-fade 0.12 s, play-rate reset to 1. A new hit mid-reaction crossfades from the previous. The renderer adds **additive** head/torso flinch (jab small, hook ~30-45 deg head turn target, recover 0.2-0.3 s) so a hand mid-release is not interrupted ("preserve_hand": if the victim's own fist is already released/committed, their punch continues and the flinch is deferred up to 0.20/0.28 s).
Hit momentum: victim root impulse 0.016 m (jab) / 0.032 (heavy) / 0.045 m (kick), decay exp(-18 t).

---
## 7. Movement and ring
| Item | Value |
|---|---|
| Walk speed (all directions, normalised diagonals) | **1.25 m/s** free; **0.85 m/s** with guard up; x0.68 if rocked. While in slip / duck / hand-strike (layered): `1.25 x (1-0.10|slip|) x (1-0.35 duck) x (0.68 if guarding) x (0.68 if rocked) x (0.46 during a jab)`; heavy hands are planted |
| Acceleration | velocity lerp `1-exp(-rate dt)`: player 14/s start, 20/s stop; CPU 10 / 14; burst step 40 |
| Backpedal / strafe | no speed difference; animation chosen from blend-tree axes `Horizontal` (forward component of move vs foe direction, smoothed 5/s) and `Vertical` (lateral component x stance, smoothed 5/s) |
| Burst step | 0.42 m in 0.22 s (double-tap) |
| Facing | always toward opponent; stance `stands` +-1 mirrors |
| Square ring (Gym, Club, Championship; `ropeHalf 3.28`, canvas 3.5) | fighter root clamp **x,z in [-3.2, 3.2]** |
| Cage (octagon, apothem 4.1) | root kept inside 8 planes at 45 deg steps, limit **3.8 m** from centre (4.1 - 0.30 wall clearance) |
| Spawn | x = -1.15 / +1.15, 2.3 m apart |
| Body spacing | min centre-to-centre 0.60 m (pushed apart equally); contact pressure ramps 0.92 -> 0.68 m |
| Working ranges | jab/cross connect at ~0.80 m root gap (miss ~0.91); hooks ~0.98; uppercuts ~0.88 (pocket < 0.94); kicks 1.18-1.35 m; low kick 1.0; hard cap 1.45 m |
| CPU range targets | jab band 0.93 (+/-0.02), pocket 0.78, edge 0.93; retreat target 1.62 when exhausted |
| Speed measures | `speed_direct` (m/s closing), `speed_side` (deg/s relative orbit) feed damage bonuses and move to hit logic |
| Camera yaw | movement input is camera-relative (`view_yaw`) |
Gait/footwork foot-lock is renderer-only (`footwork.js`, `footwork-gait.json`) - not required for gameplay.

---
## 8. CPU AI
No difficulty selector exists; one deterministic xorshift brain per CPU fighter (`ExchangeBrain`), re-decided every tick, fed an observation of gap, own stamina/health, foe's attack (kind, progress, zone, limb, outcome, recovery left) and foe defending flag. P1 and P2 can both be CPU (T/Y, `?demo`).
| Behaviour | Rule |
|---|---|
| Phases/pressure | Edge (jab range), Pocket (hook/upper range), Counter, Defend, Reset/Recover. Start with a staggered assess delay 0.15-0.35 s. |
| Opening strike choice | gap 0.55-0.94 (pocket): noise <0.30 LJab, <0.55 RJab, <0.75 LHook, <0.85 RHook, <0.925 LUppercut (if gap <= 0.88 else LHook), else RBodyHook. gap <= 1.02: 55% LJab, 30% RJab, 15% LBodyJab. Kicks (kickboxing only, gap 1.18-1.30, stamina > 42%, noise < 0.35): 18% body round, 17% head round. Boxing never kicks. |
| Cadence | commit window after a throw: jab 0.16 s, hook 0.28, uppercut 0.32, kick 0.50; next action after 0.48 / 0.62 / 0.68 / 0.96 s + 0.28 x noise. ai_cd 0.16 s between launches. |
| Reaction to a visible strike | delay `0.12 + 0.07 noise + 0.01(1-readiness)` (<= 0.20 s). For an "ordinary jab" (hand action_left <= 0.64): **68%** meets it with a stepping return jab (delay 0.02-0.06 s, gap 0.66-1.06); else guard. Heavy/kick threats are never answered with a blind return. |
| Defence choice | head hand jab/cross: 25% SlipLeft, 25% SlipRight, else HighGuard; hook: 50% Duck else HighGuard; body: BodyGuard; leg kick: step back (-0.85 radial). Guard held 0.18-0.56 s (`delay + contact + 0.10`), cool-down 0.12-0.36 s. Defence input held at least 0.22 s. |
| Counter | see 4.3. Whiff read delay 0.04-0.10 s. |
| Spacing | Pocket exit: after >= 1 s inside <0.96 m, retreats/laterals for 0.22 s, cooldown 2.0 s. Circles with `lateral_sign` flipped every 1.1-2.5 s; direction held 0.38-0.52 s; biased to centre near ropes (starts 1.1 m from edge). Advances 0.40-0.56 radial when beyond target gap. |
| Fatigue/health | stamina < 30%: Recover (retreat to 1.62 m, high guard); < 45% or health < 30%: Reset (no new combos, backs off). CPU never starts a strike below stamina 15 (25 when resetting). |
| Rocked | CPU backs away (x0.9 retreat, no offence while rock-locked). |
| Combos | After the opening strike, with probability from an authored list of 2-3-move combos beginning with that move, it queues the rest (up to 4); abandons if gap > striking reach, stamina < spend or < 25, defence/reaction pending, or Recover. Boxing swaps leg moves for RJab. Authored lists (from `combos.yaml`, tags): |
- HEAD_Q1: LJab, LHook, LUppercut, RJab, RHook, RUppercut
- HEAD_Q2: LJab+LJab, LJab+LHook, LJab+LUppercut, LJab+RJab, LJab+RHook, LJab+RUppercut, LHook+RHook, LUppercut+RUppercut, RJab+LJab, RJab+LHook, RHook+LHook, RUppercut+LUppercut, RUppercut+LHook
- HEAD_Q3: LJab+LJab+RJab, LJab+LJab+RHook, LJab+LJab+RUppercut, LJab+RJab+LJab, LJab+RJab+LJab+RJab, LJab+RJab+LUppercut, LJab+RHook+LHook, LJab+RHook+LUppercut, RJab+LJab+RJab, RJab+LJab+RUppercut
- BODY_Q1: LBodyJab, LBodyHook, LBodyUppercut, RBodyJab, RBodyHook, RBodyUppercut
- BODY_Q2: LBodyJab+RBodyJab, LBodyJab+RBodyHook, RBodyJab+LBodyJab, RBodyJab+LBodyHook, LBodyUppercut+RBodyUppercut, RBodyHook+LBodyHook, RBodyUppercut+LBodyUppercut, RBodyUppercut+LBodyHook, LJab+RBodyJab, LJab+RBodyHook, LJab+RBodyUppercut
- BODY_Q3: LBodyJab+RBodyJab+LBodyJab, LBodyJab+RBodyHook+LBodyHook, RBodyJab+LBodyHook+RBodyHook, LJab+LJab+RBodyJab, LJab+LJab+RBodyHook, LJab+LJab+RBodyUppercut, LJab+RBodyHook+LBodyHook
- KICK_HEAD: LFrontKick, RFrontKick
- PUNCH_KICK_HEAD: LJab+RFrontKick, LJab+LJab+RFrontKick, LJab+RJab+LJab+RFrontKick, RJab+LJab+RFrontKick
- KICK_BODY: LBodySideKick, RBodySide1Kick
- PUNCH_KICK_BODY: LJab+RBodySide1Kick, LJab+LJab+RBodySide1Kick, LJab+RJab+LJab+RBodySide1Kick, RJab+LJab+RBodySide1Kick
- KICK_LEG: LLowKick, RLowKick, LJab+RLowKick, LJab+LJab+RLowKick, RJab+LJab+RLowKick, LLowKick+RJab
Combo selection picks uniformly among the 2-3 move lists whose first move equals the opening strike (4-move lists are never started). CPU "knobs" worth exposing for difficulty: reaction delay (0.12-0.20 s), meet-jab chance (0.68), slip/duck share in `choose_defense`, cadence (0.48-0.96 s), feint/probe rates, counter read delay (0.04-0.10 s), fatigue thresholds (0.30 / 0.45), `ai_cd` 0.16 s.

---
## 9. Game flow

| Screen | Contents |
|---|---|
| Boot -> Main menu | Exhibition, Sparring, Training, Settings, How to play. Keyboard/gamepad navigable (arrows/D-pad, Enter/A, Esc/B; LB/RB tabs). Window blur during a bout opens pause. |
| Exhibition (01 Timed Bout) | Venue (Gym, Club, Championship, Cage), Ruleset (Boxing / **Kickboxing default**), Opponent (CPU / LOCAL 2P), Rounds (1 / **3**), Round length (2:00 / **3:00** / 5:00), Fighter model (roster). Permanent damage, judged decision, KO replay. |
| Sparring (02) | Venue, Ruleset, Session length (3:00 / **5:00**); CPU P2; practice mode (no KO, damage not carried, recovery on); ends with "SESSION COMPLETE". |
| Training (03) | Venue, Ruleset, Dummy (**Stationary** / Guarding / Moving), Timer (**OFF** / 2:00 / 3:00), model; P2 is a non-CPU dummy: guarding holds Block (+Body when P1 holds Body), moving strafes in depth and closes if > 1.25 m apart; infinite stamina. |
| Settings | Graphics quality auto/high/medium/low, FPS counter, reduced motion (scales camera shake x0.15), HUD hints, touch controls. Stored in localStorage `knocknight.settings.v1`. |
| How to play | Controls panel (keyboard, pad). |
| Pause (Esc, pad Start, window blur) | Freezes sim + audio-driven timers; Resume (Esc), Restart bout, Exit to menu. Input cleared on pause/exit. |
| Round intro | Bell, banner `ROUND n / FIGHT`, fighters reset to corners, no walk-in. |
| Knockdown | Banner `KNOCKDOWN / n`, HUD cue; sim frozen for the other fighter; camera pulls out. Counter-window cue `COUNTER OPEN` while a counter window > 0. |
| KO | Banner K.O. -> **replay** -> victory/loser clips -> results line `K.O. - NAME WINS`; R restarts. |
| Results | HUD text `NAME WINS`, `DECISION`, `DOUBLE K.O. - DRAW`, `SESSION COMPLETE`. No separate results scene; R or pause -> Restart / Exit. |
| HUD | Round `n / limit`, clock `m:ss` (low <= 10 s), per-fighter head bar + number (`cur / max` when max < 99.5), stamina bar `/255`, body, two leg and guard meters, rock indicator, combo counter (visible 1.5 s), result line, flash banner. Names default "ANVIL"/"VIPER" roster. |

**KO replay**: the last 4.5 s of state is ringed (540 ticks). When a KO or knockdown-finish contact occurs, 3.0 s later the replay starts at **1.4 s before** the finishing contact and runs **2.0 s after** it at **0.4x speed**, label `REPLAY`, low close camera (fov 34, centre y 1.15, orbiting 0.42 rad/s starting 0.7 rad off the fight axis). Any key ends it; HUD hidden during replay.

---
## 10. Camera and audio

### 10.1 Camera (`fight-camera.js`, `impact.js`)
| Item | Value |
|---|---|
| Rig | Third-person orbit around the fighters' midpoint; target height 1.0 m; FOV 42 deg. Distance `3.10 + 0.65 x gap` clamped 3.95-8.0 (rest 7.1); camera height `0.46 + 0.045 x distance` above target |
| Tracking | Critically damped spring on the centre (omega 6.4, max speed 2.6 m/s, max accel 11, lead 0.14 s of velocity, cap 0.36 m); distance spring (omega 3.6, 1.7 m/s, 5.5 accel, gap lead 0.16 s); never reads head bones |
| Orbit | Yaw = `atan2(-dz, dx)` of the fight axis (camera sees the fighters side-on, looking down the axis normal); yaw PD omega 2.7, max 1.05 rad/s, accel 2.6; keeps its current side; deadband 0.0002 on axis; axis needs gap >= 0.22 |
| Framing | Both fighters' heads and feet stay inside the frame (posed-hull fit); foreground cage/rope geometry is clipped by camera direction |
| Input relation | Movement keys are camera-relative (`view_yaw`) |
| Hit response (build-60 profiles, measured from reference) | Light hits and most guard hits: nothing. Medium: roll 1-4 deg peak at 94 ms, half gone by 260 ms. Big/clean power hit: roll up to **12-13.4 deg** in the punch direction, first frame 43% of peak, peak at **94 ms**, <1 deg by ~0.38 s, translation 6-7% frame, pull-back 3-5%, **2 frames of motion blur** (1/29.9 s each) clearing by 0.4 s, HUD fades (0.11 s delay, 0.27 s fade). Rock: same kick then push-in to **x1.28** (in 0.113 s, hold 0.45, out 0.8 s) with dutch tilt 8.5 deg (trough -7 deg at 1.4 s, settled 2.4 s). Knockdown: no kick; pull-out to x0.6 over ~0.8 s, rope bump 3 deg (0.14-0.32 s). Reduced-motion scales all by 0.15. Max roll 13.4 deg |
| Screen effects | Impact blur, spark particles per hit (size `0.24 + 0.008 total`, heights: head 1.4, body 0.95, leg 0.5), shake state `0.12 + 0.008 num` (guard 0.035, glove clash 0.025, guard break 0.18, KO 0.5, rock 0.65) decaying exp(-16 t) |
| Not present | Hit-stop, slow motion in live play (replay only), vignette, chromatic aberration, desaturation, letterbox |

### 10.2 Audio events (files in `assets/audio/*.ogg`; pools in `sounds.json`)
Pools (unique files): `punchSounds`/`headLightSounds` jab-01..05; `mediumSounds`/`headMediumSounds` hook-02..05; `critSounds`/`headHeavySounds` heavy-01, heavy-04, heavy-32, heavy-33; `bodySounds`/`bodyThudSounds` body-01..04; `blockSounds` guard-heavy-01..04, guard-01..04, grab-01..04, clinch-01..04; `gloveBlockSounds` guard-heavy-01..04 + guard-01..04; `guardBreakSounds` guard-heavy-01..04; `grazeSounds` guard-01..04; `stunSounds` stagger-03, stagger-05; `koSounds` knockout-01..04; `breathSounds` breath-01.
| Event | Trigger | Sound |
|---|---|---|
| Whoosh | state ATTACK begins (or clip restarts) | synthesized band-passed noise sweep; kind J (jab/uppercut), H (hook/BackFist/OverHand), U, K (kicks heaviest); power "P" moves x1.25 |
| Impact class (sim `impact_class`) | 1 absorbed (blocked), 2 graze (quality < 0.35), 3 clean, 4 counter, 5 guard break, 6 knockdown, 7 KO | base gain `[0, .50, .14, .58, .96, .78, 1.02, 1.06]` x (1 + 0.14 (level-1)) x (1 + 0.005 min(20,damage)) x (0.97 + 0.06 quality); clamp .06-1.1; glove contact x0.78 |
| Layers | Absorbed: `gloveBlockSounds` (pitch .90/.96, lowpass 1100/1600). Graze: `grazeSounds` pitch 1.14. Guard break: 2x `guardBreakSounds` pitch .84/.90. Clean/counter by zone and tier (tier = massive if level >= 3 or damage >= 14, heavy if level >= 2 or damage >= 9.5; counter/knockdown/KO force tier 3): **Head** T1 headLight; T2 headLight .46 + headMedium .54; T3 light .26 + medium .36 + heavy .38. **Body/leg** T1 bodyThud; T2 bodyThud .58-.60 + headMedium; T3 bodyThud .40 + medium .28 + heavy .30-.32 (pitches 0.86-0.95). Knockdown x0.8 + 0.2 thud/heavy pitch .82. KO x0.72 + 0.28 `koSounds`. Rock (flag 1): x0.78 + 0.22 `stunSounds`. Extra sub-bass boom and ring on rocks/KOs |
| Level (sim `level`) | 3 if KO; 2 if guard break, rock started, heavy move, earned counter, head kick/code!=0 move, or body weakened (< 25 / kick < 50); else 1 |
| Flags | 1 rock started, 2 KO, 4 counter, 8 guard break, 16 knockdown, 32 glove contact |
| Crowd | synthesized noise bed (gain .018) with `swell`: KO +.2 for 5 s, rock +.12 for 2.2 s, heavy hit +.07 for 1.4 s, light +.04 for .8 s |
| Bell | rings **x1** when a new round starts (phase -> FIGHT after the first), **x3** when a round ends (phase -> END). Inharmonic partials, ~2.2 s decay |
| Hurt mix | `breathSounds` / low-pass mix while a fighter is rocked, strength = rock severity |
| Dedupe | one impact bundle per attacker per event serial |

---
## 11. Open questions / things to confirm with the owner
1. **Contact windows** for non-core strikes are raw clip estimates; real hits come from limb sweeps. Decide Godot hitbox active frames per clip (suggest `[c0, max(c1, recoil)]` from the table).
2. **Decision tie** goes to P2 (probable bug); no real scoring by round. Decide if a judge-card system is wanted.
3. **Guarded leg kick** math (leg -5 or -damage x5, max -damage x2) looks like a source-port quirk.
4. Slip effectiveness vs hooks, authored defence clips (`defense.json`, 26 clips at 120 fps) and planned features (guard styles, rocked rework, shell/roll defence, strike variants) live in `docs/handoff86/design-*.json`; they are designs, not built.
5. Ruleset metadata (`downSeconds 4`, `scorecards`, standing count) is unused by the sim.
6. `KNOCKDOWN / n` counts knockdowns, not a referee 10-count; three knockdowns = TKO.
7. Taunt is mechanically a liability (+100% damage). Keep or make cosmetic.
8. No difficulty tiers, no player feint, no clinch, no ground game, no tournament (all absent in source).
