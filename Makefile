CXX      = g++
CXXFLAGS = -O2 -std=c++17 -Wall -Wextra -Wno-unused-result -pthread
SRCDIR   = .
BINDIR   = bin
TESTDIR  = test

SRC      = scheduler.cpp
TARGET   = $(BINDIR)/scheduler
TESTS    = $(TESTDIR)/test_boundary.sh $(TESTDIR)/test_stress.sh

.PHONY: all clean test help

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(BINDIR)
	$(CXX) $(CXXFLAGS) $(SRCDIR)/$(SRC) -o $(TARGET)
	@echo "Build succeeded: $(TARGET)"

clean:
	rm -rf $(BINDIR)
	@echo "Cleaned build artifacts."

test: $(TARGET)
	@echo "========================================="
	@echo "Running boundary tests (N=3, N=10)..."
	@echo "========================================="
	@bash $(TESTDIR)/test_boundary.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running stress test (all workers fail)..."
	@echo "========================================="
	@bash $(TESTDIR)/test_stress.sh $(TARGET)
	@echo ""
	@echo "All tests passed."

help:
	@echo "Usage:"
	@echo "  make          - Build the scheduler binary"
	@echo "  make test     - Run all tests"
	@echo "  make clean    - Remove build artifacts"
	@echo "  make help     - Show this help message"
