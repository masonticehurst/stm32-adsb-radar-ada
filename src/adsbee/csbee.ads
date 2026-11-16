--  Parser for ADSBee CSBee aircraft report lines.
--
--  "#A:" = 1090 MHz Mode S / ADS-B aircraft, "#U:" = 978 MHz UAT aircraft.
--  Both carry 20 comma-separated fields and then a checksum, e.g.
--
--  #A:A779BB,1F80907F,?,1057,0,41.45654,-74.07419,21325,21075,186,430,
--     -1600,0,EA58,7F0002,2,-32768,-32768,4,2,AB6
--
--  The first 13 fields are the same for both line types:
--     1 ICAO address (hex)    2 flags (hex)        3 callsign ("?" = none)
--     4 squawk ("?" = none)   5 emitter category   6 latitude (deg)
--     7 longitude (deg)       8 baro altitude (ft) 9 GNSS altitude (ft)
--    10 direction (deg)      11 speed (kt)        12 baro vert. rate (fpm)
--    13 GNSS vert. rate (fpm)
--  The rest (accuracy, dimensions, version, signal, frame counts) differ
--  between the two and are not used. The checksum is CRC-16/CCITT-FALSE
--  (polynomial 16#1021#, initial 16#FFFF#) of everything from '#' up to and
--  including the comma before it, printed with its two bytes swapped.
--
--  Source: ADSBee firmware, firmware/common/comms/csbee/csbee_utils.hh and
--  firmware/common/utils/buffer_utils.cpp (github.com/PantsForBirds/adsbee).
--  Checked against real lines from the receiver.
--
--  No exceptions, no allocation: a malformed line is reported, not raised.

with Interfaces; use Interfaces;

package CSBee is

   Max_Callsign : constant := 8;

   type Source_Kind is (Mode_S, UAT);

   type Aircraft_Report is record
      Source         : Source_Kind                := Mode_S;
      ICAO           : Unsigned_32 := 0;  --  24-bit aircraft address
      Flags          : Unsigned_32                := 0;
      Callsign       : String (1 .. Max_Callsign) := (others => ' ');
      Callsign_Len   : Natural := 0;  --  0 = not received yet
      Latitude       : Long_Float                 := 0.0;
      Longitude      : Long_Float                 := 0.0;
      Baro_Alt_Ft    : Integer                    := 0;
      GNSS_Alt_Ft    : Integer                    := 0;
      Direction_Deg  : Integer                    := 0;
      Speed_Kt       : Integer                    := 0;
      Baro_VRate_Fpm : Integer                    := 0;
      GNSS_VRate_Fpm : Integer                    := 0;
   end record;

   --  Flag bits, the same for "#A:" and "#U:" lines
   function Flag (R : Aircraft_Report; Bit : Natural) return Boolean is
     ((Shift_Right (R.Flags, Bit) and 1) = 1) with
      Pre => Bit < 32;

   function Airborne (R : Aircraft_Report) return Boolean is (Flag (R, 0));
   function Baro_Alt_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 1));
   function GNSS_Alt_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 2));
   function Position_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 3));
   function Direction_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 4));
   function Speed_Valid (R : Aircraft_Report) return Boolean is (Flag (R, 5));
   function Baro_VRate_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 6));
   function GNSS_VRate_Valid (R : Aircraft_Report) return Boolean is
     (Flag (R, 7));

   type Parse_Result is
     (OK,
      Not_Aircraft,   --  some other line ("#S:" statistics, ...)
      Bad_Checksum,   --  corrupted in transit
      Bad_Format);    --  wrong field count or a field that doesn't parse

   --  Parse one line, without its CR/LF. Report is only meaningful when
   --  Result = OK.
   procedure Parse
     (Line : String; Report : out Aircraft_Report; Result : out Parse_Result);

   --  CSBee checksum of Data (already byte-swapped, as printed)
   function CRC16 (Data : String) return Unsigned_16;

end CSBee;
