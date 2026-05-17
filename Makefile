CXX      = g++
CXXFLAGS = -O2 -std=c++17 -Wall -Wextra -Wno-unused-result -pthread
SRCDIR   = .
BINDIR   = bin
TESTDIR  = test

SRC      = scheduler.cpp
TARGET   = $(BINDIR)/scheduler
TESTS    = $(TESTDIR)/test_boundary.sh \
           $(TESTDIR)/test_stress.sh \
           $(TESTDIR)/test_dynamic.sh \
           $(TESTDIR)/test_signal.sh \
           $(TESTDIR)/test_timeout_retry.sh \
           $(TESTDIR)/test_perf.sh \
           $(TESTDIR)/test_concurrent.sh \
           $(TESTDIR)/test_graceful.sh \
           $(TESTDIR)/test_jsonl.sh

.PHONY: all clean test test-all test-quick help

all: $(TARGET)

$(TARGET): $(SRC)
	@mkdir -p $(BINDIR)
	$(CXX) $(CXXFLAGS) $(SRCDIR)/$(SRC) -o $(TARGET)
	@echo "Build succeeded: $(TARGET)"

clean:
	rm -rf $(BINDIR)
	rm -f scheduler_*.jsonl
	@echo "Cleaned build artifacts and JSONL logs."

test: $(TARGET)
	@echo "========================================="
	@echo "Running boundary tests (N=3, N=10, N=2/11)..."
	@echo "========================================="
	@bash $(TESTDIR)/test_boundary.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running stress test (all workers fail)..."
	@echo "========================================="
	@bash $(TESTDIR)/test_stress.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running dynamic add/remove worker tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_dynamic.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running signal handling tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_signal.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running timeout and retry tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_timeout_retry.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running performance metric tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_perf.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running concurrent stress tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_concurrent.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running graceful shutdown tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_graceful.sh $(TARGET)
	@echo ""
	@echo "========================================="
	@echo "Running JSONL structured log tests..."
	@echo "========================================="
	@bash $(TESTDIR)/test_jsonl.sh $(TARGET)
	@echo ""
	@echo "All tests passed."

test-quick: $(TARGET)
	@echo "========================================="
	@echo "Running quick tests (boundary + graceful)..."
	@echo "========================================="
	@bash $(TESTDIR)/test_boundary.sh $(TARGET)
	@bash $(TESTDIR)/test_graceful.sh $(TARGET)
	@echo ""
	@echo "Quick tests passed."

help:
	@echo "Usage:"
	@echo "  make           - Build the scheduler binary"
	@echo "  make test      - Run all tests (boundary, stress, dynamic,"
	@echo "                   signal, timeout/retry, performance,"
	@echo "                   concurrent, graceful, jsonl)"
	@echo "  make test-quick - Run quick smoke tests only"
	@echo "  make clean     - Remove build artifacts and JSONL logs"
	@echo "  make help      - Show this help message"
