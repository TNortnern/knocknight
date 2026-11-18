class_name FighterInput
extends RefCounted
## One tick of intent for a fighter. Produced by HumanController / CpuBrain / dummy, consumed by Fighter.

## Movement in "screen" frame: x = right (+X world), y = up/away from camera (-Z world), magnitude <= 1.
var move := Vector2.ZERO
var block := false
var body := false
var duck := false
var shell := false     ## shoulder-roll modifier: Block + Shell = shell guard
## -1 = slip towards the fighter's left? No: -1 = screen-left, +1 = screen-right is resolved by Fighter; here
## slip is expressed in the FIGHTER frame: +1 = fighter's left side, -1 = fighter's right side, 0 none.
var slip := 0
## Analog lean in the FIGHTER frame (x: +1 = fighter's left, y: +1 = forward / -1 = back), magnitude <= 1. The gamepad right stick fills it;
## `slip` (Q / E) stays as the digital shortcut for a full side lean. `lean_mod` = hold the lean modifier: the move stick (screen frame) leans instead of walking.
var lean := Vector2.ZERO
var lean_mod := false
var backstep := false
## Fresh strike presses this tick (strike tags, rising edge only).
var strikes: Array[String] = []
var taunt := false
var shove := false     ## shove off the foe in body contact (one tick = one shove, see body_contact.gd)
var burst := Vector2.ZERO


func clear() -> void:
	move = Vector2.ZERO
	block = false
	body = false
	duck = false
	shell = false
	slip = 0
	lean = Vector2.ZERO
	lean_mod = false
	backstep = false
	strikes.clear()
	taunt = false
	shove = false
	burst = Vector2.ZERO
