extends Node

# Slow tick: 1s — extraction, conversion, routing, delivery
var _slow_timer: Timer

func _ready() -> void:
	_slow_timer = Timer.new()
	_slow_timer.wait_time = 1.0
	_slow_timer.autostart = true
	_slow_timer.timeout.connect(_on_slow_tick)
	add_child(_slow_timer)

func _on_slow_tick() -> void:
	GameState.process_tick()

# Every frame — extractor timers, belt movement, delivery
func _process(delta: float) -> void:
	GameState.advance_packets(delta)
