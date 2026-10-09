CFLAGS  ?= -O2 -Wall -Wno-deprecated-declarations
LDFLAGS := -framework IOKit -framework CoreFoundation

bin/uvcctl: src/uvcctl.c
	@mkdir -p bin
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

bin/preview: src/preview.swift src/Preview-Info.plist
	@mkdir -p bin
	swiftc -O -o $@ src/preview.swift -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker src/Preview-Info.plist

clean:
	rm -rf bin

.PHONY: clean
