CFLAGS ?= -O2
all: compile
compile: flowproxy-dns flowproxy-health
flowproxy-dns: flowproxy-dns.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -Wall -Wextra -Werror -std=c99 -o $@ $< $(LDFLAGS)
flowproxy-health: flowproxy-health.c
	$(CC) $(CFLAGS) $(CPPFLAGS) -Wall -Wextra -Werror -std=c99 -o $@ $< $(LDFLAGS)
clean:
	rm -f flowproxy-dns flowproxy-health
install: flowproxy-dns flowproxy-health
	install -d $(DESTDIR)/usr/sbin
	install -m 0755 flowproxy-dns $(DESTDIR)/usr/sbin/flowproxy-dns
	install -m 0755 flowproxy-health $(DESTDIR)/usr/sbin/flowproxy-health
.PHONY: all compile clean install
