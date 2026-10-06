.PHONY: app run install test cli clean fake-server

# Build build/Earshot.app
app:
	./scripts/build-app.sh

# Build and launch
run: app
	open build/Earshot.app

# Copy into ~/Applications so Spotlight, Launchpad and "Open at login" find it
install: app
	mkdir -p "$(HOME)/Applications"
	rm -rf "$(HOME)/Applications/Earshot.app"
	cp -R build/Earshot.app "$(HOME)/Applications/"
	@echo "Installed to $(HOME)/Applications/Earshot.app"

test:
	swift test

# Command-line tool: .build/release/earshot-cli --help
cli:
	swift build -c release --product earshot-cli

# A stand-in for MLX Studio's API on port 8080 (needs: pip install fastapi uvicorn python-multipart)
fake-server:
	python3 Tools/fake_mlx_studio.py --port 8080 --gateway

clean:
	rm -rf .build build
