package main

import "lib:iris"

theme: iris.User_Interface_Theme

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

	theme = iris.User_Interface_Theme {
		borders = true,
		border_color = {1, 1, 1, 1},
		contrast_values = {0 = 0.35, 1 = 0.75, 2 = 1, 3 = 1.25, 4 = 1.5},
		base_color = {0.35, 0.35, 0.35, 1},
		highlight_color = {0.7, 0.7, 0.8, 1},
		text_color = 1,
		text_size = 20,
		font = iris.font_resource(
			iris.Font_Loader{path = "fonts/Roboto-Regular.ttf", sizes = {20}},
		).data.(^iris.Font),
		title_style = .Center,
	}

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
