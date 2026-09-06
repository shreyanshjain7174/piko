.PHONY: project open test build clean setup lint

project:   ## regenerate the Xcode project from App/project.yml
	cd App && xcodegen generate

open: project
	open App/Piko.xcodeproj

test:      ## module tests, no simulator needed
	swift build
	/usr/libexec/PlistBuddy -c "Clear dict" \
		-c "Add :CFBundleIdentifier string local.piko.PikoUI.tests" \
		"$$(swift build --show-bin-path)/Piko_PikoUI.bundle/Info.plist"
	xcrun actool Sources/PikoUI/Resources/PikoColors.xcassets \
		--compile "$$(swift build --show-bin-path)/Piko_PikoUI.bundle" \
		--platform macosx --minimum-deployment-target 15.0
	swift test

build:     ## build the app for a simulator
	xcodebuild -project App/Piko.xcodeproj -scheme Piko \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' build

clean:
	rm -rf .build App/Piko.xcodeproj DerivedData

setup:
	./scripts/setup.sh

lint:
	swift format lint --recursive Sources Tests || true
