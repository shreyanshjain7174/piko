.PHONY: project open test build clean setup lint

project:   ## regenerate the Xcode project from App/project.yml
	cd App && xcodegen generate

open: project
	open App/Piko.xcodeproj

test:      ## module tests, no simulator needed
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
