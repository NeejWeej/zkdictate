.PHONY: test test-native open app install sync build
sync:
	uv sync --frozen
test:
	uv run --frozen python -m unittest discover -s tests -v
test-native:
	./scripts/test_native.sh
open:
	./zkdictate
app:
	uv run --frozen python scripts/build_app.py
install:
	./install.sh
build:
	uv build
