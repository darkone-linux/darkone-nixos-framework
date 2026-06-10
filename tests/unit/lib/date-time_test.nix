# Tests for dnf/lib/date-time.nix
# Run with: nix-unit --flake .#libTests
{ dnfLib }: {

  # ----- shiftHour -----

  # Zero shift is the identity (the regression that broke the build:
  # `toInt "01"` rejected the zero-padded hour).
  testShiftHourZeroPadded = {
    expr = dnfLib.shiftHour "01:00" 0;
    expected = "01:00";
  };
  testShiftHourSimple = {
    expr = dnfLib.shiftHour "01:00" 5;
    expected = "06:00";
  };

  # Minutes are preserved verbatim, hour stays zero-padded.
  testShiftHourKeepsMinutes = {
    expr = dnfLib.shiftHour "00:30" 1;
    expected = "01:30";
  };

  # Wraps over midnight (mod 24).
  testShiftHourWrap = {
    expr = dnfLib.shiftHour "23:30" 2;
    expected = "01:30";
  };

  # Exactly 24h wraps back to the same time.
  testShiftHourFullDay = {
    expr = dnfLib.shiftHour "08:15" 24;
    expected = "08:15";
  };

  # Shift landing on a single-digit hour is zero-padded.
  testShiftHourPadsResult = {
    expr = dnfLib.shiftHour "22:00" 3;
    expected = "01:00";
  };

  # Large multi-day shift wraps correctly.
  testShiftHourMultiDay = {
    expr = dnfLib.shiftHour "10:00" 50;
    expected = "12:00";
  };
}
