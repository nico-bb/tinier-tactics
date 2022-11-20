package main

import "core:fmt"
import "core:mem"
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
			if child_result in d.expected {
				result = .Success
				return
			}
		}
	case ^Behavior_Branch_Node:
		if execute_node(bt, d.condtion) == .Success {
			execute_node(bt, d.left)
		} else {
			execute_node(bt, d.right)
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
	ctx:             ^Combat_Context,
	b_tree:          Behavior_Tree,
	mem_buffer:      [mem.Kilobyte * 32]byte,
	agent_info:      ^Character_Info,
	target_info:     ^Character_Info,
	buffered_action: Combat_Action,

	// Navigation
	path_buf:        [50]Tile_Info,
	path:            []Tile_Info,
	path_count:      int,
	path_index:      int,
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
			right = new_behavior_node_from(
				&ai.b_tree,
				Behavior_Action_Node{user_data = ai, effect_proc = ai_move_to_closest_enemy},
			),
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

	execute_node(&ai.b_tree, ai.b_tree.root)

	action = Nil_Action{}
	done = true
	return
}

ai_enemy_in_close_range :: proc(data: rawptr) -> bool {
	ai := cast(^AI_Controller)data

	adjacents := adjacent_tiles(c = ai.ctx, coord = ai.agent_info.coord, with_blocked_tiles = true)
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

ai_attack_enemy :: proc(data: rawptr) {
	fmt.println("Attack!")
}

ai_move_to_closest_enemy :: proc(data: rawptr) {
	ai := cast(^AI_Controller)data
	target := find_closest_target(ai.ctx, ai.agent_info.coord, ai.agent_info.team)

	if target != nil {
		ai.path, ai.path_count, _ = path_to_tile(
			ai.ctx,
			Path_Options{
				start = ai.agent_info.coord,
				end = target.?.coord,
				include_start = true,
				include_end = false,
			},
			ai.path_buf[:],
		)
	}

	fmt.printf("Let's move to: %v!", target.?.coord)
}
