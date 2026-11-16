--  GT-U7 GPS receiver on USART6 (see GPS_UART).

with Ada.Real_Time;

with Geo;
with NMEA;

package GPS is

   Module_Baud : constant := 9_600;

   --  A fix older than this counts as lost (the module reports once a
   --  second)
   Fix_Timeout : constant Ada.Real_Time.Time_Span := Ada.Real_Time.Seconds (3);

   --  Start USART6 at Module_Baud and begin receiving. Never raises.
   procedure Initialize;

   --  Take every byte received so far, split it into lines and decode
   --  them. Call once per main-loop tick. Never raises.
   procedure Poll;

   --  A position fix arrived within Fix_Timeout
   function Has_Fix return Boolean;

   --  A position fix has arrived at some time since start-up
   function Ever_Fixed return Boolean;

   --  Latest state reported by the module
   type Fix_Info is record
      Position : Geo.Position := (Lat => 0.0, Lon => 0.0);  --  last fix

      Has_Speed       : Boolean    := False;
      Ground_Speed_Kt : Long_Float := 0.0;
      Has_Track       : Boolean    := False;
      Track_Deg       : Long_Float := 0.0;
      Has_Altitude    : Boolean    := False;
      Altitude_Ft     : Long_Float := 0.0;  --  above mean sea level

      Satellites : Natural          := 0;      --  used in the fix
      Has_Time   : Boolean          := False;
      UTC        : NMEA.Day_Seconds := 0;      --  seconds since 00:00 UTC
   end record;

   function Latest return Fix_Info;

   --  Line counts since the last call to Take_Stats
   type Stats is record
      Lines        : Natural := 0;  --  complete lines of any kind
      RMC          : Natural := 0;
      GGA          : Natural := 0;
      Other        : Natural := 0;  --  valid sentences not used
      Bad_Checksum : Natural := 0;  --  includes lines that aren't NMEA
      Bad_Format   : Natural := 0;
      Too_Long     : Natural := 0;  --  lines over Max_Line, discarded
   end record;

   function Take_Stats return Stats;

   --  NMEA allows 82 characters; leave room for u-blox extras
   Max_Line : constant := 120;

end GPS;
