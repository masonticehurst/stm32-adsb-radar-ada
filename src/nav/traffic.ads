--  Table of aircraft heard by the ADS-B receiver: fixed size, no heap.
--
--  Each CSBee report updates the entry with the same ICAO address (a new
--  entry if it is not there; the longest-silent entry is reused when the
--  table is full). Only fields the report marks valid are copied, so an
--  aircraft keeps its last good position, altitude, etc.
--
--  Timeouts: a position older than Position_Timeout is not drawn; an
--  aircraft not heard for Drop_Timeout is removed.

with Ada.Real_Time; use Ada.Real_Time;
with Interfaces;    use Interfaces;

with CSBee;
with Geo;

package Traffic is

   Max_Aircraft     : constant           := 64;
   Position_Timeout : constant Time_Span := Seconds (20);
   Drop_Timeout     : constant Time_Span := Seconds (60);

   type Aircraft is record
      In_Use        : Boolean                          := False;
      ICAO          : Unsigned_32                      := 0;
      Source        : CSBee.Source_Kind                := CSBee.Mode_S;
      Callsign      : String (1 .. CSBee.Max_Callsign) := (others => ' ');
      Callsign_Len  : Natural                          := 0;  --  0 = unknown
      Airborne      : Boolean                          := True;
      Has_Position  : Boolean                          := False;
      Position      : Geo.Position := (Lat => 0.0, Lon => 0.0);
      Has_Altitude  : Boolean                          := False;
      Altitude_Ft   : Integer := 0;  --  baro, else GNSS
      Has_Direction : Boolean                          := False;
      Direction_Deg : Integer := 0;  --  track or heading
      Has_Speed     : Boolean                          := False;
      Speed_Kt      : Integer                          := 0;
      Has_VRate     : Boolean                          := False;
      VRate_Fpm     : Integer                          := 0;  --  + climbing
      Last_Heard    : Time                             := Time_First;
      Position_Time : Time                             := Time_First;
   end record;

   subtype Slot is Positive range 1 .. Max_Aircraft;

   --  "Nothing selected": never a real 24-bit ICAO address
   No_Aircraft : constant Unsigned_32 := 16#FFFF_FFFF#;

   --  Slot holding this aircraft, or 0 if it is not in the table
   function Find (ICAO : Unsigned_32) return Natural;

   --  Apply one parsed report
   procedure Update (Report : CSBee.Aircraft_Report; Now : Time);

   --  Remove aircraft not heard for Drop_Timeout
   procedure Expire (Now : Time);

   function Get (S : Slot) return Aircraft;

   --  Aircraft in the table
   function Count return Natural;

   --  True if A should be drawn
   function Position_Fresh (A : Aircraft; Now : Time) return Boolean is
     (A.In_Use and then A.Has_Position
      and then Now - A.Position_Time <= Position_Timeout);

   --  True if the table changed since the last call; clears the flag
   function Take_Changed return Boolean;

end Traffic;
