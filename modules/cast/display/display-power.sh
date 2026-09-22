action="${1:-}"
owner="${2:-}"
state_dir=/run/display
framebuffer=@framebuffer@

usage() {
  echo "usage: $0 acquire|release owner, or $0 reconcile (owners: uxplay, miracle)" >&2
  exit 2
}

case "$action" in
  acquire|release)
    test "$#" -eq 2 || usage
    case "$owner" in
      uxplay) other_owner=miracle ;;
      miracle) other_owner=uxplay ;;
      *) usage ;;
    esac
    ;;
  reconcile)
    test "$#" -eq 1 || usage
    ;;
  *) usage ;;
esac

test -d "$state_dir" || {
  echo "display state directory is unavailable: $state_dir" >&2
  exit 1
}

dpms_file=
fallback_dpms=
for candidate in @dpmsGlob@; do
  test -r "$candidate" || continue
  fallback_dpms=${fallback_dpms:-$candidate}
  status_file=${candidate%/dpms}/status
  status=
  if test -r "$status_file" && read -r status < "$status_file" &&
     test "$status" = connected
  then
    dpms_file="$candidate"
    break
  fi
done
dpms_file=${dpms_file:-$fallback_dpms}

umask 007

has_claims() {
  test -f "$state_dir/active-uxplay" || test -f "$state_dir/active-miracle"
}

display_is() {
  local state

  test -n "$dpms_file" || return 1
  read -r state < "$dpms_file" 2>/dev/null || return 1
  test "$state" = "$1"
}

power_off() {
  test -n "$dpms_file" || return 0
  display_is Off && return 0

  for ((attempt = 0; attempt < 30; attempt++)); do
    has_claims && return 0
    printf '%s' 4 > "$framebuffer" || return 1
    if display_is Off; then
      sleep 0.5
      has_claims && return 0
      display_is Off && return 0
    fi

    # KMS teardown can undo blanking; let new claimants interrupt retries.
    flock -u 9
    sleep 0.5
    flock 9
  done

  echo "error: could not power off the cast display" >&2
  return 1
}

exec 9<"$state_dir"
flock 9

case "$action" in
  acquire)
    owner_file="$state_dir/active-$owner"
    if test -z "$dpms_file"; then
      echo "no DRM display connector is available" >&2
      exit 1
    fi
    if test -f "$state_dir/active-$other_owner"; then
      echo "display is already reserved by another service" >&2
      exit 75
    fi

    owner_was_present=false
    test -e "$owner_file" && owner_was_present=true
    touch "$owner_file"
    for ((attempt = 0; attempt < 30; attempt++)); do
      printf '%s' 0 > "$framebuffer" || break
      if display_is On; then
        exit 0
      fi
      sleep 0.2
    done
    if ! "$owner_was_present"; then
      rm -f "$owner_file"
    fi
    echo "error: could not wake the cast display" >&2
    exit 1
    ;;
  release|reconcile)
    if test "$action" = release; then
      rm -f "$state_dir/active-$owner"
    fi
    if has_claims; then
      exit 0
    fi
    power_off
    ;;
esac
