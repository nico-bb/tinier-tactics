package main

import "lib:iris"

GAME_MARGIN :: 25

Game_Stack :: [dynamic]Game_Context

last_item_game_stack :: proc(g: Game_Stack) -> Game_Context {
	return g[len(g) - 1]
}

Game_Context :: union {
	^Combat_Context,
}


init_game_context :: proc(ctx: Game_Context) {
	switch c in ctx {
	case ^Combat_Context:
		init_combat_context(c)
	}
}

destroy_game_context :: proc(ctx: Game_Context) {
	switch c in ctx {
	case ^Combat_Context:
		iris.destroy_scene(&c.scene)
		free(c)
	}
}
