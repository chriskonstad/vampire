# Vampire — local dev tasks. No CI by design; `just check` is the gate:
# lint + pure-core tests + full app build. Run it before committing.
set positional-arguments

# Everything the gate should catch
check: lint test build

# Strict lint (findings are errors)
lint:
    swift format lint --strict -r App VampireCore

# Re-format everything in place
format:
    swift format -i -r App VampireCore

# Pure unit tests (fast — seconds, no device)
test:
    cd VampireCore && swift test

# Full App build for the iOS Simulator (generic destination: works on any
# machine with the iOS SDK, no specific simulator needed)
build:
    xcodebuild -project Vampire.xcodeproj -scheme Vampire -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/DerivedData build

# Lint + tests only — the fast loop when iterating on pure logic
fast: lint test

# Alias for the common case
default: check
