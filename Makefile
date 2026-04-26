CC = clang
CFLAGS = -Wall -Wextra -O2 -fobjc-arc
LDFLAGS = -framework ApplicationServices -framework AppKit -framework Carbon
TARGET = macos-hotkeys
PREFIX = /usr/local

.PHONY: all clean install uninstall

all: $(TARGET)

$(TARGET): main.m
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $<
	codesign -s - --force $@

install: $(TARGET)
	install -d $(PREFIX)/bin
	install -m 755 $(TARGET) $(PREFIX)/bin/$(TARGET)
	mkdir -p ~/Library/LaunchAgents
	sed 's|__PREFIX__|$(PREFIX)|g' com.thheller.macos-hotkeys.plist \
		> ~/Library/LaunchAgents/com.thheller.macos-hotkeys.plist

uninstall:
	-launchctl unload ~/Library/LaunchAgents/com.thheller.macos-hotkeys.plist 2>/dev/null
	rm -f $(PREFIX)/bin/$(TARGET)
	rm -f ~/Library/LaunchAgents/com.thheller.macos-hotkeys.plist

clean:
	rm -f $(TARGET)
