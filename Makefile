CONFIG ?= debug
APP := build/Yatty.app

.PHONY: deps ghostty zmx build app run clean

deps: ghostty zmx

ghostty:
	scripts/build-ghostty.sh

zmx:
	scripts/fetch-zmx.sh

# --disable-sandbox: SwiftPM's own manifest sandbox can't nest inside another
# sandbox (fence), and a plain build doesn't need it.
build: deps
	swift build -c $(CONFIG) --scratch-path .build/swift --disable-sandbox

app: build
	scripts/bundle-app.sh $(CONFIG)

run: app
	open $(APP)

clean:
	rm -rf .build/swift build
