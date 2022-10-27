package main

import "lib:iris"

main :: proc() {
	iris.init_app(
		&iris.App_Config{
			width = 1600,
			height = 900,
			title = "tinier tactics",
			decorated = true,
			asset_dir = "assets/",
			data = iris.App_Data(&Game{}),
			init = init,
			update = update,
			draw = render,
			close = close,
		},
	)

	iris.run_app()
	iris.close_app()
}

Game :: struct {
	ctx_stack: Game_Stack,
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	append(&g.ctx_stack, new(Combat_Context))

	for ctx in g.ctx_stack {
		init_game_context(ctx)
	}
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	current := last_item_game_stack(g.ctx_stack)
	dt := f32(iris.elapsed_time())

	switch c in current {
	case ^Combat_Context:
		defer iris.update_scene(&c.scene, dt)

		iris.advance_animation(&c.player_animation, dt)
		iris.node_local_transform(c.player, iris.transform(t = c.player_position))
	}
}

render :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.start_render()
	defer iris.end_render()

	current := last_item_game_stack(g.ctx_stack)

	switch c in current {
	case ^Combat_Context:
		iris.render_scene(&c.scene)
	}
}

close :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	for ctx in g.ctx_stack {
		destroy_game_context(ctx)
	}
}
