package body CSBee is

   Field_Count : constant := 20;  --  fields before the checksum

   -----------
   -- CRC16 --
   -----------

   function CRC16 (Data : String) return Unsigned_16 is
      CRC : Unsigned_16 := 16#FFFF#;
   begin
      for C of Data loop
         CRC := CRC xor Shift_Left (Unsigned_16 (Character'Pos (C)), 8);

         for Bit in 1 .. 8 loop
            if (CRC and 16#8000#) /= 0 then
               CRC := Shift_Left (CRC, 1) xor 16#1021#;
            else
               CRC := Shift_Left (CRC, 1);
            end if;
         end loop;
      end loop;

      --  The ADSBee prints the CRC with its bytes swapped
      return Shift_Left (CRC, 8) or Shift_Right (CRC, 8);
   end CRC16;

   ------------------
   -- Field parsers --
   ------------------

   --  Each returns Good = False instead of raising on bad input

   procedure Parse_Hex
     (Text : String; Value : out Unsigned_32; Good : out Boolean)
   is
      Digit : Unsigned_32;
   begin
      Value := 0;
      Good  := Text'Length in 1 .. 8;

      if not Good then
         return;
      end if;

      for C of Text loop
         case C is
            when '0' .. '9' =>
               Digit := Character'Pos (C) - Character'Pos ('0');
            when 'A' .. 'F' =>
               Digit := Character'Pos (C) - Character'Pos ('A') + 10;
            when 'a' .. 'f' =>
               Digit := Character'Pos (C) - Character'Pos ('a') + 10;
            when others =>
               Good := False;
               return;
         end case;

         Value := Shift_Left (Value, 4) or Digit;
      end loop;
   end Parse_Hex;

   --  Optional '-', then 1 to 9 digits (always fits in Integer)
   procedure Parse_Int (Text : String; Value : out Integer; Good : out Boolean)
   is
      First    : Integer := Text'First;
      Negative : Boolean := False;
   begin
      Value := 0;

      if Text'Length > 0 and then Text (First) = '-' then
         Negative := True;
         First    := First + 1;
      end if;

      Good := Text'Last - First + 1 in 1 .. 9;

      if not Good then
         return;
      end if;

      for C of Text (First .. Text'Last) loop
         if C not in '0' .. '9' then
            Good := False;
            return;
         end if;

         Value := Value * 10 + (Character'Pos (C) - Character'Pos ('0'));
      end loop;

      if Negative then
         Value := -Value;
      end if;
   end Parse_Int;

   --  Optional '-', up to 4 whole digits, optional '.' and up to 9 decimals
   procedure Parse_Decimal
     (Text : String; Value : out Long_Float; Good : out Boolean)
   is
      First    : Integer    := Text'First;
      Negative : Boolean    := False;
      Seen_Dot : Boolean    := False;
      Whole    : Natural    := 0;
      Decimals : Natural    := 0;
      Scale    : Long_Float := 1.0;
      Frac     : Long_Float := 0.0;
   begin
      Value := 0.0;

      if Text'Length > 0 and then Text (First) = '-' then
         Negative := True;
         First    := First + 1;
      end if;

      Good := Text'Last - First + 1 in 1 .. 14;

      if not Good then
         return;
      end if;

      for C of Text (First .. Text'Last) loop
         if C = '.' and then not Seen_Dot then
            Seen_Dot := True;
         elsif C in '0' .. '9' then
            if Seen_Dot then
               Decimals := Decimals + 1;
               if Decimals > 9 then
                  Good := False;
                  return;
               end if;
               Scale := Scale / 10.0;
               Frac  :=
                 Frac +
                 Long_Float (Character'Pos (C) - Character'Pos ('0')) * Scale;
            else
               if Whole > 999 then
                  Good := False;  --  more than 4 whole digits
                  return;
               end if;
               Whole := Whole * 10 + (Character'Pos (C) - Character'Pos ('0'));
            end if;
         else
            Good := False;
            return;
         end if;
      end loop;

      Value := Long_Float (Whole) + Frac;
      if Negative then
         Value := -Value;
      end if;
   end Parse_Decimal;

   -----------
   -- Parse --
   -----------

   procedure Parse
     (Line : String; Report : out Aircraft_Report; Result : out Parse_Result)
   is
      --  Start and end of each field (inclusive) within Line
      type Bounds is record
         First, Last : Integer;
      end record;
      Fields : array (1 .. Field_Count) of Bounds;

      Last_Comma : Natural := 0;
      Count      : Natural := 0;
      Start      : Integer;
      Sent_CRC   : Unsigned_32;
      Hex_Value  : Unsigned_32;
      Good       : Boolean;

      function Text (N : Positive) return String is
        (Line (Fields (N).First .. Fields (N).Last));
   begin
      Report := (others => <>);
      Result := Bad_Format;

      if Line'Length < 4 or else Line (Line'First) /= '#'
        or else Line (Line'First + 2) /= ':'
      then
         Result := Not_Aircraft;
         return;
      end if;

      case Line (Line'First + 1) is
         when 'A' =>
            Report.Source := Mode_S;
         when 'U' =>
            Report.Source := UAT;
         when others =>
            Result := Not_Aircraft;
            return;
      end case;

      --  Checksum: the text after the last comma
      for I in reverse Line'Range loop
         if Line (I) = ',' then
            Last_Comma := I;
            exit;
         end if;
      end loop;

      if Last_Comma = 0 then
         return;
      end if;

      Parse_Hex (Line (Last_Comma + 1 .. Line'Last), Sent_CRC, Good);
      if not Good or else Sent_CRC > 16#FFFF# then
         return;
      end if;

      if Unsigned_16 (Sent_CRC) /= CRC16 (Line (Line'First .. Last_Comma)) then
         Result := Bad_Checksum;
         return;
      end if;

      --  Split the fields between "#A:" and the last comma
      Start := Line'First + 3;
      for I in Start .. Last_Comma loop
         if Line (I) = ',' then
            Count := Count + 1;
            if Count > Field_Count then
               return;
            end if;
            Fields (Count) := (First => Start, Last => I - 1);
            Start          := I + 1;
         end if;
      end loop;

      if Count /= Field_Count then
         return;
      end if;

      --  1 ICAO address, 2 flags
      Parse_Hex (Text (1), Report.ICAO, Good);
      if not Good or else Report.ICAO > 16#FF_FFFF# then
         return;
      end if;

      Parse_Hex (Text (2), Hex_Value, Good);
      if not Good then
         return;
      end if;
      Report.Flags := Hex_Value;

      --  3 callsign: "?" when unknown, space-padded otherwise
      declare
         Call : constant String := Text (3);
         Len  : Natural         := 0;
      begin
         if Call /= "?" then
            for C of Call loop
               exit when C = ' ';
               if C not in '0' .. '9' | 'A' .. 'Z' | 'a' .. 'z' | '-'
                 or else Len = Max_Callsign
               then
                  return;
               end if;
               Len                   := Len + 1;
               Report.Callsign (Len) := C;
            end loop;
         end if;
         Report.Callsign_Len := Len;
      end;

      --  6, 7 position
      Parse_Decimal (Text (6), Report.Latitude, Good);
      if not Good or else abs Report.Latitude > 90.0 then
         return;
      end if;

      Parse_Decimal (Text (7), Report.Longitude, Good);
      if not Good or else abs Report.Longitude > 180.0 then
         return;
      end if;

      --  8 .. 13 altitudes, direction, speed, vertical rates
      Parse_Int (Text (8), Report.Baro_Alt_Ft, Good);
      if not Good then
         return;
      end if;
      Parse_Int (Text (9), Report.GNSS_Alt_Ft, Good);
      if not Good then
         return;
      end if;
      Parse_Int (Text (10), Report.Direction_Deg, Good);
      if not Good or else Report.Direction_Deg not in 0 .. 360 then
         return;
      end if;
      Parse_Int (Text (11), Report.Speed_Kt, Good);
      if not Good then
         return;
      end if;
      Parse_Int (Text (12), Report.Baro_VRate_Fpm, Good);
      if not Good then
         return;
      end if;
      Parse_Int (Text (13), Report.GNSS_VRate_Fpm, Good);
      if not Good then
         return;
      end if;

      Result := OK;
   end Parse;

end CSBee;
