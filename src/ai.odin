package main

import "core:fmt"
import "core:mem"
import "core:math/linalg"
import "lib:iris"
import "lib:iris/allocators"

// Do we need to be able to traverse the tree bottom-up?
Behavior_Tree :: struct {
	blackboard: Behavior_Blackboard,
	root:       ^Behavior_Node,
	current:    Maybe(^Behavior_Node),
	free_list:  allocators.Free_List_Allocator,
	allocator:  mem.Allocator,
}

Behavior_Blackboard :: map[int]rawptr

Behavior_Results :: distinct bit_set[Behavior_Result]

Behavior_Result :: enum {
	Success,
	Failure,
	In_Process,
}

Behavior_Error :: enum {
	Invalid_Parent,
}

Behavior_Node :: struct {
	blackboard: Behavior_Blackboard,
	derived:    Any_Behavior_Node,
}

Any_Behavior_Node :: union {
	// Leaf nodes
	^Behavior_Condition_Node,
	^Behavior_Action_Node,

	// Composite nodes
	^Behavior_Composite_Node,
	^Behavior_Branch_Node,
}

// predicate
Behavior_Condition_Node :: struct {
	using base:     Behavior_Node,
	user_data:      rawptr,
	condition_proc: proc(data: rawptr) -> bool,
}

Behavior_Action_Node :: struct {
	using base:  Behavior_Node,
	user_data:   rawptr,
	effect_proc: proc(data: rawptr) -> (done: bool),
}

// Pack both sequence and fallback
Behavior_Composite_Node :: struct {
	using base: Behavior_Node,
	children:   [dynamic]^Behavior_Node,
	expected:   Behavior_Results,
}

Behavior_Branch_Node :: struct {
	using base: Behavior_Node,
	condtion:   ^Behavior_Node,
	left:       ^Behavior_Node,
	right:      ^Behavior_Node,
}

Behavior_Logic_Node :: struct {
	using base:   Behavior_Node,
	node:         ^Behavior_Node,
	logic:        enum {
		Repeat,
		Invert,
		Always_Success,
		Until_Fail,
	},

	// Fat struct data
	repeat_times: int,
}

init_behavior_tree :: proc(bt: ^Behavior_Tree, buf: []byte) {
	allocators.init_free_list_allocator(&bt.free_list, buf, .Find_Best, 4)
	bt.allocator = allocators.free_list_allocator(&bt.free_list)
}

destroy_behavior_tree :: proc(bt: ^Behavior_Tree) {
	destroy_behavior_node(bt, bt.root)
}

new_behavior_node :: proc(bt: ^Behavior_Tree, $T: typeid) -> ^T {
	node := new(T, bt.allocator)
	node.derived = node
	init_behavior_node(bt, node)
	return node
}

new_behavior_node_from :: proc(bt: ^Behavior_Tree, proto: $T) -> ^T {
	node := new_clone(proto, bt.allocator)
	node.derived = node
	init_behavior_node(bt, node)
	return node
}

init_behavior_node :: proc(bt: ^Behavior_Tree, node: ^Behavior_Node) {
	context.allocator = bt.allocator
	switch d in node.derived {
	case ^Behavior_Condition_Node:
	case ^Behavior_Action_Node:
	case ^Behavior_Composite_Node:
		d.children = make([dynamic]^Behavior_Node)
	case ^Behavior_Branch_Node:
	}
}

destroy_behavior_node :: proc(bt: ^Behavior_Tree, node: ^Behavior_Node) {
	switch d in node.derived {
	case ^Behavior_Condition_Node:
		free(d)
	case ^Behavior_Action_Node:
		free(d)
	case ^Behavior_Composite_Node:
		for child in d.children {
			destroy_behavior_node(bt, child)
		}
		free(d)
	case ^Behavior_Branch_Node:
		destroy_behavior_node(bt, d.condtion)
		destroy_behavior_node(bt, d.left)
		destroy_behavior_node(bt, d.right)
		free(d)
	}
}

// probably need to pass the AI_Controller structure
execute_node :: proc(bt: ^Behavior_Tree, node: ^Behavior_Node) -> (result: Behavior_Result) {
	switch d in node.derived {
	case ^Behavior_Condition_Node:
		condition_ok := d.condition_proc(d.user_data)
		result = .Success if condition_ok else .Failure

	case ^Behavior_Action_Node:
		done := d.effect_proc(d.user_data)
		result = .Success if done else .In_Process

	case ^Behavior_Composite_Node:
		for child in d.children {
			child_result := execute_node(bt, child)
			switch {
			case child_result == .In_Process:
				result = child_result
				return
			case child_result not_in d.expected:
				result = .Failure
				return
			}
		}
	case ^Behavior_Branch_Node:
		if execute_node(bt, d.condtion) == .Success {
			result = execute_node(bt, d.left)
		} else {
			result = execute_node(bt, d.right)
		}
	}
	return
}

execute_behavior :: proc(bt: ^Behavior_Tree) {
	if bt.current != nil {
		execute_node(bt, bt.current.?)
	} else {
		execute_node(bt, bt.root)
	}
}

AI_Controller :: struct {
	ctx:                ^Combat_Context,
	b_tree:             Behavior_Tree,
	mem_buffer:         [mem.Kilobyte * 32]byte,
	agent_info:         ^Character_Info,
	target_info:        ^Character_Info,
	buffered_action:    Combat_Action,

	// Navigation
	dt:                 f32,
	path_acquired:      bool,
	path_buf:           [50]Tile_Info,
	path:               []Tile_Info,
	path_length:        int,
	path_index:         int,

	// Movement Animations
	animation_offset:   f32,
	movement_animation: iris.Animation_Player,
	direction:          iris.Vector3,
	position:           iris.Vector3,
}

AI_Data_Kind :: enum {
	Target,
}

init_ai_controller :: proc(ctx: ^Combat_Context) {
	ctx.ai_controller = AI_Controller{}

	ai := &ctx.ai_controller
	ai.ctx = ctx
	init_behavior_tree(&ai.b_tree, ai.mem_buffer[:])
	ai.b_tree.root = new_behavior_node_from(
		&ai.b_tree,
		Behavior_Branch_Node{
			condtion = new_behavior_node_from(
				&ai.b_tree,
				Behavior_Condition_Node{user_data = ai, condition_proc = ai_enemy_in_close_range},
			),
			left = new_behavior_node_from(
				&ai.b_tree,
				Behavior_Action_Node{user_data = ai, effect_proc = ai_attack_enemy},
			),
			right = ai_move_sub_tree(ai),
		},
	)
}

compute_ai_action :: proc(
	ctx: ^Combat_Context,
	info: ^Character_Info,
) -> (
	action: Combat_Action,
	done: bool,
) {
	ai := &ctx.ai_controller
	ai.agent_info = info
	ai.dt = f32(iris.elapsed_time())
	ai.buffered_action = Nil_Action{}

	result := execute_node(&ai.b_tree, ai.b_tree.root)
	switch result {
	case .Failure:
		assert(false)
	case .In_Process:
		done = false
	case .Success:
		done = true
	}

	action = ai.buffered_action
	return
}

ai_move_sub_tree :: proc(ai: ^AI_Controller) -> ^Behavior_Node {
	sub := new_behavior_node(&ai.b_tree, Behavior_Composite_Node)
	sub.expected = {.Success}

	enemy_in_range := new_behavior_node_from(&ai.b_tree, Behavior_Condition_Node {
		user_data = ai,
		condition_proc = proc(data: rawptr) -> (ok: bool) {
			ai := cast(^AI_Controller)data
			if ai.target_info != nil {
				ok = true
			} else {
				target := find_closest_target(ai.ctx, ai.agent_info.coord, ai.agent_info.team)
				if target != nil {
					ai.target_info = target.?
					ok = true
				}
			}
			return
		},
	})
	get_path := new_behavior_node_from(&ai.b_tree, Behavior_Condition_Node {
		user_data = ai,
		condition_proc = proc(data: rawptr) -> (ok: bool) {
			ai := cast(^AI_Controller)data
			if ai.path_acquired {
				ok = true
				return
			}
			ai.path, ai.path_length, ok = path_to_tile(
				ai.ctx,
				Path_Options{
					start = ai.agent_info.coord,
					end = ai.target_info.coord,
					include_start = true,
					include_end = false,
					mask = {.Ok, .Blocked},
				},
				ai.path_buf[:],
			)
			ai.path_acquired = ok
			ai.path_index = 0
			first := index_to_world(ai.path[0].index)
			then := index_to_world(ai.path[1].index)
			ai.direction = linalg.vector_normalize(then - first)
			ai.position = iris.translation_from_matrix(ai.agent_info.node.local_transform)
			return
		},
	})

	move_along := new_behavior_node_from(&ai.b_tree, Behavior_Action_Node {
			user_data = ai,
			effect_proc = proc(data: rawptr) -> (done: bool) {
				ai := cast(^AI_Controller)data
				step_done := iris.advance_animation(&ai.movement_animation, ai.dt)

				fmt.println(ai.animation_offset)
				displacement := ai.direction * ai.animation_offset
				pos := ai.position + displacement
				iris.node_local_transform(
					ai.agent_info.node,
					iris.transform(t = pos, s = CHARACTER_SCALE),
				)

				if step_done {
					ai.path_index += 1
					if ai.path_index < ai.path_length - 1 {
						current := index_to_world(ai.path[ai.path_index].index)
						next := index_to_world(ai.path[ai.path_index + 1].index)

						ai.position = current
						ai.direction = linalg.vector_normalize(next - current)
						iris.reset_animation(&ai.movement_animation)
						ai.movement_animation.playing = true
					}
				}

				done = !(ai.path_index < 2) || ai.path_index >= ai.path_length - 1
				if done {
					ai.path_index = 0
					ai.path_acquired = false
					ai.buffered_action = Move_Action {
						from = ai.agent_info.coord,
						to   = index_to_coord(ai.path[ai.path_length - 1].index),
					}
				}
				return
			},
		})

	append(&sub.children, enemy_in_range, get_path, move_along)

	return sub
}

ai_enemy_in_close_range :: proc(data: rawptr) -> bool {
	ai := cast(^AI_Controller)data

	adjacents := adjacent_tiles(c = ai.ctx, coord = ai.agent_info.coord, mask = {.Ok, .Blocked})
	for adj in adjacents {
		if adj != nil {
			adjacent := adj.?
			if target, ok := adjacent.content.(^Character_Info); ok {
				if target.team != ai.agent_info.team {
					b_id := int(AI_Data_Kind.Target)
					ai.b_tree.blackboard[b_id] = target
					return true
				}
			}
		}
	}

	return false
}

ai_attack_enemy :: proc(data: rawptr) -> bool {
	fmt.println("Attack!")
	return true
}
