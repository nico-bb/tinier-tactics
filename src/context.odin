package main

import "lib:iris"

Game_Stack :: [dynamic]Game_Context

last_item_game_stack :: proc(g: Game_Stack) -> Game_Context {
	return g[len(g) - 1]
}

Game_Context :: union {
	^Combat_Context,
}

Combat_Context :: struct {
	scene:              iris.Scene,
	character_mesh:     ^iris.Mesh,
	character_material: ^iris.Material,
	player:             ^iris.Model_Node,
	player_animation:   iris.Animation_Player,
	player_position:    iris.Vector3,
	enemy:              ^iris.Model_Node,
}

init_game_context :: proc(ctx: Game_Context) {
	switch c in ctx {
	case ^Combat_Context:
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
			iris.Material_Loader{
				name = "character",
				shader = shader,
				specialization = shader_spec,
			},
		)
		c.character_material = mat_res.data.(^iris.Material)

		c.character_mesh = iris.cube_mesh(1, 1, 1).data.(^iris.Mesh)

		iris.init_scene(&c.scene)
		camera := iris.new_default_camera(&c.scene)

		c.player = iris.model_node_from_mesh(
			&c.scene,
			c.character_mesh,
			c.character_material,
			iris.transform(t = iris.Vector3{0, 0, 1}),
		)

		// c.enemy = iris.model_node_from_mesh(
		// 	&c.scene,
		// 	c.character_mesh,
		// 	c.character_material,
		// 	iris.transform(t = iris.Vector3{0, 0, -1}),
		// )

		iris.insert_node(&c.scene, camera)
		iris.insert_node(&c.scene, c.player)
		// iris.insert_node(&c.scene, c.enemy)

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
	}
}

destroy_game_context :: proc(ctx: Game_Context) {
	switch c in ctx {
	case ^Combat_Context:
		iris.destroy_scene(&c.scene)
		free(c)
	}
}
