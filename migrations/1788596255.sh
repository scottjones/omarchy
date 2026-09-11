echo "Add vi as a standard terminal editor"

# There is no vi package on Arch Linux ARM. Do not fail the rest of migrate.
[[ $(uname -m) == aarch64 ]] && exit 0

omarchy-pkg-add vi
