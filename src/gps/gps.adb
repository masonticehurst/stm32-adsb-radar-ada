with Ada.Real_Time; use Ada.Real_Time;

with Debug_Log;
with GPS_UART;

package body GPS is

   Started : Boolean := False;

   --  Line being assembled from the received stream
   Line     : String (1 .. Max_Line);
   Line_Len : Natural := 0;
   Overlong : Boolean := False;  --  current line already too long

   Counts : Stats;
   Info   : Fix_Info;

   Fixed_Once : Boolean := False;
   Last_Fix   : Time    := Time_First;

   procedure Bump (N : in out Natural) with
      Inline;

   procedure Bump (N : in out Natural) is
   begin
      if N < Natural'Last then
         N := N + 1;
      end if;
   end Bump;

   --------------
   -- Add_Char --
   --------------

   --  Feed one received byte into the line buffer. Returns True when it
   --  completed a line (now in Line (1 .. Line_Len)). CR is ignored, LF
   --  ends a line, "$" always starts a new one (so a line cut short by a
   --  lost LF doesn't swallow the next sentence); over-long lines are
   --  dropped whole.
   function Add_Char (C : Character) return Boolean is
   begin
      case C is
         when ASCII.CR =>
            return False;

         when ASCII.LF =>
            if Overlong then
               Overlong := False;
               Line_Len := 0;
               Bump (Counts.Too_Long);
               return False;
            end if;

            return Line_Len > 0;

         when others =>
            if C = '$' then
               Line_Len := 0;
               Overlong := False;
            end if;

            if Line_Len < Max_Line then
               Line_Len        := Line_Len + 1;
               Line (Line_Len) := C;
            else
               Overlong := True;
            end if;

            return False;
      end case;
   end Add_Char;

   -----------
   -- Apply --
   -----------

   --  Take what a good RMC or GGA sentence said into Info
   procedure Apply (R : NMEA.Fix_Report) is
   begin
      if R.Has_Time then
         Info.Has_Time := True;
         Info.UTC      := R.UTC;
      end if;

      case R.Kind is
         when NMEA.RMC =>
            Bump (Counts.RMC);
            if R.Has_Position then
               Info.Has_Speed       := R.Has_Speed;
               Info.Ground_Speed_Kt := R.Ground_Speed_Kt;
               --  Keep the last track while stopped (course is often empty)
               if R.Has_Track then
                  Info.Has_Track := True;
                  Info.Track_Deg := R.Track_Deg;
               end if;
            end if;

         when NMEA.GGA =>
            Bump (Counts.GGA);
            Info.Satellites := R.Satellites;
            if R.Has_Position then
               Info.Has_Altitude := R.Has_Altitude;
               Info.Altitude_Ft  := R.Altitude_Ft;
            end if;
      end case;

      if R.Has_Position then
         Info.Position := R.Position;
         Fixed_Once    := True;
         Last_Fix      := Clock;
      end if;
   end Apply;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      GPS_UART.Initialize (Module_Baud);
      Started := True;
      Debug_Log.Put_Line
        ("gps: listening for NMEA at" & Module_Baud'Image & " baud");

   exception
      when others =>
         Debug_Log.Put_Line ("gps: UART start-up failed");
   end Initialize;

   ----------
   -- Poll --
   ----------

   procedure Poll is
      C         : Character;
      Available : Boolean;
      Report    : NMEA.Fix_Report;
      Result    : NMEA.Parse_Result;
   begin
      if not Started then
         return;
      end if;

      loop
         GPS_UART.Get (C, Available);
         exit when not Available;

         if Add_Char (C) then
            Bump (Counts.Lines);
            NMEA.Parse (Line (1 .. Line_Len), Report, Result);

            case Result is
               when NMEA.OK =>
                  Apply (Report);
               when NMEA.Not_Used =>
                  Bump (Counts.Other);
               when NMEA.Bad_Checksum =>
                  Bump (Counts.Bad_Checksum);
               when NMEA.Bad_Format =>
                  Bump (Counts.Bad_Format);
            end case;

            Line_Len := 0;
         end if;
      end loop;

   exception
      when others =>
         Line_Len := 0;
         Overlong := False;
   end Poll;

   function Has_Fix return Boolean is
     (Fixed_Once and then Clock - Last_Fix <= Fix_Timeout);

   function Ever_Fixed return Boolean is (Fixed_Once);

   function Latest return Fix_Info is (Info);

   ----------------
   -- Take_Stats --
   ----------------

   function Take_Stats return Stats is
      Result : constant Stats := Counts;
   begin
      Counts := (others => 0);
      return Result;
   end Take_Stats;

end GPS;
