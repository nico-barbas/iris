package main

import "lib:zoe"

main :: proc() {
	zoe.init_app({width = 800, height = 600, title = "Small World", decorated = true})
	zoe.run_app()
	zoe.close_app()
}
