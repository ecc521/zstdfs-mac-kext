# Kext build — works with either a KDK or the stock CLI Tools SDK (macOS 26+).
#
# Usage:
#   make vendor-zstd       # run once to populate kext/zstd/
#   make                   # build DecmpfsZstd.kext
#   make deploy VM=user@ip # scp + load on a no-SIP VM
#
# With a KDK installed at /Library/Developer/KDKs/, the KDK is used (preferred).
# Without one, the MacOSX*.sdk Kernel.framework from CLI Tools is used instead.

KEXT     := DecmpfsZstd
ARCH     := arm64e
BUILD    := build/$(ARCH)
BUNDLE   := $(KEXT).kext

CC       := clang
CXX      := clang++

# ---- SDK detection ----
# Only treat a KDK as usable if it actually ships full kernel headers. Recent
# KDKs are header-sparse (binary + dSYM only) and rely on the CLI Tools SDK for
# headers, so we fall back to the SDK in that case.
KDK_DIR  := $(shell for d in $$(ls -d /Library/Developer/KDKs/KDK_*.kdk 2>/dev/null | sort -V); do [ -f "$$d/System/Library/Frameworks/Kernel.framework/Headers/IOKit/IOService.h" ] && echo "$$d"; done | tail -1)

ifneq ($(KDK_DIR),)
  # Preferred path: use KDK for full private-header coverage
  KERNEL_FRAMEWORK := $(KDK_DIR)/System/Library/Frameworks/Kernel.framework
  KERN_INC     := $(KERNEL_FRAMEWORK)/Headers
  PRIV_INC     := $(KERNEL_FRAMEWORK)/PrivateHeaders
  LINK_LIB_DIR := $(KERNEL_FRAMEWORK)/Libraries
  LINK_LIBS    := -lkmod -lcc_kext
else
  # Fallback: CLI Tools SDK (macOS 26+ has everything we need in public headers)
  CLT_SDK := $(shell ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk 2>/dev/null | sort -V | tail -1)
  ifeq ($(CLT_SDK),)
    CLT_SDK := $(shell ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX*.sdk 2>/dev/null | sort -V | tail -1)
  endif
  ifeq ($(CLT_SDK),)
    $(error No KDK or SDK found. Install Xcode Command Line Tools.)
  endif
  KERNEL_FRAMEWORK := $(CLT_SDK)/System/Library/Frameworks/Kernel.framework
  KERN_INC     := $(KERNEL_FRAMEWORK)/Headers
  PRIV_INC     := $(KERN_INC)
  LINK_LIB_DIR := $(CLT_SDK)/usr/lib
  LINK_LIBS    := -lkmod -lkmodc++
  $(info Building without KDK: using $(CLT_SDK))
endif

CFLAGS := \
  -arch $(ARCH) \
  -I$(KERN_INC) \
  -I$(PRIV_INC) \
  -I$(KERN_INC)/IOKit \
  -Isrc \
  -Izstd \
  -fno-builtin \
  -fno-common \
  -fno-stack-protector \
  -fno-exceptions \
  -mkernel \
  -DKERNEL -DKERNEL_PRIVATE -DDRIVER_PRIVATE -DAPPLE -DNeXT \
  -DZSTD_DISABLE_ASM \
  -DZSTD_NO_INTRINSICS \
  -DZSTD_STATIC_LINKING_ONLY \
  -DXXH_NO_STDLIB \
  -Wno-macro-redefined \
  -Os -g

CXXFLAGS := $(CFLAGS) \
  -I$(KERN_INC)/libkern \
  -I$(KERN_INC)/libkern/c++ \
  -fno-rtti

LDFLAGS := \
  -arch $(ARCH) \
  -Xlinker -kext \
  -nostdlib \
  -L$(LINK_LIB_DIR) \
  $(LINK_LIBS)

# ---- Sources ----
SRCS_C   := src/type200.c src/type201.c src/zstd_ctx.c src/kmod_glue.c src/kernel_sym.c
SRCS_CPP := src/service.cpp
ZSTD_SRCS := $(wildcard zstd/decompress/*.c zstd/common/*.c)

ifeq ($(ZSTD_SRCS),)
  $(error zstd/ sources not found. Run: make vendor-zstd)
endif

OBJS := \
  $(patsubst src/%.c,          $(BUILD)/%.o,            $(SRCS_C))   \
  $(patsubst src/%.cpp,        $(BUILD)/%.o,            $(SRCS_CPP)) \
  $(patsubst zstd/%.c,         $(BUILD)/zstd/%.o,       $(ZSTD_SRCS))

.PHONY: all clean vendor-zstd deploy

all: $(BUNDLE)/Contents/MacOS/$(KEXT)
	@echo "Built: $(BUNDLE)"

$(BUNDLE)/Contents/MacOS/$(KEXT): $(OBJS)
	@mkdir -p $(@D)
	$(CXX) $(LDFLAGS) -o $@ $^

$(BUILD)/%.o: src/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/%.o: src/%.cpp
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(BUILD)/zstd/%.o: zstd/%.c
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -Wno-unused-function -Wno-unused-variable -c $< -o $@

clean:
	rm -rf $(BUILD) $(BUNDLE)/Contents/MacOS

vendor-zstd:
	@bash ../scripts/vendor-zstd.sh

deploy: all
ifndef VM
	$(error Set VM=user@host — e.g. make deploy VM=agent@192.168.64.5)
endif
	sshpass -p sandbox scp -r $(BUNDLE) $(VM):/tmp/
	sshpass -p sandbox ssh $(VM) 'sudo kmutil load -p /tmp/$(BUNDLE) && echo "Loaded OK"'
