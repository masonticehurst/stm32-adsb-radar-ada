with Ada.Real_Time; use Ada.Real_Time;

with Adsb_UART;
with CSBee;
with Debug_Log;
with Traffic;

package body Adsbee is

   Started : Boolean := False;

   --  Line being assembled from the received stream
   Line     : String (1 .. Max_Line);
   Line_Len : Natural := 0;
   Overlong : Boolean := False;  --  current line already too long

   Counts : Stats;

   --  Last aircraft report, for the debug log
   Last_Line     : String (1 .. Max_Line);
   Last_Line_Len : Natural := 0;

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
   --  ends a line; over-long lines are dropped whole.
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
            if Line_Len < Max_Line then
               Line_Len        := Line_Len + 1;
               Line (Line_Len) := C;
            else
               Overlong := True;
            end if;

            return False;
      end case;
   end Add_Char;

   ----------------
   -- Initialize --
   ----------------

   procedure Initialize is
   begin
      Adsb_UART.Initialize (Module_Baud);
      Started := True;
      Debug_Log.Put_Line
        ("adsbee: listening for CSBee at" & Module_Baud'Image & " baud");

   exception
      when others =>
         Debug_Log.Put_Line ("adsbee: UART start-up failed");
   end Initialize;

   ----------
   -- Poll --
   ----------

   procedure Poll is
      C         : Character;
      Available : Boolean;
   begin
      if not Started then
         return;
      end if;

      loop
         Adsb_UART.Get (C, Available);
         exit when not Available;

         if Add_Char (C) then
            Bump (Counts.Lines);

            declare
               Text : constant String := Line (1 .. Line_Len);
            begin
               if Text'Length >= 3
                 and then
                 (Text (Text'First .. Text'First + 2) = "#A:"
                  or else Text (Text'First .. Text'First + 2) = "#U:")
               then
                  if Text (Text'First + 1) = 'A' then
                     Bump (Counts.Mode_S);
                  else
                     Bump (Counts.UAT);
                  end if;

                  Last_Line (1 .. Line_Len) := Text;
                  Last_Line_Len             := Line_Len;

                  declare
                     Report : CSBee.Aircraft_Report;
                     Result : CSBee.Parse_Result;
                  begin
                     CSBee.Parse (Text, Report, Result);

                     case Result is
                        when CSBee.OK =>
                           Traffic.Update (Report, Clock);
                        when CSBee.Bad_Checksum =>
                           Bump (Counts.Bad_Checksum);
                        when CSBee.Bad_Format | CSBee.Not_Aircraft =>
                           Bump (Counts.Bad_Format);
                     end case;
                  end;
               elsif Text'Length >= 3
                 and then Text (Text'First .. Text'First + 2) = "#S:"
               then
                  Bump (Counts.Status);
               else
                  Bump (Counts.Other);
               end if;
            end;

            Line_Len := 0;
         end if;
      end loop;

   exception
      when others =>
         Line_Len := 0;
         Overlong := False;
   end Poll;

   ----------------
   -- Take_Stats --
   ----------------

   function Take_Stats return Stats is
      Result : constant Stats := Counts;
   begin
      Counts := (others => 0);
      return Result;
   end Take_Stats;

   ------------------------
   -- Last_Aircraft_Line --
   ------------------------

   function Last_Aircraft_Line return String is
     (Last_Line (1 .. Last_Line_Len));

end Adsbee;
