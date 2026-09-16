PAM_MODULE := pam_macos_auth.so
SRC := pam_macos_auth.c

UNAME_S := $(shell uname -s)
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -fPIC
PAM_LDFLAGS := -shared
LDLIBS ?= -lpam
TEST_RUNNERS := tests/unit

ifeq ($(UNAME_S),Darwin)
  PAM_LDFLAGS := -bundle -undefined dynamic_lookup
  LDLIBS :=
endif
ifeq ($(UNAME_S),Linux)
  TEST_RUNNERS += tests/unit-fallback
endif

.PHONY: all clean check test

all: $(PAM_MODULE)

$(PAM_MODULE): $(SRC)
	$(CC) $(CFLAGS) $(PAM_LDFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

check:
	$(CC) $(CFLAGS) -fsyntax-only $(SRC)

tests/helper-fixture: tests/helper.c
	$(CC) $(CFLAGS) -o $@ $<

tests/unit: tests/unit.c $(SRC)
	$(CC) $(CFLAGS) -o $@ $<

tests/unit-fallback: tests/unit.c $(SRC)
	$(CC) $(CFLAGS) -DMACOS_AUTH_NO_CLOSE_RANGE -o $@ $<

test: check tests/helper-fixture $(TEST_RUNNERS)
	@for runner in $(TEST_RUNNERS); do ./$$runner || exit $$?; done

clean:
	rm -f $(PAM_MODULE) *.o tests/helper-fixture tests/unit tests/unit-fallback
