--  NMEA 0183 sentence parser for the GT-U7 (u-blox 7 class) GPS.
--
--  Only the two sentences the map needs are decoded; the rest (GSV, GSA,
--  VTG, GLL, TXT) are checked and then ignored:
--     $--RMC  time, status, lat, N/S, lon, E/W, speed (kn), course, date,
--             magnetic variation, E/W, mode
--     $--GGA  time, lat, N/S, lon, E/W, fix quality, satellites, HDOP,
--             altitude (m MSL), M, geoid separation, M, age, station
--  "--" is the talker: GP (GPS only), GN (multi-system), GL, GA, BD...
--  Lines must be complete, "$...*HH", without CR/LF. HH is the XOR of
--  every character between "$" and "*".
--
--  Parse never raises: malformed input only gives a bad result.

with Interfaces; use Interfaces;

with Geo;

package NMEA is

   type Sentence_Kind is (RMC, GGA);

   type Parse_Result is
     (OK,
      Not_Used,      --  valid sentence of another type
      Bad_Checksum,  --  "*HH" missing or wrong
      Bad_Format);   --  checksum fine, fields unreadable

   subtype Day_Seconds is Natural range 0 .. 86_399;

   --  What one RMC or GGA sentence said. Has_Position is False when the
   --  receiver reports no fix (RMC status "V" or mode "N", GGA quality 0).
   type Fix_Report is record
      Kind : Sentence_Kind := RMC;

      Has_Time : Boolean     := False;
      UTC      : Day_Seconds := 0;  --  seconds since 00:00 UTC

      Has_Position : Boolean      := False;
      Position     : Geo.Position := (Lat => 0.0, Lon => 0.0);

      --  RMC only
      Has_Speed       : Boolean    := False;
      Ground_Speed_Kt : Long_Float := 0.0;
      Has_Track       : Boolean    := False;
      Track_Deg       : Long_Float := 0.0;  --  true course, 0 .. 360

      --  GGA only
      Has_Altitude : Boolean    := False;
      Altitude_Ft  : Long_Float := 0.0;  --  above mean sea level
      Satellites   : Natural    := 0;    --  used in the fix
   end record;

   procedure Parse
     (Line : String; Report : out Fix_Report; Result : out Parse_Result);

   --  XOR of every character of Data
   function Checksum (Data : String) return Unsigned_8;

end NMEA;
