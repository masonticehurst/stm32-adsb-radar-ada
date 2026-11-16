package body Text_Format is

   ---------
   -- Img --
   ---------

   function Img (N : Integer) return String is
      S : constant String := Integer'Image (N);
   begin
      return (if S (S'First) = ' ' then S (S'First + 1 .. S'Last) else S);
   end Img;

   -------------
   -- Grouped --
   -------------

   function Grouped (N : Integer) return String is
      Digits_Text : constant String :=
        Img (if N = Integer'First then Integer'Last else abs N);
      Result : String (1 .. Digits_Text'Length * 2);
      Len    : Natural := 0;
   begin
      for I in Digits_Text'Range loop
         --  A comma before every group of three counted from the right
         if I /= Digits_Text'First
           and then (Digits_Text'Last - I + 1) mod 3 = 0
         then
            Len          := Len + 1;
            Result (Len) := ',';
         end if;
         Len          := Len + 1;
         Result (Len) := Digits_Text (I);
      end loop;

      return (if N < 0 then "-" else "") & Result (1 .. Len);
   end Grouped;

   ----------
   -- Hex6 --
   ----------

   function Hex6 (Value : Unsigned_32) return String is
      Hex    : constant String := "0123456789ABCDEF";
      Result : String (1 .. 6);
   begin
      for I in Result'Range loop
         Result (I) :=
           Hex (Natural (Shift_Right (Value, 4 * (6 - I)) and 16#F#) + 1);
      end loop;
      return Result;
   end Hex6;

   ----------
   -- Hex8 --
   ----------

   function Hex8 (Value : Unsigned_32) return String is
   begin
      return
        Hex6 (Shift_Right (Value, 8)) (1 .. 4) &
        Hex6 (Value and 16#FFFF#) (3 .. 6);
   end Hex8;

   -------------
   -- Degrees --
   -------------

   function Degrees
     (Value     : Long_Float; Positive : Character; Negative : Character;
      Int_Width : Natural) return String
   is
      Scale : constant := 100_000;
      --  Round, don't truncate: 41.45654 * 100000 is 4145653.99999...
      --  in binary floating point
      Scaled : constant Long_Integer :=
        Long_Integer (Long_Float'Rounding (abs Value * Long_Float (Scale)));
      Whole  : constant String := Img (Integer (Scaled / Scale));
      Frac   : constant String := Img (Integer (Scaled mod Scale) + Scale);
      Pad    : constant String (1 .. Int_Width) := (others => '0');
      Padded : constant String                  :=
        (if Whole'Length < Int_Width then
           Pad (1 .. Int_Width - Whole'Length) & Whole
         else Whole);
   begin
      --  Frac is Scale + fraction, so drop its leading "1"
      return
        Padded & "." & Frac (Frac'First + 1 .. Frac'Last) &
        (if Value < 0.0 then Negative else Positive);
   end Degrees;

   ------------
   -- Tenths --
   ------------

   function Tenths (Value : Long_Float) return String is
      Scaled : constant Integer :=
        Integer (Long_Float'Rounding (abs Value * 10.0));
   begin
      return
        (if Value < 0.0 and then Scaled > 0 then "-" else "") &
        Img (Scaled / 10) & "." & Img (Scaled mod 10);
   end Tenths;

end Text_Format;
