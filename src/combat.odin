package main

import "core:fmt"
import "core:sort"
import "core:slice"
// import "core:math"
import "core:math/linalg"
import "lib:iris"

Combat_Context :: struct {
	scene:                   ^iris.Scene,
	character_mesh:          ^iris.Mesh,
	character_material:      ^iris.Material,
	player:                  ^iris.Model_Node,
	enemy:                   ^iris.Model_Node,
	default_spec:            ^iris.Shader_Specialization,
	highlight_spec:          ^iris.Shader_Specialization,
	tile_material_default:   ^iris.Material,
	tile_material_highlight: ^iris.Material,

	// Logic
	player_controller:       Player_Controller,
	characters:              [dynamic]Character_Info,
	current:                 Turn_ID,

	// Spatial
	mouse_ray:               iris.Ray,
	grid_model:              ^iris.Model_Node,
	grid:                    []Tile_Info,

	// UI
	ui:                      ^iris.User_Interface_Node,
}

Combat_Button_ID :: enum {
	Move,
	Attack,
	Wait,
}

GRID_WIDTH :: 5
GRID_HEIGHT :: 5

init_combat_context :: proc(c: ^Combat_Context) {
	iris.add_light(.Directional, iris.Vector3{2, 3, 2}, {100, 100, 90, 1}, false)

	shader, shader_exist := iris.shader_from_name("deferred_geometry")
	assert(shader_exist)
	spec_res := iris.shader_specialization_resource("deferred_default", shader)
	c.default_spec = spec_res.data.(^iris.Shader_Specialization)
	iris.set_specialization_subroutine(
		shader,
		c.default_spec,
		.Fragment,
		"sampleAlbedo",
		"sampleDefaultAlbedo",
	)

	tile_spec_res := iris.shader_specialization_resource("highlight_tile", shader)
	c.highlight_spec = tile_spec_res.data.(^iris.Shader_Specialization)
	iris.set_specialization_subroutine(
		shader,
		c.highlight_spec,
		.Fragment,
		"sampleAlbedo",
		"sampleHighlightTileAlbedo",
	)


	mat_res := iris.material_resource(
		iris.Material_Loader{name = "character", shader = shader, specialization = c.default_spec},
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
				id = iris.Widget_ID(Combat_Button_ID.Move),
				flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
				background = iris.Widget_Background{style = .Solid},
			},
			text = iris.Text{data = "Move", style = .Center},
			data = &c.player_controller,
			callback = on_action_btn_pressed,
		},
	)
	iris.layout_add_widget(action_panel, move_btn, 25)

	attack_btn := iris.new_widget_from(
		c.ui,
		iris.Button_Widget{
			base = iris.Widget{
				id = iris.Widget_ID(Combat_Button_ID.Attack),
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
				id = iris.Widget_ID(Combat_Button_ID.Wait),
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
	c.tile_material_default =
	iris.material_resource(
		iris.Material_Loader{
			name = "tile",
			shader = c.character_material.shader,
			specialization = c.default_spec,
		},
	).data.(^iris.Material)
	iris.set_material_map(
		c.tile_material_default,
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

	c.tile_material_highlight =
	iris.material_resource(
		iris.Material_Loader{
			name = "tile_highlight",
			shader = c.character_material.shader,
			specialization = c.highlight_spec,
		},
	).data.(^iris.Material)

	c.grid = make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT)
	for y in 0 ..< GRID_HEIGHT {
		for x in 0 ..< GRID_WIDTH {
			tile_node := iris.model_node_from_mesh(c.scene, tile_mesh, c.tile_material_default)
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
	pc.ctx = c
	pc.tiles = make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT)
	pc.path = make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT)
	pc.action_panel = init_action_ui(c)
	pc.unit_portrait = init_portrait(c, iris.Vector2{GAME_MARGIN, GAME_MARGIN})
	pc.target_portrait = init_portrait(c, iris.Vector2{1600 - 250 - GAME_MARGIN, GAME_MARGIN})
	pc.info_panel = init_info_panel(c)
	c.player_controller.refresh_portraits = true

	// Attack animation
	{
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
		pc.attack_animation.targets_start_value[0] = f32(0)
		iris.reset_animation(&pc.attack_animation)
	}

	// Movement animation
	{
		UNIT_MOVEMENT_DURATION :: 0.5

		anim_res := iris.animation_resource({name = "character_movement", loop = false})
		animation := anim_res.data.(^iris.Animation)
		animation.channels = make([]iris.Animation_Channel, 1)

		channel := iris.Animation_Channel {
			kind            = .Translation,
			mode            = .Linear,
			frame_durations = make([]f32, 1),
			frame_outputs   = make([]iris.Animation_Value, 1),
		}

		channel.frame_durations[0] = UNIT_MOVEMENT_DURATION
		channel.frame_outputs[0] = f32(1)

		animation.channels[0] = channel

		pc.movement_animation = iris.make_animation_player(animation)
		pc.movement_animation.targets[0] = &pc.animation_offset
		pc.movement_animation.targets_start_value[0] = f32(0)
		iris.reset_animation(&pc.movement_animation)
	}
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
	// Context
	ctx:                  ^Combat_Context,

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
	tiles:                []Tile_Info,
	tile_count:           int,
	path:                 []Tile_Info,
	path_length:          int,
	path_index:           int,

	// Spatial data
	position:             iris.Vector3,
	direction:            iris.Vector3,
	animation_offset:     f32,
	target_position:      iris.Vector3,

	// All the animations
	idle_animation:       iris.Animation_Player,
	attack_animation:     iris.Animation_Player,
	movement_animation:   iris.Animation_Player,
	current_animation:    ^iris.Animation_Player,
}

Player_Controller_State :: enum {
	Idle,
	Select_Move,
	Select_Target,
	Wait_For_Animation,
	Wait_For_Movement,
}

start_player_turn :: proc(pc: ^Player_Controller, current: ^Character_Info) {
	controller_state_transition(pc, .Idle)
	pc.character_info = current
	pc.position = iris.translation_from_matrix(current.node.local_transform)
}

on_action_btn_pressed :: proc(data: rawptr, id: iris.Widget_ID) {
	pc := cast(^Player_Controller)data
	btn_id := Combat_Button_ID(id)

	fmt.println(id, btn_id)

	switch btn_id {
	case .Move:
		controller_state_transition(pc, .Select_Move)
	case .Attack:
		controller_state_transition(pc, .Select_Target)
	case .Wait:
	}
}

on_animation_end :: proc(pc: ^Player_Controller) {
	#partial switch pc.state {
	case .Wait_For_Movement:
		if pc.path_index + 1 < pc.path_length - 1 {
			current := index_to_world(pc.path[pc.path_index + 1].index)
			next := index_to_world(pc.path[pc.path_index + 2].index)

			pc.position = current
			pc.direction = linalg.vector_normalize(next - current)
			iris.reset_animation(&pc.movement_animation)
			pc.movement_animation.playing = true
			pc.current_animation = &pc.movement_animation
		}
		pc.path_index += 1
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
	case .Select_Move:
		m_left := iris.mouse_button_state(.Left)
		m_right := iris.mouse_button_state(.Right)
		esc := iris.key_state(.Escape)

		switch {
		case .Just_Pressed in m_left:
			// Find the tile cliked
			for tile in pc.tiles[:pc.tile_count] {
				result := iris.ray_bounding_box_intersection(
					pc.ctx.mouse_ray,
					tile.node.global_bounds,
				)
				if result.hit {
					exist: bool
					_, pc.path_length, exist = path_to_tile(
						pc.ctx,
						pc.character_info.coord,
						index_to_coord(tile.index),
						true,
						pc.path[:],
					)
					pc.path_index = 0
					pc.current_animation = &pc.movement_animation
					pc.movement_animation.playing = true

					first := index_to_world(pc.path[0].index)
					then := index_to_world(pc.path[1].index)
					pc.direction = linalg.vector_normalize(then - first)

					controller_state_transition(pc, .Wait_For_Movement)
				}
			}

		case .Just_Pressed in m_right || .Just_Pressed in esc:
			controller_state_transition(pc, .Idle)
		}

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
				pc.current_animation = &pc.attack_animation

				pc.state = .Wait_For_Animation
				pc.selected_target_info = t
			}
		case .Just_Pressed in m_right || .Just_Pressed in esc:
			controller_state_transition(pc, .Idle)
		}

	case .Wait_For_Animation:
		if !pc.attack_animation.playing {
			controller_state_transition(pc, .Idle)

			action := Attack_Action {
				target = pc.selected_target_info.turn_id,
				amount = 1,
			}
			return action, true
		}

	case .Wait_For_Movement:
		if pc.path_index >= pc.path_length {
			// We are done moving
			controller_state_transition(pc, .Idle)
			action := Move_Action {
				from = pc.character_info.coord,
				to   = index_to_coord(pc.path[pc.path_length - 1].index),
			}
			return action, true
		}
	}

	return Nil_Action{}, false
}

controller_state_transition :: proc(pc: ^Player_Controller, to: Player_Controller_State) {
	#partial switch pc.state {
	case .Select_Move:
		tiles_highlight(pc.ctx, pc.tiles[:pc.tile_count], false)
	}

	switch to {
	case .Idle:
		iris.widget_active(widget = pc.action_panel, active = true)
		iris.widget_active(widget = pc.unit_portrait, active = true)
		iris.widget_active(widget = pc.info_panel, active = false)
	case .Select_Move:
		iris.widget_active(widget = pc.info_panel, active = true)
		iris.set_label_text(
			pc.info_panel.children[0].derived.(^iris.Label_Widget),
			"Please select a destination",
		)
		_, pc.tile_count, _ = tiles_in_range(
			c = pc.ctx,
			start = pc.character_info.coord,
			range = 2,
			include_start = false,
			buf = pc.tiles[:],
		)
		tiles_highlight(pc.ctx, pc.tiles[:pc.tile_count], true)

	case .Select_Target:
		iris.widget_active(widget = pc.info_panel, active = true)
		iris.set_label_text(
			pc.info_panel.children[0].derived.(^iris.Label_Widget),
			"Please select a target",
		)
	case .Wait_For_Animation, .Wait_For_Movement:
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

Tile_Result :: enum {
	Ok,
	Out_Of_Bounds,
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

tile_query :: proc(c: ^Combat_Context, coord: Tile_Coordinate) -> (result: Tile_Result) {
	index := coord_to_index(coord)
	if (coord.x < 0 || coord.x >= GRID_WIDTH) || (coord.y < 0 || coord.y >= GRID_HEIGHT) {
		result = .Out_Of_Bounds
		return
	}

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
	result: Tile_Result,
) {
	if tile_query(c, index_to_coord(index)) == .Ok {
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
	result: Tile_Result,
) {
	index := coord_to_index(coord)
	if tile_query(c, coord) == .Ok {
		info.coord = coord
		c.grid[index].content = info
		iris.node_local_transform(info.node, iris.transform(t = coord_to_world(info.coord)))
	}
	return
}

/* TODO:
	- A* search
	- Range search
*/

adjacent_tiles :: proc(
	c: ^Combat_Context,
	coord: Tile_Coordinate,
) -> (
	result: [4]Maybe(Tile_Info),
) {
	adjacents := [len(iris.Direction)]Tile_Coordinate {
		iris.Direction.Up = {coord.x, coord.y - 1},
		iris.Direction.Right = {coord.x + 1, coord.y},
		iris.Direction.Down = {coord.x, coord.y + 1},
		iris.Direction.Left = {coord.x - 1, coord.y},
	}

	for direction in iris.Direction {
		index := coord_to_index(adjacents[direction])
		if tile_query(c, adjacents[direction]) == .Ok {
			result[direction] = c.grid[index]
		}
	}

	return
}

tiles_highlight :: proc(c: ^Combat_Context, tiles: []Tile_Info, on: bool) {
	for tile in tiles {
		switch on {
		case true:
			tile.node.materials[0] = c.tile_material_highlight
		case false:
			tile.node.materials[0] = c.tile_material_default
		}
	}
}

tiles_in_range :: proc(
	c: ^Combat_Context,
	start: Tile_Coordinate,
	range: int,
	include_start: bool,
	buf: []Tile_Info,
) -> (
	[]Tile_Info,
	int,
	bool,
) {
	contains :: proc(data: []Tile_Info, t: Tile_Info) -> bool {
		for tile in data {
			if t.index == tile.index {
				return true
			}
		}
		return false
	}

	at :: proc(data: []Tile_Info, t: Tile_Info) -> (index: int, exist: bool) {
		for tile, i in data {
			if t.index == tile.index {
				return i, true
			}
		}
		return -1, false
	}

	start_index := coord_to_index(start)
	if include_start && tile_query(c, start) != .Ok {
		return {}, -1, false
	}

	iris.begin_temp_allocation()
	defer iris.end_temp_allocation()

	os := make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT, context.temp_allocator)
	f := make([]Tile_Info, GRID_WIDTH * GRID_HEIGHT, context.temp_allocator)

	open_set := slice.into_dynamic(os)
	frontier := slice.into_dynamic(f)
	closed_set := slice.into_dynamic(buf)

	clear(&open_set)
	clear(&frontier)
	clear(&closed_set)

	step := 0
	append(&open_set, c.grid[start_index])
	for step <= range {
		for len(open_set) > 0 {
			tile := pop(&open_set)
			append(&closed_set, tile)

			adjacents := adjacent_tiles(c, index_to_coord(tile.index))
			for adjacent in adjacents {
				if adjacent != nil {
					adj := adjacent.?
					visited :=
						contains(open_set[:], adj) ||
						contains(closed_set[:], adj) ||
						contains(frontier[:], adj)
					if !visited {
						append(&frontier, adj)
					}
				}
			}

		}

		for tile in frontier {
			append(&open_set, tile)
		}
		clear(&frontier)
		step += 1
	}

	if !include_start {
		si, _ := at(closed_set[:], c.grid[start_index])
		unordered_remove(&closed_set, si)
	}
	return closed_set[:], len(closed_set), true
}

// This path searching implementation is O(n) (we use a linear search for the min)
// This isn't the best but considering that the
// combat grids are pretty small, it shouldn't matter much
path_to_tile :: proc(
	c: ^Combat_Context,
	start: Tile_Coordinate,
	end: Tile_Coordinate,
	include_start: bool,
	buf: []Tile_Info,
) -> (
	path: []Tile_Info,
	path_length: int,
	path_found: bool,
) {
	MOVEMENT_COST :: 5
	Search_Node :: struct {
		data:   Tile_Info,
		parent: Maybe(^Search_Node),
		g_cost: int, // The accumulation of all the previous cost
		h_cost: int, // The heuristic or Manhattan distance in this case
		f_cost: int, // The sum of the g_cost and h_cost
	}
	search_min :: proc(node_set: []Search_Node) -> (index: int) {
		current_min := 99999
		for node, i in node_set {
			if node.f_cost < current_min {
				index = i
				current_min = node.f_cost
			}
		}
		return
	}
	heuristic :: proc(current, end: Tile_Coordinate) -> (h: int) {
		return abs(current.x - end.x) + abs(current.y - end.y)
	}
	contains :: proc(node_set: []Search_Node, node: Search_Node) -> (at: int, exist: bool) {
		for n, i in node_set {
			if node.data.index == n.data.index {
				return i, true
			}
		}
		return -1, false
	}

	start_index := coord_to_index(start)
	end_index := coord_to_index(end)
	if (include_start && tile_query(c, start) != .Ok) && tile_query(c, end) != .Ok {
		return {}, -1, false
	}

	iris.begin_temp_allocation()
	defer iris.end_temp_allocation()

	os := make([]Search_Node, GRID_WIDTH * GRID_HEIGHT, context.temp_allocator)
	cs := make([]Search_Node, GRID_WIDTH * GRID_HEIGHT, context.temp_allocator)

	open_set := slice.into_dynamic(os)
	closed_set := slice.into_dynamic(cs)

	clear(&open_set)
	clear(&closed_set)

	end_node: ^Search_Node
	append(&open_set, Search_Node{data = c.grid[start_index], parent = nil})
	search: for len(open_set) > 0 {
		min_index := search_min(open_set[:])
		current := open_set[min_index]
		unordered_remove(&open_set, min_index)
		append(&closed_set, current)

		adjacents := adjacent_tiles(c, index_to_coord(current.data.index))
		search_adjacents: for adj in adjacents {
			if adj != nil {
				adjacent := adj.?

				next := Search_Node {
					data   = adjacent,
					parent = &closed_set[len(closed_set) - 1],
					g_cost = current.g_cost + 1,
					h_cost = heuristic(index_to_coord(adjacent.index), end),
				}
				next.f_cost = next.g_cost + next.h_cost

				// Are we done yet?
				if adjacent.index == end_index {
					// unimplemented("Path retrace not done yet")
					append(&closed_set, next)
					end_node = &closed_set[len(closed_set) - 1]
					break search
				}

				if at, exist := contains(open_set[:], next); exist {
					other := &open_set[at]
					if next.f_cost < other.f_cost {
						other.parent = next.parent
						other.f_cost = next.f_cost
					}
					continue search_adjacents
				}

				if _, exist := contains(closed_set[:], next); !exist {
					append(&open_set, next)
				}
			}
		}
	}

	path_buf := slice.into_dynamic(buf)
	clear(&path_buf)
	current := end_node
	for {
		if current.parent == nil {
			if include_start {
				append(&path_buf, current.data)
			}
			break
		}
		append(&path_buf, current.data)
		current = current.parent.?
	}
	slice.reverse(path_buf[:])

	return path_buf[:], len(path_buf), true
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
	Move_Action,
	Attack_Action,
}

Nil_Action :: struct {}

Move_Action :: struct {
	from: Tile_Coordinate,
	to:   Tile_Coordinate,
}

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
		ctx.mouse_ray = iris.camera_mouse_ray(ctx.scene.main_camera)
		for character, i in ctx.characters {
			result := iris.ray_bounding_box_intersection(
				ctx.mouse_ray,
				character.node.global_bounds,
			)
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

		current_animation := ctx.player_controller.current_animation
		if current_animation != nil && current_animation.playing {
			done := iris.advance_animation(current_animation, f32(iris.elapsed_time()))

			displacement :=
				ctx.player_controller.direction * ctx.player_controller.animation_offset
			fmt.println(ctx.player_controller.animation_offset)
			pos := ctx.player_controller.position + displacement
			iris.node_local_transform(
				ctx.player_controller.character_info.node,
				iris.transform(t = pos),
			)
			if done {
				on_animation_end(&ctx.player_controller)
			}
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
	case Move_Action:
		from_index := coord_to_index(a.from)
		ctx.grid[from_index].content = nil
		move_character_to_tile_coord(ctx, character, a.to)
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
