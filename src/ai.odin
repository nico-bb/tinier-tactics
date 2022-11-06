package main

import "core:mem"
import "lib:iris/allocators"

// Do we need to be able to traverse the tree bottom-up?
Behavior_Tree :: struct {
	blackboard: Behavior_Blackboard,
	root:       ^Behavior_Node,
	current:    ^Behavior_Node,
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
	effect_proc: proc(data: rawptr),
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

new_behavior_tree :: proc(buf: []byte) -> Behavior_Tree {
	tree := Behavior_Tree{}
	allocators.init_free_list_allocator(&tree.free_list, buf, .Find_Best, 4)
	tree.allocator = allocators.free_list_allocator(&tree.free_list)
	return tree
}

destroy_behavior_tree :: proc(bt: ^Behavior_Tree) {
	destroy_behavior_node(bt, bt.root)
}

new_behavior_node :: proc(bt: ^Behavior_Tree, $T: typeid) -> ^T {
	node := new(T, bt.allocator)
	init_behavior_node(bt, node)
	return node
}

new_behavior_node_from :: proc(bt: ^Behavior_Tree, proto: $T) -> ^T {
	node := new_clone(proto, bt.allocator)
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
execute_node :: proc(node: ^Behavior_Node) -> (result: Behavior_Result) {
	switch d in node.derived {
	case ^Behavior_Condition_Node:
		condition_ok := d.condition_proc(d.user_data)
		result = .Success if condition_ok else .Failure

	case ^Behavior_Action_Node:
		d.effect_proc(d.user_data)
		result = .Success

	case ^Behavior_Composite_Node:
		for child in d.children {
			child_result := execute_node(child)
			if child_result in d.expected {
				result = .Success
				return
			}
		}
	case ^Behavior_Branch_Node:
		if execute_node(d.condtion) == .Success {
			execute_node(d.left)
		} else {
			execute_node(d.right)
		}
	}
	return .Failure
}

AI_Controller :: struct {
	ctx:             ^Combat_Context,
	b_tree:          Behavior_Tree,
	mem_buffer:      [mem.Kilobyte * 32]byte,
	agent_info:      ^Character_Info,
	target_info:     ^Character_Info,
	buffered_action: Combat_Action,
}

AI_Data_Kind :: enum {
	Target,
}

init_ai_controller :: proc(ctx: ^Combat_Context) {
	ctx.ai_controller = AI_Controller{}
	ctx.ai_controller.b_tree = new_behavior_tree(ctx.ai_controller.mem_buffer[:])

	ai := &ctx.ai_controller
	ai.b_tree.root = new_behavior_node_from(
		&ai.b_tree,
		Behavior_Branch_Node{
			condtion = new_behavior_node_from(
				&ai.b_tree,
				Behavior_Condition_Node{user_data = ai, condition_proc = ai_enemy_in_close_range},
			),
			left = new_behavior_node_from(&ai.b_tree, Behavior_Action_Node {
					user_data = ai,
					effect_proc = proc(data: rawptr) {},
				}),
			right = new_behavior_node_from(&ai.b_tree, Behavior_Action_Node {
					user_data = ai,
					effect_proc = proc(data: rawptr) {},
				}),
		},
	)
}

ai_enemy_in_close_range :: proc(data: rawptr) -> bool {
	ai := cast(^AI_Controller)data

	adjacents := adjacent_tiles(ai.ctx, ai.agent_info.coord)
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

ai_attack_enemy :: proc() {}
