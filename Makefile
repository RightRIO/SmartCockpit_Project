# VoYah Scheduler — Build System
# Supports: Linux (epoll, timerfd, socketpair)
# Requires: GCC 7+ or Clang 7+, CMake 3.10+ or GNU Make

# ---------- Version ----------
VERSION       ?= 1.0.0
CXX           ?= g++

# ---------- Compiler ----------
CXXFLAGS      := -O2 -std=c++17 -Wall -Wextra -Wno-unused-result -pthread -I$(INCDIR)

# ---------- Paths ----------
SRCDIR        := src
INCDIR        := include
BINDIR        := bin
TESTDIR       := test
EXAMPLESDIR   := examples
PREFIX        ?= /usr/local
INSTALL_BIN   := $(DESTDIR)$(PREFIX)/bin
INSTALL_DOC   := $(DESTDIR)$(PREFIX)/share/doc/voyah-scheduler

# ---------- Targets ----------
SRC           := $(SRCDIR)/scheduler.cpp
HDR           := $(INCDIR)/voyah/version.h
TARGET        := $(BINDIR)/scheduler

TESTS         := $(TESTDIR)/test_boundary.sh \
                $(TESTDIR)/test_stress.sh \
                $(TESTDIR)/test_dynamic.sh \
                $(TESTDIR)/test_signal.sh \
                $(TESTDIR)/test_timeout_retry.sh \
                $(TESTDIR)/test_perf.sh \
                $(TESTDIR)/test_concurrent.sh \
                $(TESTDIR)/test_graceful.sh \
                $(TESTDIR)/test_jsonl.sh

.PHONY: all clean test test-all test-quick help install uninstall distclean

all: $(TARGET)
	@echo "Build succeeded: $(TARGET)  (VoYah Scheduler v$(VERSION))"

$(TARGET): $(SRC) $(HDR)
	@mkdir -p $(BINDIR)
	$(CXX) $(CXXFLAGS) $(SRC) -o $(TARGET)
	@echo "$(TARGET) built."

# ---------- Installation ----------
install: $(TARGET)
	@echo "Installing VoYah Scheduler v$(VERSION) to $(INSTALL_BIN)..."
	@mkdir -p $(INSTALL_BIN)
	@mkdir -p $(INSTALL_DOC)
	install -m 0755 $(TARGET) $(INSTALL_BIN)/voyah-scheduler
	install -m 0644 LICENSE               $(INSTALL_DOC)/
	install -m 0644 docs/README.md        $(INSTALL_DOC)/README_zh.md
	install -m 0644 docs/README_en.md     $(INSTALL_DOC)/README_en.md
	install -m 0644 docs/README_ja.md     $(INSTALL_DOC)/README_ja.md
	install -m 0644 docs/README_ru.md     $(INSTALL_DOC)/README_ru.md
	install -m 0644 docs/README_ar.md     $(INSTALL_DOC)/README_ar.md
	install -m 0644 docs/DESIGN.md       $(INSTALL_DOC)/
	@echo "Installed. Run: voyah-scheduler --help"

uninstall:
	@echo "Uninstalling VoYah Scheduler..."
	@rm -f $(INSTALL_BIN)/voyah-scheduler
	@rm -rf $(INSTALL_DOC)
	@echo "Uninstalled."

# ---------- Testing ----------
test: $(TARGET)
	@echo "========================================="
	@echo " VoYah Scheduler v$(VERSION) — Full Test Suite"
	@echo "========================================="
	@bash $(TESTDIR)/test_boundary.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_stress.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_dynamic.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_signal.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_timeout_retry.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_perf.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_concurrent.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_graceful.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_jsonl.sh $(TARGET)
	@echo ""
	@echo "All tests passed."

test-quick: $(TARGET)
	@echo "========================================="
	@echo " VoYah Scheduler — Quick Smoke Tests"
	@echo "========================================="
	@bash $(TESTDIR)/test_boundary.sh $(TARGET)
	@echo ""
	@bash $(TESTDIR)/test_graceful.sh $(TARGET)
	@echo ""
	@echo "Quick tests passed."

# ---------- Cleanup ----------
clean:
	rm -rf $(BINDIR)
	rm -f scheduler_*.jsonl
	@echo "Cleaned build artifacts and JSONL logs."

distclean: clean
	rm -f *.o a.out core
	rm -rf build/
	@echo "Deep clean complete."

# ---------- Help ----------
help:
	@echo "VoYah Scheduler v$(VERSION) — Build System"
	@echo ""
	@echo "  make               Build scheduler binary"
	@echo "  make test          Run full test suite (9 suites)"
	@echo "  make test-quick    Run smoke tests only"
	@echo "  make install       Install to $(PREFIX)"
	@echo "  make uninstall    Uninstall"
	@echo "  make clean         Remove build artifacts"
	@echo "  make distclean     Deep clean (clean + build/ directory)"
	@echo "  make help          Show this message"
	@echo ""
	@echo "  cmake -B build     Configure with CMake (optional)"
	@echo "  cmake --build build  Build with CMake"
	@echo ""
	@echo "Variables:"
	@echo "  CXX=$(CXX)"
	@echo "  PREFIX=$(PREFIX)"
	@echo "  VERSION=$(VERSION)"
