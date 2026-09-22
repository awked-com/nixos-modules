state_dir=/run/display

power_status=0
@displayPower@ reconcile || power_status=$?

# Waiting for stop jobs under the claim lock deadlocks their release hooks.
exec 9<"$state_dir"
flock 9
if test -f "$state_dir/active-uxplay"; then
  systemctl --no-block stop miracle-sink.service miracle-wifid.service miracle-routing.service
elif test -f "$state_dir/active-miracle"; then
  systemctl --no-block stop uxplay.service
else
  systemctl --no-block start miracle-routing.service miracle-wifid.service uxplay.service
fi
exit "$power_status"
