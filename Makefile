.PHONY: project clean build test

project:
	xcodegen generate

clean:
	rm -rf ScreenShare.xcodeproj .derived-data build

build: project
	xcodebuild -project ScreenShare.xcodeproj -scheme ScreenShareSender -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .derived-data CODE_SIGNING_ALLOWED=NO build
	xcodebuild -project ScreenShare.xcodeproj -scheme ScreenShareReceiver -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath .derived-data CODE_SIGNING_ALLOWED=NO build

test: project
	./scripts/test.sh

