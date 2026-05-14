PAM_MODULE := pam_macos_auth.so
SRC := pam_macos_auth.c

UNAME_S := $(shell uname -s)
CC ?= cc
CFLAGS ?= -O2 -Wall -Wextra -Werror -fPIC
PAM_LDFLAGS := -shared
LDLIBS ?= -lpam

ifeq ($(UNAME_S),Darwin)
  PAM_LDFLAGS := -bundle -undefined dynamic_lookup
  LDLIBS :=
endif

.PHONY: all clean check

all: $(PAM_MODULE)

$(PAM_MODULE): $(SRC)
	$(CC) $(CFLAGS) $(PAM_LDFLAGS) $(LDFLAGS) -o $@ $< $(LDLIBS)

check:
	$(CC) $(CFLAGS) -fsyntax-only $(SRC)

clean:
	rm -f $(PAM_MODULE) *.o
