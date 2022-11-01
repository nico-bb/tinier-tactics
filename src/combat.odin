package main

import "core:fmt"
import "core:sort"
import "core:math/linalg"
import "lib:iris"

Combat_Context :: struct {
	scene:              ^iris.Scene,
	character_mesh:     ^iris.Mesh,
	character_material: ^iris.Material,
	player:             ^iris.Model_Node,
	enemy:              ^iris.Model_Node,

	// Logic
	player_controller:  Player_Controller,
	characters:         [dynamic]Character_Info,
	current:            Turn_ID,

	// Spatial
	grid_model:         ^iris.Model_Node,
	grid:               []Tile_Info,

	// UI
	ui:                 ^iris.User_Interface_Node,
}

Combat_Button_ID :: enum {
	Attack,
	Wait,
}

GRID_WIDTH :: 5
GRID_HEIGHT :: 5

init_combat_context :: proc(c: ^Combat_Context) {
	iris.add_light(.Directional, iris.Vector3{2, 3, 2}, {100, 100, 90, 1}, false)

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
	iris.node_local_transform(c.player, iris.transform(t = {0, 0, 1}))

	c.enemy = iris.model_node_from_mesh(c.scene, c.character_mesh, c.character_material)
	c.enemy.local_bounds = iris.bounding_box_from_min_max(
		iris.Vector3{-0.5, -0.5, -0.5},
		iris.Vector3{0.5, 0.5, 0.5},
	)
	iris.node_local_transform(c.enemy, iris.transform(t = {0, 0, -1}))

	iris.insert_node(c.scene, camera)
	iris.insert_node(c.scene, c.player)
	iris.insert_node(c.scene, c.enemy)

	{
		canvas := iris.new_node_from(c.scene, iris.Canvas_Node{width = 1600, height = 900})
		iris.insert_node(c.scene, canvas)
		c.ui = iris.new_node_from(c.scene, iris.User_Interface_Node{canvas = canvas})
		iris.insert_node(c.scene, c.ui)
		iris.ui_node_theme(c.ui, theme)
	}

	init_grid(c)

	// Controllers
	init_controllers(c, &c.player_controller)
	init_simulation(c)
}

init_action_ui :: proc(c: ^Combat_Context) -> ^iris.Layout_Widget {
	action_panel := iris.new_widget_from(
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
	iris.layout_add_widget(action_panel, move_btn, 25)

	attack_btn := iris.new_widget_from(
		c.ui,
		iris.Button_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Attack", style = .Center},
			data = &c.player_controller,
			callback = on_action_btn_pressed,
		},
	)
	iris.layout_add_widget(action_panel, attack_btn, 25)

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
	iris.layout_add_widget(action_panel, wait_btn, 25)


	return action_panel
}

init_info_panel :: proc(c: ^Combat_Context) -> ^iris.Layout_Widget {
	info_panel := iris.new_widget_from(
		c.ui,
		iris.Layout_Widget{
			base = iris.Widget{
				flags = {.Initialized_On_New, .Root_Widget, .Fit_Theme},
				rect = {
					x = 250 + GAME_MARGIN * 2,
					y = GAME_MARGIN,
					width = 1600 - (250 + GAME_MARGIN * 2) * 2,
					height = 40,
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

	info_label := iris.new_widget_from(
		c.ui,
		iris.Label_Widget{
			base = iris.Widget{
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Please select a target", style = .Center},
		},
	)
	iris.layout_add_widget(info_panel, info_label, 32)

	return info_panel
}

init_portrait :: proc(c: ^Combat_Context, position: iris.Vector2) -> ^iris.Layout_Widget {
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

	return portrait_layout
}

init_grid :: proc(c: ^Combat_Context) {
	tile_mesh := iris.plane_mesh(1, 1, 1, 1, 1).data.(^iris.Mesh)
	tile_material := iris.material_resource(
		iris.Material_Loader{
			name = "tile",
			shader = c.character_material.shader,
			specialization = c.character_material.specialization,
		},
	).data.(^iris.Material)
	iris.set_material_map(
		tile_material,
		.Diffuse0,
		iris.texture_resource(
			iris.Texture_Loader{
				info = iris.File_Texture_Info{path = "textures/grid_texture.png"},
				filter = .Nearest,
				wrap = .Repeat,
				space = .sRGB,
			},
		).data.(^iris.Texture),
	)

	c.grid = make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT)
	for y in 0 ..< GRID_HEIGHT {
		for x in 0 ..< GRID_WIDTH {
			tile_node := iris.model_node_from_mesh(c.scene, tile_mesh, tile_material)
			iris.node_local_transform(tile_node, iris.transform(t = coord_to_world({x, y})))
			tile_node.local_bounds = iris.bounding_box_from_min_max(
				p_min = {-0.5, -0.05, -0.5},
				p_max = {0.5, 0.05, 0.5},
			)
			iris.insert_node(c.scene, tile_node)

			c.grid[y * GRID_WIDTH + x] = Tile_Info {
				index   = y * GRID_WIDTH + x,
				node    = tile_node,
				content = nil,
			}
		}
	}
}

init_controllers :: proc(c: ^Combat_Context, pc: ^Player_Controller) {
	pc.action_panel = init_action_ui(c)
	pc.unit_portrait = init_portrait(c, iris.Vector2{GAME_MARGIN, GAME_MARGIN})
	pc.target_portrait = init_portrait(c, iris.Vector2{1600 - 250 - GAME_MARGIN, GAME_MARGIN})
	pc.info_panel = init_info_panel(c)
	c.player_controller.refresh_portraits = true

	anim_res := iris.animation_resource({name = "character_attack", loop = false})
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

	channel.frame_outputs[0] = f32(1)
	channel.frame_outputs[1] = f32(0)

	animation.channels[0] = channel

	pc.attack_animation = iris.make_animation_player(animation)
	pc.attack_animation.targets[0] = &pc.animation_offset
	pc.attack_animation.targets_start_value[0] = iris.compute_animation_start_value(
		animation.channels[0],
	)
	iris.reset_animation(&pc.attack_animation)
}

init_simulation :: proc(c: ^Combat_Context) {
	append(
		&c.characters,
		Character_Info{
			node = c.player,
			kind = .Player,
			team = {.Team_A},
			stats = {Stat_Kind.Health = stat(10), Stat_Kind.Speed = stat(3)},
		},
		Character_Info{
			node = c.enemy,
			kind = .Computer,
			team = {.Team_A},
			stats = {Stat_Kind.Health = stat(10), Stat_Kind.Speed = stat(3)},
		},
	)

	move_character_to_tile(c, &c.characters[0], Tile_Coordinate{0, 0})
	move_character_to_tile(c, &c.characters[1], Tile_Coordinate{3, 4})

	// Sort by speed
	it := sort.Interface {
		len = proc(it: sort.Interface) -> int {
			ctx := cast(^Combat_Context)it.collection
			return len(ctx.characters)
		},
		less = proc(it: sort.Interface, i, j: int) -> bool {
			ctx := cast(^Combat_Context)it.collection
			i_speed := ctx.characters[i].stats[Stat_Kind.Speed].current
			j_speed := ctx.characters[j].stats[Stat_Kind.Speed].current
			return i_speed > j_speed
		},
		swap = proc(it: sort.Interface, i, j: int) {
			ctx := cast(^Combat_Context)it.collection
			ctx.characters[i], ctx.characters[j] = ctx.characters[j], ctx.characters[i]
		},
		collection = c,
	}
	sort.sort(it)


	for info, i in &c.characters {
		info.turn_id = Turn_ID(i)
	}

	first := &c.characters[0]
	switch first.kind {
	case .Player:
		start_player_turn(&c.player_controller, first)
	case .Computer:
	}
}

//////////////////////////
//////////
/*
	Player Input
*/
//////////
//////////////////////////

Player_Controller :: struct {
	// Context query callbacks

	// UI
	action_panel:         ^iris.Layout_Widget,
	unit_portrait:        ^iris.Layout_Widget,
	target_portrait:      ^iris.Layout_Widget,
	info_panel:           ^iris.Layout_Widget,
	refresh_portraits:    bool,

	// Logic data
	state:                Player_Controller_State,
	character_info:       ^Character_Info,
	target_info:          Maybe(^Character_Info),
	selected_target_info: ^Character_Info,

	// Spatial data
	position:             iris.Vector3,
	direction:            iris.Vector3,
	animation_offset:     f32,
	target_position:      iris.Vector3,

	// All the animations
	idle_animation:       iris.Animation_Player,
	attack_animation:     iris.Animation_Player,
}

Player_Controller_State :: enum {
	Idle,
	Select_Target,
	Wait_For_Animation,
}

start_player_turn :: proc(pc: ^Player_Controller, current: ^Character_Info) {
	controller_state_transition(pc, .Idle)
	pc.character_info = current
	pc.position = iris.translation_from_matrix(current.node.local_transform)
}

on_action_btn_pressed :: proc(data: rawptr, id: iris.Widget_ID) {

	pc := cast(^Player_Controller)data
	btn_id := Combat_Button_ID(id)

	switch btn_id {
	case .Attack:
		controller_state_transition(pc, .Select_Target)
	case .Wait:
	}
}

compute_player_action :: proc(pc: ^Player_Controller) -> (action: Combat_Action, done: bool) {
	if pc.refresh_portraits {
		HP_SLIDER :: 1

		unit_progress := stat_current_value_percent(&pc.character_info.stats[Stat_Kind.Health])
		u := pc.unit_portrait.children[HP_SLIDER]
		unit_hp_slider := u.derived.(^iris.Slider_Widget)
		iris.slider_progress_value(unit_hp_slider, unit_progress)

		if pc.target_info != nil {
			target_progress := stat_current_value_percent(
				&(pc.target_info.?).stats[Stat_Kind.Health],
			)
			t := pc.target_portrait.children[HP_SLIDER]
			target_hp_slider := t.derived.(^iris.Slider_Widget)
			iris.slider_progress_value(target_hp_slider, target_progress)
		}
	}

	portrait_on: bool
	if pc.target_info != nil {
		t := pc.target_info.?
		portrait_on = t.kind == .Computer
	}
	iris.widget_active(widget = pc.target_portrait, active = portrait_on)

	switch pc.state {
	case .Idle:
	case .Select_Target:
		m_left := iris.mouse_button_state(.Left)
		m_right := iris.mouse_button_state(.Right)
		esc := iris.key_state(.Escape)

		switch {
		case .Just_Pressed in m_left:
			if pc.target_info != nil {
				t := pc.target_info.?
				pos := iris.translation_from_matrix(pc.character_info.node.global_transform)
				pc.direction = linalg.vector_normalize(pc.target_position - pos)
				iris.reset_animation(&pc.attack_animation)
				pc.attack_animation.playing = true
				pc.state = .Wait_For_Animation
				pc.selected_target_info = t
			}
		case .Just_Pressed in m_right || .Just_Pressed in esc:
			controller_state_transition(pc, .Idle)
		}

	case .Wait_For_Animation:
		if !pc.attack_animation.playing {
			pc.state = .Idle

			action := Attack_Action {
				target = pc.selected_target_info.turn_id,
				amount = 1,
			}
			return action, true
		}
	}

	return Nil_Action{}, false
}

controller_state_transition :: proc(pc: ^Player_Controller, to: Player_Controller_State) {
	switch to {
	case .Idle:
		iris.widget_active(widget = pc.action_panel, active = true)
		iris.widget_active(widget = pc.unit_portrait, active = true)
		iris.widget_active(widget = pc.info_panel, active = false)
	case .Select_Target:
		iris.widget_active(widget = pc.info_panel, active = true)
	case .Wait_For_Animation:
		iris.widget_active(widget = pc.info_panel, active = false)
	}

	pc.state = to
}

end_player_turn :: proc(pc: ^Player_Controller) {
	iris.widget_active(widget = pc.unit_portrait, active = false)
	iris.widget_active(widget = pc.action_panel, active = false)
	iris.widget_active(widget = pc.info_panel, active = false)
}

//////////////////////////
//////////
/*
	Grid
*/
//////////
//////////////////////////

Tile_Info :: struct {
	index:   int,
	node:    ^iris.Model_Node,
	content: union {
		Empty_Tile,
		^Character_Info,
	},
}

Tile_Coordinate :: [2]int

Move_Result :: enum {
	Ok,
	Blocked,
}

Empty_Tile :: struct {}

coord_to_index :: proc(coord: Tile_Coordinate) -> int {
	return coord.y * GRID_WIDTH + coord.x
}

coord_to_world :: proc(coord: Tile_Coordinate) -> (result: iris.Vector3) {
	GRID_ORIGIN_X :: f32(GRID_WIDTH) / 2
	GRID_ORIGIN_Y :: f32(GRID_HEIGHT) / 2
	result = {f32(coord.x) - GRID_ORIGIN_X, 0.0, f32(coord.y) - GRID_ORIGIN_Y}
	fmt.printf("START: [%f, %f], TILE: %v, TO: %v\n", GRID_ORIGIN_X, GRID_ORIGIN_X, coord, result)
	return
}

index_to_coord :: proc(index: int) -> Tile_Coordinate {
	return {index % GRID_WIDTH, index / GRID_WIDTH}
}

index_to_world :: proc(index: int) -> iris.Vector3 {
	GRID_ORIGIN_X :: f32(GRID_WIDTH) / 2
	GRID_ORIGIN_Y :: f32(GRID_HEIGHT) / 2
	x := index % GRID_WIDTH
	y := index / GRID_WIDTH

	return {f32(x) - GRID_ORIGIN_X, 0.5, f32(y) - GRID_ORIGIN_Y}
}

tile_move_query :: proc(c: ^Combat_Context, index: int) -> (result: Move_Result) {
	tile := c.grid[index]
	switch content in tile.content {
	case Empty_Tile:
		result = .Ok
	case ^Character_Info:
		result = .Blocked
	case:
		result = .Ok
	}
	return
}

move_character_to_tile :: proc {
	move_character_to_tile_index,
	move_character_to_tile_coord,
}

move_character_to_tile_index :: proc(
	c: ^Combat_Context,
	info: ^Character_Info,
	index: int,
) -> (
	result: Move_Result,
) {
	if tile_move_query(c, index) == .Ok {
		info.coord = coord_to_index(index)
		c.grid[index].content = info
		iris.node_local_transform(info.node, iris.transform(t = coord_to_world(info.coord)))
	}
	return
}

move_character_to_tile_coord :: proc(
	c: ^Combat_Context,
	info: ^Character_Info,
	coord: Tile_Coordinate,
) -> (
	result: Move_Result,
) {
	index := coord_to_index(coord)
	if tile_move_query(c, index) == .Ok {
		info.coord = coord
		c.grid[index].content = info
		iris.node_local_transform(info.node, iris.transform(t = coord_to_world(info.coord)))
	}
	return
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

stat :: proc(max: int) -> Stat {
	return Stat{current = max, min = 0, max = max}
}

increase_stat :: proc(s: ^Stat, by: int) {
	s.current = min(s.current + by, s.max)
}

decrease_stat :: proc(s: ^Stat, by: int) {
	s.current = max(s.current - by, 0)
}

stat_current_value_percent :: proc(s: ^Stat) -> f32 {
	return f32(s.current) / f32(s.max)
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
	node:    ^iris.Model_Node,

	// Actual data
	kind:    Character_Kind,
	team:    Team_Mask,
	turn_id: Turn_ID,
	stats:   [len(Stat_Kind)]Stat,

	// Spatial data
	coord:   Tile_Coordinate,
}

Character_Kind :: enum {
	Player,
	Computer,
}

advance_simulation :: proc(ctx: ^Combat_Context) {
	character_take_damage :: proc(ctx: ^Combat_Context, id: Turn_ID, amount: int) {
		decrease_stat(&ctx.characters[id].stats[Stat_Kind.Health], amount)
	}

	compute_ai_action :: proc(
		ctx: ^Combat_Context,
		info: ^Character_Info,
	) -> (
		action: Combat_Action,
		done: bool,
	) {
		action = Nil_Action{}
		done = true
		return
	}

	// Player specific procedures
	{
		// Reset the states
		ctx.player_controller.target_info = nil

		target_position: iris.Vector3
		target_info: ^Character_Info
		ray := iris.camera_mouse_ray(ctx.scene.main_camera)
		for character, i in ctx.characters {
			result := iris.ray_bounding_box_intersection(ray, character.node.global_bounds)
			if result.hit {
				target_position = iris.translation_from_matrix(character.node.global_transform)
				target_info = &ctx.characters[i]
				break
			}
		}

		ctx.player_controller.target_position = target_position
		if target_info != nil {
			ctx.player_controller.target_info = target_info
			ctx.player_controller.refresh_portraits = true
		}

		if ctx.player_controller.attack_animation.playing {
			iris.advance_animation(
				&ctx.player_controller.attack_animation,
				f32(iris.elapsed_time()),
			)

			displacement :=
				ctx.player_controller.direction * ctx.player_controller.animation_offset
			pos := ctx.player_controller.position + displacement
			iris.node_local_transform(
				ctx.player_controller.character_info.node,
				iris.transform(t = pos),
			)
		}
	}

	character := &ctx.characters[ctx.current]
	action: Combat_Action
	turn_over: bool

	switch character.kind {
	case .Player:
		action, turn_over = compute_player_action(&ctx.player_controller)
	case .Computer:
		action, turn_over = compute_ai_action(ctx, character)
	}

	switch a in action {
	case Nil_Action:
	case Attack_Action:
		character_take_damage(ctx, a.target, a.amount)
	}

	if turn_over {
		switch character.kind {
		case .Player:
			end_player_turn(&ctx.player_controller)
		case .Computer:
		}

		ctx.current += 1
		if int(ctx.current) >= len(ctx.characters) {
			ctx.current = 0
			// Resort the turn order
		}

		next := &ctx.characters[ctx.current]
		switch next.kind {
		case .Player:
			start_player_turn(&ctx.player_controller, next)
		case .Computer:
		}
	}
}
