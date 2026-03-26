.PHONY: build build-rust build-xcode build-x86_64 generate clean run install dmg release

ARCH := aarch64-apple-darwin
XCODE_ARCH := arm64
BUILD_DIR = $(shell xcodebuild -project KoeApp/Reso.xcodeproj -scheme Reso -configuration Release -showBuildSettings 2>/dev/null | grep ' BUILD_DIR' | head -1 | awk '{print $$3}')
APP_PATH = $(BUILD_DIR)/Release/Reso.app

build: generate build-rust build-xcode

build-x86_64: generate
	cargo build --manifest-path koe-core/Cargo.toml --release --target x86_64-apple-darwin
	cd KoeApp && xcodebuild -project Reso.xcodeproj -scheme Reso -configuration Release ARCHS=x86_64 ONLY_ACTIVE_ARCH=NO build

generate:
	cd KoeApp && xcodegen generate

build-rust:
	cargo build --manifest-path koe-core/Cargo.toml --release --target $(ARCH)

build-xcode:
	cd KoeApp && xcodebuild -project Reso.xcodeproj -scheme Reso -configuration Release ARCHS=$(XCODE_ARCH) build

clean:
	cargo clean
	cd KoeApp && xcodebuild -project Reso.xcodeproj -scheme Reso clean

run:
	open "$(BUILD_DIR)/Debug/Reso.app"

# Build, kill running instance, replace in /Applications, and launch
install: build
	-pkill -x Reso
	sleep 1
	rm -rf /Applications/Reso.app
	cp -R "$(APP_PATH)" /Applications/
	open /Applications/Reso.app

# Create DMG installer
dmg: build
	$(eval DMG_DIR := $(shell mktemp -d))
	cp -R "$(APP_PATH)" "$(DMG_DIR)/"
	ln -s /Applications "$(DMG_DIR)/Applications"
	hdiutil create -volname "Reso" -srcfolder "$(DMG_DIR)" -ov -format UDZO /tmp/Reso-macOS.dmg
	rm -rf "$(DMG_DIR)"
	@echo "DMG created: /tmp/Reso-macOS.dmg"
	@ls -lh /tmp/Reso-macOS.dmg

# Build DMG and create GitHub release (usage: make release V=0.2.1)
release: dmg
ifndef V
	$(error Usage: make release V=0.2.1)
endif
	gh release create v$(V) /tmp/Reso-macOS.dmg --title "v$(V)" --generate-notes
	@echo "Released: https://github.com/yikZero/reso/releases/tag/v$(V)"
