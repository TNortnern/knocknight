extends "res://scripts/main.gd"
## Capture-only scene script: background/offscreen evidence must not pause when another
## capture or the user's browser gains focus. Ordinary gameplay retains its focus pause.


func pause() -> void:
	# _notification propagates through the script inheritance chain. Override the invoked
	# pause operation itself so the inherited focus handler cannot stop the capture tree.
	pass
