PROJECT := kid-video-thing.xcodeproj
SCHEME := kid-video-thing
CONFIGURATION := Debug
ICONSET := kid-video-thing/Assets.xcassets/AppIcon.appiconset

.PHONY: build icon clean

build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) build

# Regenerates the app icon PNGs and their Contents.json from Tools/MakeIcon.swift.
icon:
	swift Tools/MakeIcon.swift $(ICONSET)

clean:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIGURATION) clean
