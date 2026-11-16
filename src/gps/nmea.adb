package body NMEA is

   Feet_Per_Metre : constant := 3.280_84;

   --------------
   -- Checksum --
   --------------

   function Checksum (Data : String) return Unsigned_8 is
      Sum : Unsigned_8 := 0;
   begin
      for C of Data loop
         Sum := Sum xor Unsigned_8 (Character'Pos (C));
      end loop;
      return Sum;
   end Checksum;

   -------------
   -- Helpers --
   -------------

   --  All of these report failure through OK instead of raising

   procedure Get_Hex_Digit
     (C : Character; V : out Unsigned_8; OK : out Boolean)
   is
   begin
      OK := True;
      case C is
         when '0' .. '9' =>
            V := Character'Pos (C) - Character'Pos ('0');
         when 'A' .. 'F' =>
            V := Character'Pos (C) - Character'Pos ('A') + 10;
         when 'a' .. 'f' =>
            V := Character'Pos (C) - Character'Pos ('a') + 10;
         when others =>
            V  := 0;
            OK := False;
      end case;
   end Get_Hex_Digit;

   function Is_Digit (C : Character) return Boolean is (C in '0' .. '9');

   function Digit (C : Character) return Natural is
     (Character'Pos (C) - Character'Pos ('0'));

   --  Whole number, digits only (at most 9 of them)
   procedure Get_Natural (S : String; Value : out Natural; OK : out Boolean) is
   begin
      Value := 0;
      OK    := False;
      if S'Length = 0 or else S'Length > 9 then
         return;
      end if;
      for C of S loop
         if not Is_Digit (C) then
            Value := 0;
            return;
         end if;
         Value := Value * 10 + Digit (C);
      end loop;
      OK := True;
   end Get_Natural;

   --  Decimal number such as "-12.345" (no exponent)
   procedure Get_Decimal (S : String; Value : out Long_Float; OK : out Boolean)
   is
      I       : Natural    := S'First;
      Neg     : Boolean    := False;
      In_Frac : Boolean    := False;
      Seen    : Boolean    := False;  --  at least one digit
      Scale   : Long_Float := 1.0;
   begin
      Value := 0.0;
      OK    := False;
      if S'Length = 0 or else S'Length > 15 then
         return;
      end if;

      if S (I) = '-' then
         Neg := True;
         I   := I + 1;
      end if;

      while I <= S'Last loop
         if Is_Digit (S (I)) then
            Seen := True;
            if In_Frac then
               Scale := Scale / 10.0;
               Value := Value + Long_Float (Digit (S (I))) * Scale;
            else
               Value := Value * 10.0 + Long_Float (Digit (S (I)));
            end if;
         elsif S (I) = '.' and then not In_Frac then
            In_Frac := True;
         else
            Value := 0.0;
            return;
         end if;
         I := I + 1;
      end loop;

      if Seen then
         if Neg then
            Value := -Value;
         end if;
         OK := True;
      else
         Value := 0.0;
      end if;
   end Get_Decimal;

   --  "ddmm.mmmm" (latitude, Deg_Digits = 2) or "dddmm.mmmm" (longitude,
   --  Deg_Digits = 3) plus its hemisphere letter, to signed degrees
   procedure Get_Angle
     (S : String; Hemisphere : String; Deg_Digits : Positive; Max : Long_Float;
      Value : out Long_Float; OK : out Boolean)
   is
      Degrees : Natural;
      Minutes : Long_Float;
      Good    : Boolean;
   begin
      Value := 0.0;
      OK    := False;
      if S'Length < Deg_Digits + 2 or else Hemisphere'Length /= 1 then
         return;
      end if;

      Get_Natural (S (S'First .. S'First + Deg_Digits - 1), Degrees, Good);
      if not Good then
         return;
      end if;

      Get_Decimal (S (S'First + Deg_Digits .. S'Last), Minutes, Good);
      if not Good or else Minutes < 0.0 or else Minutes >= 60.0 then
         return;
      end if;

      Value := Long_Float (Degrees) + Minutes / 60.0;
      if Value > Max then
         Value := 0.0;
         return;
      end if;

      case Hemisphere (Hemisphere'First) is
         when 'N' | 'E' =>
            null;
         when 'S' | 'W' =>
            Value := -Value;
         when others =>
            Value := 0.0;
            return;
      end case;

      OK := True;
   end Get_Angle;

   --  "hhmmss" or "hhmmss.ss" to seconds since midnight
   procedure Get_Time (S : String; Value : out Day_Seconds; OK : out Boolean)
   is
      H, M, Sec  : Natural;
      G1, G2, G3 : Boolean;
   begin
      Value := 0;
      OK    := False;
      if S'Length < 6 then
         return;
      end if;
      Get_Natural (S (S'First .. S'First + 1), H, G1);
      Get_Natural (S (S'First + 2 .. S'First + 3), M, G2);
      Get_Natural (S (S'First + 4 .. S'First + 5), Sec, G3);
      if G1 and then G2 and then G3 and then H < 24 and then M < 60
        and then Sec <= 60
      then
         Value := H * 3_600 + M * 60 + Natural'Min (Sec, 59);
         OK    := True;
      end if;
   end Get_Time;

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Line : String; Report : out Fix_Report; Result : out Parse_Result)
   is
      Max_Fields : constant := 24;

      type Span is record
         First, Last : Natural := 0;  --  Last < First: empty field
      end record;

      Spans : array (1 .. Max_Fields) of Span;
      Count : Natural := 0;

      Hi, Lo : Unsigned_8;
      G1, G2 : Boolean;
   begin
      Report := (others => <>);
      Result := Bad_Checksum;

      --  Shortest useful sentence: "$GPRMC*hh"
      if Line'Length < 9 or else Line (Line'First) /= '$'
        or else Line (Line'Last - 2) /= '*'
      then
         return;
      end if;

      Get_Hex_Digit (Line (Line'Last - 1), Hi, G1);
      Get_Hex_Digit (Line (Line'Last), Lo, G2);
      if not (G1 and G2)
        or else Hi * 16 + Lo /=
          Checksum (Line (Line'First + 1 .. Line'Last - 3))
      then
         return;
      end if;

      Result := Bad_Format;

      --  Split "$" .. "*" into comma-separated fields; field 1 is the
      --  address ("GPRMC")
      declare
         Data  : String renames Line (Line'First + 1 .. Line'Last - 3);
         Start : Natural := Data'First;
      begin
         for I in Data'First .. Data'Last + 1 loop
            if I > Data'Last or else Data (I) = ',' then
               if Count = Max_Fields then
                  return;
               end if;
               Count         := Count + 1;
               Spans (Count) := (First => Start, Last => I - 1);
               Start         := I + 1;
            end if;
         end loop;
      end;

      declare
         function Field (N : Positive) return String is
           (if N <= Count then Line (Spans (N).First .. Spans (N).Last)
            else "");

         Address : constant String := Field (1);

         --  Read the position from these fields into Report
         function Read_Position (Lat, NS, Lon, EW : Positive) return Boolean is
            Lat_V, Lon_V : Long_Float;
            G_Lat, G_Lon : Boolean;
         begin
            Get_Angle (Field (Lat), Field (NS), 2, 90.0, Lat_V, G_Lat);
            Get_Angle (Field (Lon), Field (EW), 3, 180.0, Lon_V, G_Lon);
            if G_Lat and then G_Lon then
               Report.Position     := (Lat => Lat_V, Lon => Lon_V);
               Report.Has_Position := True;
               return True;
            end if;
            return False;
         end Read_Position;

         Good : Boolean;
      begin
         if Address'Length /= 5 then
            return;
         end if;

         declare
            Kind_Text : constant String :=
              Address (Address'First + 2 .. Address'Last);
         begin
            if Kind_Text = "RMC" then
               --  2 time, 3 status, 4-7 position, 8 speed, 9 course,
               --  10 date, 11-12 variation, 13 mode (NMEA 2.3 and later)
               if Count < 10 then
                  return;
               end if;
               Report.Kind := RMC;
               Get_Time (Field (2), Report.UTC, Report.Has_Time);

               if Field (3) = "A" and then Field (13) /= "N" then
                  if not Read_Position (4, 5, 6, 7) then
                     return;
                  end if;

                  Get_Decimal (Field (8), Report.Ground_Speed_Kt, Good);
                  Report.Has_Speed :=
                    Good and then Report.Ground_Speed_Kt >= 0.0;

                  Get_Decimal (Field (9), Report.Track_Deg, Good);
                  Report.Has_Track :=
                    Good and then Report.Track_Deg >= 0.0
                    and then Report.Track_Deg <= 360.0;
               end if;

            elsif Kind_Text = "GGA" then
               --  2 time, 3-6 position, 7 quality, 8 satellites, 9 HDOP,
               --  10 altitude, 11 "M"
               if Count < 10 then
                  return;
               end if;
               Report.Kind := GGA;
               Get_Time (Field (2), Report.UTC, Report.Has_Time);

               declare
                  Quality : Natural;
                  Sats    : Natural;
                  Alt_M   : Long_Float;
               begin
                  Get_Natural (Field (8), Sats, Good);
                  if Good then
                     Report.Satellites := Sats;
                  end if;

                  Get_Natural (Field (7), Quality, Good);
                  if Good and then Quality > 0 then
                     if not Read_Position (3, 4, 5, 6) then
                        return;
                     end if;

                     Get_Decimal (Field (10), Alt_M, Good);
                     if Good then
                        Report.Altitude_Ft  := Alt_M * Feet_Per_Metre;
                        Report.Has_Altitude := True;
                     end if;
                  end if;
               end;

            else
               Result := Not_Used;
               return;
            end if;
         end;
      end;

      Result := OK;

   exception
      when others =>
         Report := (others => <>);
         Result := Bad_Format;
   end Parse;

end NMEA;
