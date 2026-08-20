CC := cosmocc
# dhall-c is vendored as a git submodule; override with DHALL_C=../dhall-c to use sibling checkout.
DHALL_C ?= vendor/dhall-c
CFLAGS = -std=c11 -O2 -g -Wall -Wextra -D_POSIX_C_SOURCE=200809L -I $(DHALL_C)/src
CORE_DHALL = $(DHALL_C)/src/arena.c $(DHALL_C)/src/lexer.c $(DHALL_C)/src/parser.c \
             $(DHALL_C)/src/ast.c $(DHALL_C)/src/normalize.c $(DHALL_C)/src/typecheck.c \
             $(DHALL_C)/src/builtins.c $(DHALL_C)/src/serialize.c $(DHALL_C)/src/import.c \
             $(DHALL_C)/src/bignum.c $(DHALL_C)/src/sha256.c $(DHALL_C)/src/ssrf.c $(DHALL_C)/src/http.c

all: dhake.com

dhake.com: src/dhake.c $(CORE_DHALL)
	$(CC) $(CFLAGS) -o dhake.com src/dhake.c $(CORE_DHALL)

test: dhake.com
	./tests/build.sh ./dhake.com.dbg

clean:
	rm -f dhake.com dhake.com.dbg dhake.aarch64.elf

.PHONY: all test clean
