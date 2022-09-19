playground: ./assets/shaders/aether
	./assets/shaders/aether
	odin run . -out:playground -vet -strict-style -debug

./assets/shaders/aether:
	odin build assets/shaders/process.odin -file -out:assets/shaders/aether -vet -strict-style -debug -o:minimal