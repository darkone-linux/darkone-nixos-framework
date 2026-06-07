# Date & time helpers
#
# Pure helpers manipulating systemd `OnCalendar`-style time strings.

{ lib }:
rec {

  # Add `n` hours (mod 24) to a `"HH:MM"` time, preserving the minutes and
  # keeping a zero-padded 2-digit hour. Used to stagger the timers of several
  # backup targets sharing the same base time.
  #
  # `toIntBase10` is mandatory: `toInt "08"` rejects zero-padded values as
  # ambiguous octal. `n` may be any non-negative integer; it wraps over 24h.
  #
  # Usage:
  #   shiftHour "01:00" 0  => "01:00"
  #   shiftHour "23:30" 2  => "01:30"
  shiftHour =
    base: n:
    let
      parts = lib.splitString ":" base;
      h = lib.toIntBase10 (builtins.head parts);
      mm = builtins.elemAt parts 1;
      s = h + n;
      nh = lib.mod s 24;
      hh = if nh < 10 then "0${toString nh}" else toString nh;
    in
    "${hh}:${mm}";
}
