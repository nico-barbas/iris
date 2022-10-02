package main

import "core:mem"
import "core:fmt"
// import "core:os"
// import "core:math/linalg"
import iris "../"
// import gltf "../gltf"

UNIT_PER_METER :: 2

// TOML_TEST :: `
// `

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	// frustum := iris.frustum(iris.VECTOR_ZERO, {0, 0, -1}, 1, 100, 90)
	// for plane in iris.Frustum_Planes {
	// 	fmt.printf("%s: %v\n", plane, frustum[plane])
	// }

	// bb := iris.Bounding_Box {
	// 	points = {
	// 		{-0.5, 0.5, 50},
	// 		{-0.5, -0.5, 50},
	// 		{0.5, -0.5, 50},
	// 		{0.5, 0.5, 50},
	// 		{-0.5, 0.5, 51},
	// 		{-0.5, -0.5, 51},
	// 		{0.5, -0.5, 51},
	// 		{0.5, 0.5, 51},
	// 	},
	// }

	// fmt.println(iris.bounding_box_in_frustum(frustum, bb))

	iris.init_app(
		&iris.App_Config{
			width = 1600,
			height = 900,
			title = "Small World",
			decorated = true,
			asset_dir = "assets/",
			data = iris.App_Data(&Game{}),
			init = init,
			update = update,
			draw = draw,
			close = close,
		},
	)
	iris.run_app()
	iris.close_app()

	if len(track.allocation_map) > 0 {
		fmt.printf("Leaks:")
		for _, v in track.allocation_map {
			fmt.printf("\t%v\n\n", v)
		}
	}
	fmt.printf("Leak count: %d\n", len(track.allocation_map))
	if len(track.bad_free_array) > 0 {
		fmt.printf("Bad Frees:")
		for v in track.bad_free_array {
			fmt.printf("\t%v\n\n", v)
		}
	}
}

Game :: struct {
	scene:           ^iris.Scene,
	light:           iris.Light_ID,
	mesh:            ^iris.Mesh,
	lantern:         ^iris.Node,
	rig:             ^iris.Node,
	skin:            ^iris.Node,
	canvas:          ^iris.Canvas_Node,
	terrain:         Terrain,
	delta:           f32,
	flat_material:   ^iris.Material,
	skybox_material: ^iris.Material,
	font:            ^iris.Font,
	ui_theme:        iris.User_Interface_Theme,

	// temps
	instanced_cubes: ^iris.Model_Group_Node,
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.set_key_proc(.Escape, on_escape_key)

	font_res := iris.font_resource(iris.Font_Loader{path = "Roboto-Regular.ttf", sizes = {20}})
	g.font = font_res.data.(^iris.Font)

	scene_res := iris.scene_resource("main", {.Draw_Debug_Collisions})
	g.scene = scene_res.data.(^iris.Scene)

	// lantern_document, err := gltf.parse_from_file(
	// 	"lantern/Lantern.gltf",
	// 	.Gltf_External,
	// 	context.temp_allocator,
	// 	context.temp_allocator,
	// )
	// fmt.assertf(err == nil, "%s\n", err)
	// iris.load_resources_from_gltf(&lantern_document)
	// root := lantern_document.root.nodes[0]

	// lt := iris.transform(t = {0, 0, -10}, s = {0.1, 0.1, 0.1})
	// lantern_transform := linalg.matrix_mul(
	// 	linalg.matrix4_from_trs_f32(lt.translation, lt.rotation, lt.scale),
	// 	root.local_transform,
	// )
	// g.lantern = iris.new_node(g.scene, iris.Empty_Node, lantern_transform)
	// iris.insert_node(g.scene, g.lantern)
	// for node in root.children {
	// 	lantern_node := iris.new_node(g.scene, iris.Model_Node)
	// 	iris.model_node_from_gltf(
	// 		lantern_node,
	// 		iris.Model_Loader{
	// 			flags = {.Load_Position, .Load_Normal, .Load_Tangent, .Load_TexCoord0},
	// 			rigged = false,
	// 		},
	// 		node,
	// 	)
	// 	iris.insert_node(g.scene, lantern_node, g.lantern)
	// }

	mesh_res := iris.cube_mesh(1, 1, 1)
	g.mesh = mesh_res.data.(^iris.Mesh)


	// flat_shader, f_exist := iris.shader_from_name("unlit")
	// assert(f_exist)
	flat_material_res := iris.material_resource(iris.Material_Loader{name = "flat"})
	g.flat_material = flat_material_res.data.(^iris.Material)

	test_cube := iris.model_node_from_mesh(g.scene, g.mesh, g.flat_material, iris.transform())
	iris.insert_node(g.scene, test_cube)
	test_cube.local_bounds = iris.bounding_box_from_min_max(
		iris.Vector3{-0.5, -0.5, -0.5},
		iris.Vector3{0.5, 0.5, 0.5},
	)
	iris.node_local_transform(test_cube, iris.transform(t = {0, 0, -10}))

	// skybox_shader, s_exist := iris.shader_from_name("skybox")
	// assert(s_exist)
	// skybox_material_res := iris.material_resource(
	// 	iris.Material_Loader{name = "skybox", shader = skybox_shader, double_face = true},
	// )
	// g.skybox_material = skybox_material_res.data.(^iris.Material)
	// iris.set_material_map(
	// 	g.skybox_material,
	// 	.Diffuse,
	// 	iris.texture_resource(
	// 		iris.Texture_Loader{
	// 			filter = .Linear,
	// 			wrap = .Repeat,
	// 			info = iris.File_Cubemap_Info{
	// 				paths = [6]string{
	// 					"skybox/front.png",
	// 					"skybox/back.png",
	// 					"skybox/top.png",
	// 					"skybox/bottom.png",
	// 					"skybox/left.png",
	// 					"skybox/right.png",
	// 				},
	// 			},
	// 		},
	// 	).data.(^iris.Texture),
	// )


	camera := iris.new_node_from(g.scene, iris.Camera_Node {
		derived_flags = {.Main_Camera, .Frustum_Cull},
		pitch = 45,
		target = {0, 0.5, 0},
		target_distance = 10,
		target_rotation = 90,
		min_pitch = 10,
		max_pitch = 170,
		min_distance = 2,
		distance_speed = 1,
		position_speed = 12,
		rotation_proc = proc() -> (trigger: bool, delta: iris.Vector2) {
			m_right := iris.mouse_button_state(.Right)
			if .Pressed in m_right {
				trigger = true
				delta = iris.mouse_delta()
			} else {
				KEY_CAMERA_PAN_SPEED :: 2
				left_state := iris.key_state(.Q)
				right_state := iris.key_state(.E)
				if .Pressed in left_state {
					trigger = true
					delta = {KEY_CAMERA_PAN_SPEED, 0}
				} else if .Pressed in right_state {
					trigger = true
					delta = {-KEY_CAMERA_PAN_SPEED, 0}
				}
			}
			return
		},
		distance_proc = proc() -> (trigger: bool, displacement: f32) {
			displacement = f32(iris.mouse_scroll())
			trigger = displacement != 0
			return
		},
		position_proc = proc() -> (trigger: bool, fb: f32, lr: f32) {
			if .Pressed in iris.key_state(.W) {
				trigger = true
				fb = 1
			} else if .Pressed in iris.key_state(.S) {
				trigger = true
				fb = -1
			}

			if .Pressed in iris.key_state(.A) {
				trigger = true
				lr = -1
			} else if .Pressed in iris.key_state(.D) {
				trigger = true
				lr = 1
			}
			return
		},
	})
	iris.insert_node(g.scene, camera)


	iris.add_light(.Directional, iris.Vector3{2, 3, 2}, {100, 100, 90, 1}, true)
	// iris.add_light(.Directional, iris.Vector3{2, 3, -2}, {100, 100, 90, 1}, true)

	// {
	// 	rig_document, _err := gltf.parse_from_file(
	// 		"human_rig/CesiumMan.gltf",
	// 		.Gltf_External,
	// 		context.temp_allocator,
	// 		context.temp_allocator,
	// 	)
	// 	assert(_err == nil)
	// 	iris.load_resources_from_gltf(&rig_document)

	// 	node, _ := gltf.find_node_with_name(&rig_document, "Cesium_Man")
	// 	g.rig = iris.new_node(g.scene, iris.Empty_Node, node.global_transform)
	// 	iris.insert_node(g.scene, g.rig)

	// 	mesh_node := iris.new_node(g.scene, iris.Model_Node)
	// 	iris.model_node_from_gltf(
	// 		mesh_node,
	// 		iris.Model_Loader{
	// 			flags = {
	// 				.Load_Position,
	// 				.Load_Normal,
	// 				.Load_TexCoord0,
	// 				.Load_Joints0,
	// 				.Load_Weights0,
	// 				.Load_Bones,
	// 			},
	// 			rigged = true,
	// 		},
	// 		node,
	// 	)
	// 	iris.insert_node(g.scene, mesh_node, g.rig)

	// 	skin_node := iris.new_node(g.scene, iris.Skin_Node)
	// 	iris.skin_node_from_gltf(skin_node, node)
	// 	iris.skin_node_target(skin_node, mesh_node)
	// 	iris.insert_node(g.scene, skin_node, g.rig)

	// 	animation, _ := iris.animation_from_name("animation0")
	// 	iris.skin_node_add_animation(skin_node, animation)
	// 	iris.skin_node_play_animation(skin_node, "animation0")
	// }

	// {
	// 	g.terrain = Terrain {
	// 		scene       = g.scene,
	// 		width       = 200,
	// 		height      = 200,
	// 		octaves     = 3,
	// 		persistance = 0.5,
	// 		lacunarity  = 2,
	// 		factor      = 6,
	// 	}
	// 	init_terrain(&g.terrain)
	// }

	// {
	// 	g.instanced_cubes = iris.new_node(g.scene, iris.Model_Group_Node)
	// 	g.instanced_cubes.mesh_transform = linalg.matrix4_from_trs_f32(
	// 		iris.Vector3{},
	// 		iris.Quaternion(1),
	// 		iris.Vector3{1, 1, 1},
	// 	)
	// 	iris.insert_node(g.scene, g.instanced_cubes)

	// 	iris.init_group_node(
	// 		group = g.instanced_cubes,
	// 		meshes = {g.mesh},
	// 		materials = {g.flat_material},
	// 		count = 9,
	// 	)
	// 	for y in 0 ..< 3 {
	// 		for x in 0 ..< 3 {
	// 			iris.group_node_instance_transform(
	// 				g.instanced_cubes,
	// 				y * 3 + x,
	// 				iris.transform(t = iris.Vector3{f32(x * 2), 2, f32(y * 2)}),
	// 			)
	// 		}
	// 	}
	// }

	{
		g.ui_theme = iris.User_Interface_Theme {
			borders = true,
			border_color = {1, 1, 1, 1},
			contrast_values = {0 = 0.35, 1 = 0.75, 2 = 1, 3 = 1.25, 4 = 1.5},
			base_color = {0.35, 0.35, 0.35, 1},
			highlight_color = {0.7, 0.7, 0.8, 1},
			text_color = 1,
			text_size = 20,
			font = g.font,
			title_style = .Center_Left,
		}
		g.canvas = iris.new_node_from(g.scene, iris.Canvas_Node{width = 1600, height = 900})
		iris.insert_node(g.scene, g.canvas)
		ui_node := iris.new_node_from(g.scene, iris.User_Interface_Node{canvas = g.canvas})
		iris.insert_node(g.scene, ui_node, g.canvas)
		iris.ui_node_theme(ui_node, g.ui_theme)
		layout := iris.new_widget_from(
			ui_node,
			iris.Layout_Widget{
				base = iris.Widget{
					flags = {.Active, .Initialized_On_New, .Root_Widget, .Fit_Theme},
					rect = {100, 100, 350, 500},
					background = iris.Widget_Background{style = .Solid},
				},
				options = {.Decorated, .Titled, .Moveable, .Close_Widget},
				optional_title = "Window",
				format = .Row,
				origin = .Up,
				margin = 3,
				padding = 2,
			},
		)

		tabs := iris.new_widget_from(
			ui_node,
			iris.Tab_Viewer_Widget{
				layout = iris.Layout_Widget{
					base = iris.Widget{
						flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
						background = iris.Widget_Background{style = .Solid},
					},
					format = .Row,
					origin = .Up,
				},
			},
		)

		iris.layout_add_widget(layout, tabs, iris.layout_remaining_size(layout))

		scene_layout := iris.tab_viewer_add_tab(
			tabs,
			iris.Tab_Config{
				name = "world",
				id = 24,
				format = .Row,
				origin = .Up,
				set_as_active = true,
			},
		)
		g_buffer_layout := iris.tab_viewer_add_tab(
			tabs,
			iris.Tab_Config{
				name = "g-buffer",
				id = 25,
				format = .Row,
				origin = .Up,
				set_as_active = false,
			},
		)

		iris.scene_graph_to_list(scene_layout, g.scene, 20)

		position_buffer_view := iris.new_widget_from(
			ui_node,
			iris.Image_Widget{
				base = iris.Widget{
					flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
					background = iris.Widget_Background{style = .Solid},
				},
				constraint = .Fit_Height,
				display_option = .Stream,
				content = iris.g_buffer_texture(.Color0),
				tint = 1,
				flip_y = true,
			},
		)
		iris.layout_add_widget(g_buffer_layout, position_buffer_view, 150)

		normal_buffer_view := iris.new_widget_from(
			ui_node,
			iris.Image_Widget{
				base = iris.Widget{
					flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
					background = iris.Widget_Background{style = .Solid},
				},
				constraint = .Fit_Height,
				display_option = .Stream,
				content = iris.g_buffer_texture(.Color1),
				tint = 1,
				flip_y = true,
			},
		)
		iris.layout_add_widget(g_buffer_layout, normal_buffer_view, 150)

		albedo_buffer_view := iris.new_widget_from(
			ui_node,
			iris.Image_Widget{
				base = iris.Widget{
					flags = iris.DEFAULT_LAYOUT_CHILD_FLAGS + {.Fit_Theme},
					background = iris.Widget_Background{style = .Solid},
				},
				constraint = .Fit_Height,
				display_option = .Stream,
				content = iris.g_buffer_texture(.Color2),
				tint = 1,
				flip_y = true,
			},
		)
		iris.layout_add_widget(g_buffer_layout, albedo_buffer_view, 150)

		// init_terrain_ui(&g.terrain, ui_node)
	}
}

update :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	dt := f32(iris.elapsed_time())

	g.delta += dt
	if g.delta >= 5 {
		g.delta = 0
	}
	iris.light_position(g.light, iris.Vector3{2, 3, 2})

	// update_terrain(&g.terrain)
	iris.update_scene(g.scene, dt)
}

draw :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.start_render()
	{
		iris.render_scene(g.scene)
		// fmt.println(g.lantern.visibility)

		iris.draw_mesh(
			g.mesh,
			iris.transform(t = iris.Vector3{2, 3, 2}, s = {0.2, 0.2, 0.2}),
			g.flat_material,
		)
		// iris.draw_mesh(g.mesh, iris.transform(s = {95, 95, 95}), g.skybox_material)
	}
	iris.end_render()
}

close :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.destroy_mesh(g.mesh)
}

on_escape_key :: proc(data: iris.App_Data, state: iris.Input_State) {
	iris.close_app_on_next_frame()
}
