#!/usr/bin/env sh
# R-ENG-TEST: every file in tests/ must run in CI and in scripts/check.sh,
# unless it is nested (invoked by another contract) or archived (exercises a
# disabled prototype; see R-ARCH-6). Prevents tests that silently never run.
set -eu

workflow="${1:-.github/workflows/build.yml}"
check="${2:-scripts/check.sh}"
tests_dir="$(dirname "$0")"

# Invoked by another contract rather than directly.
nested="obs_udp_relay_contract.sh"
# Exercise archived prototypes; must NOT run in CI (windows_ci_contract.sh).
archived="virtual_camera_source_contract.sh virtual_camera_contract_test.cpp gpu_frame_transport_contract_test.cpp"

fail() {
  echo "TEST REGISTRY [R-ENG-TEST]: $1" >&2
  exit 1
}

listed() { # NAME LIST
  for item in $2; do
    if [ "$item" = "$1" ]; then return 0; fi
  done
  return 1
}

for name in $nested $archived; do
  [ -f "$tests_dir/$name" ] || fail "registry lists $name but tests/$name does not exist"
done

for path in "$tests_dir"/*; do
  name=$(basename "$path")
  case "$name" in
    *.sh)
      tr -d '\r' < "$path" | sed -n 1p | grep -qx '#!/usr/bin/env sh' ||
        fail "tests/$name must start with '#!/usr/bin/env sh'"
      tr -d '\r' < "$path" | sed -n 1,8p | grep -qx 'set -eu' ||
        fail "tests/$name must run 'set -eu' within its first 8 lines"
      ;;
    *.cpp|*.swift|*.ps1) ;;
    *) fail "unexpected file tests/$name; tests are .sh, .cpp, .swift or .ps1" ;;
  esac

  if listed "$name" "$archived"; then
    if grep -q "tests/$name" "$workflow"; then
      fail "archived test tests/$name must not run in CI"
    fi
    continue
  fi

  if listed "$name" "$nested"; then
    caller=$(grep -l "$name" "$tests_dir"/*.sh | grep -v "/$name\$" | grep -v '/test_registry_contract.sh$' || true)
    [ -n "$caller" ] || fail "nested test tests/$name is not invoked by any other contract"
    continue
  fi

  grep -q "tests/$name" "$workflow" ||
    fail "tests/$name is not run by $workflow (wire it in, or list it as archived with a reason)"
  grep -q "tests/$name" "$check" ||
    fail "tests/$name is not run by $check (local gate must mirror CI)"
done

# Runtime C++ tests rely on assert(); NDEBUG would silently disable them.
if grep -q 'NDEBUG' "$workflow" "$check"; then
  fail "NDEBUG must not be defined when compiling tests"
fi

echo "test registry: OK"
