CXX = clang++
CXXFLAGS = -Wall -O2

LODEPNG_SRC = lodepng/lodepng.cpp
GENERATOR = generate_test_data
GENERATOR_SRC = generate_test_data.c

.PHONY: generate clean

generate: $(GENERATOR)
	./$(GENERATOR)

$(GENERATOR): $(GENERATOR_SRC) $(LODEPNG_SRC)
	$(CXX) $(CXXFLAGS) -o $(GENERATOR) $(GENERATOR_SRC) $(LODEPNG_SRC)

clean:
	rm -f $(GENERATOR)
	rm -rf ../test-data/*.png

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  make generate - Generate test PNG files"
	@echo "  make clean    - Remove generated files"
