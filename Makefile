PROJECT := kid-video-thing.xcodeproj
SCHEME := kid-video-thing
CONFIGURATION := Debug
ICONSET := kid-video-thing/Assets.xcassets/AppIcon.appiconset
INSTALL_DIR := $(HOME)/Applications
XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION)

.PHONY: build icon install clean

build:
	$(XCODEBUILD) build

# Regenerates the app icon PNGs and their Contents.json from Tools/MakeIcon.swift.
icon:
	swift Tools/MakeIcon.swift $(ICONSET)

# Copies the built app to ~/Applications, replacing any copy already there.
# `make install CONFIGURATION=Release` for a release build.
install: build
	@set -e; \
	settings=$$($(XCODEBUILD) -showBuildSettings 2>/dev/null); \
	dir=$$(echo "$$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $$2}'); \
	app=$$(echo "$$settings" | awk -F' = ' '/ FULL_PRODUCT_NAME = /{print $$2}'); \
	mkdir -p "$(INSTALL_DIR)"; \
	rm -rf "$(INSTALL_DIR)/$$app"; \
	ditto "$$dir/$$app" "$(INSTALL_DIR)/$$app"; \
	echo "installed $(INSTALL_DIR)/$$app"

clean:
	$(XCODEBUILD) clean
