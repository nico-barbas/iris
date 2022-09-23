package main

import "core:mem"
import "core:fmt"
// import "core:os"
import "core:math/linalg"
import iris "../"
import gltf "../gltf"

UNIT_PER_METER :: 2

// TOML_TEST :: `
// `

main :: proc() {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	context.allocator = mem.tracking_allocator(&track)

	// toml_document, toml_err := toml.parse_string(TOML_TEST)
	// if toml_err != nil {
	// 	fmt.println(toml_err)
	// 	assert(false)
	// }
	// fmt.println(toml_document)
	// toml.destroy(toml_document)

	// helios_source, _ := os.read_entire_file("playground/assets/shaders/lib.helios")
	// helios_document, err := helios.parse(helios_source)

	// if err != nil {
	// 	fmt.println(err)
	// 	assert(false)
	// }

	// shader, build_err := helios.build_shader(
	// 	&helios_document,
	// 	helios.Builder{
	// 		build_name = "deferred_geometry_terrain",
	// 		prototype_name = "deferred_geometry",
	// 		stages = helios.DEFAULT_REQUIRED_STAGE,
	// 		stages_info = {
	// 			helios.Stage.Vertex = {with_extension = false},
	// 			helios.Stage.Fragment = {with_extension = true, name = "terrain"},
	// 		},
	// 	},
	// )

	// if build_err != nil {
	// 	fmt.println(build_err)
	// 	assert(false)
	// }
	// fmt.println(shader.stages[helios.Stage.Vertex])
	// fmt.println(shader.stages[helios.Stage.Fragment])

	// helios.destroy(helios_document)
	// helios.destroy_shader(&shader)

	// if len(track.allocation_map) > 0 {
	// 	fmt.printf("Leaks:")
	// 	for _, v in track.allocation_map {
	// 		fmt.printf("\t%v\n\n", v)
	// 	}
	// }
	// fmt.printf("Leak count: %d\n", len(track.allocation_map))
	// if len(track.bad_free_array) > 0 {
	// 	fmt.printf("Bad Frees:")
	// 	for v in track.bad_free_array {
	// 		fmt.printf("\t%v\n\n", v)
	// 	}
	// }


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
}

init :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.set_key_proc(.Escape, on_escape_key)

	font_res := iris.font_resource(iris.Font_Loader{path = "Roboto-Regular.ttf", sizes = {20}})
	g.font = font_res.data.(^iris.Font)

	scene_res := iris.scene_resource("main")
	g.scene = scene_res.data.(^iris.Scene)

	lantern_document, err := gltf.parse_from_file(
		"lantern/Lantern.gltf",
		.Gltf_External,
		context.temp_allocator,
		context.temp_allocator,
	)
	fmt.assertf(err == nil, "%s\n", err)
	iris.load_resources_from_gltf(&lantern_document)
	root := lantern_document.root.nodes[0]

	lt := iris.transform(t = {1, 0, 1}, s = {0.1, 0.1, 0.1})
	lantern_transform := linalg.matrix_mul(
		linalg.matrix4_from_trs_f32(lt.translation, lt.rotation, lt.scale),
		root.local_transform,
	)
	g.lantern = iris.new_node(g.scene, iris.Empty_Node, lantern_transform)
	iris.insert_node(g.scene, g.lantern)
	for node in root.children {
		lantern_node := iris.new_node(g.scene, iris.Model_Node)
		iris.model_node_from_gltf(
			lantern_node,
			iris.Model_Loader{
				flags = {
					.Use_Local_Transform,
					.Load_Position,
					.Load_Normal,
					.Load_Tangent,
					.Load_TexCoord0,
				},
				rigged = false,
			},
			node,
		)
		iris.insert_node(g.scene, lantern_node, g.lantern)
	}

	mesh_res := iris.cube_mesh(1, 1, 1)
	g.mesh = mesh_res.data.(^iris.Mesh)

	// flat_shader, f_exist := iris.shader_from_name("unlit")
	// assert(f_exist)
	flat_material_res := iris.material_resource(iris.Material_Loader{name = "flat"})
	g.flat_material = flat_material_res.data.(^iris.Material)

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

	iris.add_light(.Directional, iris.Vector3{2, 3, 2}, {1, 1, 1, 1})

	{
		rig_document, _err := gltf.parse_from_file(
			"human_rig/CesiumMan.gltf",
			.Gltf_External,
			context.temp_allocator,
			context.temp_allocator,
		)
		assert(_err == nil)
		iris.load_resources_from_gltf(&rig_document)

		node, _ := gltf.find_node_with_name(&rig_document, "Cesium_Man")
		g.rig = iris.new_node(g.scene, iris.Empty_Node, node.global_transform)
		iris.insert_node(g.scene, g.rig)

		mesh_node := iris.new_node(g.scene, iris.Model_Node)
		iris.model_node_from_gltf(
			mesh_node,
			iris.Model_Loader{
				flags = {
					.Use_Identity,
					.Load_Position,
					.Load_Normal,
					.Load_TexCoord0,
					.Load_Joints0,
					.Load_Weights0,
					.Load_Bones,
				},
				rigged = true,
			},
			node,
		)
		iris.insert_node(g.scene, mesh_node, g.rig)

		skin_node := iris.new_node(g.scene, iris.Skin_Node)
		iris.skin_node_from_gltf(skin_node, node)
		iris.skin_node_target(skin_node, mesh_node)
		iris.insert_node(g.scene, skin_node, g.rig)

		animation, _ := iris.animation_from_name("animation0")
		iris.skin_node_add_animation(skin_node, animation)
		iris.skin_node_play_animation(skin_node, "animation0")
	}

	{
		g.terrain = Terrain {
			scene       = g.scene,
			width       = 200,
			height      = 200,
			octaves     = 5,
			persistance = 0.5,
			lacunarity  = 2,
			factor      = 6,
		}
		init_terrain(&g.terrain)
	}

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
					rect = {100, 100, 200, 400},
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

		iris.scene_graph_to_list(layout, g.scene, 20)

		init_terrain_ui(&g.terrain, ui_node)
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

	iris.update_scene(g.scene, dt)
}

draw :: proc(data: iris.App_Data) {
	g := cast(^Game)data
	iris.start_render()
	{
		iris.render_scene(g.scene)

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
