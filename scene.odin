package iris

import "core:log"
import "core:mem"
import "core:slice"
import "core:math/linalg"

import "gltf"
import "allocators"

Scene :: struct {
	free_list: allocators.Free_List_Allocator,
	allocator: mem.Allocator,
	name:      string,
	nodes:     [dynamic]^Node,
	roots:     [dynamic]^Node,
}

Node :: struct {
	scene:            ^Scene,
	flags:            Node_Flags,
	local_transform:  Matrix4,
	global_transform: Matrix4,
	parent:           ^Node,
	children:         [dynamic]^Node,
	user_data:        rawptr,
	derived:          Any_Node,
}

Node_Flags :: distinct bit_set[Node_Flag]

Node_Flag :: enum {
	Active,
	Root_Node,
	Dirty_Transform,
	Rendered,
}

Any_Node :: union {
	^Empty_Node,
	^Model_Node,
	^Skin_Node,
	^Canvas_Node,
	^User_Interface_Node,
}

Empty_Node :: struct {
	using base: Node,
}

Model_Node :: struct {
	using base:     Node,
	mesh_transform: Matrix4,
	meshes:         [dynamic]^Mesh,
	materials:      [dynamic]^Material,
}

init_scene :: proc(scene: ^Scene, allocator := context.allocator) {
	DEFAULT_SCENE_ALLOCATOR_SIZE :: mem.Megabyte * 50
	DEFAULT_SCENE_CAPACITY :: 20

	buf := make([]byte, DEFAULT_SCENE_ALLOCATOR_SIZE, allocator)
	allocators.init_free_list_allocator(&scene.free_list, buf, .Find_Best, 8)
	scene.allocator = allocators.free_list_allocator(&scene.free_list)

	context.allocator = scene.allocator
	scene.nodes = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)
	scene.roots = make([dynamic]^Node, 0, DEFAULT_SCENE_CAPACITY)
}

destroy_scene :: proc(scene: ^Scene) {
	free_all(scene.allocator)
	delete(scene.free_list.data)
	delete(scene.name)
}

update_scene :: proc(scene: ^Scene, dt: f32) {
	traverse_node :: proc(node: ^Node, parent_transform: Matrix4, dt: f32) {
		children_dirty_transform := false
		if .Dirty_Transform in node.flags {
			node.global_transform = linalg.matrix_mul(node.local_transform, parent_transform)
			node.flags -= {.Dirty_Transform}
			children_dirty_transform = true
		}
		switch n in node.derived {
		case ^Empty_Node:

		case ^Model_Node:

		case ^Skin_Node:
			update_skin_node(n, dt)

		case ^Canvas_Node:
			prepare_canvas_node_render(n)

		case ^User_Interface_Node:
			render_ui_node(n)
		}
		for child in node.children {
			if children_dirty_transform {
				child.flags += {.Dirty_Transform}
			}
			traverse_node(child, node.global_transform, dt)
		}
	}
	for root in scene.roots {
		traverse_node(root, linalg.MATRIX4F32_IDENTITY, dt)
	}
}

render_scene :: proc(scene: ^Scene) {
	traverse_node :: proc(node: ^Node) {
		if .Rendered in node.flags {
			switch n in node.derived {
			case ^Empty_Node:

			case ^Model_Node:
				mat_model := linalg.matrix_mul(n.global_transform, n.mesh_transform)
				for mesh, i in n.meshes {
					push_draw_command(
						Render_Mesh_Command{
							mesh = mesh,
							global_transform = mat_model,
							material = n.materials[i],
							cast_shadows = true,
						},
					)
				}
			case ^Skin_Node:
				mat_model := linalg.matrix_mul(n.target.global_transform, n.target.mesh_transform)
				for mesh, i in n.target.meshes {
					model_shader := n.target.materials[i].shader
					if _, exist := model_shader.uniforms["matJoints"]; exist {
						joint_matrices := skin_node_joint_matrices(n)
						set_shader_uniform(model_shader, "matJoints", &joint_matrices[0])
					}
					push_draw_command(
						Render_Mesh_Command{
							mesh = mesh,
							global_transform = mat_model,
							local_transform = n.target.local_transform,
							material = n.target.materials[i],
							cast_shadows = true,
						},
					)
				}
			case ^Canvas_Node:
				push_draw_command(
					Render_Custom_Command{
						data = n,
						render_proc = flush_canvas_node_buffers,
						options = {.Disable_Culling},
					},
				)

			case ^User_Interface_Node:
			}
		}
		for child in node.children {
			traverse_node(child)
		}
	}
	for root in scene.roots {
		traverse_node(root)
	}
}

new_node :: proc(scene: ^Scene, $T: typeid, local := linalg.MATRIX4F32_IDENTITY) -> ^T {
	node := new(T, scene.allocator)
	node.derived = node
	node.scene = scene

	node.local_transform = local
	init_node(scene, node)
	append(&scene.nodes, node)
	return node
}

new_node_from :: proc(scene: ^Scene, from: $T, local := linalg.MATRIX4F32_IDENTITY) -> ^T {
	node := new_clone(from)
	node.derived = node
	node.scene = scene

	node.local_transform = local
	init_node(scene, node)
	append(&scene.nodes, node)
	return node
}

init_node :: proc(scene: ^Scene, node: ^Node) {
	node.children.allocator = scene.allocator
	switch n in node.derived {
	case ^Empty_Node:

	case ^Model_Node:
		n.meshes.allocator = scene.allocator
		n.materials.allocator = scene.allocator
		n.flags += {.Rendered}

	case ^Skin_Node:
		n.flags -= {.Rendered}
		n.joint_roots.allocator = scene.allocator
		n.joint_lookup.allocator = scene.allocator
		n.animations.allocator = scene.allocator

	case ^Canvas_Node:
		n.flags += {.Rendered}
		init_canvas_node(n)

	case ^User_Interface_Node:
		n.flags += {.Rendered}
		n.commands.allocator = scene.allocator
		n.roots.allocator = scene.allocator
		init_ui_node(n, scene.allocator)
	}
}

insert_node :: proc(scene: ^Scene, node: ^Node, parent: ^Node = nil) {
	if parent == nil {
		node.flags += {.Root_Node}
		append(&scene.roots, node)
	} else {
		append(&parent.children, node)
	}
	node.flags += {.Dirty_Transform}
}

node_offset_transform :: proc(node: ^Node, t: Transform) {
	transform := linalg.matrix4_from_trs_f32(t = t.translation, r = t.rotation, s = t.scale)
	node.local_transform = linalg.matrix_mul(transform, node.local_transform)
	node.flags += {.Dirty_Transform}
}

node_local_transform :: proc(node: ^Node, t: Transform) {
	node.local_transform = linalg.matrix4_from_trs_f32(
		t = t.translation,
		r = t.rotation,
		s = t.scale,
	)
	node.flags += {.Dirty_Transform}
}

Model_Loader :: struct {
	flags:  Model_Loader_Flags,
	shader: ^Shader,
}

Model_Loader_Flags :: distinct bit_set[Model_Loader_Flag]

Model_Loader_Flag :: enum {
	Flip_Normals,
	Use_Global_Transform,
	Use_Local_Transform,
	Use_Identity,
	Load_Position,
	Load_Normal,
	Load_Tangent,
	Load_Joints0,
	Load_Weights0,
	Load_TexCoord0,

	// Specific data
	Load_Bones,
}

Model_Loading_Error :: enum {
	None,
	Invalid_Node,
	Missing_Mesh_Indices,
	Missing_Mesh_Attribute,
}

model_node_from_gltf :: proc(
	model: ^Model_Node,
	loader: Model_Loader,
	node: ^gltf.Node,
) -> (
	err: Model_Loading_Error,
) {
	if node.mesh != nil {
		data := node.mesh.?
		if .Use_Global_Transform in loader.flags {
			model.mesh_transform = node.global_transform
		} else if .Use_Local_Transform in loader.flags {
			model.mesh_transform = node.local_transform
		} else {
			model.mesh_transform = linalg.MATRIX4F32_IDENTITY
		}
		for _, i in data.primitives {
			begin_temp_allocation()

			mesh_res, err := load_mesh_from_gltf(loader = loader, p = &data.primitives[i])
			assert(err == nil)
			mesh := mesh_res.data.(^Mesh)

			material, exist := material_from_name(data.primitives[0].material.name)
			if !exist {
				material = load_material_from_gltf(data.primitives[0].material^)
			}
			material.shader = loader.shader

			end_temp_allocation()
			append(&model.meshes, mesh)
			append(&model.materials, material)
		}
	} else {
		err = .Invalid_Node
	}
	return
}

load_mesh_from_gltf :: proc(
	loader: Model_Loader,
	p: ^gltf.Primitive,
) -> (
	resource: ^Resource,
	err: Model_Loading_Error,
) {
	kind_to_float_count :: proc(kind: gltf.Accessor_Kind) -> uint {
		#partial switch kind {
		case .Vector2:
			return 2
		case .Vector3:
			return 3
		case .Vector4:
			return 4
		case .Scalar:
			return 1
		}
		unreachable()
	}
	MIN_ATTRIB_FLAG :: Model_Loader_Flag.Load_Position
	MAX_ATTRIB_FLAG :: Model_Loader_Flag.Load_TexCoord0

	if p.indices == nil {
		log.fatalf("%s: Only support indexed primitive", App_Module.Mesh)
		err = .Missing_Mesh_Indices
		return
	}
	indices: []u32
	vertices := make([dynamic]f32, 0, len(p.attributes) * 2 * 1000, context.temp_allocator)
	layout := make([dynamic]Vertex_Format, 0, len(p.attributes), context.temp_allocator)
	offsets := make([dynamic]int, 0, len(p.attributes), context.temp_allocator)

	#partial switch data in p.indices.data {
	case []u16:
		indices = make([]u32, len(data), context.temp_allocator)
		for index, i in data {
			indices[i] = u32(index)
		}
	case []u32:
		indices = data
	case:
		unreachable()
	}

	count: uint
	offset: int
	if .Load_Position in loader.flags {
		if gltf_position, has_position := p.attributes[gltf.POSITION]; has_position {
			offset = int(count) * size_of(f32)
			count += gltf_position.data.count * kind_to_float_count(gltf_position.data.kind)
			data := gltf_position.data.data.([]gltf.Vector3f32)
			position := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float3)
			append(&offsets, offset)
			append(&vertices, ..position)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Normal in loader.flags {
		if gltf_normal, has_normal := p.attributes[gltf.NORMAL]; has_normal {
			offset = int(count) * size_of(f32)
			count += gltf_normal.data.count * kind_to_float_count(gltf_normal.data.kind)
			data := gltf_normal.data.data.([]gltf.Vector3f32)
			normal := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float3)
			append(&offsets, offset)
			append(&vertices, ..normal)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Tangent in loader.flags {
		if gltf_tangent, has_tangent := p.attributes[gltf.TANGENT]; has_tangent {
			offset = int(count) * size_of(f32)
			count += gltf_tangent.data.count * kind_to_float_count(gltf_tangent.data.kind)
			data := gltf_tangent.data.data.([]gltf.Vector4f32)
			tangent := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..tangent)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Joints0 in loader.flags {
		if gltf_joints, has_joints := p.attributes[gltf.JOINTS_0]; has_joints {
			offset = int(count) * size_of(f32)
			temp_count := count
			count += gltf_joints.data.count * kind_to_float_count(gltf_joints.data.kind)
			data := gltf_joints.data.data.([]gltf.Vector4u16)
			joints := make([]f32, len(data) * 4, context.temp_allocator)
			for joint_ids, i in data {
				joints[i * 4] = f32(joint_ids.x)
				joints[i * 4 + 1] = f32(joint_ids.y)
				joints[i * 4 + 2] = f32(joint_ids.z)
				joints[i * 4 + 3] = f32(joint_ids.w)
			}
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..joints)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_Weights0 in loader.flags {
		if gltf_weights, has_weights := p.attributes[gltf.WEIGHTS_0]; has_weights {
			offset = int(count) * size_of(f32)
			count += gltf_weights.data.count * kind_to_float_count(gltf_weights.data.kind)
			data := gltf_weights.data.data.([]gltf.Vector4f32)
			weights := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float4)
			append(&offsets, offset)
			append(&vertices, ..weights)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	if .Load_TexCoord0 in loader.flags {
		if gltf_texcoord, has_texcoord := p.attributes[gltf.TEXCOORD_0]; has_texcoord {
			offset = int(count) * size_of(f32)
			count += gltf_texcoord.data.count * kind_to_float_count(gltf_texcoord.data.kind)
			data := gltf_texcoord.data.data.([]gltf.Vector2f32)
			texcoord := slice.reinterpret([]f32, data)
			append(&layout, Vertex_Format.Float2)
			append(&offsets, offset)
			append(&vertices, ..texcoord)
		} else {
			err = .Missing_Mesh_Attribute
			return
		}
	}

	resource = mesh_resource(
		Mesh_Loader{
			vertices = vertices[:],
			indices = indices,
			format = .Packed_Blocks,
			layout = Vertex_Layout(layout[:]),
			offsets = offsets[:],
		},
	)
	return
}

Skin_Node :: struct {
	using base:     Node,
	derived_flags:  Skin_Flags,
	target:         ^Model_Node,
	joints:         []Skin_Joint,
	joint_roots:    [dynamic]^Skin_Joint,
	joint_lookup:   map[uint]^Skin_Joint,
	joint_matrices: []Matrix4,

	// Animation data
	animations:     map[string]Animation_Player,
	player:         ^Animation_Player,
}

Skin_Joint :: struct {
	parent:               Maybe(^Skin_Joint),
	children:             []^Skin_Joint,
	local_transform:      Transform,
	root_space_transform: Matrix4,
	inverse_bind:         Matrix4,
}

Skin_Flags :: distinct bit_set[Skin_Flag]

Skin_Flag :: enum {
	Dirty_Joints,
	Dirty_Animation_Start_Values,
	Playing,
}

Skin_Loading_Error :: enum {
	None,
	Invalid_Node,
}

skin_node_from_gltf :: proc(skin: ^Skin_Node, node: ^gltf.Node) -> (err: Skin_Loading_Error) {
	if node.skin != nil {
		skin_info := node.skin.?
		inverse_binds: []Matrix4
		switch ibm in skin_info.inverse_bind_matrices {
		case gltf.Skin_Accessor_Inverse_Bind_Matrices:
			inverse_binds = slice.reinterpret([]Matrix4, ibm.data.([]gltf.Mat4f32))
		case gltf.Skin_Identity_Inverse_Bind_Matrices:
			inverse_binds = slice.reinterpret([]Matrix4, ibm)
		}

		skin.joints = make([]Skin_Joint, len(skin_info.joints), skin.scene.allocator)
		skin.joint_matrices = make([]Matrix4, len(skin_info.joints), skin.scene.allocator)
		for joint, i in skin_info.joints {
			skin.joints[i] = Skin_Joint {
				local_transform = transform_from_matrix(joint.local_transform),
				inverse_bind    = inverse_binds[i],
			}
			if len(joint.children) > 0 {
				skin.joints[i].children = make(
					[]^Skin_Joint,
					len(joint.children),
					skin.scene.allocator,
				)
			}
			skin.joint_lookup[skin_info.joint_indices[i]] = &skin.joints[i]
		}
		for joint_info, i in skin_info.joints {
			joint := &skin.joints[i]
			for child_index, j in joint_info.children_indices {
				joint.children[j] = skin.joint_lookup[child_index]
				skin.joint_lookup[child_index].parent = joint.children[j]
			}
		}

		for joint, i in skin.joints {
			if joint.parent == nil {
				append(&skin.joint_roots, &skin.joints[i])
			}
		}
		skin.derived_flags += {.Dirty_Joints}
	} else {
		err = .Invalid_Node
	}
	return
}

skin_node_target :: proc(skin: ^Skin_Node, model: ^Model_Node) {
	skin.target = model
	skin.flags += {.Rendered}
	skin.target.flags -= {.Rendered}
}

skin_node_joint_matrices :: proc(skin: ^Skin_Node) -> []Matrix4 {
	traverse_joint :: proc(j: ^Skin_Joint, parent_transform: Matrix4) {
		local := linalg.matrix4_from_trs_f32(
			j.local_transform.translation,
			j.local_transform.rotation,
			j.local_transform.scale,
		)
		j.root_space_transform = parent_transform * local
		for child in j.children {
			traverse_joint(child, j.root_space_transform)
		}
	}
	if .Dirty_Joints in skin.derived_flags {
		for root in skin.joint_roots {
			traverse_joint(root, linalg.MATRIX4F32_IDENTITY)
		}
		for joint, i in skin.joints {
			skin.joint_matrices[i] =
				skin.global_transform * joint.root_space_transform * joint.inverse_bind
		}
		skin.derived_flags -= {.Dirty_Joints}
	}
	return skin.joint_matrices
}

skin_node_add_animation :: proc(skin: ^Skin_Node, a: ^Animation) {
	player := Animation_Player {
		ptr                 = a,
		channels_info       = make(
			[]Animation_Channel_Info,
			len(a.channels),
			skin.scene.allocator,
		),
		targets             = make([]Animation_Target, len(a.channels), skin.scene.allocator),
		targets_start_value = make([]Animation_Value, len(a.channels), skin.scene.allocator),
	}
	for channel, i in a.channels {
		if joint, exist := skin.joint_lookup[channel.target_id]; exist {
			switch channel.kind {
			case .Translation:
				player.targets[i] = &joint.local_transform.translation
			case .Rotation:
				player.targets[i] = &joint.local_transform.rotation
			case .Scale:
				player.targets[i] = &joint.local_transform.scale
			}
			player.targets_start_value[i] = compute_animation_start_value(channel)
		}
	}
	skin.animations[a.name] = player
}

skin_node_play_animation :: proc(skin: ^Skin_Node, name: string) {
	if _, exist := skin.animations[name]; exist {
		skin.player = &skin.animations[name]
		reset_animation(skin.player)
		skin.derived_flags += {.Playing}
	} else {
		log.warnf("%s: Invalid animation name: %s", App_Module.Skin, name)
	}
}

update_skin_node :: proc(skin: ^Skin_Node, dt: f32) {
	if .Playing in skin.derived_flags {
		complete := advance_animation(skin.player, dt)
		skin.derived_flags += {.Dirty_Joints}
		if complete && !skin.player.loop {
			skin.derived_flags -= {.Playing}
		}
	}
}


// User Interface

User_Interface_Node :: struct {
	using base:     Node,
	arena:          mem.Arena,
	allocator:      mem.Allocator,
	dirty:          bool,
	m_pos:          Vector2,
	previous_m_pos: Vector2,
	m_delta:        Vector2,
	theme:          User_Interface_Theme,
	canvas:         ^Canvas_Node,
	roots:          [dynamic]^Widget,
	commands:       [dynamic]User_Interface_Command,
}

User_Interface_Theme :: struct {
	borders:         bool,
	border_color:    Color,
	contrast_values: [len(Contrast_Level)]f32,
	base_color:      Color,
	highlight_color: Color,
	text_color:      Color,
	text_size:       int,
	font:            ^Font,

	// Miscelleanous configs
	title_style:     Text_Style,
}

Contrast_Level :: enum {
	Level_Minus_2 = 0,
	Level_Minus_1 = 1,
	Level_0       = 2,
	Level_Plus_1  = 3,
	Level_Plus_2  = 4,
}

User_Interface_Command :: union {
	User_Interface_Rect_Command,
	User_Interface_Text_Command,
}

User_Interface_Rect_Command :: struct {
	rect:  Rectangle,
	color: Color,
}

User_Interface_Text_Command :: struct {
	text:     string,
	font:     ^Font,
	position: Vector2,
	size:     int,
	color:    Color,
}

init_ui_node :: proc(node: ^User_Interface_Node, allocator: mem.Allocator) {
	mem.arena_init(&node.arena, make([]byte, mem.Megabyte * 1, allocator))
	node.allocator = mem.arena_allocator(&node.arena)
	node.dirty = true
}

ui_node_theme :: proc(node: ^User_Interface_Node, theme: User_Interface_Theme) {
	node.theme = theme
}

ui_node_dirty :: proc(node: ^User_Interface_Node) {
	node.dirty = true
}

render_ui_node :: proc(node: ^User_Interface_Node) {
	update_widget_slice(node.roots[:])
	if node.dirty {
		clear(&node.commands)
		draw_widget_slice(node.roots[:])

		for command in node.commands {
			switch c in command {
			case User_Interface_Rect_Command:
				draw_rect(node.canvas, c.rect, c.color)
			case User_Interface_Text_Command:
				draw_text(node.canvas, c.font, c.text, c.position, c.size, c.color)
			}
		}
		node.dirty = false
	} else {
		node.canvas.derived_flags += {.Preserve_Last_Frame}
	}
}

Widget :: struct {
	ui:           ^User_Interface_Node,
	id:           Widget_ID,
	flags:        Widget_Flags,
	parent_flags: ^Widget_Flags,
	rect:         Rectangle,
	background:   Widget_Background,
	derived:      Any_Widget,
}

Widget_ID :: distinct uint

Widget_Flags :: distinct bit_set[Widget_Flag]

Widget_Flag :: enum {
	Active,
	Dirty_Hierarchy,
	Root_Widget,
	Initialized_On_New,
	Initialized,
	Fit_Theme,
}

Widget_Background :: struct {
	style:   enum {
		None,
		Solid,
		Texture_Slice,
	},
	borders: bool,
	color:   Color,
	texture: ^Texture,
}

Any_Widget :: union {
	^Layout_Widget,
	^List_Widget,
	^Button_Widget,
	^Label_Widget,
}

new_widget_from :: proc(node: ^User_Interface_Node, from: $T) -> ^T {
	widget := new_clone(from, node.allocator)
	widget.derived = widget
	widget.ui = node

	if .Root_Widget in widget.flags {
		append(&node.roots, widget)
	}
	if .Initialized_On_New in widget.flags {
		init_widget(widget)
	}
	return widget
}

init_widget :: proc(widget: ^Widget) {
	if .Fit_Theme in widget.flags {
		fit_theme(widget.ui.theme, widget)
	}
	switch w in widget.derived {
	case ^Layout_Widget:
		w.children.allocator = widget.ui.allocator
		init_layout(w)
	case ^List_Widget:
		w.children.allocator = widget.ui.allocator
		init_list(w)
	case ^Button_Widget:
		init_button(w)
	case ^Label_Widget:
		text_position(&w.text, w.rect)
	}
	widget.flags += {.Initialized}
}

@(private)
fit_theme :: proc(theme: User_Interface_Theme, widget: ^Widget) {
	contrast: f32
	switch w in widget.derived {
	case ^Layout_Widget:
		if .Root_Widget in widget.flags {
			contrast = theme.contrast_values[Contrast_Level.Level_Minus_1]
		} else if .Child_Handle in w.options {
			contrast = theme.contrast_values[Contrast_Level.Level_Minus_2]
		} else {
			contrast = theme.contrast_values[Contrast_Level.Level_0]
		}
		w.background.borders = theme.borders
	case ^List_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_Minus_1]
	case ^Button_Widget:
		w.color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_1]
		w.hover_color = theme.base_color * theme.contrast_values[Contrast_Level.Level_Plus_2]
		w.press_color = theme.highlight_color
		w.background.borders = theme.borders
		if w.text != nil {
			t := w.text.?
			t.font = theme.font
			t.size = theme.text_size
			t.color = theme.text_color
			w.text = t
		}
	case ^Label_Widget:
		contrast = theme.contrast_values[Contrast_Level.Level_0]
		w.text.font = theme.font
		w.text.size = theme.text_size
		w.text.color = theme.text_color
	}
	widget.background.color.rbg = theme.base_color.rgb * contrast
	widget.background.color.a = 1
}

update_widget_slice :: proc(widgets: []^Widget) {
	for widget in widgets {
		if .Active in widget.flags {
			update_widget(widget)
		}
	}
}

update_widget :: proc(widget: ^Widget) {
	switch w in widget.derived {
	case ^Layout_Widget:
		update_layout(w)
	case ^List_Widget:
		update_list(w)
	case ^Button_Widget:
		update_button(w)
	case ^Label_Widget:
	}
}

offset_widget_slice :: proc(widgets: []^Widget, offset: Vector2) {
	for widget in widgets {
		offset_widget(widget, offset)
	}
}

offset_widget :: proc(widget: ^Widget, offset: Vector2) {
	widget.rect.x += offset.x
	widget.rect.y += offset.y
	switch w in &widget.derived {
	case ^Layout_Widget:
		offset_widget_slice(w.children[:], offset)
	case ^List_Widget:
		offset_widget_slice(w.children[:], offset)
	case ^Button_Widget:
		if w.text != nil {
			t := w.text.?
			text_position(
				&t,
				Rectangle{
					w.rect.x + w.left_padding,
					w.rect.y,
					w.rect.width - w.right_padding,
					w.rect.height,
				},
			)
			w.text = t
		}
	case ^Label_Widget:
		text_position(&w.text, w.rect)
	}
}


draw_widget_slice :: proc(widgets: []^Widget) {
	for widget in widgets {
		if .Active in widget.flags {
			draw_widget(widget)
		}
	}
}

draw_widget :: proc(widget: ^Widget) {
	buf := &widget.ui.commands
	switch w in widget.derived {
	case ^Layout_Widget:
		draw_widget_background(buf, w.background, w.rect)
		for child in w.children {
			draw_widget(child)
		}

	case ^List_Widget:
		if .Folded not_in w.states {
			for child in w.children {
				draw_widget(child)
			}
		} else {
			draw_widget(w.root)
		}

	case ^Button_Widget:
		draw_widget_background(buf, w.background, w.rect)
		if w.text != nil {
			t := w.text.?
			text_cmd := User_Interface_Text_Command {
				text     = t.data,
				font     = t.font,
				position = t.origin,
				size     = t.size,
				color    = t.color,
			}
			append(buf, text_cmd)
		}
	case ^Label_Widget:
		draw_widget_background(buf, w.background, w.rect)
		t := w.text
		text_cmd := User_Interface_Text_Command {
			text     = t.data,
			font     = t.font,
			position = t.origin,
			size     = t.size,
			color    = t.color,
		}
		append(buf, text_cmd)
	}
}

widget_height :: proc(widget: ^Widget) -> (result: f32) {
	switch w in widget.derived {
	case ^Layout_Widget, ^Button_Widget, ^Label_Widget:
		result = widget.rect.height
	case ^List_Widget:
		if .Folded not_in w.states {
			for child in w.children {
				result += widget_height(child)
			}
		} else {
			result = w.root.rect.height
		}
	}
	return
}

draw_widget_background :: proc(
	buf: ^[dynamic]User_Interface_Command,
	bg: Widget_Background,
	rect: Rectangle,
) {
	switch bg.style {
	case .None:
	case .Solid:
		append(buf, User_Interface_Rect_Command{rect, bg.color})
	case .Texture_Slice:
		assert(false)
	}
}

Layout_Widget :: struct {
	using base:     Widget,
	options:        Layout_Options,
	optional_title: string,
	handle:         ^Layout_Widget,
	children:       [dynamic]^Widget,
	format:         Layout_Format,
	origin:         Direction,
	next:           Vector2,
	margin:         f32,
	padding:        f32,
	default_size:   f32,
}

Layout_Format :: enum {
	Row,
	Column,
}

Layout_Options :: distinct bit_set[Layout_Option]

Layout_Option :: enum {
	Decorated,
	Titled,
	Close_Widget,
	Moveable,
	Moving,
	Child_Handle,
}

DEFAULT_LAYOUT_FLAGS :: Widget_Flags{.Active, .Initialized_On_New}
DEFAULT_LAYOUT_CHILD_FLAGS :: Widget_Flags{.Active}
DEFAULT_LAYOUT_HANDLE_DIM :: 20
DEFAULT_LAYOUT_HANDLE_MARGIN :: 2
DEFAULT_LAYOUT_HANDLE_PADDING :: 2

layout_add_widget :: proc(layout: ^Layout_Widget, child: ^Widget, size: f32 = 0) {
	s := size if size > 0 else layout.default_size
	switch layout.format {
	case .Row:
		offset := layout.next.y if layout.origin == .Up else -(layout.next.y + s)
		child.rect = Rectangle {
			x      = layout.rect.x + layout.next.x,
			y      = layout.rect.y + offset,
			width  = layout.rect.width - (layout.margin * 2),
			height = s,
		}
		layout.next.y += s + layout.padding
	case .Column:
		offset := layout.next.x
		if layout.origin == .Right {
			offset = layout.rect.width - (layout.next.x + s)
		}
		child.rect = Rectangle {
			x      = layout.rect.x + offset,
			y      = layout.rect.y + layout.next.y,
			width  = s,
			height = layout.rect.height - (layout.margin * 2),
		}
		layout.next.x += s + layout.padding
	}
	append(&layout.children, child)
	child.parent_flags = &layout.flags
	if .Initialized not_in child.flags {
		init_widget(child)
	}
}

layout_remaining_size :: proc(layout: ^Layout_Widget) -> (rem: f32) {
	switch layout.format {
	case .Row:
		rem = layout.rect.height - layout.next.y - layout.margin
	case .Column:
		rem = layout.rect.width - layout.next.x - layout.margin
	}
	return
}

init_layout :: proc(layout: ^Layout_Widget) {
	if .Root_Widget in layout.flags && .Decorated in layout.options {
		margin := layout.margin
		padding := layout.padding
		layout.margin = 0
		layout.padding = 0

		flags := DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme}
		base := Widget {
			flags = flags,
			background = Widget_Background{style = .Solid},
		}
		layout.handle = new_widget_from(
			layout.ui,
			Layout_Widget{
				base = base,
				options = {.Child_Handle},
				format = .Column,
				origin = .Right,
				margin = DEFAULT_LAYOUT_HANDLE_MARGIN,
				padding = DEFAULT_LAYOUT_HANDLE_PADDING,
			},
		)
		layout_add_widget(layout, layout.handle, DEFAULT_LAYOUT_HANDLE_DIM)

		if .Close_Widget in layout.options {
			close_btn := new_widget_from(
				layout.ui,
				Button_Widget{base = base, text = Text{data = "X", style = .Center}},
			)
			layout_add_widget(
				layout.handle,
				close_btn,
				DEFAULT_LAYOUT_HANDLE_DIM - (DEFAULT_LAYOUT_HANDLE_MARGIN * 2),
			)
		}

		if .Titled in layout.options && layout.optional_title != "" {
			base.background.style = .None
			title := new_widget_from(
				layout.ui,
				Label_Widget{
					base = base,
					text = Text{data = layout.optional_title, style = layout.ui.theme.title_style},
				},
			)
			title.background.style = .None
			layout_add_widget(layout.handle, title, layout_remaining_size(layout.handle))
		}

		layout.margin = margin
		layout.padding = padding
		layout.next += margin
	} else {
		layout.next = Vector2{layout.margin, layout.margin}
	}
}

update_layout :: proc(layout: ^Layout_Widget) {
	if .Root_Widget in layout.flags && .Decorated in layout.options {
		if .Moveable in layout.options {
			m_left := mouse_button_state(.Left)
			if .Moving in layout.options {
				if .Just_Released in m_left {
					layout.options -= {.Moving}
				} else {
					m_delta := mouse_delta()
					if m_delta != 0 {
						offset_widget(layout, m_delta)
						layout.ui.dirty = true
					}
				}
			} else {
				if in_rect_bounds(layout.handle.rect, mouse_position()) {
					if .Just_Pressed in m_left {
						layout.options += {.Moving}
					}
				}

			}
		}
	}
	if .Dirty_Hierarchy in layout.flags {
		if .Decorated in layout.options {
			layout.next = {
				layout.rect.x + layout.margin,
				layout.rect.y + layout.handle.rect.height + layout.margin,
			}
			for child in layout.children[1:] {
				offset := layout.next - Vector2{child.rect.x, child.rect.y}
				offset_widget(child, offset)
				layout.next.y += widget_height(child) + layout.padding
			}
		} else {
			layout.next = {layout.rect.x + layout.margin, layout.rect.y + layout.margin}
			for child in layout.children {
				offset := layout.next - Vector2{child.rect.x, child.rect.y}
				offset_widget(child, offset)
				layout.next.y += widget_height(child) + layout.padding
			}
		}
		layout.flags -= {.Dirty_Hierarchy}
	}
	update_widget_slice(layout.children[:])
}

List_Widget :: struct {
	using base:     Widget,
	options:        List_Options,
	optional_name:  string,
	states:         List_States,
	root:           ^Button_Widget,
	children:       [dynamic]^Widget,
	next:           Vector2,
	margin:         f32,
	padding:        f32,
	indent:         f32,
	default_height: f32,
}

List_Options :: distinct bit_set[List_Option]

List_Option :: enum {
	Named_Header,
	Indent_Children,
	Foldable,
}

List_States :: distinct bit_set[List_State]

List_State :: enum {
	Folded,
}

list_add_widget :: proc(list: ^List_Widget, child: ^Widget, height: f32 = 0) {
	h := height if height > 0 else list.default_height
	offset := list.next.x
	width := list.rect.width - (list.margin * 2)
	if .Indent_Children in list.options {
		offset += list.indent
		width -= list.indent
	}
	child.rect = Rectangle {
		x      = list.rect.x + offset,
		y      = list.rect.y + list.next.y,
		width  = width,
		height = h,
	}
	list.next.y += h + list.padding

	append(&list.children, child)
	child.parent_flags = &list.flags
	list.flags += {.Dirty_Hierarchy}
	if .Initialized_On_New not_in child.flags {
		init_widget(child)
	}
}

init_list :: proc(list: ^List_Widget) {
	DEFAULT_LIST_ROOT_HEIGHT :: 20
	named := .Named_Header in list.options && list.optional_name != ""
	if named || .Foldable in list.options {
		margin := list.margin
		padding := list.padding
		indent := list.indent
		list.padding = 0
		list.margin = 0
		list.indent = 0

		base := Widget {
			flags = DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
			background = Widget_Background{style = .Solid},
		}
		list.root = new_widget_from(
			list.ui,
			Button_Widget{base = base, data = list, callback = collapse_list},
		)
		if .Named_Header in list.options {
			list.root.text = Text {
				data  = list.optional_name,
				style = .Center_Left,
			}
		}
		list_add_widget(list, list.root, DEFAULT_LIST_ROOT_HEIGHT)

		list.margin = margin
		list.padding = padding
		list.indent = indent
		list.next += margin
	} else {
		list.next = Vector2{list.margin, list.margin}
	}
	if .Root_Widget not_in list.flags && list.parent_flags != nil {
		f := list.parent_flags^ + {.Dirty_Hierarchy}
		list.parent_flags^ = f
	}
}

update_list :: proc(list: ^List_Widget) {
	if .Dirty_Hierarchy in list.flags {
		if .Foldable in list.options {
			list.next = {
				list.rect.x + list.margin,
				list.rect.y + list.root.rect.height + list.margin,
			}
			for child in list.children[1:] {
				next := list.next
				if .Indent_Children in list.options {
					next.x += list.indent
				}

				offset := next - Vector2{child.rect.x, child.rect.y}
				offset_widget(child, offset)
				list.next.y += widget_height(child) + list.padding
			}
			list.flags -= {.Dirty_Hierarchy}
		}
	}
	update_widget_slice(list.children[:])
}

collapse_list :: proc(data: rawptr, id: Widget_ID) {
	list := cast(^List_Widget)data
	if .Foldable in list.options {
		list.states ~= {.Folded}
		if .Root_Widget not_in list.flags && list.parent_flags != nil {
			f := list.parent_flags^ + {.Dirty_Hierarchy}
			list.parent_flags^ = f
		}
		list.ui.dirty = true
	}
}

Label_Widget :: struct {
	using base: Widget,
	text:       Text,
}

Button_Widget :: struct {
	using base:     Widget,
	state:          Button_Widget_State,
	previous_state: Button_Widget_State,
	color:          Color,
	hover_color:    Color,
	press_color:    Color,
	text:           Maybe(Text),
	left_padding:   f32,
	right_padding:  f32,

	//
	data:           rawptr,
	callback:       proc(data: rawptr, id: Widget_ID),
	notify_parent:  ^bool,
}

Button_Widget_State :: enum {
	Idle,
	Hovered,
	Pressed,
}

init_button :: proc(btn: ^Button_Widget) {
	btn.background.color = btn.color
	if btn.text != nil {
		t := btn.text.?
		text_position(
			&t,
			Rectangle{
				btn.rect.x + btn.left_padding,
				btn.rect.y,
				btn.rect.width - btn.right_padding,
				btn.rect.height,
			},
		)
		btn.text = t
	}
}

update_button :: proc(btn: ^Button_Widget) {
	btn.previous_state = btn.state
	m_left := mouse_button_state(.Left)
	if in_rect_bounds(btn.rect, mouse_position()) {
		if .Pressed in m_left {
			btn.state = .Pressed
		} else {
			if .Just_Released in m_left {
				if btn.state == .Pressed {
					btn.state = .Idle
					if btn.callback != nil {
						btn.callback(btn.data, btn.id)
					}
					if btn.notify_parent != nil {
						btn.notify_parent^ = true
					}
				}
			} else {
				btn.state = .Hovered
			}
		}
	} else {
		btn.state = .Idle
	}
	if btn.state != btn.previous_state {
		ui_node_dirty(btn.ui)
		switch btn.state {
		case .Idle:
			btn.background.color = btn.color
		case .Hovered:
			btn.background.color = btn.hover_color
		case .Pressed:
			btn.background.color = btn.press_color
		}
	}
}
