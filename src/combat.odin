package main

import "lib:iris"

Combat_Context :: struct {
	scene:              iris.Scene,
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

	c.character_mesh = iris.cube_mesh(1, 1, 1).data.(^iris.Mesh)

	iris.init_scene(&c.scene)
	camera := iris.new_default_camera(&c.scene)

	c.player = iris.model_node_from_mesh(&c.scene, c.character_mesh, c.character_material)

	c.enemy = iris.model_node_from_mesh(&c.scene, c.character_mesh, c.character_material)
	iris.node_local_transform(c.enemy, iris.transform(t = {0, 0, -1}))

	iris.insert_node(&c.scene, camera)
	iris.insert_node(&c.scene, c.player)
	iris.insert_node(&c.scene, c.enemy)

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

	channel.frame_outputs[0] = iris.Vector3{0, 0, 1}
	channel.frame_outputs[1] = iris.Vector3{0, 0, 0}

	animation.channels[0] = channel

	c.player_animation = iris.make_animation_player(animation)
	c.player_animation.targets[0] = &c.player_position
	c.player_animation.targets_start_value[0] = iris.compute_animation_start_value(
		animation.channels[0],
	)
	iris.reset_animation(&c.player_animation)

	{
		canvas := iris.new_node_from(&c.scene, iris.Canvas_Node{width = 1600, height = 900})
		iris.insert_node(&c.scene, canvas)
		c.ui = iris.new_node_from(&c.scene, iris.User_Interface_Node{canvas = canvas})
		iris.insert_node(&c.scene, c.ui)
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
}
