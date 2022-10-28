package main

import "lib:iris"

Combat_Context :: struct {
	scene:              ^iris.Scene,
	character_mesh:     ^iris.Mesh,
	character_material: ^iris.Material,
	player:             ^iris.Model_Node,
	player_animation:   iris.Animation_Player,
	player_position:    iris.Vector3,
	enemy:              ^iris.Model_Node,

	// UI
	ui:                 ^iris.User_Interface_Node,
	unit_portrait:      ^iris.Layout_Widget,
	target_portrait:    ^iris.Layout_Widget,
}

init_combat_context :: proc(c: ^Combat_Context) {
	iris.add_light(.Directional, iris.Vector3{2, 3, 2}, {100, 100, 90, 1}, true)

	shader, shader_exist := iris.shader_from_name("deferred_geometry")
	assert(shader_exist)
	spec_res := iris.shader_specialization_resource("deferred_character", shader)
	shader_spec := spec_res.data.(^iris.Shader_Specialization)
	iris.set_specialization_subroutine(
		shader,
		shader_spec,
		.Fragment,
		"sampleAlbedo",
		"sampleDefaultAlbedo",
	)
	mat_res := iris.material_resource(
		iris.Material_Loader{name = "character", shader = shader, specialization = shader_spec},
	)
	c.character_material = mat_res.data.(^iris.Material)
	iris.set_material_map(
		c.character_material,
		.Diffuse0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/char_texture.png"},
				filter = .Nearest,
				wrap = .Repeat,
				space = .sRGB,
			},
		).data.(^iris.Texture),
	)

	c.character_mesh = iris.cube_mesh(1, 1, 1).data.(^iris.Mesh)

	c.scene = iris.scene_resource("combat", {.Draw_Debug_Collisions}).data.(^iris.Scene)
	camera := iris.new_default_camera(c.scene)

	c.player = iris.model_node_from_mesh(c.scene, c.character_mesh, c.character_material)
	c.player.local_bounds = iris.bounding_box_from_min_max(
		iris.Vector3{-0.5, -0.5, -0.5},
		iris.Vector3{0.5, 0.5, 0.5},
	)
	// c.enemy = iris.model_node_from_mesh(c.scene, c.character_mesh, c.character_material)
	// iris.node_local_transform(c.enemy, iris.transform(t = {0, 0, -1}))

	iris.insert_node(c.scene, camera)
	iris.insert_node(c.scene, c.player)
	// iris.insert_node(c.scene, c.enemy)

	anim_res := iris.animation_resource({name = "character_attack", loop = true})
	animation := anim_res.data.(^iris.Animation)
	animation.channels = make([]iris.Animation_Channel, 1)

	channel := iris.Animation_Channel {
		kind            = .Translation,
		mode            = .Linear,
		frame_durations = make([]f32, 2),
		frame_outputs   = make([]iris.Animation_Value, 2),
	}

	channel.frame_durations[0] = 0.5
	channel.frame_durations[1] = 0.5

	channel.frame_outputs[0] = iris.Vector3{1, 0, 1}
	channel.frame_outputs[1] = iris.Vector3{0, 0, 0}

	animation.channels[0] = channel

	c.player_animation = iris.make_animation_player(animation)
	c.player_animation.targets[0] = &c.player_position
	c.player_animation.targets_start_value[0] = iris.compute_animation_start_value(
		animation.channels[0],
	)
	iris.reset_animation(&c.player_animation)

	{
		canvas := iris.new_node_from(c.scene, iris.Canvas_Node{width = 1600, height = 900})
		iris.insert_node(c.scene, canvas)
		c.ui = iris.new_node_from(c.scene, iris.User_Interface_Node{canvas = canvas})
		iris.insert_node(c.scene, c.ui)
		iris.ui_node_theme(c.ui, theme)

		init_action_controller(c)
		init_portrait(c, iris.Vector2{GAME_MARGIN, GAME_MARGIN})
		init_portrait(c, iris.Vector2{1600 - 250 - GAME_MARGIN, GAME_MARGIN})
	}
}

init_action_controller :: proc(c: ^Combat_Context) {
	action_layout := iris.new_widget_from(
		c.ui,
		iris.Layout_Widget{
			base = iris.Widget{
				flags = {.Initialized_On_New, .Root_Widget, .Fit_Theme, .Active},
				rect = {
					x = 1600 - 250 - GAME_MARGIN,
					y = 900 - 150 - GAME_MARGIN,
					width = 250,
					height = 150,
				},
				background = iris.Widget_Background{style = .Solid},
			},
			options = {},
			format = .Row,
			origin = .Up,
			margin = 3,
			padding = 2,
		},
	)

	move_btn := iris.new_widget_from(
		c.ui,
		iris.Button_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Move", style = .Center},
			data = c,
		},
	)
	iris.layout_add_widget(action_layout, move_btn, 25)

	attack_btn := iris.new_widget_from(
		c.ui,
		iris.Button_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Attack", style = .Center},
			data = c,
		},
	)
	iris.layout_add_widget(action_layout, attack_btn, 25)

	wait_btn := iris.new_widget_from(
		c.ui,
		iris.Button_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Wait", style = .Center},
			data = c,
		},
	)
	iris.layout_add_widget(action_layout, wait_btn, 25)
}

init_portrait :: proc(c: ^Combat_Context, position: iris.Vector2) {
	portrait_layout := iris.new_widget_from(
		c.ui,
		iris.Layout_Widget{
			base = iris.Widget{
				flags = {.Initialized_On_New, .Root_Widget, .Fit_Theme, .Active},
				rect = {x = position.x, y = position.y, width = 250, height = 150},
				background = iris.Widget_Background{style = .Solid},
			},
			options = {},
			format = .Row,
			origin = .Up,
			margin = 3,
			padding = 2,
		},
	)

	name_label := iris.new_widget_from(
		c.ui,
		iris.Label_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Player", style = .Center},
		},
	)
	iris.layout_add_widget(portrait_layout, name_label, 25)


	hp_slider := iris.new_widget_from(
		c.ui,
		iris.Slider_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			progress = 0.5,
			progress_origin = .Left,
		},
	)
	iris.layout_add_widget(portrait_layout, hp_slider, 25)

	mp_slider := iris.new_widget_from(
		c.ui,
		iris.Slider_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			progress = 0.5,
			progress_origin = .Left,
		},
	)
	iris.layout_add_widget(portrait_layout, mp_slider, 25)
}

//////////////////////////
//////////
/*
	Player Input
*/
//////////
//////////////////////////

Player_Controller :: struct {
	action_panel:    ^iris.Layout_Widget,
	unit_portrait:   ^iris.Layout_Widget,
	layout_portrait: ^iris.Layout_Widget,
}

start_player_turn :: proc(pc: ^Player_Controller) {
	iris.widget_active(widget = pc.action_panel, active = true)
}

compute_player_action :: proc(c: ^Character_Info, pc: ^Player_Controller) -> Combat_Action {
	return Nil_Action{}
}

end_player_turn :: proc(pc: ^Player_Controller) {
	iris.widget_active(widget = pc.action_panel, active = false)
}

//////////////////////////
//////////
/*
	Combat simulation
*/
//////////
//////////////////////////

Stat_Kind :: enum {
	Health,
	Speed,
}

Stat :: struct {
	current: int,
	min:     int,
	max:     int,
}

increase_stat :: proc(s: ^Stat, by: int) {
	s.current = max(s.current + by, s.max)
}

decrease_stat :: proc(s: ^Stat, by: int) {
	s.current = min(s.current - by, 0)
}

// All the data about the current state of the combat
Combat_Simulation :: struct {
	characters: [dynamic]Character_Info,
	current:    Turn_ID,
}

Turn_ID :: distinct uint

Combat_Action :: union {
	Nil_Action,
	Attack_Action,
}

Nil_Action :: struct {}

Attack_Action :: struct {
	amount: int,
	target: Turn_ID,
}

Team_Mask :: distinct bit_set[Team_Marker]

Team_Marker :: enum {
	Team_A,
	Team_B,
	Team_C,
	Team_D,
}

Character_Info :: struct {
	// Turns out we probably need a ref to the scene node for
	// mouse picking and other stuff
	node:       ^iris.Model_Node,
	controller: ^Player_Controller,

	// Actual data
	kind:       Character_Kind,
	team:       Team_Mask,
	turn_id:    Turn_ID,
	position:   iris.Vector3,
	stats:      [len(Stat_Kind)]Stat,
}

Character_Kind :: enum {
	Player,
	Computer,
}

advance_simulation :: proc(sim: ^Combat_Simulation) {
	// character := &sim.characters[sim.current]
	// switch character.kind {
	// case .Player:
	// 	compute_player_turn()
	// case .Computer:
	// 	compute_ai_action()
	// }
}
