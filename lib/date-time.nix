# Date & time helpers
#
# Pure helpers manipulating systemd `OnCalendar`-style time strings.

{ lib }: {

  # `"HH:MM"` shifted by `n` hours (mod 24), minutes kept: staggers the timers
  # of backup targets sharing one base time. `toIntBase10`, as `toInt "08"`
  # rejects a zero-padded value (ambiguous octal).
  #
  #   shiftHour "23:30" 2 => "01:30"
  shiftHour =
    base: n:
    let
      parts = lib.splitString ":" base;
      hour = lib.mod (lib.toIntBase10 (builtins.head parts) + n) 24;
    in
    "${lib.fixedWidthNumber 2 hour}:${builtins.elemAt parts 1}";
}
